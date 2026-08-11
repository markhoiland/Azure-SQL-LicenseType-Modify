#!/usr/bin/env bash
# =============================================================================
# set-az-sql-db-license-type.sh
#
# SYNOPSIS:
#   Modifies the license type for Azure SQL Databases across one or more
#   subscriptions using Azure CLI.
#
# DESCRIPTION:
#   Scans Azure SQL Databases in the specified scope and converts them from
#   Azure Hybrid Benefit (BasePrice) to Pay-as-you-go (LicenseIncluded), or
#   sets any supported license type. Supports filtering by subscription,
#   resource group, server, or database name, and can exclude resources by tags.
#
#   License type values for Azure SQL Database:
#     LicenseIncluded  - Pay-as-you-go (PAYG)
#     BasePrice        - Azure Hybrid Benefit (AHB/BYOL)
#
# PREREQUISITES:
#   - Azure CLI >= 2.50.0  (az --version)
#   - Logged in to Azure  (az login) or running with managed identity
#   - Required role: SQL Server Contributor (or Contributor)
#
# USAGE:
#   ./set-az-sql-db-license-type.sh [OPTIONS]
#
# OPTIONS:
#   -s, --subscription-id   <id|file>   Subscription ID or path to a file with
#                                       one subscription ID per line. If omitted,
#                                       all accessible subscriptions are scanned.
#   -g, --resource-group    <name>      Limit scope to a specific resource group.
#   -n, --server-name       <name>      Limit scope to a specific SQL server.
#   -d, --database-name     <name>      Limit scope to a specific database.
#   -l, --license-type      <type>      Target license type: LicenseIncluded|BasePrice.
#       --disable-ahub                  Shorthand: set LicenseType=LicenseIncluded and --force.
#   -f, --force                         Update all resources, not just those that differ.
#   -t, --tenant-id         <id>        Azure tenant ID (used during az login).
#       --report-only                   Print what would change; do not modify anything.
#   -h, --help                          Show this help message.
#
# EXAMPLES:
#   # Report which databases would be converted from AHB to PAYG
#   ./set-az-sql-db-license-type.sh --disable-ahub --report-only
#
#   # Disable AHB on all databases in a specific subscription
#   ./set-az-sql-db-license-type.sh --subscription-id "<sub_id>" --disable-ahub --force
#
#   # Set a specific resource group to LicenseIncluded
#   ./set-az-sql-db-license-type.sh --subscription-id "<sub_id>" \
#     --resource-group "<rg>" --license-type LicenseIncluded --force
#
#   # Use a file with multiple subscription IDs
#   ./set-az-sql-db-license-type.sh --subscription-id subscriptions.txt --disable-ahub --force
# =============================================================================

set -euo pipefail

# --------------------------------------------------------------------------- #
# Defaults
# --------------------------------------------------------------------------- #
SUBSCRIPTION_ID=""
RESOURCE_GROUP=""
SERVER_NAME=""
DATABASE_NAME=""
LICENSE_TYPE=""
TENANT_ID=""
FORCE=false
REPORT_ONLY=false
DISABLE_AHUB=false
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
REPORT_FILE="SqlDb_LicenseChange_${TIMESTAMP}.csv"

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
        -n|--server-name)       SERVER_NAME="$2";     shift 2 ;;
        -d|--database-name)     DATABASE_NAME="$2";   shift 2 ;;
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
    echo "[INFO] --disable-ahub: only databases currently using BasePrice will be changed to LicenseIncluded (PAYG)."
fi

if [[ -z "$LICENSE_TYPE" ]]; then
    echo "[ERROR] You must specify --license-type or --disable-ahub." >&2
    exit 1
fi

if [[ "$LICENSE_TYPE" != "LicenseIncluded" && "$LICENSE_TYPE" != "BasePrice" ]]; then
    echo "[ERROR] --license-type must be 'LicenseIncluded' or 'BasePrice'." >&2
    exit 1
fi

