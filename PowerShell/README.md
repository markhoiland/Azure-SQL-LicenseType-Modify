# PowerShell Scripts – Azure SQL License Type Modification

This folder contains PowerShell scripts for modifying the SQL Server license type across all supported Azure SQL resource types. Use these scripts to convert resources from Azure Hybrid Benefit (AHB) or Paid license to Pay-as-you-go (PAYG) at scale.

---

## Scripts Overview

| Script | Target Resource | Module(s) Required |
|--------|----------------|--------------------|
| `Set-SqlDbLicenseType.ps1` | Azure SQL Database | `Az.Accounts`, `Az.Sql` |
| `Set-SqlMILicenseType.ps1` | Azure SQL Managed Instance | `Az.Accounts`, `Az.Sql` |
| `Set-SqlVMLicenseType.ps1` | SQL Server on Azure VMs | `Az.Accounts`, `Az.SqlVirtualMachine` |
| `Set-ArcSqlLicenseType.ps1` | Azure Arc-enabled SQL Server | `Az.Accounts`, `Az.ConnectedMachine`, `Az.ResourceGraph` |

---

## Prerequisites

1. **PowerShell 7.x** (recommended) or Windows PowerShell 5.1+
2. **Az PowerShell module** installed:
   ```powershell
   Install-Module -Name Az -AllowClobber -Scope CurrentUser
   ```
3. **Authentication** – log in before running any script:
   ```powershell
   Connect-AzAccount
   # Or for a specific tenant:
   Connect-AzAccount -TenantId "<tenant_id>"
   ```
4. **Required RBAC roles** (per script):
   - SQL Database / MI: `SQL Server Contributor` or `Contributor`
   - SQL VMs: `SQL Virtual Machine Contributor` or `Contributor`
   - Arc SQL: `Azure Connected Machine Resource Administrator`

---

## License Type Quick Reference

### Azure SQL Database & Managed Instance

| Value | Meaning |
|-------|---------|
| `LicenseIncluded` | Pay-as-you-go (PAYG) – license cost included in Azure billing |
| `BasePrice` | Azure Hybrid Benefit (AHB) – bring your own SQL Server license |

### SQL Server on Azure VMs

| Value | Meaning |
|-------|---------|
| `PAYG` | Pay-as-you-go – SQL Server license billed through Azure |
| `AHUB` | Azure Hybrid Benefit – bring your own SQL Server license |
| `DR` | Disaster Recovery – free passive DR replica license |

### Azure Arc-enabled SQL Server

| Value | Meaning |
|-------|---------|
| `PAYG` | Pay-as-you-go – SQL Server usage billed hourly via Azure |
| `Paid` | Paid license with Software Assurance (SA) |
| `LicenseOnly` | License only – perpetual license, no SA |

---

## Set-SqlDbLicenseType.ps1 – Azure SQL Database

### Common Parameters

| Parameter | Description |
|-----------|-------------|
| `-SubId` | Subscription ID or path to a CSV file (`SubscriptionId` column) |
| `-ResourceGroup` | Limit scope to a resource group |
| `-ServerName` | Limit scope to a SQL server |
| `-DatabaseName` | Limit scope to a single database |
| `-LicenseType` | Target: `LicenseIncluded` or `BasePrice` |
| `-DisableAHUB` | Shorthand: sets `LicenseIncluded` + `-Force` |
| `-Force` | Update all databases, not just those that differ |
| `-ExclusionTags` | JSON string of tags to exclude (e.g. `'{"Env":"Dev"}'`) |
| `-TenantId` | Azure tenant ID |
| `-ReportOnly` | Generate CSV report without making changes |
| `-UseManagedIdentity` | Authenticate with managed identity |

### Examples

```powershell
# Report which databases would be converted from AHB to PAYG (no changes)
.\Set-SqlDbLicenseType.ps1 -TenantId "<tenant_id>" -DisableAHUB -ReportOnly

# Disable AHB (convert to PAYG) on all databases in a subscription
.\Set-SqlDbLicenseType.ps1 -SubId "<sub_id>" -DisableAHUB -Force

# Set all databases in a resource group to LicenseIncluded
.\Set-SqlDbLicenseType.ps1 -SubId "<sub_id>" -ResourceGroup "<rg>" -LicenseType LicenseIncluded -Force

# Exclude databases tagged Environment=Dev
.\Set-SqlDbLicenseType.ps1 -SubId "<sub_id>" -DisableAHUB -Force -ExclusionTags '{"Environment":"Dev"}'

# Process subscriptions from a CSV file using managed identity
.\Set-SqlDbLicenseType.ps1 -SubId "subscriptions.csv" -DisableAHUB -Force -UseManagedIdentity
```

---

## Set-SqlMILicenseType.ps1 – Azure SQL Managed Instance

### Common Parameters

| Parameter | Description |
|-----------|-------------|
| `-SubId` | Subscription ID or path to a CSV file (`SubscriptionId` column) |
| `-ResourceGroup` | Limit scope to a resource group |
| `-InstanceName` | Limit scope to a specific managed instance |
| `-LicenseType` | Target: `LicenseIncluded` or `BasePrice` |
| `-DisableAHUB` | Shorthand: sets `LicenseIncluded` + `-Force` |
| `-Force` | Update all instances, not just those that differ |
| `-ExclusionTags` | JSON string of tags to exclude |
| `-TenantId` | Azure tenant ID |
| `-ReportOnly` | Generate CSV report without making changes |
| `-UseManagedIdentity` | Authenticate with managed identity |

### Examples

