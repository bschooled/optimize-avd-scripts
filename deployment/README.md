# Azure Virtual Desktop - Pooled Multi-Session Host Pool

This Azure Developer CLI (azd) template deploys a complete Azure Virtual Desktop (AVD) pooled host pool environment with support for multi-session desktops and optional ephemeral OS disks.

## Features

- **Pooled Multi-Session Host Pool**: Optimized for multiple users per VM
- **Desktop Application Group**: Full desktop experience
- **AVD Workspace**: Centralized workspace for user access
- **Ephemeral OS Disk Support**: Optional cost-saving feature using local VM cache
- **West US Region**: Default deployment location (easily customizable)
- **Azure Verified Modules**: Uses official AVM Bicep registry modules
- **Azure Developer CLI Ready**: Simple deployment with `azd up`

## Architecture

The template deploys:

```
├── Resource Group
│   ├── Host Pool (Pooled, Multi-Session)
│   ├── Desktop Application Group
│   └── Workspace
```

### Ephemeral OS Disk Configuration

When `enableEphemeralOSDisk` is set to `true`, session hosts will use ephemeral OS disks which:
- Store the OS disk on the local VM cache or temporary storage
- Reduce costs (no managed disk charges)
- Provide faster VM provisioning and reimaging
- Are ideal for stateless workloads where user data is stored elsewhere (FSLogix, Azure Files, etc.)

**Note**: Ephemeral OS requires VM sizes with sufficient cache/temp storage. Standard_D4s_v5 and larger are recommended.

## Prerequisites

