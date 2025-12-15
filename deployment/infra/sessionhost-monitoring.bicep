targetScope = 'resourceGroup'

metadata name = 'AVD Session Host Monitoring Configuration'
metadata description = 'Deploys Azure Monitor Agent and associates Data Collection Rule to AVD session hosts'

@description('Name of the session host VM')
param vmName string

@description('Location for the VM extension')
param location string

@description('Resource ID of the Data Collection Rule')
param dataCollectionRuleId string

@description('Enable Azure Monitor Agent')
param enableMonitoring bool = true

@description('Tags to apply to resources')
param tags object = {}

// Reference to existing VM
resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' existing = {
  name: vmName
}

// Azure Monitor Agent Extension for Windows
resource azureMonitorAgent 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = if (enableMonitoring) {
  parent: vm
  name: 'AzureMonitorWindowsAgent'
  location: location
  tags: tags
  properties: {
    publisher: 'Microsoft.Azure.Monitor'
    type: 'AzureMonitorWindowsAgent'
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
    enableAutomaticUpgrade: true
    settings: {
      authentication: {
        managedIdentity: {
          'identifier-name': 'mi_res_id'
          'identifier-value': ''  // Uses system-assigned identity
        }
      }
    }
  }
}

// Data Collection Rule Association
resource dataCollectionRuleAssociation 'Microsoft.Insights/dataCollectionRuleAssociations@2022-06-01' = if (enableMonitoring) {
  name: 'avd-dcr-${uniqueString(vmName, dataCollectionRuleId)}'
  scope: vm
  properties: {
    dataCollectionRuleId: dataCollectionRuleId
    description: 'Association of Data Collection Rule for AVD Insights'
  }
  dependsOn: [
    azureMonitorAgent
  ]
}

@description('Name of the Azure Monitor Agent extension')
output azureMonitorAgentName string = enableMonitoring ? azureMonitorAgent.name : ''

@description('Provisioning state of the Azure Monitor Agent')
output azureMonitorAgentProvisioningState string = azureMonitorAgent.?properties.?provisioningState ?? ''

@description('Name of the Data Collection Rule Association')
output dataCollectionRuleAssociationName string = enableMonitoring ? dataCollectionRuleAssociation.name : ''
