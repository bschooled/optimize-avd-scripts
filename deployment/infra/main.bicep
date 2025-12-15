targetScope = 'subscription'

metadata name = 'AVD Pooled Multi-Session Host Pool Deployment'
metadata description = 'Deploys an Azure Virtual Desktop pooled host pool with desktop app group in West US, with optional ephemeral OS disk support'
metadata owner = 'AVD Admin'

@description('Name prefix for AVD resources (host pool, app group, workspace)')
param namePrefix string = 'avd'

@description('Environment name (dev, test, prod)')
param environmentName string = 'dev'

@description('Location for all resources')
param location string = 'westus'

@description('Resource group name for AVD resources')
param resourceGroupName string = '${namePrefix}-${environmentName}-rg'

@description('Host pool friendly name')
param hostPoolFriendlyName string = 'Pooled Multi-Session Host Pool'

@description('Host pool description')
param hostPoolDescription string = 'Pooled host pool for multi-session desktops'

@description('Maximum number of sessions per session host')
@minValue(1)
@maxValue(999999)
param maxSessionLimit int = 10

@description('Load balancer type')
@allowed([
  'BreadthFirst'
  'DepthFirst'
])
param loadBalancerType string = 'BreadthFirst'

@description('Enable Start VM On Connect feature')
param startVMOnConnect bool = true

@description('Validation environment')
param validationEnvironment bool = false

@description('Custom RDP properties')
param customRdpProperty string = 'drivestoredirect:s:;redirectclipboard:i:1;redirectcomports:i:1;redirectprinters:i:1;redirectsmartcards:i:1;screen mode id:i:2;'

@description('Application group friendly name')
param appGroupFriendlyName string = 'Desktop Application Group'

@description('Workspace friendly name')
param workspaceFriendlyName string = '${namePrefix}-${environmentName} Workspace'

@description('Workspace description')
param workspaceDescription string = 'AVD Workspace for ${environmentName} environment'

@description('Enable VM template with ephemeral OS disk configuration')
param enableEphemeralOSDisk bool = false

@description('VM size for session hosts')
param vmSize string = 'Standard_D4s_v5'

@description('OS disk type (Standard_LRS, Premium_LRS, StandardSSD_LRS)')
@allowed([
  'Standard_LRS'
  'Premium_LRS'
  'StandardSSD_LRS'
  'Premium_ZRS'
  'StandardSSD_ZRS'
])
param osDiskType string = 'StandardSSD_LRS'

@description('Image reference for session hosts')
param imageReference object = {
  publisher: 'MicrosoftWindowsDesktop'
  offer: 'windows-11'
  sku: 'win11-25h2-avd'
  version: 'latest'
}

@description('Tags to apply to all resources')
param tags object = {
  Environment: environmentName
  Workload: 'AVD'
  ManagedBy: 'AZD'
}

@description('Enable AVD Insights monitoring')
param enableInsights bool = true

@description('Log Analytics workspace name for AVD Insights')
param logAnalyticsWorkspaceName string = '${namePrefix}-${environmentName}-law'

@description('Log Analytics workspace retention in days')
@minValue(30)
@maxValue(730)
param logAnalyticsRetentionDays int = 30

@description('Data Collection Rule name')
param dataCollectionRuleName string = '${namePrefix}-${environmentName}-dcr'

// Resource group for AVD resources
resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

// Log Analytics Workspace for AVD Insights
module logAnalytics 'br/public:avm/res/operational-insights/workspace:0.9.1' = if (enableInsights) {
  scope: rg
  name: 'logAnalytics-${namePrefix}-${environmentName}'
  params: {
    name: logAnalyticsWorkspaceName
    location: location
    dataRetention: logAnalyticsRetentionDays
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
    skuName: 'PerGB2018'
    tags: union(tags, {
      ResourceType: 'LogAnalytics'
    })
  }
}

// Data Collection Endpoint for AVD Insights (deployed as module to resource group)
module dataCollectionEndpoint 'modules/dce.bicep' = if (enableInsights) {
  scope: rg
  name: 'dce-${namePrefix}-${environmentName}'
  params: {
    name: '${namePrefix}-${environmentName}-dce'
    location: location
    tags: union(tags, {
      ResourceType: 'DataCollectionEndpoint'
    })
  }
}

// Data Collection Rule for AVD Insights (deployed as module to resource group)
module dataCollectionRule 'modules/dcr.bicep' = if (enableInsights) {
  scope: rg
  name: 'dcr-${namePrefix}-${environmentName}'
  params: {
    name: dataCollectionRuleName
    location: location
    dataCollectionEndpointId: dataCollectionEndpoint.outputs.id
    logAnalyticsWorkspaceId: logAnalytics.outputs.resourceId
    tags: union(tags, {
      ResourceType: 'DataCollectionRule'
    })
  }
}

