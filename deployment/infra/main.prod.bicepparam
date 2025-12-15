using './main.bicep'

// Basic Configuration
param namePrefix = 'avd'
param environmentName = 'prod'
param location = 'westus'

// Host Pool Configuration  
param hostPoolFriendlyName = 'Production Multi-Session Pool'
param hostPoolDescription = 'Production pooled host pool for enterprise desktops'
param maxSessionLimit = 20
param loadBalancerType = 'BreadthFirst'
param startVMOnConnect = true
param validationEnvironment = false

// Application Group
param appGroupFriendlyName = 'Production Desktop Apps'

// Workspace
param workspaceFriendlyName = 'Production Workspace'
param workspaceDescription = 'AVD Workspace for production environment'

// VM Configuration (without Ephemeral OS for production persistence)
param enableEphemeralOSDisk = false
param vmSize = 'Standard_D8s_v5'
param osDiskType = 'Premium_LRS'
param imageReference = {
  publisher: 'MicrosoftWindowsDesktop'
  offer: 'windows-11'
  sku: 'win11-25h2-avd-m365'
  version: 'latest'
}

// Custom RDP Properties  
param customRdpProperty = 'drivestoredirect:s:;redirectclipboard:i:1;redirectcomports:i:1;redirectprinters:i:1;redirectsmartcards:i:1;screen mode id:i:2;audiocapturemode:i:1;videoplaybackmode:i:1;'

// Tags
param tags = {
  Environment: 'Production'
  Workload: 'AVD'
  ManagedBy: 'AZD'
  CostCenter: 'IT'
  Criticality: 'High'
}
