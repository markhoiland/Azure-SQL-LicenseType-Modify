#!/usr/bin/env bash
# =============================================================================
# set-arc-sql-license-type.sh
#
# SYNOPSIS:
#   Modifies the license type and related settings for Azure Arc-enabled SQL
#   Server instances across one or more subscriptions using Azure CLI.
#
# DESCRIPTION:
#   Scans Azure Arc-enabled SQL Server extension resources (type:
#   microsoft.hybridcompute/machines/extensions, publisher: Microsoft.AzureData)
#   in the specified scope and updates the license type, ESU policy, and/or
#   unlimited virtualization (p-core) license. Supports filtering by
#   subscription, resource group, or machine name.
#
#   This script is based on the Microsoft sql-server-samples reference:
#   https://github.com/microsoft/sql-server-samples/tree/master/samples/manage/
#   azure-arc-enabled-sql-server/modify-license-type
#
#   License type values for Azure Arc-enabled SQL Server:
#     PAYG        - Pay-as-you-go. SQL Server usage is billed hourly via Azure.
#     Paid        - Paid license with Software Assurance (SA).
#     LicenseOnly - License without SA (perpetual license, no SA).
#
# PREREQUISITES:
#   - Azure CLI >= 2.50.0  (az --version)
#   - Logged in to Azure  (az login) or running with managed identity
#   - Required role: Azure Connected Machine Resource Administrator
#   - Azure Extension for SQL Server version >= 1.1.2230.58
#
# USAGE:
#   ./set-arc-sql-license-type.sh [OPTIONS]
#
# OPTIONS:
#   -s, --subscription-id   <id|file>   Subscription ID or path to a file with
#                                       one subscription ID per line.
#   -g, --resource-group    <name>      Limit scope to a specific resource group.
#   -m, --machine-name      <name>      Limit scope to a specific machine name.
#   -l, --license-type      <type>      Target license type: PAYG|Paid|LicenseOnly.
#       --enable-esu        <Yes|No>    Enable or disable ESU policy.
#       --use-pcore-license <Yes|No>    Enable or disable unlimited virt. license.
#   -f, --force                         Apply license type even if already set.
#   -t, --tenant-id         <id>        Azure tenant ID (used during az login).
#       --report-only                   Print what would change; do not modify.
#   -h, --help                          Show this help message.
#
# EXAMPLES:
#   # Report which Arc SQL servers would have license type changed to PAYG
#   ./set-arc-sql-license-type.sh --license-type PAYG --report-only
#
#   # Set license type to PAYG on all Arc SQL servers in a subscription
#   ./set-arc-sql-license-type.sh --subscription-id "<sub_id>" \
#     --license-type PAYG --force
#
#   # Enable ESU on all Arc SQL servers in a resource group (requires PAYG/Paid)
#   ./set-arc-sql-license-type.sh --subscription-id "<sub_id>" \
#     --resource-group "<rg>" --enable-esu Yes
#
#   # Set to PAYG and enable p-core license
#   ./set-arc-sql-license-type.sh --subscription-id "<sub_id>" \
#     --license-type PAYG --use-pcore-license Yes --force
#
#   # Disable ESU on all Arc SQL servers in a subscription
#   ./set-arc-sql-license-type.sh --subscription-id "<sub_id>" --enable-esu No
# =============================================================================

set -euo pipefail