// Host Pool deployment
module hostPool 'br/public:avm/res/desktop-virtualization/host-pool:0.8.1' = {
  scope: rg
  name: 'hostPool-${namePrefix}-${environmentName}'
  params: {
    name: '${namePrefix}-${environmentName}-hp'
    location: location
    hostPoolType: 'Pooled'
    loadBalancerType: loadBalancerType
    preferredAppGroupType: 'Desktop'
    maxSessionLimit: maxSessionLimit
    startVMOnConnect: startVMOnConnect
    validationEnvironment: validationEnvironment
    customRdpProperty: customRdpProperty
    friendlyName: hostPoolFriendlyName
    description: hostPoolDescription
    diagnosticSettings: enableInsights
      ? [
          {
            name: 'avd-insights-hostpool'
            workspaceResourceId: logAnalytics.outputs.resourceId
            logCategoriesAndGroups: [
              {
                categoryGroup: 'allLogs'
              }
            ]
          }
        ]
      : []
    vmTemplate: enableEphemeralOSDisk ? {
      domain: ''
      galleryImageOffer: imageReference.offer
      galleryImagePublisher: imageReference.publisher
      galleryImageSKU: imageReference.sku
      imageType: 'Gallery'
      imageUri: null
      customImageId: null
      namePrefix: '${namePrefix}${environmentName}'
      osDiskType: osDiskType
      useManagedDisks: true
      vmSize: {
        id: vmSize
        cores: null
        ram: null
      }
      galleryItemId: '${imageReference.publisher}.${imageReference.offer}${imageReference.sku}'
      // Ephemeral OS disk configuration
      osDisk: {
        caching: 'ReadOnly'
        diffDiskSettings: {
          option: 'Local'
          placement: 'CacheDisk'
        }
        managedDisk: {
          storageAccountType: osDiskType
        }
      }
    } : {}
    tags: union(tags, {
      ResourceType: 'HostPool'
    })
  }
}

// Desktop Application Group
module appGroup 'br/public:avm/res/desktop-virtualization/application-group:0.4.1' = {
  scope: rg
  name: 'appGroup-${namePrefix}-${environmentName}'
  params: {
    name: '${namePrefix}-${environmentName}-dag'
    location: location
    applicationGroupType: 'Desktop'
    hostpoolName: hostPool.outputs.name
    friendlyName: appGroupFriendlyName
    tags: union(tags, {
      ResourceType: 'ApplicationGroup'
    })
  }
}

// Workspace
module workspace 'br/public:avm/res/desktop-virtualization/workspace:0.9.1' = {
  scope: rg
  name: 'workspace-${namePrefix}-${environmentName}'
  params: {
    name: '${namePrefix}-${environmentName}-ws'
    location: location
    friendlyName: workspaceFriendlyName
    description: workspaceDescription
    applicationGroupReferences: [
      appGroup.outputs.resourceId
    ]
    diagnosticSettings: enableInsights
      ? [
          {
            name: 'avd-insights-workspace'
            workspaceResourceId: logAnalytics.outputs.resourceId
            logCategoriesAndGroups: [
              {
                categoryGroup: 'allLogs'
              }
            ]
          }
        ]
      : []
    tags: union(tags, {
      ResourceType: 'Workspace'
    })
  }
}

@description('The name of the resource group')
output resourceGroupName string = rg.name

@description('The resource ID of the host pool')
output hostPoolResourceId string = hostPool.outputs.resourceId

@description('The name of the host pool')
output hostPoolName string = hostPool.outputs.name

@description('The registration token for the host pool (if managementType is Standard)')
output hostPoolRegistrationToken string = hostPool.outputs.?registrationToken ?? ''

@description('The resource ID of the application group')
output applicationGroupResourceId string = appGroup.outputs.resourceId

@description('The name of the application group')
output applicationGroupName string = appGroup.outputs.name

@description('The resource ID of the workspace')
output workspaceResourceId string = workspace.outputs.resourceId

@description('The name of the workspace')
output workspaceName string = workspace.outputs.name

@description('The location of the deployed resources')
output location string = location

@description('The resource ID of the Log Analytics workspace')
output logAnalyticsWorkspaceId string = logAnalytics.?outputs.?resourceId ?? ''

@description('The name of the Log Analytics workspace')
output logAnalyticsWorkspaceName string = logAnalytics.?outputs.?name ?? ''

@description('The workspace ID (customer ID) of the Log Analytics workspace')
output logAnalyticsWorkspaceCustomerId string = logAnalytics.?outputs.?logAnalyticsWorkspaceId ?? ''

@description('The resource ID of the Data Collection Rule')
output dataCollectionRuleId string = dataCollectionRule.?outputs.?id ?? ''

@description('The name of the Data Collection Rule')
output dataCollectionRuleName string = dataCollectionRule.?outputs.?name ?? ''

@description('The resource ID of the Data Collection Endpoint')
output dataCollectionEndpointId string = dataCollectionEndpoint.?outputs.?id ?? ''

@description('AVD Insights enabled status')
output insightsEnabled bool = enableInsights
