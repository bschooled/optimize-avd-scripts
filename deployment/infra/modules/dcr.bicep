targetScope = 'resourceGroup'

metadata name = 'Data Collection Rule for AVD Insights'
metadata description = 'Creates a Data Collection Rule with performance counters and event logs for AVD monitoring'

@description('Name of the Data Collection Rule')
param name string

@description('Location for the Data Collection Rule')
param location string

@description('Resource ID of the Data Collection Endpoint')
param dataCollectionEndpointId string

@description('Resource ID of the Log Analytics Workspace')
param logAnalyticsWorkspaceId string

@description('Tags to apply to the resource')
param tags object = {}

resource dataCollectionRule 'Microsoft.Insights/dataCollectionRules@2022-06-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    dataCollectionEndpointId: dataCollectionEndpointId
    dataSources: {
      performanceCounters: [
        {
          name: 'perfCounterCore30'
          streams: [
            'Microsoft-Perf'
          ]
          samplingFrequencyInSeconds: 30
          counterSpecifiers: [
            '\\LogicalDisk(C:)\\% Free Space'
            '\\Memory\\% Committed Bytes In Use'
            '\\Processor Information(_Total)\\% Processor Time'
            '\\User Input Delay per Session(*)\\Max Input Delay'
            '\\Terminal Services(*)\\Active Sessions'
            '\\Terminal Services(*)\\Total Sessions'
          ]
        }
        {
          name: 'perfCounterDiskRemoteFx90'
          streams: [
            'Microsoft-Perf'
          ]
          samplingFrequencyInSeconds: 90
          counterSpecifiers: [
            '\\LogicalDisk(C:)\\Avg. Disk sec/Read'
            '\\LogicalDisk(C:)\\Avg. Disk sec/Write'
            '\\LogicalDisk(C:)\\Disk Bytes/sec'
            '\\LogicalDisk(C:)\\Disk Read Bytes/sec'
            '\\LogicalDisk(C:)\\Disk Reads/sec'
            '\\LogicalDisk(C:)\\Disk Transfers/sec'
            '\\LogicalDisk(C:)\\Disk Write Bytes/sec'
            '\\LogicalDisk(C:)\\Disk Writes/sec'
            '\\LogicalDisk(C:)\\Free Megabytes'
            '\\PhysicalDisk(*)\\% Disk Read Time'
            '\\PhysicalDisk(*)\\% Disk Write Time'
            '\\PhysicalDisk(*)\\Avg. Disk Bytes/Read'
            '\\PhysicalDisk(*)\\Avg. Disk Bytes/Transfer'
            '\\PhysicalDisk(*)\\Avg. Disk Bytes/Write'
            '\\PhysicalDisk(*)\\Disk Bytes/sec'
            '\\PhysicalDisk(*)\\Disk Read Bytes/sec'
            '\\PhysicalDisk(*)\\Disk Reads/sec'
            '\\PhysicalDisk(*)\\Disk Transfers/sec'
            '\\PhysicalDisk(*)\\Disk Write Bytes/sec'
            '\\PhysicalDisk(*)\\Disk Writes/sec'
            '\\RemoteFX Network(*)\\Current TCP RTT'
            '\\RemoteFX Network(*)\\Current UDP Bandwidth'
          ]
        }
      ]
      windowsEventLogs: [
        {
          name: 'eventLogsDataSource'
          streams: [
            'Microsoft-Event'
          ]
          xPathQueries: [
            // AVD (TS) channels: warnings + errors (Level 2=Error, 3=Warning)
            'Microsoft-Windows-TerminalServices-LocalSessionManager/Operational!*[System[(Level=2 or Level=3)]]'
            'Microsoft-Windows-TerminalServices-RemoteConnectionManager/Admin!*[System[(Level=2 or Level=3)]]'

            // FSLogix channels: warnings + errors (Level 2=Error, 3=Warning)
            'Microsoft-FSLogix-Apps/Operational!*[System[(Level=2 or Level=3)]]'
            'Microsoft-FSLogix-Apps/Admin!*[System[(Level=2 or Level=3)]]'

            // OS/application broad logs: errors only (Level 2)
            'System!*[System[(Level=2)]]'
            'Application!*[System[(Level=2)]]'
          ]
        }
      ]
    }
    destinations: {
      logAnalytics: [
        {
          workspaceResourceId: logAnalyticsWorkspaceId
          name: 'avd-workspace'
        }
      ]
    }
    dataFlows: [
      {
        streams: [
          'Microsoft-Perf'
        ]
        destinations: [
          'avd-workspace'
        ]
      }
      {
        streams: [
          'Microsoft-Event'
        ]
        destinations: [
          'avd-workspace'
        ]
      }
    ]
  }
}

@description('Resource ID of the Data Collection Rule')
output id string = dataCollectionRule.id

@description('Name of the Data Collection Rule')
output name string = dataCollectionRule.name

@description('Immutable ID of the Data Collection Rule')
output immutableId string = dataCollectionRule.properties.immutableId