# --------------------------------------------------------------------------- #
# Defaults
# --------------------------------------------------------------------------- #
SUBSCRIPTION_ID=""
RESOURCE_GROUP=""
MACHINE_NAME=""
LICENSE_TYPE=""
ENABLE_ESU=""
USE_PCORE_LICENSE=""
TENANT_ID=""
FORCE=false
REPORT_ONLY=false
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
REPORT_FILE="ArcSql_LicenseChange_${TIMESTAMP}.csv"

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
        -s|--subscription-id)    SUBSCRIPTION_ID="$2";    shift 2 ;;
        -g|--resource-group)     RESOURCE_GROUP="$2";     shift 2 ;;
        -m|--machine-name)       MACHINE_NAME="$2";       shift 2 ;;
        -l|--license-type)       LICENSE_TYPE="$2";       shift 2 ;;
           --enable-esu)         ENABLE_ESU="$2";         shift 2 ;;
           --use-pcore-license)  USE_PCORE_LICENSE="$2";  shift 2 ;;
        -f|--force)              FORCE=true;              shift   ;;
        -t|--tenant-id)          TENANT_ID="$2";          shift 2 ;;
           --report-only)        REPORT_ONLY=true;        shift   ;;
        -h|--help)               usage ;;
        *) echo "Unknown option: $1" >&2; usage ;;
    esac
done

# --------------------------------------------------------------------------- #
# Validate parameters
# --------------------------------------------------------------------------- #
if [[ -z "$LICENSE_TYPE" && -z "$ENABLE_ESU" && -z "$USE_PCORE_LICENSE" ]]; then
    echo "[ERROR] You must specify at least one of: --license-type, --enable-esu, --use-pcore-license." >&2
    exit 1
fi

if [[ -n "$LICENSE_TYPE" ]] && \
   [[ "$LICENSE_TYPE" != "PAYG" && "$LICENSE_TYPE" != "Paid" && "$LICENSE_TYPE" != "LicenseOnly" ]]; then
    echo "[ERROR] --license-type must be 'PAYG', 'Paid', or 'LicenseOnly'." >&2
    exit 1
fi

if [[ -n "$ENABLE_ESU" && "$ENABLE_ESU" != "Yes" && "$ENABLE_ESU" != "No" ]]; then
    echo "[ERROR] --enable-esu must be 'Yes' or 'No'." >&2
    exit 1
fi

if [[ -n "$USE_PCORE_LICENSE" && "$USE_PCORE_LICENSE" != "Yes" && "$USE_PCORE_LICENSE" != "No" ]]; then
    echo "[ERROR] --use-pcore-license must be 'Yes' or 'No'." >&2
    exit 1
fi

if [[ "$LICENSE_TYPE" == "LicenseOnly" && "$ENABLE_ESU" == "Yes" ]]; then
    echo "[ERROR] ESU cannot be enabled when license type is 'LicenseOnly'." >&2
    exit 1
fi

# --------------------------------------------------------------------------- #
# Azure CLI check
# --------------------------------------------------------------------------- #
if ! command -v az &>/dev/null; then
    echo "[ERROR] Azure CLI (az) is not installed or not in PATH." >&2
    exit 1
fi

if ! command -v python3 &>/dev/null; then
    echo "[ERROR] python3 is required for JSON parsing." >&2
    exit 1
fi

# --------------------------------------------------------------------------- #
# Authentication check
# --------------------------------------------------------------------------- #
if [[ -n "$TENANT_ID" ]]; then
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
echo "SubscriptionId,ResourceGroup,MachineName,ExtensionName,OriginalLicenseType,TargetLicenseType,Action" \
    > "$REPORT_FILE"

TOTAL_MODIFIED=0

