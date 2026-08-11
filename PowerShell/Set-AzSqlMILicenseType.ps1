<#
.SYNOPSIS
    Modifies the license type for Azure SQL Managed Instances across one or more subscriptions.

.DESCRIPTION
    This script scans Azure SQL Managed Instances in the specified scope and converts them from
    Azure Hybrid Benefit (BasePrice) to Pay-as-you-go (LicenseIncluded), or sets any supported
    license type. It supports filtering by subscription, resource group, or instance name, and
    can exclude resources by tags.

    License type values for Azure SQL Managed Instance:
      LicenseIncluded  - Pay-as-you-go (PAYG). You pay for SQL Server license + compute.
      BasePrice        - Azure Hybrid Benefit (AHB). You bring your own SQL Server license.

.PARAMETER SubId
    Optional. A single subscription ID or the path to a CSV file containing a list of
    subscription IDs (column name: SubscriptionId). If omitted, all accessible subscriptions
    in the current tenant are scanned.

.PARAMETER ResourceGroup
    Optional. Limits the scope to a specific resource group name.

.PARAMETER InstanceName
    Optional. Limits the scope to a specific SQL Managed Instance name.

.PARAMETER LicenseType
    Optional. The target license type to set. Allowed values: "LicenseIncluded", "BasePrice".
    If -DisableAHUB is also specified, this is overridden to "LicenseIncluded".

.PARAMETER DisableAHUB
    Optional switch. When specified, the script finds all managed instances with Azure Hybrid
    Benefit (BasePrice) enabled and converts them to Pay-as-you-go (LicenseIncluded).
    Equivalent to specifying -LicenseType LicenseIncluded -Force.

.PARAMETER Force
    Optional switch. When specified, the license type is updated on all managed instances
    regardless of their current setting. Without -Force, only instances that currently differ
    from the target license type are modified.

.PARAMETER ExclusionTags
    Optional. A JSON string of tags used to exclude resources from modification.
    Example: '{"Environment":"Dev","Owner":"TestTeam"}'
    Resources that have ANY of the specified tag key-value pairs will be skipped.

.PARAMETER TenantId
    Optional. The Azure Entra ID (AAD) tenant ID to use for authentication. If not specified,
    the current login context tenant is used.

.PARAMETER ReportOnly
    Optional switch. When specified, the script generates a CSV report of instances that
    would be modified, but does NOT make any changes.

.PARAMETER UseManagedIdentity
    Optional switch. When specified, authenticates using a managed identity. Required when
    running as an Azure Automation runbook or from an Azure resource with a managed identity.

.EXAMPLE
    # Report which managed instances would be converted from AHB to PAYG across all subscriptions
    .\Set-AzSqlMILicenseType.ps1 -TenantId "<tenant_id>" -DisableAHUB -ReportOnly

.EXAMPLE
    # Disable AHB on all managed instances in a specific subscription
    .\Set-AzSqlMILicenseType.ps1 -SubId "<sub_id>" -DisableAHUB -Force

.EXAMPLE
    # Set all managed instances in a resource group to LicenseIncluded (PAYG)
    .\Set-AzSqlMILicenseType.ps1 -SubId "<sub_id>" -ResourceGroup "<rg_name>" -LicenseType LicenseIncluded -Force

.EXAMPLE
    # Disable AHB on a specific instance, excluding Dev-tagged resources
    .\Set-AzSqlMILicenseType.ps1 -SubId "<sub_id>" -InstanceName "<mi_name>" -ResourceGroup "<rg_name>" -DisableAHUB -Force -ExclusionTags '{"Environment":"Dev"}'

.EXAMPLE
    # Process a list of subscriptions from a CSV file using managed identity
    .\Set-AzSqlMILicenseType.ps1 -SubId "subscriptions.csv" -DisableAHUB -Force -UseManagedIdentity

.NOTES
    Required PowerShell Modules: Az.Accounts, Az.Sql
    Required RBAC Role: SQL Managed Instance Contributor (or Contributor) on each subscription/resource group modified.

    The CSV file for -SubId must contain a column named "SubscriptionId".
    Example subscriptions.csv:
      SubscriptionId
      xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
      yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy
#>

