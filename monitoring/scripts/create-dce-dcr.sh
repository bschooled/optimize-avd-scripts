#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Creates a Data Collection Endpoint (DCE) and Data Collection Rule (DCR) using the JSON templates in dcr-manual/.

Usage:
  create-dce-dcr.sh \
    --location <azure-region> \
    --resource-group <rg> \
    --dce-name <name> \
    --dcr-name <name> \
    --log-analytics-workspace-id <resourceId>

Notes:
- Requires Azure CLI: az
- This script creates resources in the provided resource group.
EOF
}

LOCATION=""
RG=""
DCE_NAME=""
DCR_NAME=""
LAW_RESOURCE_ID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --location) LOCATION="$2"; shift 2;;
    --resource-group) RG="$2"; shift 2;;
    --dce-name) DCE_NAME="$2"; shift 2;;
    --dcr-name) DCR_NAME="$2"; shift 2;;
    --log-analytics-workspace-id) LAW_RESOURCE_ID="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2;;
  esac
done

if [[ -z "$LOCATION" || -z "$RG" || -z "$DCE_NAME" || -z "$DCR_NAME" || -z "$LAW_RESOURCE_ID" ]]; then
  echo "Missing required arguments." >&2
  usage
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONITORING_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

DCE_JSON_TEMPLATE="$MONITORING_DIR/dce.json"
DCR_JSON_TEMPLATE="$MONITORING_DIR/dcr.json"

if [[ ! -f "$DCE_JSON_TEMPLATE" || ! -f "$DCR_JSON_TEMPLATE" ]]; then
  echo "Missing dce.json or dcr.json under $MONITORING_DIR" >&2
  exit 2
fi

# Ensure RG exists
az group show -n "$RG" >/dev/null

echo "Creating/updating DCE: $DCE_NAME"
DCE_ID=$(az resource create \
  --resource-group "$RG" \
  --name "$DCE_NAME" \
  --resource-type Microsoft.Insights/dataCollectionEndpoints \
  --api-version 2022-06-01 \
  --location "$LOCATION" \
  --properties "$(env LOCATION="$LOCATION" envsubst < "$DCE_JSON_TEMPLATE" | jq -c '.properties')" \
  --query id -o tsv)

echo "DCE id: $DCE_ID"

echo "Creating/updating DCR: $DCR_NAME"
# Build the DCR JSON by substituting variables, then strip to properties for az resource create
DCR_PROPERTIES=$(env LOCATION="$LOCATION" DCE_RESOURCE_ID="$DCE_ID" LAW_RESOURCE_ID="$LAW_RESOURCE_ID" envsubst < "$DCR_JSON_TEMPLATE" | jq -c '.properties')

DCR_ID=$(az resource create \
  --resource-group "$RG" \
  --name "$DCR_NAME" \
  --resource-type Microsoft.Insights/dataCollectionRules \
  --api-version 2022-06-01 \
  --location "$LOCATION" \
  --properties "$DCR_PROPERTIES" \
  --query id -o tsv)

echo "DCR id: $DCR_ID"

echo "Done. Next: associate the DCR to each session host VM."
