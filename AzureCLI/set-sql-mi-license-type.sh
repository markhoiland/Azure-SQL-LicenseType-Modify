#!/usr/bin/env bash
# =============================================================================
# set-sql-mi-license-type.sh
#
# SYNOPSIS:
#   Modifies the license type for Azure SQL Managed Instances across one or
#   more subscriptions using Azure CLI.
#
# DESCRIPTION:
#   Scans Azure SQL Managed Instances in the specified scope and converts them
#   from Azure Hybrid Benefit (BasePrice) to Pay-as-you-go (LicenseIncluded),
#   or sets any supported license type. Supports filtering by subscription,
#   resource group, or instance name.
#
#   License type values for Azure SQL Managed Instance:
#     LicenseIncluded  - Pay-as-you-go (PAYG)
#     BasePrice        - Azure Hybrid Benefit (AHB/BYOL)
#
# PREREQUISITES:
#   - Azure CLI >= 2.50.0  (az --version)
#   - Logged in to Azure  (az login) or running with managed identity
#   - Required role: SQL Managed Instance Contributor (or Contributor)
#
# USAGE:
#   ./set-sql-mi-license-type.sh [OPTIONS]
#
# OPTIONS:
#   -s, --subscription-id   <id|file>   Subscription ID or path to a file with
#                                       one subscription ID per line. If omitted,
#                                       all accessible subscriptions are scanned.
#   -g, --resource-group    <name>      Limit scope to a specific resource group.
#   -i, --instance-name     <name>      Limit scope to a specific managed instance.
#   -l, --license-type      <type>      Target license type: LicenseIncluded|BasePrice.
#       --disable-ahub                  Shorthand: set LicenseType=LicenseIncluded and --force.
#   -f, --force                         Update all resources, not just those that differ.
#   -t, --tenant-id         <id>        Azure tenant ID (used during az login).
#       --report-only                   Print what would change; do not modify anything.
#   -h, --help                          Show this help message.
#
# EXAMPLES:
#   # Report which managed instances would be converted from AHB to PAYG
#   ./set-sql-mi-license-type.sh --disable-ahub --report-only
#
#   # Disable AHB on all managed instances in a specific subscription
#   ./set-sql-mi-license-type.sh --subscription-id "<sub_id>" --disable-ahub --force
#
#   # Set all managed instances in a resource group to LicenseIncluded
#   ./set-sql-mi-license-type.sh --subscription-id "<sub_id>" \
#     --resource-group "<rg>" --license-type LicenseIncluded --force
#
#   # Disable AHB on a specific managed instance
#   ./set-sql-mi-license-type.sh --subscription-id "<sub_id>" \
#     --resource-group "<rg>" --instance-name "<mi_name>" --disable-ahub --force
# =============================================================================

set -euo pipefail

# --------------------------------------------------------------------------- #
# Defaults
# --------------------------------------------------------------------------- #
SUBSCRIPTION_ID=""
RESOURCE_GROUP=""
INSTANCE_NAME=""
LICENSE_TYPE=""
TENANT_ID=""
FORCE=false
REPORT_ONLY=false
DISABLE_AHUB=false
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
REPORT_FILE="SqlMI_LicenseChange_${TIMESTAMP}.csv"

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
        -i|--instance-name)     INSTANCE_NAME="$2";   shift 2 ;;
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
    LICENSE_TYPE="LicenseIncluded"
    FORCE=true
    echo "[INFO] --disable-ahub: targeting LicenseType=LicenseIncluded (PAYG) with --force."
fi

if [[ -z "$LICENSE_TYPE" ]]; then
    echo "[ERROR] You must specify --license-type or --disable-ahub." >&2
    exit 1
fi

if [[ "$LICENSE_TYPE" != "LicenseIncluded" && "$LICENSE_TYPE" != "BasePrice" ]]; then
    echo "[ERROR] --license-type must be 'LicenseIncluded' or 'BasePrice'." >&2
    exit 1
fi

# --------------------------------------------------------------------------- #
# Azure CLI check
# --------------------------------------------------------------------------- #
if ! command -v az &>/dev/null; then
    echo "[ERROR] Azure CLI (az) is not installed or not in PATH." >&2
    exit 1
fi

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
echo "SubscriptionId,ResourceGroup,InstanceName,CurrentLicenseType,TargetLicenseType,SKU,Location,Action" \
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

    # Enumerate managed instances
    mi_args=()
    [[ -n "$RESOURCE_GROUP" ]] && mi_args+=("--resource-group" "$RESOURCE_GROUP")
    [[ -n "$INSTANCE_NAME" ]] && mi_args+=("--name" "$INSTANCE_NAME" "--resource-group" "$RESOURCE_GROUP")

    if [[ -n "$INSTANCE_NAME" && -n "$RESOURCE_GROUP" ]]; then
        mi_list=$(az sql mi show --name "$INSTANCE_NAME" --resource-group "$RESOURCE_GROUP" \
            --query "[{name:name,licenseType:licenseType,sku:sku.name,location:location,rg:resourceGroup}]" \
            -o json 2>/dev/null) || { echo "  [WARNING] Could not retrieve instance $INSTANCE_NAME"; continue; }
    elif [[ -n "$RESOURCE_GROUP" ]]; then
        mi_list=$(az sql mi list --resource-group "$RESOURCE_GROUP" \
            --query "[].{name:name,licenseType:licenseType,sku:sku.name,location:location,rg:resourceGroup}" \
            -o json 2>/dev/null) || { echo "  [WARNING] Could not list instances in RG $RESOURCE_GROUP"; continue; }
    else
        mi_list=$(az sql mi list \
            --query "[].{name:name,licenseType:licenseType,sku:sku.name,location:location,rg:resourceGroup}" \
            -o json 2>/dev/null) || { echo "  [WARNING] Could not list managed instances"; continue; }
    fi

    mi_count=$(echo "$mi_list" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
    echo "  Found $mi_count managed instance(s)."

    for ((i=0; i<mi_count; i++)); do
        mi_name=$(echo "$mi_list" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[$i]['name'])")
        current_license=$(echo "$mi_list" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[$i].get('licenseType') or '')")
        sku=$(echo "$mi_list" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[$i].get('sku') or '')")
        location=$(echo "$mi_list" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[$i].get('location') or '')")
        rg=$(echo "$mi_list" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[$i].get('rg') or '')")

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
                echo "  [ReportOnly] Would modify: $mi_name [$current_license -> $LICENSE_TYPE]"
                action="WouldModify"
            else
                echo "  Modifying: $mi_name [$current_license -> $LICENSE_TYPE]"
                if az sql mi update \
                    --name "$mi_name" \
                    --resource-group "$rg" \
                    --license-type "$LICENSE_TYPE" \
                    --output none 2>/dev/null; then
                    echo "    Updated successfully."
                    action="Modified"
                else
                    echo "    [WARNING] Failed to update $mi_name" >&2
                    action="Failed"
                fi
            fi
        else
            echo "  NO CHANGE: $mi_name (already $current_license)"
        fi

        echo "${sub},${rg},${mi_name},${current_license},${LICENSE_TYPE},${sku},${location},${action}" \
            >> "$REPORT_FILE"
    done
done

# --------------------------------------------------------------------------- #
# Summary
# --------------------------------------------------------------------------- #
echo ""
echo "============================================"
echo "Report saved to: $REPORT_FILE"
echo "Total managed instances targeted for modification: $TOTAL_MODIFIED"
echo "Completed at: $(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================"
