#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Associates an existing Data Collection Rule (DCR) to a VM and (optionally) installs Azure Monitor Agent.

Usage:
  associate-dcr-to-vm.sh \
    --resource-group <rg> \
    --vm-name <name> \
    --dcr-resource-id <resourceId> \
    [--association-name <name>] \
    [--install-ama]

Notes:
- The association is created at:
  Microsoft.Insights/dataCollectionRuleAssociations
- If --install-ama is used, this installs the AMA VM extension first.
EOF
}

RG=""
VM_NAME=""
DCR_ID=""
ASSOC_NAME="dcr-association"
INSTALL_AMA="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --resource-group) RG="$2"; shift 2;;
    --vm-name) VM_NAME="$2"; shift 2;;
    --dcr-resource-id) DCR_ID="$2"; shift 2;;
    --association-name) ASSOC_NAME="$2"; shift 2;;
    --install-ama) INSTALL_AMA="true"; shift 1;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2;;
  esac
done

if [[ -z "$RG" || -z "$VM_NAME" || -z "$DCR_ID" ]]; then
  echo "Missing required arguments." >&2
  usage
  exit 2
fi

VM_ID=$(az vm show -g "$RG" -n "$VM_NAME" --query id -o tsv)
LOCATION=$(az vm show -g "$RG" -n "$VM_NAME" --query location -o tsv)

if [[ "$INSTALL_AMA" == "true" ]]; then
  echo "Installing Azure Monitor Agent (AMA) on $VM_NAME"
  az vm extension set \
    --resource-group "$RG" \
    --vm-name "$VM_NAME" \
    --name AzureMonitorWindowsAgent \
    --publisher Microsoft.Azure.Monitor \
    --location "$LOCATION" \
    --enable-auto-upgrade true \
    --only-show-errors
fi

echo "Creating DCR association '$ASSOC_NAME' on $VM_NAME"
# Association is a child resource under the VM scope.
az resource create \
  --name "$ASSOC_NAME" \
  --resource-group "$RG" \
  --resource-type Microsoft.Insights/dataCollectionRuleAssociations \
  --api-version 2022-06-01 \
  --scope "$VM_ID" \
  --properties "{\"dataCollectionRuleId\":\"$DCR_ID\"}" \
  --only-show-errors >/dev/null

echo "Done. Validate in Logs/Insights after a few minutes."