[CmdletBinding(SupportsShouldProcess)]
param (
    [Parameter(Mandatory = $false)]
    [string] $SubId,

    [Parameter(Mandatory = $false)]
    [string] $ResourceGroup,

    [Parameter(Mandatory = $false)]
    [string] $InstanceName,

    [Parameter(Mandatory = $false)]
    [ValidateSet("LicenseIncluded", "BasePrice", IgnoreCase = $false)]
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

Start-Transcript -Path ".\Set-AzSqlMILicenseType.log" -Append
$scriptStartTime = Get-Date
Write-Output "Script execution started at: $($scriptStartTime.ToString('yyyy-MM-dd HH:mm:ss'))"

#region --- Parameter validation ---
if ($DisableAHUB) {
    $LicenseType = "LicenseIncluded"
    Write-Output "-DisableAHUB specified: only instances currently using BasePrice will be changed to LicenseIncluded (PAYG)."
}

if (-not $LicenseType) {
    Write-Error "You must specify either -LicenseType or -DisableAHUB."
    Stop-Transcript
    exit 1
}

if ($InstanceName -and -not $ResourceGroup) {
    Write-Error "-InstanceName requires -ResourceGroup to identify the managed instance."
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
foreach ($module in @("Az.Accounts", "Az.Sql")) {
    try { Import-Module $module -ErrorAction Stop }
    catch { throw "Could not import required module '$module'. Install or update the Az PowerShell modules before running this script. $($_.Exception.Message)" }
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

    # Enumerate Managed Instances
    try {
        if ($InstanceName -and $ResourceGroup) {
            $instances = @(Get-AzSqlInstance -Name $InstanceName -ResourceGroupName $ResourceGroup -ErrorAction Stop)
        } elseif ($ResourceGroup) {
            $instances = Get-AzSqlInstance -ResourceGroupName $ResourceGroup -ErrorAction Stop
        } else {
            $instances = Get-AzSqlInstance -ErrorAction Stop
        }
    } catch {
        Write-Warning "Failed to list SQL Managed Instances in subscription $($sub.Id): $_"
        continue
    }

    Write-Output "Found $($instances.Count) Managed Instance(s)."

    foreach ($instance in $instances) {
        # Check exclusion tags
        if ($tagTable.Count -gt 0 -and (Test-ExcludedByTags -ResourceTags $instance.Tags -ExclusionMap $tagTable)) {
            Write-Output "  SKIPPED (tag exclusion): $($instance.ManagedInstanceName)"
            continue
        }

        $currentLicense = $instance.LicenseType
        $needsUpdate = (($Force -or ($currentLicense -ne $LicenseType)) -and
            (-not $DisableAHUB -or $currentLicense -eq "BasePrice"))

        $record = [PSCustomObject]@{
            TenantId            = $TenantId
            SubscriptionId      = $sub.Id
            SubscriptionName    = $sub.Name
            ResourceGroup       = $instance.ResourceGroupName
            InstanceName        = $instance.ManagedInstanceName
            CurrentLicenseType  = $currentLicense
            TargetLicenseType   = $LicenseType
            SKU                 = $instance.Sku.Name
            Location            = $instance.Location
            Action              = if ($needsUpdate) { "Modify" } else { "NoChange" }
        }

        if (-not $needsUpdate) {
            Write-Output "  NO CHANGE: $($instance.ManagedInstanceName) (already $currentLicense)"
            $skippedResources.Add($record)
            continue
        }

        Write-Output "  $(if ($ReportOnly) { '[ReportOnly] Would modify' } else { 'Modifying' }): $($instance.ManagedInstanceName) [$currentLicense -> $LicenseType]"

        if (-not $ReportOnly) {
            if ($PSCmdlet.ShouldProcess(
                "$($instance.ResourceGroupName)/$($instance.ManagedInstanceName)",
                "Set license type to $LicenseType")) {
                try {
                    Set-AzSqlInstance -Name $instance.ManagedInstanceName `
                        -ResourceGroupName $instance.ResourceGroupName `
                        -LicenseType $LicenseType `
                        -Force | Out-Null
                    $record.Action = "Modified"
                    Write-Output "    Updated successfully."
                } catch {
                    Write-Warning "    Failed to update $($instance.ManagedInstanceName): $_"
                    $record.Action = "Failed"
                }
            } else {
                $record.Action = "WhatIf"
            }
        }

        $modifiedResources.Add($record)
    }
}
#endregion

#region --- Export report ---
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
if ($modifiedResources.Count -gt 0) {
    $csvPath = ".\SqlMI_LicenseChange_$timestamp.csv"
    $modifiedResources | Export-Csv -Path $csvPath -NoTypeInformation
    Write-Output "`nReport saved to: $csvPath"
    Write-Output "Total instances targeted for modification: $($modifiedResources.Count)"
} else {
    Write-Output "`nNo managed instances required modification."
}
#endregion

$scriptEndTime = Get-Date
Write-Output "Script completed at: $($scriptEndTime.ToString('yyyy-MM-dd HH:mm:ss'))"
Write-Output "Total duration: $(($scriptEndTime - $scriptStartTime).ToString('hh\:mm\:ss'))"
Stop-Transcript
