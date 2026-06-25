<#
.SYNOPSIS
    Modifies the SQL Server license type for SQL Server on Azure Virtual Machines across
    one or more subscriptions.

.DESCRIPTION
    This script scans SQL Server VMs (resources of type Microsoft.SqlVirtualMachine/SqlVirtualMachines)
    in the specified scope and converts them from Azure Hybrid Benefit (AHUB) or Paid to
    Pay-as-you-go (PAYG), or sets any supported license type. It supports filtering by
    subscription, resource group, or VM name, and can exclude resources by tags.

    License type values for SQL Server on Azure VMs:
      PAYG   - Pay-as-you-go. SQL Server license cost is included in the VM billing.
      AHUB   - Azure Hybrid Benefit. Use your on-premises SQL Server license (SA required).
      DR     - Disaster Recovery replica. Free license for passive DR replicas.

    Note: The VM must be registered with the SQL IaaS Agent Extension (at least Lightweight
    mode) to appear as a SqlVirtualMachine resource. VMs not registered will not be returned.

.PARAMETER SubId
    Optional. A single subscription ID or the path to a CSV file containing a list of
    subscription IDs (column name: SubscriptionId). If omitted, all accessible subscriptions
    in the current tenant are scanned.

.PARAMETER ResourceGroup
    Optional. Limits the scope to a specific resource group name.

.PARAMETER VMName
    Optional. Limits the scope to a specific SQL VM name. Requires -ResourceGroup when specified.

.PARAMETER LicenseType
    Optional. The target license type to set. Allowed values: "PAYG", "AHUB", "DR".
    If -DisableAHUB is specified, this is overridden to "PAYG".

.PARAMETER DisableAHUB
    Optional switch. When specified, the script finds all SQL VMs with Azure Hybrid Benefit
    (AHUB) enabled and converts them to Pay-as-you-go (PAYG).
    Equivalent to specifying -LicenseType PAYG -Force.

.PARAMETER Force
    Optional switch. When specified, the license type is updated on all SQL VMs regardless
    of their current setting. Without -Force, only VMs that currently differ from the target
    license type are modified.

.PARAMETER ExclusionTags
    Optional. A JSON string of tags used to exclude resources from modification.
    Example: '{"Environment":"Dev","Owner":"TestTeam"}'
    Resources that have ANY of the specified tag key-value pairs will be skipped.

.PARAMETER TenantId
    Optional. The Azure Entra ID (AAD) tenant ID to use for authentication. If not specified,
    the current login context tenant is used.

.PARAMETER ReportOnly
    Optional switch. When specified, the script generates a CSV report of SQL VMs that would
    be modified, but does NOT make any changes.

.PARAMETER UseManagedIdentity
    Optional switch. When specified, authenticates using a managed identity. Required when
    running as an Azure Automation runbook or from an Azure resource with a managed identity.

.EXAMPLE
    # Report which SQL VMs would be converted from AHUB to PAYG across all subscriptions
    .\Set-SqlVMLicenseType.ps1 -TenantId "<tenant_id>" -DisableAHUB -ReportOnly

.EXAMPLE
    # Disable AHUB on all SQL VMs in a specific subscription
    .\Set-SqlVMLicenseType.ps1 -SubId "<sub_id>" -DisableAHUB -Force

.EXAMPLE
    # Set all SQL VMs in a resource group to PAYG
    .\Set-SqlVMLicenseType.ps1 -SubId "<sub_id>" -ResourceGroup "<rg_name>" -LicenseType PAYG -Force

.EXAMPLE
    # Disable AHUB on a specific VM, excluding Dev-tagged resources
    .\Set-SqlVMLicenseType.ps1 -SubId "<sub_id>" -ResourceGroup "<rg_name>" -VMName "<vm_name>" -DisableAHUB -Force -ExclusionTags '{"Environment":"Dev"}'

.EXAMPLE
    # Process a list of subscriptions from a CSV file using managed identity
    .\Set-SqlVMLicenseType.ps1 -SubId "subscriptions.csv" -DisableAHUB -Force -UseManagedIdentity

.NOTES
    Required PowerShell Modules: Az.Accounts, Az.SqlVirtualMachine
    Required RBAC Role: SQL Virtual Machine Contributor (or Contributor) on each subscription/resource group modified.

    Only SQL VMs registered with the SQL IaaS Agent Extension are visible. To register all
    VMs in a subscription with the extension, run:
      Register-AzSqlVMWithSqlIaasExtension -SubscriptionId "<sub_id>"

    The CSV file for -SubId must contain a column named "SubscriptionId".
#>