# --------------------------------------------------------------------------- #
# Helper: build Resource Graph query
# --------------------------------------------------------------------------- #
build_rg_query() {
    local sub_id="$1"
    local license_filter=""
    local rg_filter=""
    local machine_filter=""

    [[ -n "$LICENSE_TYPE" ]] && \
        license_filter="| where properties.settings.LicenseType!='${LICENSE_TYPE}'"
    [[ -n "$RESOURCE_GROUP" ]] && \
        rg_filter="| where resourceGroup =~ '${RESOURCE_GROUP}'"
    [[ -n "$MACHINE_NAME" ]] && \
        machine_filter="| where name =~ '${MACHINE_NAME}'"

    cat <<EOF
resources
| where subscriptionId =~ '${sub_id}'
| where type == 'microsoft.hybridcompute/machines'
| where properties.detectedProperties.mssqldiscovered == 'true'
${rg_filter}
${machine_filter}
| extend machineId = tolower(tostring(id))
| project machineId, machineName = tolower(name)
| join kind=inner (
    resources
    | where subscriptionId =~ '${sub_id}'
    | where type == 'microsoft.hybridcompute/machines/extensions'
    | where properties.publisher =~ 'Microsoft.AzureData'
    | where properties.provisioningState == 'Succeeded'
    ${license_filter}
    | extend extensionName = name
    | extend extensionPublisher = properties.publisher
    | extend extensionType = properties.type
    | parse id with '/subscriptions/' subId '/resourceGroups/' resourceGroup '/providers/Microsoft.HybridCompute/machines/' machineNameRaw '/extensions/' extName
    | extend machineName = tolower(machineNameRaw)
) on \$left.machineName == \$right.machineName
| project machineName, extensionName, resourceGroup, location, subscriptionId = subId, extensionPublisher, extensionType
| order by machineName asc
EOF
}

