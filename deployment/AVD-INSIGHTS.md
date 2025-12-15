# AVD Insights Deployment

This deployment includes comprehensive monitoring for Azure Virtual Desktop using AVD Insights.

## What's Deployed

### Monitoring Infrastructure

1. **Log Analytics Workspace**
   - Centralized logging for all AVD components
   - Configurable retention (default: 30 days)
   - PerGB2018 pricing tier

2. **Data Collection Endpoint (DCE)**
   - Regional endpoint for data ingestion
   - Public network access enabled

3. **Data Collection Rule (DCR)**
  - Cost-optimized performance counters (30s and 90s intervals)
   - Windows Event Logs
   - AVD-specific metrics:
     - Session host performance
     - User input delay
     - RemoteFX network metrics
     - FSLogix operations
     - Terminal Services events

### Diagnostic Settings

All AVD components are configured to send diagnostic logs to Log Analytics:
- **Host Pool**: Connection logs, errors, management operations
- **Workspace**: Feed operations, connections
- **Application Groups**: Application usage

## Performance Counters Collected (Cost-Optimized)

### High Frequency (30 seconds)
- **CPU**: `\\Processor Information(_Total)\\% Processor Time`
- **Memory**: `\\Memory\\% Committed Bytes In Use`
- **User input delay (session)**: `\\User Input Delay per Session(*)\\Max Input Delay`
- **Terminal Services sessions**: `\\Terminal Services(*)\\Active Sessions`, `\\Terminal Services(*)\\Total Sessions`
- **OS disk free space**: `\\LogicalDisk(C:)\\% Free Space`

### Standard Frequency (90 seconds)
- **Disk I/O / latency** (LogicalDisk + PhysicalDisk)
- **RemoteFX network quality**: RTT and UDP bandwidth

Omitted for cost/noise reduction:
- `User Input Delay per Process(*)\\Max Input Delay` (very noisy)
- Page-fault oriented memory counters (e.g., `Page Faults/sec`, `Pages/sec`, `Cache Faults/sec`, `Demand Zero Faults/sec`, `Transition Faults/sec`, `Page Reads/sec`, `Page Writes/sec`)
- High-cardinality network adapter counters (often duplicated across adapters and noisy)

## Event Logs Collected

To keep ingestion cost predictable, event collection is restricted to actionable levels:

- **AVD (Terminal Services)**: Warnings + Errors
  - Local Session Manager (Operational)
  - Remote Connection Manager (Admin)
- **FSLogix**: Warnings + Errors
  - FSLogix Apps (Operational)
  - FSLogix Apps (Admin)
- **System / Application**: Errors only

## Deploying AVD with Insights

### 1. Deploy Infrastructure

```bash
# Using Azure Developer CLI
azd up

# Or using Azure CLI
az deployment sub create \
  --location westus \
  --template-file infra/main.bicep \
  --parameters infra/main.bicepparam
```

### 2. Deploy Session Hosts with Monitoring

After deploying the infrastructure, use the helper script to deploy session hosts:

```bash
cd avd-deployment

# Edit the script to configure your environment
vim deploy-sessionhost-with-monitoring.sh

# Update these variables:
# - RESOURCE_GROUP
# - HOST_POOL_NAME
# - VM_NAME
# - SUBNET_ID
# - DATA_COLLECTION_RULE_ID (from deployment outputs)

# Deploy session host
./deploy-sessionhost-with-monitoring.sh
```

### 3. Manual Session Host Configuration

If deploying session hosts manually, use the `sessionhost-monitoring.bicep` module:

```bash
# Get DCR ID from infrastructure deployment
DCR_ID=$(az deployment sub show \
  --name <deployment-name> \
  --query 'properties.outputs.dataCollectionRuleId.value' -o tsv)

# Deploy monitoring to existing session host
az deployment group create \
  --resource-group avd-dev-rg \
  --template-file infra/sessionhost-monitoring.bicep \
  --parameters \
    vmName=avd-sh-001 \
    location=westus \
    dataCollectionRuleId="$DCR_ID" \
    enableMonitoring=true
```

## Viewing AVD Insights

### Azure Portal

1. Navigate to Azure Portal
2. Go to **Azure Virtual Desktop** service
3. Select your **Host Pool**
4. Click **Insights** in the left menu
5. View:
   - Connection Performance
   - Host Performance
   - Users
   - Diagnostics

### Kusto Queries

Access Log Analytics workspace and run queries:

