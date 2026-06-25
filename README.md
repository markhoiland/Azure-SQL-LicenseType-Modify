# Azure SQL License Type Modification Scripts

This repository provides a scalable solution to set or change the SQL Server license type across **all Azure SQL resource types** — Azure SQL Database, Azure SQL Managed Instance, SQL Server on Azure VMs, and Azure Arc-enabled SQL Server. Scripts are available in both **PowerShell** and **Azure CLI (Bash)**.

The primary use cases are:

- **Disable Azure Hybrid Benefit (AHB)** on Azure SQL DB / SQL MI (change from `BasePrice` → `LicenseIncluded`)
- **Disable AHUB** on SQL Server VMs (change from `AHUB` → `PAYG`)
- **Convert Azure Arc-enabled SQL Servers** from `Paid` or `LicenseOnly` → `PAYG`
- **Enable/disable Extended Security Updates (ESU)** on Arc-enabled SQL Servers
- **Enable/disable unlimited virtualization (p-core) license** on Arc-enabled SQL Servers

All scripts support scanning a single subscription, a list of subscriptions, or your entire tenant, with optional filtering by resource group, server/instance/VM name, and tag-based exclusions. Every script supports a **`-ReportOnly` / `--report-only`** mode that shows what would change without making any modifications.

---

## Repository Structure

```
Azure-SQL-LicenseType-Modify/
├── PowerShell/
│   ├── README.md                    # PowerShell-specific documentation
│   ├── Set-SqlDbLicenseType.ps1     # Azure SQL Database
│   ├── Set-SqlMILicenseType.ps1     # Azure SQL Managed Instance
│   ├── Set-SqlVMLicenseType.ps1     # SQL Server on Azure VMs
│   └── Set-ArcSqlLicenseType.ps1   # Azure Arc-enabled SQL Server
└── AzureCLI/
    ├── README.md                    # Azure CLI-specific documentation
    ├── set-sql-db-license-type.sh   # Azure SQL Database
    ├── set-sql-mi-license-type.sh   # Azure SQL Managed Instance
    ├── set-sql-vm-license-type.sh   # SQL Server on Azure VMs
    └── set-arc-sql-license-type.sh  # Azure Arc-enabled SQL Server
```

---

## Supported Resource Types

| Resource Type | PowerShell Script | Azure CLI Script |
|---------------|------------------|-----------------|
| Azure SQL Database | `Set-SqlDbLicenseType.ps1` | `set-sql-db-license-type.sh` |
| Azure SQL Managed Instance | `Set-SqlMILicenseType.ps1` | `set-sql-mi-license-type.sh` |
| SQL Server on Azure VMs | `Set-SqlVMLicenseType.ps1` | `set-sql-vm-license-type.sh` |
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

### Azure Arc-enabled SQL Server

| Value | Meaning |
|-------|---------|
| `PAYG` | **Pay-as-you-go** – SQL Server usage billed hourly via Azure |
| `Paid` | **Paid** – license with Software Assurance (SA) |
| `LicenseOnly` | **License Only** – perpetual license, no SA |

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
.\PowerShell\Set-SqlDbLicenseType.ps1 -TenantId "<tenant_id>" -DisableAHUB -ReportOnly

# Step 2 – Apply the change
.\PowerShell\Set-SqlDbLicenseType.ps1 -TenantId "<tenant_id>" -DisableAHUB -Force
```

### Disable AHB on All Azure SQL Databases (Azure CLI)

```bash
# Step 1 – Report what would change
./AzureCLI/set-sql-db-license-type.sh --disable-ahub --report-only

# Step 2 – Apply the change
./AzureCLI/set-sql-db-license-type.sh --disable-ahub --force
```

### Disable AHB on All SQL Managed Instances (PowerShell)

```powershell
.\PowerShell\Set-SqlMILicenseType.ps1 -SubId "<sub_id>" -DisableAHUB -Force
```

### Disable AHUB on All SQL Server VMs (PowerShell)

```powershell
.\PowerShell\Set-SqlVMLicenseType.ps1 -SubId "<sub_id>" -DisableAHUB -Force
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
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/<owner>/Azure-SQL-LicenseType-Modify/main/PowerShell/Set-SqlDbLicenseType.ps1" -OutFile "Set-SqlDbLicenseType.ps1"
.\Set-SqlDbLicenseType.ps1 -DisableAHUB -ReportOnly
```

**Bash/CLI:**
```bash
curl -O https://raw.githubusercontent.com/<owner>/Azure-SQL-LicenseType-Modify/main/AzureCLI/set-sql-db-license-type.sh
chmod +x set-sql-db-license-type.sh
./set-sql-db-license-type.sh --disable-ahub --report-only
```

---

## Detailed Documentation

For complete parameter reference and examples for each script, see:

- [PowerShell/README.md](./PowerShell/README.md) – full PowerShell documentation
- [AzureCLI/README.md](./AzureCLI/README.md) – full Azure CLI documentation

---

## Script Reference

This repository builds upon and extends the [Microsoft SQL Server Samples](https://github.com/microsoft/sql-server-samples/tree/master/samples/manage/azure-arc-enabled-sql-server/modify-license-type) reference implementation for Azure Arc-enabled SQL Server license management, adding support for Azure SQL Database, Azure SQL Managed Instance, and SQL Server on Azure VMs, as well as Azure CLI equivalents for all resource types.