# --------------------------------------------------------------------------- #
# Helper: update extension settings via REST
# --------------------------------------------------------------------------- #
update_arc_extension() {
    local sub_id="$1"
    local rg="$2"
    local machine="$3"
    local ext_name="$4"
    local publisher="$5"
    local ext_type="$6"
    local location="$7"
    local current_license="$8"

    # Get current extension settings
    local ext_json
    ext_json=$(az connectedmachine extension show \
        --machine-name "$machine" \
        --resource-group "$rg" \
        --name "$ext_name" \
        --subscription "$sub_id" \
        -o json 2>/dev/null) || { echo "    [WARNING] Could not get extension details"; return 1; }

    local settings_json
    settings_json=$(echo "$ext_json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
settings = d.get('properties', {}).get('settings', {})
print(json.dumps(settings))
")

    # Build updated settings in Python
    local NOW
    NOW=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")

    local new_settings_json
    new_settings_json=$(python3 <<PYEOF
import json, sys

settings = json.loads('''${settings_json}''')
write = False

# License type
license_type = "${LICENSE_TYPE}"
force = "${FORCE}" == "true"

if license_type:
    current_lt = settings.get("LicenseType", "")
    if current_lt == license_type and not force:
        pass
    else:
        # LicenseOnly cannot be set when ESU is enabled
        esu_enabled = settings.get("enableExtendedSecurityUpdates", False)
        enable_esu = "${ENABLE_ESU}"
        lo_allowed = (not esu_enabled and not enable_esu) or (enable_esu == "No")
        if license_type == "LicenseOnly" and not lo_allowed:
            print(json.dumps({"__error": "ESU must be disabled before setting LicenseOnly"}))
            sys.exit(0)
        if current_lt:
            if force:
                settings["LicenseType"] = license_type
                write = True
        else:
            settings["LicenseType"] = license_type
            write = True

# ESU
enable_esu = "${ENABLE_ESU}"
if enable_esu:
    lt = settings.get("LicenseType", "")
    if lt in ("Paid", "PAYG") or enable_esu == "No":
        settings["enableExtendedSecurityUpdates"] = (enable_esu == "Yes")
        settings["esuLastUpdatedTimestamp"] = "${NOW}"
        write = True

# P-Core
use_pcore = "${USE_PCORE_LICENSE}"
if use_pcore:
    lt = settings.get("LicenseType", "")
    if lt in ("Paid", "PAYG") or use_pcore == "No":
        settings["UsePhysicalCoreLicense"] = {
            "IsApplied": (use_pcore == "Yes"),
            "LastUpdatedTimestamp": "${NOW}"
        }
        write = True

if write:
    settings["__write"] = True

print(json.dumps(settings))
PYEOF
)

    # Check for errors
    if echo "$new_settings_json" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if '__error' in d else 1)" 2>/dev/null; then
        local error_msg
        error_msg=$(echo "$new_settings_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('__error',''))" 2>/dev/null)
        if [[ -n "$error_msg" ]]; then
            echo "    [SKIPPED] $error_msg"
            return 0
        fi
    fi

    # Check if any write is needed
    local needs_write
    needs_write=$(echo "$new_settings_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print('true' if d.get('__write') else 'false')")

    if [[ "$needs_write" != "true" ]]; then
        echo "  NO CHANGE needed for: $machine"
        return 0
    fi

    # Remove internal marker and send update
    local final_settings
    final_settings=$(echo "$new_settings_json" | python3 -c "
import sys,json
d=json.load(sys.stdin)
d.pop('__write', None)
print(json.dumps(d))
")

    TOTAL_MODIFIED=$((TOTAL_MODIFIED + 1))

    if $REPORT_ONLY; then
        echo "  [ReportOnly] Would update: $machine [$current_license -> ${LICENSE_TYPE:-unchanged}]"
        return 0
    fi

    echo "  Updating: $machine [$current_license -> ${LICENSE_TYPE:-unchanged}]"
    az connectedmachine extension update \
        --machine-name "$machine" \
        --resource-group "$rg" \
        --name "$ext_name" \
        --subscription "$sub_id" \
        --publisher "$publisher" \
        --type "$ext_type" \
        --settings "$final_settings" \
        --no-wait \
        --output none 2>/dev/null && echo "    Update submitted (async)." || \
        echo "    [WARNING] Update command failed."
}

# --------------------------------------------------------------------------- #
# Main loop
# --------------------------------------------------------------------------- #
echo ""
echo "-- Scanning subscriptions for Arc-enabled SQL Server resources --"

for sub in "${SUBSCRIPTIONS[@]}"; do
    echo ""
    echo "=== Subscription: $sub ==="
    az account set --subscription "$sub" 2>/dev/null || {
        echo "  [WARNING] Cannot access subscription $sub, skipping." >&2
        continue
    }

    # Run Resource Graph query
    local_query=$(build_rg_query "$sub")
    resource_list=$(az graph query -q "$local_query" \
        --query "data" -o json 2>/dev/null) || {
        echo "  [WARNING] Resource Graph query failed for $sub"
        continue
    }

    resource_count=$(echo "$resource_list" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
    echo "  Found $resource_count Arc SQL extension resource(s) to evaluate."

    for ((i=0; i<resource_count; i++)); do
        machine=$(echo "$resource_list"  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[$i]['machineName'])")
        ext_name=$(echo "$resource_list" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[$i]['extensionName'])")
        rg=$(echo "$resource_list"       | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[$i]['resourceGroup'])")
        location=$(echo "$resource_list" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[$i]['location'])")
        publisher=$(echo "$resource_list"| python3 -c "import sys,json; d=json.load(sys.stdin); print(d[$i]['extensionPublisher'])")
        ext_type=$(echo "$resource_list" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[$i]['extensionType'])")

        echo "  Processing: $machine / $ext_name"

        # Get current license type for reporting
        current_license=$(az connectedmachine extension show \
            --machine-name "$machine" \
            --resource-group "$rg" \
            --name "$ext_name" \
            --subscription "$sub" \
            --query "properties.settings.LicenseType" -o tsv 2>/dev/null || echo "")

        update_arc_extension "$sub" "$rg" "$machine" "$ext_name" "$publisher" "$ext_type" "$location" "$current_license"
        action_result=$(if $REPORT_ONLY; then echo "WouldModify"; else echo "Modified"; fi)

        echo "${sub},${rg},${machine},${ext_name},${current_license},${LICENSE_TYPE},${action_result}" \
            >> "$REPORT_FILE"
    done
done

# --------------------------------------------------------------------------- #
# Summary
# --------------------------------------------------------------------------- #
echo ""
echo "============================================"
echo "Report saved to: $REPORT_FILE"
echo "Total Arc SQL resources targeted: $TOTAL_MODIFIED"
echo "Completed at: $(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================"
