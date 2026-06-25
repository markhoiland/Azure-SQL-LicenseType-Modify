# Azure CLI Scripts – Azure SQL License Type Modification

This folder contains Bash scripts that use **Azure CLI** (`az`) to modify the SQL Server license type across all supported Azure SQL resource types. Use these scripts to convert resources from Azure Hybrid Benefit (AHB) or Paid license to Pay-as-you-go (PAYG) at scale.

---

## Scripts Overview

| Script | Target Resource | Azure CLI Commands Used |
|--------|----------------|------------------------|
| `set-sql-db-license-type.sh` | Azure SQL Database | `az sql db`, `az sql server` |
| `set-sql-mi-license-type.sh` | Azure SQL Managed Instance | `az sql mi` |
| `set-sql-vm-license-type.sh` | SQL Server on Azure VMs | `az sql vm` |
| `set-arc-sql-license-type.sh` | Azure Arc-enabled SQL Server | `az connectedmachine`, `az graph` |

---

## Prerequisites

1. **Azure CLI >= 2.50.0** – [Install instructions](https://learn.microsoft.com/cli/azure/install-azure-cli)
   ```bash
   az --version
   ```
2. **Python 3** (used internally for JSON parsing)
3. **Authentication** – log in before running any script:
   ```bash
   az login
   # Or for a specific tenant:
   az login --tenant "<tenant_id>"
   ```
4. **Required RBAC roles** (per script):
   - SQL Database: `SQL Server Contributor` or `Contributor`
   - SQL MI: `SQL Managed Instance Contributor` or `Contributor`
   - SQL VMs: `SQL Virtual Machine Contributor` or `Contributor`
   - Arc SQL: `Azure Connected Machine Resource Administrator`

---

## Making Scripts Executable

```bash
chmod +x set-sql-db-license-type.sh
chmod +x set-sql-mi-license-type.sh
chmod +x set-sql-vm-license-type.sh
chmod +x set-arc-sql-license-type.sh
```

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

## set-sql-db-license-type.sh – Azure SQL Database

### Options

| Option | Description |
|--------|-------------|
| `-s`, `--subscription-id` | Subscription ID or path to a file with one ID per line |
| `-g`, `--resource-group` | Limit scope to a resource group |
| `-n`, `--server-name` | Limit scope to a SQL server |
| `-d`, `--database-name` | Limit scope to a single database |
| `-l`, `--license-type` | Target: `LicenseIncluded` or `BasePrice` |
| `--disable-ahub` | Shorthand: sets `LicenseIncluded` + `--force` |
| `-f`, `--force` | Update all databases, not just those that differ |
| `-t`, `--tenant-id` | Azure tenant ID |
| `--report-only` | Print changes without executing them |
| `-h`, `--help` | Show help |

### Examples

```bash
# Report which databases would be converted from AHB to PAYG (no changes)
./set-sql-db-license-type.sh --disable-ahub --report-only

# Disable AHB on all databases in a subscription
./set-sql-db-license-type.sh --subscription-id "<sub_id>" --disable-ahub --force

# Set all databases in a resource group to LicenseIncluded (PAYG)
./set-sql-db-license-type.sh --subscription-id "<sub_id>" \
  --resource-group "<rg>" --license-type LicenseIncluded --force

# Limit to a specific server
./set-sql-db-license-type.sh --subscription-id "<sub_id>" \
  --server-name "<server>" --disable-ahub --force

# Use a file listing multiple subscription IDs
./set-sql-db-license-type.sh --subscription-id subscriptions.txt --disable-ahub --force
```

---

## set-sql-mi-license-type.sh – Azure SQL Managed Instance

### Options

| Option | Description |
|--------|-------------|
| `-s`, `--subscription-id` | Subscription ID or path to a file |
| `-g`, `--resource-group` | Limit scope to a resource group |
| `-i`, `--instance-name` | Limit scope to a specific managed instance |
| `-l`, `--license-type` | Target: `LicenseIncluded` or `BasePrice` |
| `--disable-ahub` | Shorthand: sets `LicenseIncluded` + `--force` |
| `-f`, `--force` | Update all instances, not just those that differ |
| `-t`, `--tenant-id` | Azure tenant ID |
| `--report-only` | Print changes without executing them |
| `-h`, `--help` | Show help |

### Examples

```bash
# Report which managed instances would be converted from AHB to PAYG
./set-sql-mi-license-type.sh --disable-ahub --report-only

# Disable AHB on all managed instances in a subscription
./set-sql-mi-license-type.sh --subscription-id "<sub_id>" --disable-ahub --force

# Set all managed instances in a resource group to PAYG
./set-sql-mi-license-type.sh --subscription-id "<sub_id>" \
  --resource-group "<rg>" --license-type LicenseIncluded --force

# Target a specific managed instance
./set-sql-mi-license-type.sh --subscription-id "<sub_id>" \
  --resource-group "<rg>" --instance-name "<mi_name>" --disable-ahub --force
```

---

## set-sql-vm-license-type.sh – SQL Server on Azure VMs

### Options

| Option | Description |
|--------|-------------|
| `-s`, `--subscription-id` | Subscription ID or path to a file |
| `-g`, `--resource-group` | Limit scope to a resource group |
| `-v`, `--vm-name` | Limit scope to a specific SQL VM (requires `--resource-group`) |
| `-l`, `--license-type` | Target: `PAYG`, `AHUB`, or `DR` |
| `--disable-ahub` | Shorthand: sets `PAYG` + `--force` |
| `-f`, `--force` | Update all VMs, not just those that differ |
| `-t`, `--tenant-id` | Azure tenant ID |
| `--report-only` | Print changes without executing them |
| `-h`, `--help` | Show help |

> **Note:** Only SQL VMs registered with the SQL IaaS Agent Extension are visible.

### Examples

```bash
# Report which SQL VMs would be converted from AHUB to PAYG
./set-sql-vm-license-type.sh --disable-ahub --report-only

# Disable AHUB on all SQL VMs in a subscription
./set-sql-vm-license-type.sh --subscription-id "<sub_id>" --disable-ahub --force

# Set all SQL VMs in a resource group to PAYG
./set-sql-vm-license-type.sh --subscription-id "<sub_id>" \
  --resource-group "<rg>" --license-type PAYG --force

# Target a specific SQL VM
./set-sql-vm-license-type.sh --subscription-id "<sub_id>" \
  --resource-group "<rg>" --vm-name "<vm_name>" --disable-ahub --force
```

---

## set-arc-sql-license-type.sh – Azure Arc-enabled SQL Server

### Options

| Option | Description |
|--------|-------------|
| `-s`, `--subscription-id` | Subscription ID or path to a file |
| `-g`, `--resource-group` | Limit scope to a resource group |
| `-m`, `--machine-name` | Limit scope to a specific machine name |
| `-l`, `--license-type` | Target: `PAYG`, `Paid`, or `LicenseOnly` |
| `--enable-esu` | Enable (`Yes`) or disable (`No`) Extended Security Updates |
| `--use-pcore-license` | Enable (`Yes`) or disable (`No`) unlimited virtualization license |
| `-f`, `--force` | Apply license type even if already set |
| `-t`, `--tenant-id` | Azure tenant ID |
| `--report-only` | Print changes without executing them |
| `-h`, `--help` | Show help |

### Examples

```bash
# Report which Arc SQL servers would be changed to PAYG
./set-arc-sql-license-type.sh --license-type PAYG --report-only

# Set all Arc SQL servers to PAYG in a subscription
./set-arc-sql-license-type.sh --subscription-id "<sub_id>" --license-type PAYG --force

# Enable ESU on all Arc SQL servers (requires PAYG or Paid license type)
./set-arc-sql-license-type.sh --subscription-id "<sub_id>" --enable-esu Yes

# Disable ESU on all Arc SQL servers
./set-arc-sql-license-type.sh --subscription-id "<sub_id>" --enable-esu No

# Set to PAYG and enable p-core (unlimited virtualization) license
./set-arc-sql-license-type.sh --subscription-id "<sub_id>" \
  --license-type PAYG --use-pcore-license Yes --force

# Target a specific resource group
./set-arc-sql-license-type.sh --subscription-id "<sub_id>" \
  --resource-group "<rg>" --license-type PAYG --force

# Target a specific machine
./set-arc-sql-license-type.sh --subscription-id "<sub_id>" \
  --resource-group "<rg>" --machine-name "<machine>" --license-type PAYG --force
```

---

## Subscription File Format

To target multiple specific subscriptions, create a plain text file with one subscription ID per line:

```
# subscriptions.txt
xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy
```

Lines starting with `#` are treated as comments and ignored.

---

## Output Reports

Each script generates a timestamped CSV file (e.g. `SqlDb_LicenseChange_20250101_120000.csv`) in the current directory. The report includes:

- Subscription ID, resource group, resource name
- Current and target license types
- Action taken (`Modified`, `NoChange`, `Failed`, `WouldModify` in report-only mode)

---

## Running from Azure Cloud Shell

Azure Cloud Shell has the Azure CLI pre-installed and authentication is automatic.

1. Open [Cloud Shell](https://shell.azure.com/) (Bash mode)
2. Upload your script or download it:
   ```bash
   curl -O https://raw.githubusercontent.com/<owner>/Azure-SQL-LicenseType-Modify/main/AzureCLI/set-sql-db-license-type.sh
   chmod +x set-sql-db-license-type.sh
   ```
3. Run the script with the appropriate options.
