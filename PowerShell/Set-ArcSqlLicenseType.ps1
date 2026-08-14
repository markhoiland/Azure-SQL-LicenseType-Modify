<#
.SYNOPSIS
    Modifies the license type and related settings for Azure Arc-enabled SQL Server instances
    across one or more subscriptions.

.DESCRIPTION
    This script scans Azure Arc-enabled SQL Server extension resources in the specified scope
    and updates their license type, ESU policy, unlimited virtualization (p-core) license, and/or
    PAYG recurring billing consent. It supports filtering by subscription, resource group, or
    machine name, and can exclude resources by tags.

    This script is based on the Microsoft sql-server-samples reference implementation:
    https://github.com/microsoft/sql-server-samples/tree/master/samples/manage/azure-arc-enabled-sql-server/modify-license-type

    License type values for Azure Arc-enabled SQL Server:
      PAYG        - Pay-as-you-go. SQL Server usage is billed hourly through Azure.
      Paid        - Paid (Software Assurance / SA). Traditional license with SA.
      LicenseOnly - License only (no SA). Use for servers with a perpetual license, no SA.

.PARAMETER SubId
    Optional. A single subscription ID or the path to a CSV file containing subscription IDs
    (column name: SubscriptionId). If omitted, all accessible subscriptions in the current
    tenant are scanned.

.PARAMETER ResourceGroup
    Optional. Limits the scope to a specific resource group name.

.PARAMETER MachineName
    Optional. A single machine name or the path to a CSV file containing machine names
    (column name: MachineName).

.PARAMETER LicenseType
    Optional. The target license type to set. Allowed values: "PAYG", "Paid", "LicenseOnly".

.PARAMETER ConsentToRecurringPAYG
    Optional. Consents to enabling recurring PAYG billing for CSP subscriptions.
    Allowed values: "Yes", "No". Requires LicenseType to be "PAYG".

.PARAMETER UsePcoreLicense
    Optional. Enables ("Yes") or disables ("No") the unlimited virtualization license.
    Allowed values: "Yes", "No". To enable, LicenseType must be "Paid" or "PAYG".

.PARAMETER EnableESU
    Optional. Enables ("Yes") or disables ("No") the Extended Security Updates (ESU) policy.
    Allowed values: "Yes", "No". To enable, LicenseType must be "Paid" or "PAYG".

.PARAMETER Force
    Optional switch. Forces the license type change on all extensions regardless of current
    setting. Without -Force, the license type is only set if it is currently undefined.

.PARAMETER ExclusionTags
    Optional. A JSON string of tags used to exclude resources from modification.
    Example: '{"Environment":"Dev","Owner":"TestTeam"}'

.PARAMETER TenantId
    Optional. The Azure Entra ID (AAD) tenant ID to use for authentication.

.PARAMETER ReportOnly
    Optional switch. Generates a CSV report of resources that would be modified, but does
    NOT make any changes.

.PARAMETER UseManagedIdentity
    Optional switch. Authenticates using a managed identity. Required when running as an
    Azure Automation runbook or from an Azure resource with a managed identity.

.EXAMPLE
    # Report which Arc SQL servers would have license type changed to PAYG
    .\Set-ArcSqlLicenseType.ps1 -TenantId "<tenant_id>" -LicenseType PAYG -ReportOnly

.EXAMPLE
    # Set license type to PAYG on all Arc SQL servers in a subscription
    .\Set-ArcSqlLicenseType.ps1 -SubId "<sub_id>" -LicenseType PAYG -Force

.EXAMPLE
    # Set license type to PAYG and enable ESU in a specific resource group
    .\Set-ArcSqlLicenseType.ps1 -SubId "<sub_id>" -ResourceGroup "<rg_name>" -LicenseType PAYG -EnableESU Yes -Force

.EXAMPLE
    # Set license type to PAYG with recurring PAYG consent (CSP subscriptions)
    .\Set-ArcSqlLicenseType.ps1 -LicenseType PAYG -ConsentToRecurringPAYG Yes -Force -UseManagedIdentity

.EXAMPLE
    # Disable ESU on all Arc SQL servers in a subscription
    .\Set-ArcSqlLicenseType.ps1 -SubId "<sub_id>" -EnableESU No

.EXAMPLE
    # Set license type to PAYG and enable p-core (unlimited virtualization) license
    .\Set-ArcSqlLicenseType.ps1 -SubId "<sub_id>" -ResourceGroup "<rg_name>" -LicenseType PAYG -UsePcoreLicense Yes -Force

.EXAMPLE
    # Process specific machines from a CSV file
    .\Set-ArcSqlLicenseType.ps1 -SubId "<sub_id>" -MachineName machines.csv -LicenseType PAYG -Force

