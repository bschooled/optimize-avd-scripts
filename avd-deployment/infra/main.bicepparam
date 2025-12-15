using './main.bicep'

// Basic Configuration
param namePrefix = 'avd'
param environmentName = 'dev'
param location = 'westus'

// Host Pool Configuration
param hostPoolFriendlyName = 'Development Multi-Session Pool'
param hostPoolDescription = 'Pooled host pool for development team desktops'
param maxSessionLimit = 10
param loadBalancerType = 'BreadthFirst'
param startVMOnConnect = true
param validationEnvironment = false

// Application Group
param appGroupFriendlyName = 'Development Desktop Apps'

// Workspace
param workspaceFriendlyName = 'Development Workspace'
param workspaceDescription = 'AVD Workspace for development environment'

// VM Configuration (with Ephemeral OS Disk enabled)
param enableEphemeralOSDisk = true
param vmSize = 'Standard_D4s_v5'
param osDiskType = 'StandardSSD_LRS'
param imageReference = {
  publisher: 'MicrosoftWindowsDesktop'
  offer: 'windows-11'
  sku: 'win11-25h2-avd'
  version: 'latest'
}

// Custom RDP Properties
param customRdpProperty = 'drivestoredirect:s:;redirectclipboard:i:1;redirectcomports:i:1;redirectprinters:i:1;redirectsmartcards:i:1;screen mode id:i:2;'

// Tags
param tags = {
  Environment: 'Development'
  Workload: 'AVD'
  ManagedBy: 'AZD'
  CostCenter: 'IT'
}