```kusto
// Session host performance
Perf
| where ObjectName == "Processor Information"
| where CounterName == "% Processor Time"
| where InstanceName == "_Total"
| summarize avg(CounterValue) by Computer, bin(TimeGenerated, 5m)
| render timechart

// User input delay
Perf
| where ObjectName == "User Input Delay per Session"
| where CounterName == "Max Input Delay"
| summarize max(CounterValue) by Computer, bin(TimeGenerated, 5m)
| render timechart

// Connection events
Event
| where Source == "Microsoft-Windows-TerminalServices-RemoteConnectionManager"
| where EventID in (1149, 1150, 1158)
| project TimeGenerated, Computer, EventID, RenderedDescription
| order by TimeGenerated desc

// FSLogix events
Event
| where Source startswith "FSLogix"
| where EventLevelName in ("Error", "Warning")
| project TimeGenerated, Computer, Source, EventID, RenderedDescription
| order by TimeGenerated desc

// Session counts
Perf
| where ObjectName == "Terminal Services"
| where CounterName in ("Active Sessions", "Total Sessions")
| summarize avg(CounterValue) by Computer, CounterName, bin(TimeGenerated, 5m)
| render timechart
```

## Data Collection Rule Details

The DCR collects comprehensive metrics for AVD Insights workbooks:

### Performance Counters
- **Processor**: CPU utilization, queue length, context switches
- **Memory**: Available memory, page faults, pool usage
- **Disk**: I/O operations, latency, throughput
- **Network**: Bandwidth utilization, errors, packets
- **Terminal Services**: Session counts, connection metrics
- **User Input Delay**: Responsiveness metrics
- **RemoteFX**: Network quality metrics

### Event Sources
- Terminal Services operational logs
- FSLogix application and admin logs
- System and application event logs
- Remote Connection Manager logs

## Cost Optimization

### Retention Settings
```bicep
param logAnalyticsRetentionDays = 30  // Minimum: 30, Maximum: 730
```

### Sampling Frequency
High-frequency metrics (30s) are limited to critical counters. Consider increasing sampling interval for cost savings:

```bicep
samplingFrequencyInSeconds: 60  // Change from 30 to 60
```

### Conditional Deployment
Disable insights for non-production environments:

```bicep
param enableInsights = false  // In dev/test parameter files
```

## Troubleshooting

### Azure Monitor Agent Not Installed

Check VM extensions:
```bash
az vm extension list \
  --resource-group <rg> \
  --vm-name <vm> \
  --query "[?name=='AzureMonitorWindowsAgent']"
```

Reinstall:
```bash
az deployment group create \
  --resource-group <rg> \
  --template-file infra/sessionhost-monitoring.bicep \
  --parameters vmName=<vm> location=<location> dataCollectionRuleId=<dcr-id>
```

### Data Not Appearing in Log Analytics

1. **Verify DCR Association**:
```bash
az monitor data-collection rule association list \
  --resource <vm-resource-id>
```

2. **Check Agent Status**:
```powershell
# On the session host
Get-Service AzureMonitorWindowsAgent
```

3. **Review Agent Logs**:
```
C:\WindowsAzure\Logs\Plugins\Microsoft.Azure.Monitor.AzureMonitorWindowsAgent\
```

4. **Wait for Data Collection**:
Data may take 5-10 minutes to appear after initial configuration.

### Workbooks Not Showing Data

1. Verify Log Analytics workspace is selected in workbook
2. Check time range (default: last 24 hours)
3. Confirm session hosts have the DCR associated
4. Validate diagnostic settings on host pool and workspace

## Integration with Troubleshooting Script

The `avd-troubleshoot.sh` script works seamlessly with monitored hosts:

```bash
# Put host in maintenance mode (monitoring continues)
./avd-troubleshoot.sh \
  --vm-name avd-sh-001 \
  --resource-group avd-dev-rg \
  --maintenance

# Restore host (monitoring automatically resumes)
./avd-troubleshoot.sh \
  --vm-name avd-sh-001 \
  --resource-group avd-dev-rg \
  --restore \
  --host-pool avd-dev-hp \
  --host-pool-rg avd-dev-rg
```

Azure Monitor Agent remains active during maintenance mode to track performance during troubleshooting.

## References

- [Azure Virtual Desktop Insights](https://learn.microsoft.com/azure/virtual-desktop/insights)
- [Data Collection Rules](https://learn.microsoft.com/azure/azure-monitor/essentials/data-collection-rule-overview)
- [Azure Monitor Agent](https://learn.microsoft.com/azure/azure-monitor/agents/azure-monitor-agent-overview)
- [AVD Diagnostics](https://learn.microsoft.com/azure/virtual-desktop/diagnostics-log-analytics)
