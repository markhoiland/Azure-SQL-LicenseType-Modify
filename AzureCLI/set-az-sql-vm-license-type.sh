#!/usr/bin/env bash
# =============================================================================
# set-az-sql-vm-license-type.sh
#
# SYNOPSIS:
#   Modifies the SQL Server license type for SQL Server on Azure Virtual
#   Machines across one or more subscriptions using Azure CLI.
#
# DESCRIPTION:
#   Scans SQL Virtual Machine resources (type: Microsoft.SqlVirtualMachine/
#   SqlVirtualMachines) in the specified scope and converts them from Azure
#   Hybrid Benefit (AHUB) to Pay-as-you-go (PAYG), or sets any supported
#   license type. Supports filtering by subscription, resource group, or VM
#   name.
#
#   License type values for SQL Server on Azure VMs:
#     PAYG  - Pay-as-you-go. SQL Server license is billed through Azure.
#     AHUB  - Azure Hybrid Benefit. Bring your own SQL Server license.
#     DR    - Disaster Recovery. Free passive DR replica license.
#
#   NOTE: Only VMs registered with the SQL IaaS Agent Extension appear as
#   SqlVirtualMachine resources. Unregistered VMs will not be found.
#
# PREREQUISITES:
#   - Azure CLI >= 2.50.0  (az --version)
#   - Logged in to Azure  (az login) or running with managed identity
#   - Required role: SQL Virtual Machine Contributor (or Contributor)
#
# USAGE:
#   ./set-az-sql-vm-license-type.sh [OPTIONS]
#
# OPTIONS:
#   -s, --subscription-id   <id|file>   Subscription ID or path to a file with
#                                       one subscription ID per line. If omitted,
#                                       all accessible subscriptions are scanned.
#   -g, --resource-group    <name>      Limit scope to a specific resource group.
#   -v, --vm-name           <name>      Limit scope to a specific SQL VM name.
#                                       Requires --resource-group.
#   -l, --license-type      <type>      Target license type: PAYG|AHUB|DR.
#       --disable-ahub                  Shorthand: set LicenseType=PAYG and --force.
#   -f, --force                         Update all resources, not just those that differ.
#   -t, --tenant-id         <id>        Azure tenant ID (used during az login).
#       --report-only                   Print what would change; do not modify anything.
#   -h, --help                          Show this help message.
#
# EXAMPLES:
#   # Report which SQL VMs would be converted from AHUB to PAYG
#   ./set-az-sql-vm-license-type.sh --disable-ahub --report-only
#
#   # Disable AHUB on all SQL VMs in a specific subscription
#   ./set-az-sql-vm-license-type.sh --subscription-id "<sub_id>" --disable-ahub --force
#
#   # Set all SQL VMs in a resource group to PAYG
#   ./set-az-sql-vm-license-type.sh --subscription-id "<sub_id>" \
#     --resource-group "<rg>" --license-type PAYG --force
#
#   # Disable AHUB on a specific SQL VM
#   ./set-az-sql-vm-license-type.sh --subscription-id "<sub_id>" \
#     --resource-group "<rg>" --vm-name "<vm_name>" --disable-ahub --force
# =============================================================================

set -euo pipefail

# --------------------------------------------------------------------------- #
# Defaults
# --------------------------------------------------------------------------- #
SUBSCRIPTION_ID=""
RESOURCE_GROUP=""
VM_NAME=""
LICENSE_TYPE=""
TENANT_ID=""
FORCE=false
REPORT_ONLY=false
DISABLE_AHUB=false
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
REPORT_FILE="SqlVM_LicenseChange_${TIMESTAMP}.csv"

# --------------------------------------------------------------------------- #
# Help
# --------------------------------------------------------------------------- #
usage() {
    sed -n '/^# USAGE:/,/^# ======/{ /^# ======/d; s/^# \{0,3\}//; p }' "$0"
    exit 0
}