```powershell
# Report which managed instances would be converted from AHB to PAYG
.\Set-SqlMILicenseType.ps1 -TenantId "<tenant_id>" -DisableAHUB -ReportOnly

# Disable AHB on all managed instances in a subscription
.\Set-SqlMILicenseType.ps1 -SubId "<sub_id>" -DisableAHUB -Force

# Set a specific managed instance to LicenseIncluded
.\Set-SqlMILicenseType.ps1 -SubId "<sub_id>" -ResourceGroup "<rg>" -InstanceName "<mi_name>" -DisableAHUB -Force
```

---

## Set-SqlVMLicenseType.ps1 – SQL Server on Azure VMs

### Common Parameters

| Parameter | Description |
|-----------|-------------|
| `-SubId` | Subscription ID or path to a CSV file (`SubscriptionId` column) |
| `-ResourceGroup` | Limit scope to a resource group |
| `-VMName` | Limit scope to a specific SQL VM (requires `-ResourceGroup`) |
| `-LicenseType` | Target: `PAYG`, `AHUB`, or `DR` |
| `-DisableAHUB` | Shorthand: sets `PAYG` + `-Force` |
| `-Force` | Update all VMs, not just those that differ |
| `-ExclusionTags` | JSON string of tags to exclude |
| `-TenantId` | Azure tenant ID |
| `-ReportOnly` | Generate CSV report without making changes |
| `-UseManagedIdentity` | Authenticate with managed identity |

> **Note:** Only SQL VMs registered with the SQL IaaS Agent Extension appear. To register all VMs in a subscription, run:
> ```powershell
> Register-AzSqlVMWithSqlIaasExtension -SubscriptionId "<sub_id>"
> ```

### Examples

```powershell
# Report which SQL VMs would be converted from AHUB to PAYG
.\Set-SqlVMLicenseType.ps1 -TenantId "<tenant_id>" -DisableAHUB -ReportOnly

# Disable AHUB on all SQL VMs in a subscription
.\Set-SqlVMLicenseType.ps1 -SubId "<sub_id>" -DisableAHUB -Force

# Set all SQL VMs in a resource group to PAYG
.\Set-SqlVMLicenseType.ps1 -SubId "<sub_id>" -ResourceGroup "<rg>" -LicenseType PAYG -Force
```

---

## Set-ArcSqlLicenseType.ps1 – Azure Arc-enabled SQL Server

### Common Parameters

| Parameter | Description |
|-----------|-------------|
| `-SubId` | Subscription ID or CSV file (`SubscriptionId` column) |
| `-ResourceGroup` | Limit scope to a resource group |
| `-MachineName` | Single machine name or CSV file (`MachineName` column) |
| `-LicenseType` | Target: `PAYG`, `Paid`, or `LicenseOnly` |
| `-EnableESU` | Enable (`Yes`) or disable (`No`) Extended Security Updates |
| `-UsePcoreLicense` | Enable (`Yes`) or disable (`No`) unlimited virtualization license |
| `-ConsentToRecurringPAYG` | `Yes`/`No` – CSP subscription PAYG consent |
| `-Force` | Apply even if license type is already set |
| `-ExclusionTags` | JSON string of tags to exclude |
| `-TenantId` | Azure tenant ID |
| `-ReportOnly` | Generate CSV report without making changes |
| `-UseManagedIdentity` | Authenticate with managed identity |

### Examples

```powershell
# Report what would change to PAYG across all subscriptions in a tenant
.\Set-ArcSqlLicenseType.ps1 -TenantId "<tenant_id>" -LicenseType PAYG -ReportOnly

# Set all Arc SQL servers to PAYG in a subscription
.\Set-ArcSqlLicenseType.ps1 -SubId "<sub_id>" -LicenseType PAYG -Force

# Set to PAYG and enable ESU in a resource group
.\Set-ArcSqlLicenseType.ps1 -SubId "<sub_id>" -ResourceGroup "<rg>" -LicenseType PAYG -EnableESU Yes -Force

# Disable ESU on all Arc SQL servers in a subscription
.\Set-ArcSqlLicenseType.ps1 -SubId "<sub_id>" -EnableESU No

# Enable p-core (unlimited virtualization) license
.\Set-ArcSqlLicenseType.ps1 -SubId "<sub_id>" -ResourceGroup "<rg>" -LicenseType PAYG -UsePcoreLicense Yes -Force

# Process machines from a CSV file
.\Set-ArcSqlLicenseType.ps1 -SubId "<sub_id>" -MachineName machines.csv -LicenseType PAYG -Force

# Consent to recurring PAYG billing (CSP subscriptions)
.\Set-ArcSqlLicenseType.ps1 -LicenseType PAYG -ConsentToRecurringPAYG Yes -Force -UseManagedIdentity
```

---

## CSV File Formats

### Subscriptions CSV (`subscriptions.csv`)
```csv
SubscriptionId
xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy
```

### Machine Names CSV (`machines.csv`) – Arc script only
```csv
MachineName
Prod1
Prod2
Prod3
```

---

## Output Reports

Each script generates a timestamped CSV report (e.g. `SqlDb_LicenseChange_20250101_120000.csv`) alongside a `.log` transcript file. The report includes:

- Subscription, resource group, resource name
- Current and target license types
- Action taken (`Modified`, `NoChange`, `Failed`, `WouldModify` in report-only mode)

---

## Running from Azure Cloud Shell

Azure Cloud Shell has the Az module pre-installed and authentication is automatic.

1. Open [Cloud Shell](https://shell.azure.com/) (PowerShell mode)
2. Upload your script or download it directly:
   ```powershell
   # Clone or download the script
   Invoke-WebRequest -Uri "https://raw.githubusercontent.com/<owner>/Azure-SQL-LicenseType-Modify/main/PowerShell/Set-SqlDbLicenseType.ps1" -OutFile "Set-SqlDbLicenseType.ps1"
   ```
3. Run the script with the appropriate parameters.