[CmdletBinding(SupportsShouldProcess)]
param (
    [Parameter(Mandatory = $false)]
    [string] $SubId,

    [Parameter(Mandatory = $false)]
    [string] $ResourceGroup,

    [Parameter(Mandatory = $false)]
    [string] $VMName,

    [Parameter(Mandatory = $false)]
    [ValidateSet("PAYG", "AHUB", "DR", IgnoreCase = $false)]
    [string] $LicenseType,

    [Parameter(Mandatory = $false)]
    [switch] $DisableAHUB,

    [Parameter(Mandatory = $false)]
    [switch] $Force,

    [Parameter(Mandatory = $false)]
    [object] $ExclusionTags,

    [Parameter(Mandatory = $false)]
    [string] $TenantId,

    [Parameter(Mandatory = $false)]
    [switch] $ReportOnly,

    [Parameter(Mandatory = $false)]
    [switch] $UseManagedIdentity
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Start-Transcript -Path ".\Set-SqlVMLicenseType.log" -Append
$scriptStartTime = Get-Date
Write-Output "Script execution started at: $($scriptStartTime.ToString('yyyy-MM-dd HH:mm:ss'))"

#region --- Parameter validation ---
if ($DisableAHUB) {
    $LicenseType = "PAYG"
    $Force = $true
    Write-Output "-DisableAHUB specified: targeting LicenseType=PAYG with -Force."
}

if (-not $LicenseType) {
    Write-Error "You must specify either -LicenseType or -DisableAHUB."
    Stop-Transcript
    exit 1
}

if ($VMName -and -not $ResourceGroup) {
    Write-Error "-VMName requires -ResourceGroup to be specified."
    Stop-Transcript
    exit 1
}
#endregion

#region --- Helper: Connect to Azure ---
function Connect-AzureContext {
    param(
        [string] $TenantId,
        [switch] $UseManagedIdentity
    )

    $isAutomation = ($env:AZUREPS_HOST_ENVIRONMENT -like "AzureAutomation*") -or $PSPrivateMetadata.JobId
    if ($isAutomation) { $UseManagedIdentity = $true }

    $currentCtx = Get-AzContext -ErrorAction SilentlyContinue
    if ($currentCtx -and $currentCtx.Account) {
        if ($TenantId -and $currentCtx.Tenant.Id -ne $TenantId) {
            Write-Output "Switching context to tenant $TenantId..."
            $null = Set-AzContext -Tenant $TenantId -ErrorAction SilentlyContinue
            if ((Get-AzContext).Tenant.Id -ne $TenantId) {
                if ($UseManagedIdentity) {
                    Connect-AzAccount -Identity -Tenant $TenantId | Out-Null
                } else {
                    Connect-AzAccount -Tenant $TenantId | Out-Null
                }
            }
        } else {
            Write-Output "Using existing Azure context: $($currentCtx.Account) in tenant $($currentCtx.Tenant.Id)"
        }
    } else {
        if ($UseManagedIdentity) {
            $loginArgs = @{ Identity = $true }
            if ($TenantId) { $loginArgs.Tenant = $TenantId }
            Connect-AzAccount @loginArgs | Out-Null
        } else {
            $loginArgs = @{}
            if ($TenantId) { $loginArgs.Tenant = $TenantId }
            Connect-AzAccount @loginArgs | Out-Null
        }
    }
    $ctx = Get-AzContext
    Write-Output "Connected as: $($ctx.Account) | Tenant: $($ctx.Tenant.Id)"
}
#endregion

#region --- Parse exclusion tags ---
$tagTable = @{}
if ($null -ne $ExclusionTags) {
    if ($ExclusionTags -is [hashtable]) {
        $tagTable = $ExclusionTags
    } else {
        ($ExclusionTags | ConvertFrom-Json).PSObject.Properties | ForEach-Object {
            $tagTable[$_.Name] = $_.Value
        }
    }
}
#endregion

#region --- Connect to Azure ---
$connectArgs = @{}
if ($TenantId) { $connectArgs.TenantId = $TenantId }
if ($UseManagedIdentity) { $connectArgs.UseManagedIdentity = $true }
Connect-AzureContext @connectArgs

$context = Get-AzContext
if (-not $TenantId) { $TenantId = $context.Tenant.Id }
#endregion

#region --- Import required modules ---
foreach ($module in @("Az.Accounts", "Az.SqlVirtualMachine")) {
    try { Import-Module $module -ErrorAction SilentlyContinue }
    catch { Write-Warning "Could not import module $module. Ensure Az PowerShell is installed." }
}
#endregion

#region --- Resolve subscriptions ---
if ($SubId -like "*.csv") {
    $subscriptions = Import-Csv $SubId | ForEach-Object {
        Get-AzSubscription -SubscriptionId $_.SubscriptionId -TenantId $TenantId -ErrorAction SilentlyContinue
    }
} elseif ($SubId) {
    $subscriptions = @(Get-AzSubscription -SubscriptionId $SubId -TenantId $TenantId)
} else {
    $subscriptions = Get-AzSubscription -TenantId $TenantId | Where-Object { $_.State -eq "Enabled" }
}
Write-Output "Processing $($subscriptions.Count) subscription(s)."
#endregion

#region --- Helper: Test exclusion tags ---
function Test-ExcludedByTags {
    param([hashtable] $ResourceTags, [hashtable] $ExclusionMap)
    foreach ($key in $ExclusionMap.Keys) {
        if ($ResourceTags -and $ResourceTags.ContainsKey($key) -and $ResourceTags[$key] -eq $ExclusionMap[$key]) {
            return $true
        }
    }
    return $false
}
#endregion

$modifiedResources = [System.Collections.Generic.List[PSCustomObject]]::new()
$skippedResources  = [System.Collections.Generic.List[PSCustomObject]]::new()

#region --- Main processing loop ---
foreach ($sub in $subscriptions) {
    if ($sub.State -ne "Enabled") {
        Write-Output "Skipping disabled subscription: $($sub.Id)"
        continue
    }

    try {
        Set-AzContext -SubscriptionId $sub.Id -TenantId $TenantId | Out-Null
    } catch {
        Write-Warning "Could not set context for subscription $($sub.Id): $_"
        continue
    }

    Write-Output "`n=== Subscription: $($sub.Name) ($($sub.Id)) ==="

    # Enumerate SQL VMs
    try {
        if ($VMName -and $ResourceGroup) {
            $sqlVMs = @(Get-AzSqlVM -Name $VMName -ResourceGroupName $ResourceGroup -ErrorAction Stop)
        } elseif ($ResourceGroup) {
            $sqlVMs = Get-AzSqlVM -ResourceGroupName $ResourceGroup -ErrorAction Stop
        } else {
            $sqlVMs = Get-AzSqlVM -ErrorAction Stop
        }
    } catch {
        Write-Warning "Failed to list SQL VMs in subscription $($sub.Id): $_"
        continue
    }

    Write-Output "Found $($sqlVMs.Count) SQL VM(s)."

    foreach ($vm in $sqlVMs) {
        # Check exclusion tags
        if ($tagTable.Count -gt 0 -and (Test-ExcludedByTags -ResourceTags $vm.Tags -ExclusionMap $tagTable)) {
            Write-Output "  SKIPPED (tag exclusion): $($vm.Name)"
            continue
        }

        $currentLicense = $vm.SqlServerLicenseType
        $needsUpdate = $Force -or ($currentLicense -ne $LicenseType)

        $record = [PSCustomObject]@{
            TenantId            = $TenantId
            SubscriptionId      = $sub.Id
            SubscriptionName    = $sub.Name
            ResourceGroup       = $vm.ResourceGroupName
            VMName              = $vm.Name
            CurrentLicenseType  = $currentLicense
            TargetLicenseType   = $LicenseType
            SQLImageOffer       = $vm.SqlImageOffer
            SQLImageSku         = $vm.SqlImageSku
            Location            = $vm.Location
            Action              = if ($needsUpdate) { "Modify" } else { "NoChange" }
        }

        if (-not $needsUpdate) {
            Write-Output "  NO CHANGE: $($vm.Name) (already $currentLicense)"
            $skippedResources.Add($record)
            continue
        }

        Write-Output "  $(if ($ReportOnly) { '[ReportOnly] Would modify' } else { 'Modifying' }): $($vm.Name) [$currentLicense -> $LicenseType]"

        if (-not $ReportOnly) {
            try {
                Update-AzSqlVM -Name $vm.Name `
                    -ResourceGroupName $vm.ResourceGroupName `
                    -LicenseType $LicenseType | Out-Null
                $record.Action = "Modified"
                Write-Output "    Updated successfully."
            } catch {
                Write-Warning "    Failed to update $($vm.Name): $_"
                $record.Action = "Failed"
            }
        }

        $modifiedResources.Add($record)
    }
}
#endregion

#region --- Export report ---
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
if ($modifiedResources.Count -gt 0) {
    $csvPath = ".\SqlVM_LicenseChange_$timestamp.csv"
    $modifiedResources | Export-Csv -Path $csvPath -NoTypeInformation
    Write-Output "`nReport saved to: $csvPath"
    Write-Output "Total SQL VMs targeted for modification: $($modifiedResources.Count)"
} else {
    Write-Output "`nNo SQL VMs required modification."
}
#endregion

$scriptEndTime = Get-Date
Write-Output "Script completed at: $($scriptEndTime.ToString('yyyy-MM-dd HH:mm:ss'))"
Write-Output "Total duration: $(($scriptEndTime - $scriptStartTime).ToString('hh\:mm\:ss'))"
Stop-Transcript