# --------------------------------------------------------------------------- #
# Parse arguments
# --------------------------------------------------------------------------- #
while [[ $# -gt 0 ]]; do
    case "$1" in
        -s|--subscription-id)   SUBSCRIPTION_ID="$2"; shift 2 ;;
        -g|--resource-group)    RESOURCE_GROUP="$2";  shift 2 ;;
        -v|--vm-name)           VM_NAME="$2";         shift 2 ;;
        -l|--license-type)      LICENSE_TYPE="$2";    shift 2 ;;
           --disable-ahub)      DISABLE_AHUB=true;    shift   ;;
        -f|--force)             FORCE=true;           shift   ;;
        -t|--tenant-id)         TENANT_ID="$2";       shift 2 ;;
           --report-only)       REPORT_ONLY=true;     shift   ;;
        -h|--help)              usage ;;
        *) echo "Unknown option: $1" >&2; usage ;;
    esac
done

# --------------------------------------------------------------------------- #
# Validate / resolve parameters
# --------------------------------------------------------------------------- #
if $DISABLE_AHUB; then
    LICENSE_TYPE="PAYG"
    FORCE=true
    echo "[INFO] --disable-ahub: targeting LicenseType=PAYG with --force."
fi

if [[ -z "$LICENSE_TYPE" ]]; then
    echo "[ERROR] You must specify --license-type or --disable-ahub." >&2
    exit 1
fi

if [[ "$LICENSE_TYPE" != "PAYG" && "$LICENSE_TYPE" != "AHUB" && "$LICENSE_TYPE" != "DR" ]]; then
    echo "[ERROR] --license-type must be 'PAYG', 'AHUB', or 'DR'." >&2
    exit 1
fi

if [[ -n "$VM_NAME" && -z "$RESOURCE_GROUP" ]]; then
    echo "[ERROR] --vm-name requires --resource-group to be specified." >&2
    exit 1
fi

# --------------------------------------------------------------------------- #
# Azure CLI check
# --------------------------------------------------------------------------- #
if ! command -v az &>/dev/null; then
    echo "[ERROR] Azure CLI (az) is not installed or not in PATH." >&2
    exit 1
fi

# Ensure the sqlvm extension is installed
az extension add --name sqlvm --only-show-errors 2>/dev/null || true

# --------------------------------------------------------------------------- #
# Authentication check
# --------------------------------------------------------------------------- #
if [[ -n "$TENANT_ID" ]]; then
    echo "[INFO] Verifying Azure CLI context for tenant $TENANT_ID..."
    CURRENT_TENANT=$(az account show --query "tenantId" -o tsv 2>/dev/null || true)
    if [[ "$CURRENT_TENANT" != "$TENANT_ID" ]]; then
        echo "[INFO] Logging in to tenant $TENANT_ID..."
        az login --tenant "$TENANT_ID" --output none
    fi
fi

CURRENT_ACCOUNT=$(az account show --query "user.name" -o tsv 2>/dev/null || echo "unknown")
echo "[INFO] Authenticated as: $CURRENT_ACCOUNT"

# --------------------------------------------------------------------------- #
# Build subscription list
# --------------------------------------------------------------------------- #
declare -a SUBSCRIPTIONS=()

