# Azure SQL License Type Modification Scripts

This repository provides scripts to review and change licensing on Azure SQL Database, Azure SQL Managed Instance, SQL Server on Azure VMs, and Azure Arc-enabled SQL Server. Scripts are available in PowerShell and Azure CLI (Bash). Run report-only first and validate the resulting billing/licensing state in Azure before and after production changes.

The primary use cases are:

- **Disable Azure Hybrid Benefit (AHB)** on Azure SQL DB / SQL MI (change from `BasePrice` → `LicenseIncluded`)
- **Disable AHUB** on SQL Server VMs (change from `AHUB` → `PAYG`)
- **Convert Azure Arc-enabled SQL Servers** from `Paid` or `LicenseOnly` → `PAYG`
- **Enable/disable Extended Security Updates (ESU)** on Arc-enabled SQL Servers
- **Enable/disable unlimited virtualization (p-core) license** on Arc-enabled SQL Servers

The Azure SQL Database, Managed Instance, and SQL VM scripts support a single subscription, subscription files, or tenant-wide discovery, with resource-group, resource-name, and tag exclusions where implemented. Every script supports a report-only mode. Arc SQL uses a separate licensing model and is not an AHUB-to-PAYG conversion.

---

## Repository Structure

```
Azure-SQL-LicenseType-Modify/
├── PowerShell/
│   ├── README.md                    # PowerShell-specific documentation
│   ├── Set-AzSqlDbLicenseType.ps1     # Azure SQL Database
│   ├── Set-AzSqlMILicenseType.ps1     # Azure SQL Managed Instance
│   ├── Set-AzSqlVMLicenseType.ps1     # SQL Server on Azure VMs
│   └── Set-ArcSqlLicenseType.ps1   # Azure Arc-enabled SQL Server
└── AzureCLI/
    ├── README.md                    # Azure CLI-specific documentation
    ├── set-az-sql-db-license-type.sh   # Azure SQL Database
    ├── set-az-sql-mi-license-type.sh   # Azure SQL Managed Instance
    ├── set-az-sql-vm-license-type.sh   # SQL Server on Azure VMs
    └── set-arc-sql-license-type.sh  # Azure Arc-enabled SQL Server
└── Reporting/
    ├── README.md                     # Reporting options and operating model
    ├── KQL/
    │   └── arc-sql-inventory.kql     # Azure Resource Graph inventory queries
    ├── AzureMonitor-Workbook.md      # Azure Monitor Workbook build guide
    └── PowerBI-Fabric.md             # Recommended Power BI/Fabric build guide
```

---

## Supported Resource Types

| Resource Type | PowerShell Script | Azure CLI Script |
|---------------|------------------|-----------------|
| Azure SQL Database | `Set-AzSqlDbLicenseType.ps1` | `set-az-sql-db-license-type.sh` |
| Azure SQL Managed Instance | `Set-AzSqlMILicenseType.ps1` | `set-az-sql-mi-license-type.sh` |
| SQL Server on Azure VMs | `Set-AzSqlVMLicenseType.ps1` | `set-az-sql-vm-license-type.sh` |
| Azure Arc-enabled SQL Server | `Set-ArcSqlLicenseType.ps1` | `set-arc-sql-license-type.sh` |

---

## License Type Quick Reference

### Azure SQL Database & Managed Instance

| Value | Meaning |
|-------|---------|
| `LicenseIncluded` | **Pay-as-you-go (PAYG)** – license cost included in Azure billing |
| `BasePrice` | **Azure Hybrid Benefit (AHB)** – bring your own SQL Server license |

> To disable AHB, change from `BasePrice` → `LicenseIncluded`.

### SQL Server on Azure VMs

| Value | Meaning |
|-------|---------|
| `PAYG` | **Pay-as-you-go** – SQL Server license billed through Azure |
| `AHUB` | **Azure Hybrid Benefit** – bring your own SQL Server license |
| `DR` | **Disaster Recovery** – free passive DR replica license |

> To disable AHB, change from `AHUB` → `PAYG`.

> `DR` is a passive disaster-recovery licensing state and is intentionally not treated as AHUB. `--disable-ahub` only targets resources whose current state is `AHUB`.

### Azure Arc-enabled SQL Server

| Value | Meaning |
|-------|---------|
| `PAYG` | **Pay-as-you-go** – SQL Server usage billed hourly via Azure |
| `Paid` | **Paid** – license with Software Assurance (SA) |
| `LicenseOnly` | **License Only** – perpetual license, no SA |

Arc SQL licensing is independent of Azure SQL Database/MI `BasePrice` and SQL VM `AHUB`. Use the Arc scripts only for Arc-connected SQL Server resources.

---

## Prerequisites

### PowerShell Scripts

- **PowerShell 7.x** recommended (5.1+ supported)
- **Az PowerShell module**:
  ```powershell
  Install-Module -Name Az -AllowClobber -Scope CurrentUser
  ```
- **Authentication**:
  ```powershell
  Connect-AzAccount
  # Specify a tenant:
  Connect-AzAccount -TenantId "<tenant_id>"
  ```
- **RBAC roles required**:
  - Azure SQL DB / MI: `SQL Server Contributor` or `Contributor`
  - SQL VMs: `SQL Virtual Machine Contributor` or `Contributor`
  - Arc SQL: `Azure Connected Machine Resource Administrator`

