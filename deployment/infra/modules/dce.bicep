targetScope = 'resourceGroup'

metadata name = 'Data Collection Endpoint'
metadata description = 'Creates a Data Collection Endpoint for Azure Monitor'

@description('Name of the Data Collection Endpoint')
param name string

@description('Location for the Data Collection Endpoint')
param location string

@description('Tags to apply to the resource')
param tags object = {}

resource dataCollectionEndpoint 'Microsoft.Insights/dataCollectionEndpoints@2022-06-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    networkAcls: {
      publicNetworkAccess: 'Enabled'
    }
  }
}

@description('Resource ID of the Data Collection Endpoint')
output id string = dataCollectionEndpoint.id

@description('Name of the Data Collection Endpoint')
output name string = dataCollectionEndpoint.name