if [[ -n "$SUBSCRIPTION_ID" ]]; then
    if [[ -f "$SUBSCRIPTION_ID" ]]; then
        while IFS= read -r line; do
            line="${line//[$'\t\r\n']}"
            [[ -z "$line" || "$line" =~ ^# ]] && continue
            SUBSCRIPTIONS+=("$line")
        done < "$SUBSCRIPTION_ID"
        echo "[INFO] Loaded ${#SUBSCRIPTIONS[@]} subscription(s) from file."
    else
        SUBSCRIPTIONS=("$SUBSCRIPTION_ID")
    fi
else
    mapfile -t SUBSCRIPTIONS < <(az account list --query "[?state=='Enabled'].id" -o tsv)
    echo "[INFO] Found ${#SUBSCRIPTIONS[@]} enabled subscription(s)."
fi

# --------------------------------------------------------------------------- #
# CSV report header
# --------------------------------------------------------------------------- #
echo "SubscriptionId,ResourceGroup,VMName,CurrentLicenseType,TargetLicenseType,SQLImageOffer,SQLImageSku,Location,Action" \
    > "$REPORT_FILE"

TOTAL_MODIFIED=0

# --------------------------------------------------------------------------- #
# Main loop
# --------------------------------------------------------------------------- #
for sub in "${SUBSCRIPTIONS[@]}"; do
    echo ""
    echo "=== Subscription: $sub ==="
    az account set --subscription "$sub" 2>/dev/null || {
        echo "  [WARNING] Cannot access subscription $sub, skipping." >&2
        continue
    }

    # Enumerate SQL VMs
    if [[ -n "$VM_NAME" && -n "$RESOURCE_GROUP" ]]; then
        vm_list=$(az sql vm show \
            --name "$VM_NAME" \
            --resource-group "$RESOURCE_GROUP" \
            --query "[{name:name,licenseType:sqlServerLicenseType,offer:sqlImageOffer,sku:sqlImageSku,location:location,rg:resourceGroup}]" \
            -o json 2>/dev/null) || { echo "  [WARNING] Could not retrieve SQL VM $VM_NAME"; continue; }
    elif [[ -n "$RESOURCE_GROUP" ]]; then
        vm_list=$(az sql vm list \
            --resource-group "$RESOURCE_GROUP" \
            --query "[].{name:name,licenseType:sqlServerLicenseType,offer:sqlImageOffer,sku:sqlImageSku,location:location,rg:resourceGroup}" \
            -o json 2>/dev/null) || { echo "  [WARNING] Could not list SQL VMs in RG $RESOURCE_GROUP"; continue; }
    else
        vm_list=$(az sql vm list \
            --query "[].{name:name,licenseType:sqlServerLicenseType,offer:sqlImageOffer,sku:sqlImageSku,location:location,rg:resourceGroup}" \
            -o json 2>/dev/null) || { echo "  [WARNING] Could not list SQL VMs"; continue; }
    fi

    vm_count=$(echo "$vm_list" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
    echo "  Found $vm_count SQL VM(s)."

    for ((i=0; i<vm_count; i++)); do
        vm_name=$(echo "$vm_list" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[$i]['name'])")
        current_license=$(echo "$vm_list" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[$i].get('licenseType') or '')")
        offer=$(echo "$vm_list" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[$i].get('offer') or '')")
        sku=$(echo "$vm_list" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[$i].get('sku') or '')")
        location=$(echo "$vm_list" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[$i].get('location') or '')")
        rg=$(echo "$vm_list" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[$i].get('rg') or '')")

        needs_update=false
        if $FORCE; then
            needs_update=true
        elif [[ "$current_license" != "$LICENSE_TYPE" ]]; then
            needs_update=true
        fi

        action="NoChange"
        if $needs_update; then
            action="Modify"
            TOTAL_MODIFIED=$((TOTAL_MODIFIED + 1))
            if $REPORT_ONLY; then
                echo "  [ReportOnly] Would modify: $vm_name [$current_license -> $LICENSE_TYPE]"
                action="WouldModify"
            else
                echo "  Modifying: $vm_name [$current_license -> $LICENSE_TYPE]"
                if az sql vm update \
                    --name "$vm_name" \
                    --resource-group "$rg" \
                    --license-type "$LICENSE_TYPE" \
                    --output none 2>/dev/null; then
                    echo "    Updated successfully."
                    action="Modified"
                else
                    echo "    [WARNING] Failed to update $vm_name" >&2
                    action="Failed"
                fi
            fi
        else
            echo "  NO CHANGE: $vm_name (already $current_license)"
        fi

        echo "${sub},${rg},${vm_name},${current_license},${LICENSE_TYPE},${offer},${sku},${location},${action}" \
            >> "$REPORT_FILE"
    done
done

# --------------------------------------------------------------------------- #
# Summary
# --------------------------------------------------------------------------- #
echo ""
echo "============================================"
echo "Report saved to: $REPORT_FILE"
echo "Total SQL VMs targeted for modification: $TOTAL_MODIFIED"
echo "Completed at: $(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================"