.NOTES
    Required PowerShell Modules: Az.Accounts, Az.ConnectedMachine, Az.ResourceGraph
    Required RBAC Role: Azure Connected Machine Resource Administrator on each subscription modified.
    The Azure Extension for SQL Server must be version 1.1.2230.58 or newer.

    Machine CSV file format (column name: MachineName):
      MachineName
      Prod1
      Prod2

    Subscription CSV file format (column name: SubscriptionId):
      SubscriptionId
      xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
#>

[CmdletBinding(SupportsShouldProcess)]
param (
    [Parameter(Mandatory = $false)]
    [string] $SubId,

    [Parameter(Mandatory = $false)]
    [string] $ResourceGroup,

    [Parameter(Mandatory = $false)]
    [string] $MachineName,

    [Parameter(Mandatory = $false)]
    [ValidateSet("PAYG", "Paid", "LicenseOnly", IgnoreCase = $false)]
    [string] $LicenseType,

    [Parameter(Mandatory = $false)]
    [ValidateSet("Yes", "No", IgnoreCase = $false)]
    [string] $ConsentToRecurringPAYG,

    [Parameter(Mandatory = $false)]
    [ValidateSet("Yes", "No", IgnoreCase = $false)]
    [string] $UsePcoreLicense,

    [Parameter(Mandatory = $false)]
    [ValidateSet("Yes", "No", IgnoreCase = $false)]
    [string] $EnableESU,

    [Parameter(Mandatory = $false)]
    [switch] $Force,

    [Parameter(Mandatory = $false)]
    [object] $ExclusionTags,

    [Parameter(Mandatory = $false)]
    [string] $TenantId,

    [Parameter(Mandatory = $false)]
    [switch] $ReportOnly,

    [Parameter(Mandatory = $false)]
    [switch] $UseManagedIdentity,

    [Parameter(Mandatory = $false)]
    [int] $BatchSize = 500
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Start-Transcript -Path ".\Set-ArcSqlLicenseType.log" -Append
$scriptStartTime = Get-Date
Write-Output "Script execution started at: $($scriptStartTime.ToString('yyyy-MM-dd HH:mm:ss'))"

#region --- Parameter validation ---
if (-not $LicenseType -and -not $EnableESU -and -not $UsePcoreLicense -and -not $ConsentToRecurringPAYG) {
    Write-Error "You must specify at least one of: -LicenseType, -EnableESU, -UsePcoreLicense, or -ConsentToRecurringPAYG."
    Stop-Transcript
    exit 1
}

if ($LicenseType -eq "LicenseOnly" -and $EnableESU -eq "Yes") {
    Write-Error "ESU cannot be enabled when LicenseType is 'LicenseOnly'. Use 'Paid' or 'PAYG' instead."
    Stop-Transcript
    exit 1
}

if ($ConsentToRecurringPAYG -eq "Yes" -and $LicenseType -ne "PAYG") {
    Write-Warning "-ConsentToRecurringPAYG Yes is only effective when LicenseType is 'PAYG'."
}
#endregion

#region --- Helper: Connect to Azure ---
function Connect-AzureContext {
    param(
        [string] $TenantId,
        [switch] $UseManagedIdentity
    )

    $privateMetadata = Get-Variable -Name PSPrivateMetadata -ValueOnly -ErrorAction SilentlyContinue
    $isAutomation = ($env:AZUREPS_HOST_ENVIRONMENT -like "AzureAutomation*") -or
        ($null -ne $privateMetadata -and $null -ne $privateMetadata.JobId)
    if ($isAutomation) { $UseManagedIdentity = $true }

    # Use login V1 for compatibility
    Update-AzConfig -LoginExperienceV2 Off -ErrorAction SilentlyContinue

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
Write-Output "Using Tenant ID: $TenantId"
#endregion

#region --- Import required modules ---
foreach ($module in @("Az.Accounts", "Az.ConnectedMachine", "Az.ResourceGraph")) {
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

#region --- Resolve machine name filter ---
$machineNames = @()
if ($MachineName) {
    if ($MachineName -like "*.csv") {
        try {
            $machines = Import-Csv $MachineName
            foreach ($m in $machines) {
                if ($m.MachineName) { $machineNames += $m.MachineName }
            }
            Write-Output "Loaded $($machineNames.Count) machine name(s) from CSV."
        } catch {
            Write-Error "Failed to import machine names from CSV: $_"
            Stop-Transcript
            exit 1
        }
    } else {
        $machineNames += $MachineName
    }
}
#endregion

$modifiedResources = [System.Collections.Generic.List[PSCustomObject]]::new()

#region --- Main processing loop ---
Write-Output "`n-- Scanning subscriptions --"

foreach ($sub in $subscriptions) {
    if ($sub.State -ne "Enabled") {
        Write-Output "Skipping disabled subscription: $($sub.Id)"
        continue
    }

    try {
        Set-AzContext -SubscriptionId $sub.Id | Out-Null
    } catch {
        Write-Warning "Could not set context for subscription $($sub.Id): $_"
        continue
    }

    Write-Output "`n=== Subscription: $($sub.Name) ($($sub.Id)) ==="
    Write-Output "Collecting Arc-enabled SQL Server extensions..."

    # Build Resource Graph query to find Arc machines with SQL extension
    $licenseFilter = if ($LicenseType) { "| where properties.settings.LicenseType!='$LicenseType'" } else { "" }
    $rgFilter      = if ($ResourceGroup) { "| where resourceGroup =~ '$ResourceGroup'" } else { "" }
    $machineFilter = ""
    if ($machineNames.Count -gt 0) {
        $machineList = ($machineNames | ForEach-Object { "'$_'" }) -join ", "
        $machineFilter = "| where name in~ ($machineList)"
    }

    $query = @"
resources
| where subscriptionId =~ '$($sub.Id)'
| where type == 'microsoft.hybridcompute/machines'
| where properties.detectedProperties.mssqldiscovered == 'true'
$rgFilter
$machineFilter
| extend machineId = tolower(tostring(id))
| project machineId, machineName = tolower(name)
| join kind=inner (
    resources
    | where subscriptionId =~ '$($sub.Id)'
    | where type == 'microsoft.hybridcompute/machines/extensions'
    | where properties.publisher =~ 'Microsoft.AzureData'
    | where properties.provisioningState == 'Succeeded'
    $licenseFilter
    | extend extensionName = name
    | extend extensionPublisher = properties.publisher
    | extend extensionType = properties.type
    | parse id with '/subscriptions/' subId '/resourceGroups/' resourceGroup '/providers/Microsoft.HybridCompute/machines/' machineNameRaw '/extensions/' extName
    | extend machineName = tolower(machineNameRaw)
) on `$left.machineName == `$right.machineName
| project machineName, extensionName, resourceGroup, location, subscriptionId = subId, extensionPublisher, extensionType
| order by machineName asc
"@

    # Execute Resource Graph query with paging
    $allResults = [System.Collections.Generic.List[PSObject]]::new()
    $skipToken = $null
    do {
        try {
            $batch = Search-AzGraph -Query $query -First $BatchSize -SkipToken $skipToken -ErrorAction Stop
            $allResults.AddRange([PSObject[]]$batch)
            $skipToken = $batch.SkipToken
        } catch {
            Write-Warning "Resource Graph query failed for subscription $($sub.Id): $_"
            break
        }
    } while ($skipToken)

    Write-Output "Found $($allResults.Count) Arc SQL extension resource(s) to evaluate."

    foreach ($resource in $allResults) {
        Write-Output "  Processing: $($resource.machineName) / $($resource.extensionName)"

        # Get connected machine to check tags
        try {
            $machine = Get-AzConnectedMachine -Name $resource.machineName -ResourceGroup $resource.resourceGroup -ErrorAction Stop
        } catch {
            Write-Warning "  Could not retrieve machine $($resource.machineName): $_"
            continue
        }

        # Check exclusion tags
        $excludedByTags = $false
        foreach ($tag in $tagTable.Keys) {
            if ($machine.Tags -and $machine.Tags.ContainsKey($tag) -and $machine.Tags[$tag] -eq $tagTable[$tag]) {
                $excludedByTags = $true
                Write-Output "  SKIPPED (tag exclusion '$tag=$($tagTable[$tag])'): $($resource.machineName)"
                break
            }
        }
        if ($excludedByTags) { continue }

        # Get extension details
        try {
            $ext = Get-AzConnectedMachineExtension -Name $resource.extensionName `
                -ResourceGroupName $resource.resourceGroup `
                -MachineName $resource.machineName -ErrorAction Stop
        } catch {
            Write-Warning "  Could not retrieve extension for $($resource.machineName): $_"
            continue
        }

        if ($ext.ProvisioningState -ne "Succeeded") {
            Write-Output "  SKIPPED (extension not in Succeeded state): $($resource.machineName)"
            continue
        }

        # Record current state
        $modifiedResources.Add([PSCustomObject]@{
            TenantId            = $TenantId
            SubscriptionId      = $resource.subscriptionId
            MachineName         = $resource.machineName
            ExtensionType       = $resource.extensionType
            Status              = $machine.Status
            OriginalLicenseType = $ext.Setting["LicenseType"]
            TargetLicenseType   = $LicenseType
            ResourceGroup       = $resource.resourceGroup
            Location            = $resource.location
        })

        $writeSettings = $false
        $settings = $ext.Setting

        # ----- License type -----
        if ($LicenseType) {
            $loAllowed = (-not $settings["enableExtendedSecurityUpdates"] -and -not $EnableESU) -or ($EnableESU -eq "No")
            if ($LicenseType -eq "LicenseOnly" -and -not $loAllowed) {
                Write-Output "  SKIPPED: ESU must be disabled before setting LicenseType to LicenseOnly on $($resource.machineName)"
            } else {
                if ($settings["LicenseType"]) {
                    if ($Force) {
                        $settings["LicenseType"] = $LicenseType
                        $writeSettings = $true
                    }
                } else {
                    $settings["LicenseType"] = $LicenseType
                    $writeSettings = $true
                }
            }
        }

        # ----- ESU policy -----
        if ($EnableESU) {
            if (($settings["LicenseType"] -in @("Paid", "PAYG")) -or ($EnableESU -eq "No")) {
                $settings["enableExtendedSecurityUpdates"] = ($EnableESU -eq "Yes")
                $settings["esuLastUpdatedTimestamp"] = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
                $writeSettings = $true
            } else {
                Write-Output "  SKIPPED ESU change: configured license type does not support ESU on $($resource.machineName)"
            }
        }

        # ----- P-Core / Unlimited virtualization license -----
        if ($UsePcoreLicense) {
            if (($settings["LicenseType"] -in @("Paid", "PAYG")) -or ($UsePcoreLicense -eq "No")) {
                $settings["UsePhysicalCoreLicense"] = @{
                    "IsApplied"             = ($UsePcoreLicense -eq "Yes")
                    "LastUpdatedTimestamp"  = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
                }
                $writeSettings = $true
            } else {
                Write-Output "  SKIPPED p-core change: configured license type does not support unlimited virtualization on $($resource.machineName)"
            }
        }

        # ----- Recurring PAYG consent (CSP subscriptions) -----
        if ($ConsentToRecurringPAYG -eq "Yes") {
            $isPayg = ($LicenseType -eq "PAYG") -or ($settings["LicenseType"] -eq "PAYG")
            if ($isPayg) {
                if (-not $settings.ContainsKey("ConsentToRecurringPAYG") -or -not $settings["ConsentToRecurringPAYG"]["Consented"]) {
                    $settings["ConsentToRecurringPAYG"] = @{
                        "Consented"        = $true
                        "ConsentTimestamp" = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
                    }
                    $writeSettings = $true
                }
            }
        }

        if (-not $writeSettings) {
            Write-Output "  NO CHANGE needed for: $($resource.machineName)"
            continue
        }

        if ($ReportOnly) {
            Write-Output "  [ReportOnly] Would update: $($resource.machineName)"
        } elseif ($PSCmdlet.ShouldProcess(
            "$($resource.resourceGroup)/$($resource.machineName)/$($resource.extensionName)",
            "Update Azure Arc SQL license settings")) {
            try {
                $settingsHash = @{}
                foreach ($k in $settings.Keys) { $settingsHash[$k] = $settings[$k] }
                Set-AzConnectedMachineExtension `
                    -Name $resource.extensionName `
                    -ResourceGroupName $resource.resourceGroup `
                    -Location $resource.location `
                    -MachineName $resource.machineName `
                    -Publisher $resource.extensionPublisher `
                    -ExtensionType $resource.extensionType `
                    -Setting $settingsHash `
                    -NoWait | Out-Null
                Write-Output "  Updated: $($resource.machineName)"
            } catch {
                Write-Warning "  Failed to update $($resource.machineName): $_"
            }
        } else {
            Write-Output "  [WhatIf] Would update: $($resource.machineName)"
        }
    }
}
#endregion

#region --- Export report ---
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
if ($modifiedResources.Count -gt 0) {
    $csvPath = ".\ArcSql_LicenseChange_$timestamp.csv"
    $modifiedResources | Export-Csv -Path $csvPath -NoTypeInformation
    Write-Output "`nReport saved to: $csvPath"
    Write-Output "Total Arc SQL resources evaluated: $($modifiedResources.Count)"
} else {
    Write-Output "`nNo Arc SQL resources required modification."
}
#endregion

$scriptEndTime = Get-Date
Write-Output "Script completed at: $($scriptEndTime.ToString('yyyy-MM-dd HH:mm:ss'))"
Write-Output "Total duration: $(($scriptEndTime - $scriptStartTime).ToString('hh\:mm\:ss'))"
Stop-Transcript