- [Azure Developer CLI (azd)](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd)
- [Azure CLI](https://docs.microsoft.com/cli/azure/install-azure-cli)
- An Azure subscription with appropriate permissions to create resources
- Azure Virtual Desktop service enabled in your subscription

## Quick Start

### 1. Initialize the project

```bash
cd deployment
azd auth login
```

### 2. Deploy with default settings (Development)

```bash
azd up
```

This will deploy the development environment with:
- Ephemeral OS disks enabled
- Standard_D4s_v5 VM size
- Windows 11 25H2 AVD image
- West US location

### 3. Deploy to Production

```bash
azd up --environment production
```

Use the production parameter file (`main.prod.bicepparam`) which includes:
- Persistent OS disks (for production stability)
- Standard_D8s_v5 VM size
- Windows 11 25H2 AVD + M365 Apps image
- Higher session limits

## Configuration Parameters

### Required Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `namePrefix` | Prefix for resource names | `avd` |
| `environmentName` | Environment (dev/test/prod) | `dev` |
| `location` | Azure region | `westus` |

### Host Pool Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `hostPoolFriendlyName` | Display name for host pool | `Pooled Multi-Session Host Pool` |
| `hostPoolDescription` | Host pool description | `Pooled host pool for multi-session desktops` |
| `maxSessionLimit` | Max sessions per host | `10` |
| `loadBalancerType` | Load balancing algorithm | `BreadthFirst` |
| `startVMOnConnect` | Enable Start VM On Connect | `true` |
| `validationEnvironment` | Use validation ring | `false` |

### VM Configuration Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `enableEphemeralOSDisk` | Enable ephemeral OS disk | `false` |
| `vmSize` | VM size for session hosts | `Standard_D4s_v5` |
| `osDiskType` | OS disk type | `StandardSSD_LRS` |
| `imageReference` | VM image reference | Windows 11 25H2 AVD |

### Custom RDP Properties

The template includes sensible defaults for RDP properties:
- Clipboard redirection: Enabled
- COM ports redirection: Enabled
- Printers redirection: Enabled
- Smart cards redirection: Enabled
- Full screen mode: Enabled

Customize via the `customRdpProperty` parameter.

## Parameter Files

Two parameter files are included:

### Development (`main.bicepparam`)
- Ephemeral OS disks: **Enabled** (cost-saving)
- VM Size: Standard_D4s_v5
- Max Sessions: 10
- Image: Windows 11 25H2 AVD

### Production (`main.prod.bicepparam`)
- Ephemeral OS disks: **Disabled** (for stability)
- VM Size: Standard_D8s_v5
- Max Sessions: 20
- Image: Windows 11 25H2 AVD + M365

## Customization

### Change Deployment Region

Edit the parameter file:

```bicep
param location = 'eastus'  // Change from 'westus' to your preferred region
```

### Adjust Session Limits

```bicep
param maxSessionLimit = 15  // Increase or decrease based on VM size and workload
```

### Use Custom Image

```bicep
param imageReference = {
  publisher: 'MicrosoftWindowsDesktop'
  offer: 'windows-11'
  sku: 'win11-25h2-avd-m365'  // Use M365 variant
  version: 'latest'
}
```

### Disable Ephemeral OS Disk

```bicep
param enableEphemeralOSDisk = false  // Use persistent managed disks
```

## Post-Deployment Steps

After deployment:

1. **Add Session Hosts**: Deploy VMs and join them to the host pool using the registration token
2. **Assign Users**: Grant users access to the application group
3. **Configure FSLogix**: Set up profile containers for user profiles (recommended with ephemeral OS)
4. **Set up Monitoring**: Enable Azure Monitor and Log Analytics
5. **Configure Policies**: Apply GPOs or Intune policies to session hosts

### Get the Registration Token

```bash
az desktopvirtualization hostpool show \
  --name <hostpool-name> \
  --resource-group <resource-group-name> \
  --query registrationInfo.token -o tsv
```

### Assign Users to Application Group

```bash
az role assignment create \
  --assignee <user-principal-name> \
  --role "Desktop Virtualization User" \
  --scope <application-group-resource-id>
```

## Outputs

The deployment provides these outputs:

- `resourceGroupName`: Name of the resource group
- `hostPoolResourceId`: Resource ID of the host pool
- `hostPoolName`: Name of the host pool
- `hostPoolRegistrationToken`: Token for joining session hosts (sensitive)
- `applicationGroupResourceId`: Resource ID of the application group
- `applicationGroupName`: Name of the application group
- `workspaceResourceId`: Resource ID of the workspace
- `workspaceName`: Name of the workspace
- `location`: Deployment location

## Cost Optimization

### Using Ephemeral OS Disks

Ephemeral OS disks can significantly reduce costs:
- **No managed disk charges** for OS disks
- **Faster provisioning** times
- **Ideal for** stateless workloads with user profiles on FSLogix

**Important**: Ensure sufficient cache or temp storage on the VM SKU. Use Dv5, Ev5, or similar series.

### Start VM On Connect

Enabled by default - VMs automatically start when users connect, allowing you to deallocate VMs when not in use.

## Troubleshooting

### Deployment Fails with "Insufficient Cache Size"

If using ephemeral OS disks, ensure your VM size has sufficient cache:
- Standard_D4s_v5: 150 GB cache (sufficient for Windows 11)
- Standard_D8s_v5: 300 GB cache

### Registration Token Expired

The registration token expires. Regenerate:

```bash
az desktopvirtualization hostpool update \
  --name <hostpool-name> \
  --resource-group <resource-group-name> \
  --registration-info expiration-time="2024-12-31T23:59:59Z" registration-token-operation="Update"
```

## Clean Up

To delete all deployed resources:

```bash
azd down
```

## References

- [Azure Virtual Desktop Documentation](https://docs.microsoft.com/azure/virtual-desktop/)
- [Azure Verified Modules - Host Pool](https://github.com/Azure/bicep-registry-modules/tree/main/avm/res/desktop-virtualization/host-pool)
- [Ephemeral OS Disks](https://learn.microsoft.com/azure/virtual-machines/ephemeral-os-disks)
- [Azure Developer CLI](https://learn.microsoft.com/azure/developer/azure-developer-cli/)
- [AVD Start VM On Connect](https://learn.microsoft.com/azure/virtual-desktop/start-virtual-machine-connect)

## Related Documentation

- [AVD Insights Setup](./AVD-INSIGHTS.md) - Monitoring and diagnostics configuration
- [Bicep Architecture](./BICEP-FIXES.md) - Module design and scoping details
- [Image Builder](../image-builder/README.md) - Building optimized AVD images
- [Manual Monitoring Setup](../monitoring/README.md) - DCR/DCE deployment without Bicep
- [Troubleshooting Tools](../troubleshooting/README.md) - Session host maintenance workflows

## License

This template is provided as-is under the MIT License.

