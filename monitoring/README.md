# Manual AVD Insights Monitoring Setup

This folder contains **standalone artifacts** for manually creating Azure Monitor Data Collection Rules (DCR) for AVD Insights **without Bicep**.

These are the same rules deployed automatically by the [Bicep templates](../deployment/infra/modules/dcr.bicep), but packaged for manual CLI or Portal-based deployment.

## What this creates

- **DCE**: `Microsoft.Insights/dataCollectionEndpoints`
- **DCR**: `Microsoft.Insights/dataCollectionRules`
  - **Perf counters**
    - 30s “core” counters
    - 90s disk + RemoteFX counters
  - **Windows Event Logs** (XPath queries)
    - AVD Terminal Services + FSLogix: **Warning + Error** (`Level=3` or `Level=2`)
    - `System` + `Application`: **Error only** (`Level=2`)
- **Association**: associates the DCR to one or more session host VMs
  - Resource type: `Microsoft.Insights/dataCollectionRuleAssociations`

## Prereqs

- Azure CLI installed (`az`) and logged in: `az login`
- You know:
  - Subscription ID
  - Resource group containing the session hosts
  - Target region (same as your session hosts is typical)
  - Log Analytics Workspace resource ID (destination)

Optional but recommended:
- The Azure Monitor Agent (AMA) must be installed on each VM. You can install it via Portal or CLI.

## Files

- `dcr.json`: DCR definition (streams, data sources, destinations, data flows).
- `dce.json`: DCE definition.
- `scripts/create-dce-dcr.sh`: Creates DCE + DCR from the JSON files.
- `scripts/associate-dcr-to-vm.sh`: Installs AMA (optional) and associates the DCR to a VM.

## Quick start (Azure CLI)

From the monitoring folder:

```bash
cd monitoring

# Set these
export LOCATION="eastus"
export RG="my-avd-rg"
export DCE_NAME="avd-dce"
export DCR_NAME="avd-dcr"
export LAW_RESOURCE_ID="/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.OperationalInsights/workspaces/<name>"

./scripts/create-dce-dcr.sh \
  --location "$LOCATION" \
  --resource-group "$RG" \
  --dce-name "$DCE_NAME" \
  --dcr-name "$DCR_NAME" \
  --log-analytics-workspace-id "$LAW_RESOURCE_ID"
```

Then associate to a session host VM:

```bash
# VM name in the same RG
export VM_NAME="avd-sh-0"

./scripts/associate-dcr-to-vm.sh \
  --resource-group "$RG" \
  --vm-name "$VM_NAME" \
  --dcr-resource-id "$(az monitor data-collection rule show -g "$RG" -n "$DCR_NAME" --query id -o tsv)"
```

## Notes / gotchas

- **Region**: DCE and DCR must be created in a supported region (usually the same region as your AVD session hosts).
- **DCR destinations**: The `logAnalytics` destination is set to a destination name of `avd-workspace`. The scripts create the DCR with that destination name.
- **Event Log filtering**: This DCR intentionally narrows AVD/FSLogix to warning/error only to reduce ingestion cost.

## Portal-only implementation (high level)

If you prefer the Portal:

1. Create **Data Collection Endpoint** in the target resource group.
2. Create **Data Collection Rule**:
   - Add **Performance counters**:
     - 30-second set: see `dcr.json` (`perfCounterCore30`)
     - 90-second set: see `dcr.json` (`perfCounterDiskRemoteFx90`)
   - Add **Windows Event Logs** with the XPath queries from `dcr.json`.
   - Set **Destination** to your Log Analytics workspace.
3. Ensure each session host has **Azure Monitor Agent** installed.
4. Create a **DCR association** to each VM.

The CLI scripts in this folder do the same steps with fewer clicks.

## Related Documentation

- [Deployment (Bicep)](../deployment/README.md) - Automated infrastructure deployment with monitoring
- [AVD Insights Guide](../deployment/AVD-INSIGHTS.md) - Full monitoring setup and queries
- [Bicep Architecture](../deployment/BICEP-FIXES.md) - DCR module design and scoping
- [Image Builder](../image-builder/README.md) - Building optimized AVD images