### Azure CLI Scripts

- **Azure CLI >= 2.50.0**:
  ```bash
  az --version
  ```
- **Python 3** (used internally for JSON parsing)
- A POSIX-compatible shell (Azure Cloud Shell Bash, Linux, macOS, or WSL). Native Windows PowerShell is not a Bash shell.
- **Authentication**:
  ```bash
  az login
  # Specify a tenant:
  az login --tenant "<tenant_id>"
  ```
- **RBAC roles** – same as above

---

## Quick Start Examples

### Disable AHB on All Azure SQL Databases (PowerShell)

```powershell
# Step 1 – Report what would change (no modifications)
.\PowerShell\Set-AzSqlDbLicenseType.ps1 -TenantId "<tenant_id>" -DisableAHUB -ReportOnly

# Step 2 – Apply the change
.\PowerShell\Set-AzSqlDbLicenseType.ps1 -TenantId "<tenant_id>" -DisableAHUB -Force
```

### Disable AHB on All Azure SQL Databases (Azure CLI)

```bash
# Step 1 – Report what would change
./AzureCLI/set-az-sql-db-license-type.sh --disable-ahub --report-only

# Step 2 – Apply the change
./AzureCLI/set-az-sql-db-license-type.sh --disable-ahub
```

### Disable AHB on All SQL Managed Instances (PowerShell)

```powershell
.\PowerShell\Set-AzSqlMILicenseType.ps1 -SubId "<sub_id>" -DisableAHUB -Force
```

### Disable AHUB on All SQL Server VMs (PowerShell)

```powershell
.\PowerShell\Set-AzSqlVMLicenseType.ps1 -SubId "<sub_id>" -DisableAHUB -Force
```

### Convert Arc-enabled SQL Servers to PAYG (PowerShell)

```powershell
.\PowerShell\Set-ArcSqlLicenseType.ps1 -SubId "<sub_id>" -LicenseType PAYG -Force
```

### Convert Arc-enabled SQL Servers to PAYG (Azure CLI)

```bash
./AzureCLI/set-arc-sql-license-type.sh --subscription-id "<sub_id>" --license-type PAYG --force
```

---

## Common Parameters

All scripts share the following common parameters/options:

| PowerShell | Azure CLI | Description |
|------------|-----------|-------------|
| `-SubId` | `-s` / `--subscription-id` | Single subscription ID or file with multiple IDs |
| `-ResourceGroup` | `-g` / `--resource-group` | Limit to a specific resource group |
| `-TenantId` | `-t` / `--tenant-id` | Azure tenant ID for authentication |
| `-Force` | `-f` / `--force` | Update all resources, not just those that differ |
| `-ReportOnly` | `--report-only` | Show what would change without modifying |
| `-ExclusionTags` | _(not yet implemented in CLI)_ | Exclude resources with specific tags |
| `-UseManagedIdentity` | _(connect before running)_ | Use managed identity for authentication |

---

## Output Reports

Each script run produces:

- **CSV report** – timestamped file (e.g. `SqlDb_LicenseChange_20250101_120000.csv`) listing every resource evaluated with its current license, target license, and action taken.
- **Log transcript** – PowerShell scripts generate a `.log` file with full execution output.

---

## Running from Azure Cloud Shell

[Azure Cloud Shell](https://shell.azure.com/) is the easiest way to run these scripts — no installation needed.

**PowerShell:**
```powershell
# Download and run
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/markhoiland/Azure-SQL-LicenseType-Modify/main/PowerShell/Set-AzSqlDbLicenseType.ps1" -OutFile "Set-AzSqlDbLicenseType.ps1"
.\Set-AzSqlDbLicenseType.ps1 -DisableAHUB -ReportOnly
```

**Bash/CLI:**
```bash
curl -O https://raw.githubusercontent.com/markhoiland/Azure-SQL-LicenseType-Modify/main/AzureCLI/set-az-sql-db-license-type.sh
chmod +x set-az-sql-db-license-type.sh
./set-az-sql-db-license-type.sh --disable-ahub --report-only
```

---

## Detailed Documentation

For complete parameter reference and examples for each script, see:

- [PowerShell/README.md](./PowerShell/README.md) – full PowerShell documentation
- [AzureCLI/README.md](./AzureCLI/README.md) – full Azure CLI documentation
- [Reporting/README.md](./Reporting/README.md) – inventory and billing reporting options
- [Reporting/AzureMonitor-Workbook.md](./Reporting/AzureMonitor-Workbook.md) – build an Azure Monitor Workbook
- [Reporting/PowerBI-Fabric.md](./Reporting/PowerBI-Fabric.md) – build the recommended Power BI/Fabric dashboard

---

## Script Reference

This repository builds upon and extends the [Microsoft SQL Server Samples](https://github.com/microsoft/sql-server-samples/tree/master/samples/manage/azure-arc-enabled-sql-server/modify-license-type) reference implementation for Azure Arc-enabled SQL Server license management, adding support for Azure SQL Database, Azure SQL Managed Instance, and SQL Server on Azure VMs, as well as Azure CLI equivalents for all resource types.