if [[ -n "$SERVER_NAME" && -z "$RESOURCE_GROUP" ]]; then
    echo "[ERROR] --server-name requires --resource-group." >&2
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
        # File with one subscription ID per line (skip blank lines and comments)
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
echo "SubscriptionId,ResourceGroup,ServerName,DatabaseName,CurrentLicenseType,TargetLicenseType,Edition,Location,Action" \
    > "$REPORT_FILE"

TOTAL_MODIFIED=0

# --------------------------------------------------------------------------- #
# Helper: process databases on a server
# --------------------------------------------------------------------------- #
process_databases() {
    local sub_id="$1"
    local server="$2"
    local rg="$3"

    local db_query_args=("--server" "$server" "--resource-group" "$rg")
    [[ -n "$DATABASE_NAME" ]] && db_query_args+=("--name" "$DATABASE_NAME")

    local db_list
    db_list=$(az sql db list "${db_query_args[@]}" \
        --query "[?name!='master'].{name:name,licenseType:licenseType,edition:edition,location:location,rg:resourceGroup}" \
        -o json 2>/dev/null) || return 0

    local db_count
    db_count=$(echo "$db_list" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)

    for ((i=0; i<db_count; i++)); do
        local db_name current_license edition location
        db_name=$(echo "$db_list" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[$i]['name'])")
        current_license=$(echo "$db_list" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[$i].get('licenseType') or '')")
        edition=$(echo "$db_list" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[$i].get('edition') or '')")
        location=$(echo "$db_list" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[$i].get('location') or '')")

        local needs_update=false
        if $FORCE; then
            needs_update=true
        elif [[ "$current_license" != "$LICENSE_TYPE" ]]; then
            needs_update=true
        fi
        if $DISABLE_AHUB && [[ "$current_license" != "BasePrice" ]]; then
            needs_update=false
        fi

        local action="NoChange"
        if $needs_update; then
            action="Modify"
            TOTAL_MODIFIED=$((TOTAL_MODIFIED + 1))
            if $REPORT_ONLY; then
                echo "  [ReportOnly] Would modify: $server/$db_name [$current_license -> $LICENSE_TYPE]"
                action="WouldModify"
            else
                echo "  Modifying: $server/$db_name [$current_license -> $LICENSE_TYPE]"
                if az sql db update \
                    --server "$server" \
                    --resource-group "$rg" \
                    --name "$db_name" \
                    --license-type "$LICENSE_TYPE" \
                    --output none 2>/dev/null; then
                    echo "    Updated successfully."
                    action="Modified"
                else
                    echo "    [WARNING] Failed to update $db_name" >&2
                    action="Failed"
                fi
            fi
        else
            echo "  NO CHANGE: $server/$db_name (already $current_license)"
        fi

        echo "${sub_id},${rg},${server},${db_name},${current_license},${LICENSE_TYPE},${edition},${location},${action}" \
            >> "$REPORT_FILE"
    done
}

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

    # Enumerate SQL servers
    servers_args=()
    [[ -n "$RESOURCE_GROUP" ]] && servers_args+=("--resource-group" "$RESOURCE_GROUP")

    server_list=$(az sql server list "${servers_args[@]}" \
        --query "[].{name:name,rg:resourceGroup}" -o json 2>/dev/null) || continue

    server_count=$(echo "$server_list" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
    echo "  Found $server_count SQL server(s)."

    for ((si=0; si<server_count; si++)); do
        srv=$(echo "$server_list" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[$si]['name'])")
        srv_rg=$(echo "$server_list" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[$si]['rg'])")
        echo ""
        echo "  Server: $srv (RG: $srv_rg)"

        if [[ -n "$SERVER_NAME" && "$srv" != "$SERVER_NAME" ]]; then
            continue
        fi

        process_databases "$sub" "$srv" "$srv_rg"
    done
done

# --------------------------------------------------------------------------- #
# Summary
# --------------------------------------------------------------------------- #
echo ""
echo "============================================"
echo "Report saved to: $REPORT_FILE"
echo "Total databases targeted for modification: $TOTAL_MODIFIED"
echo "Completed at: $(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================"
