# optimize-avd-scripts
Various scripts and image tweaks to optimize AVD Costs

## Compact image builder pipeline

- Bash driver: `avd-build-pipeline-compact.sh` (uses Azure CLI + Azure Image Builder)
- PowerShell customizer: `compact-avd.ps1` (run inside the image build)

### Prereqs
- Azure CLI with the `image-builder` extension (`az extension add --name image-builder`)
- Logged in with rights to create: resource group, shared image gallery, user-assigned identity
- Windows 11 25H2 AVD + M365 marketplace terms accepted for the subscription
- **Note**: This script uses managed identities instead of SAS keys for authentication, making it compatible with environments where key-based storage authentication is disabled by policy

### Quick use
```bash
# Standard image (default 128GB)
./avd-build-pipeline-compact.sh \
	--image-name avd-win11-25h2-compact-1 \
	--gallery avdGallery \
	--resource-group avd-image-builder-rg \
	--location eastus \
	--script ./compact-avd.ps1

# Size-optimized for ephemeral OS VMs (D2d_v5 with 70GB temp storage)
./avd-build-pipeline-compact.sh \
	--image-name avd-win11-25h2-compact-1 \
	--gallery avdGallery \
	--resource-group avd-image-builder-rg \
	--location eastus \
	--script ./compact-avd.ps1 \
	--disk-size 64

# Size-optimized for D4d_v5 (150GB temp storage)
./avd-build-pipeline-compact.sh \
	--image-name avd-win11-25h2-compact-1 \
	--gallery avdGallery \
	--resource-group avd-image-builder-rg \
	--location eastus \
	--script ./compact-avd.ps1 \
	--disk-size 127

# Size-optimized for D8d_v5 (300GB temp storage)
./avd-build-pipeline-compact.sh \
	--image-name avd-win11-25h2-compact-1 \
	--gallery avdGallery \
	--resource-group avd-image-builder-rg \
	--location eastus \
	--script ./compact-avd.ps1 \
	--disk-size 254
```

What it does:
- Ensures the resource group, Shared Image Gallery, and image definition exist
- Creates a staging resource group for Azure Image Builder temporary resources
- Ensures a user-assigned managed identity with Contributor roles on both resource groups and the gallery
- Embeds the PowerShell customizer inline (base64-encoded) - no storage account required
- Builds an Azure Image Builder template from the Windows 11 25H2 AVD + M365 marketplace image
- Distributes the output to the specified Shared Image Gallery image version
- **Uses managed identity authentication throughout** - compatible with policies that disable storage account key-based auth

### Customization performed (PowerShell)
- Enables CompactOS and LZX compression of `C:\Program Files`, `C:\Program Files (x86)`, and `C:\Users`
- Enables MMAgent features: `ApplicationLaunchPrefetching`, `ApplicationPreLaunch`, `MaxOperationAPIFiles=8192`, `MemoryCompression`, `OperationAPI`, `PageCombining`
- **Optionally shrinks OS disk to target size** (when `--disk-size` specified):
  - Runs disk cleanup to remove unnecessary files
  - Defragments and consolidates free space
  - Shrinks partition to target size for ephemeral OS disk VMs

### Disk Size Options for Ephemeral OS VMs
When using ephemeral OS disks, the OS disk is stored on the VM's local temporary storage. To maximize cost efficiency with smaller VM SKUs:

| VM SKU | Temp Storage | Recommended Disk Size | Image Definition Suffix |
|--------|--------------|----------------------|-------------------------|
| D2d_v5 | 70 GB | 64 GB (`--disk-size 64`) | `-64gb` |
| D4d_v5 | 150 GB | 127 GB (`--disk-size 127`) | `-127gb` |
| D8d_v5 | 300 GB | 254 GB (`--disk-size 254`) | `-254gb` |

When `--disk-size` is specified, the script automatically:
- Appends the size suffix to the image definition name (e.g., `avd-win11-25h2-compact-1-64gb`)
- Runs disk shrinking during the image build process
- Creates a right-sized image optimized for ephemeral OS deployments

See `avd-deployment/` for a complete Azure Developer CLI project that deploys AVD host pools with ephemeral OS disk configuration.

### References
- Azure VM Image Builder overview: https://github.com/MicrosoftDocs/azure-compute-docs/blob/main/articles/virtual-machines/image-builder-overview.md
- Azure VM Image Builder samples: https://github.com/Azure/azvmimagebuilder
