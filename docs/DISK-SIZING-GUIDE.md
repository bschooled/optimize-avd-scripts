# AVD Image Disk Sizing Guide for Ephemeral OS VMs

## Overview
This guide explains how to create size-optimized AVD images for use with ephemeral OS disks. Ephemeral OS disks are stored on the VM's local temporary storage, which provides faster performance and lower costs, but requires the OS disk to fit within the VM's temp storage capacity.

## Why Disk Sizing Matters
When using ephemeral OS disks:
- The OS disk must fit within the VM's temporary storage
- Smaller VM SKUs have limited temp storage (e.g., D2d_v5 has only 70 GB)
- CompactOS + disk shrinking can reduce a Windows 11 AVD image from 128 GB to 64 GB or smaller
- This enables using smaller, more cost-effective VM SKUs

## VM SKU and Disk Size Mapping

| VM SKU | vCPUs | RAM | Temp Storage | Recommended Image Size | Command Parameter |
|--------|-------|-----|--------------|------------------------|-------------------|
| D2d_v5 | 2 | 8 GB | 70 GB | 64 GB | `--disk-size 64` |
| D4d_v5 | 4 | 16 GB | 150 GB | 127 GB | `--disk-size 127` |
| D8d_v5 | 8 | 32 GB | 300 GB | 254 GB | `--disk-size 254` |

## How It Works

### 1. CompactOS with LZX Compression
The `compact-avd.ps1` script enables Windows CompactOS and compresses system files:
- Enables CompactOS at the system level
- Compresses `C:\Program Files` with LZX (max compression)
- Compresses `C:\Program Files (x86)` with LZX
- Compresses `C:\Users` with LZX
- Configures MMAgent for optimized memory management

### 2. Disk Shrinking
The `shrink-os-disk.ps1` script further reduces the disk size:
- Runs Windows Disk Cleanup to remove unnecessary files
- Defragments the disk to consolidate free space
- Shrinks the partition to the target size using DISKPART
- Includes validation to ensure target size is achievable

### 3. Azure Image Builder Pipeline
The `avd-build-pipeline-compact.sh` orchestrates the entire process:
- Accepts `--disk-size` parameter to specify target size
- Appends size suffix to image definition name (e.g., `-64gb`)
- Embeds both PowerShell scripts inline (no storage account needed)
- Executes CompactOS first, then disk shrinking
- Captures the final optimized image to Azure Compute Gallery

## Usage Examples

### Create a 64 GB Image for D2d_v5 VMs
```bash
./avd-build-pipeline-compact.sh \
  --image-name avd-win11-25h2-compact-1 \
  --gallery avdGallery \
  --resource-group avd-image-builder-rg \
  --location eastus \
  --script ./compact-avd.ps1 \
  --disk-size 64
```

This will create an image definition named `avd-win11-25h2-compact-1-64gb`.

### Create a 127 GB Image for D4d_v5 VMs
```bash
./avd-build-pipeline-compact.sh \
  --image-name avd-win11-25h2-compact-1 \
  --gallery avdGallery \
  --resource-group avd-image-builder-rg \
  --location eastus \
  --script ./compact-avd.ps1 \
  --disk-size 127
```

This will create an image definition named `avd-win11-25h2-compact-1-127gb`.

### Create a 254 GB Image for D8d_v5 VMs
```bash
./avd-build-pipeline-compact.sh \
  --image-name avd-win11-25h2-compact-1 \
  --gallery avdGallery \
  --resource-group avd-image-builder-rg \
  --location eastus \
  --script ./compact-avd.ps1 \
  --disk-size 254
```

This will create an image definition named `avd-win11-25h2-compact-1-254gb`.

## Deploying AVD with Ephemeral OS Disks

After creating the size-optimized images, use the `avd-deployment/` project to deploy AVD host pools:

```bash
cd avd-deployment
azd env new dev
azd env set AZURE_SUBSCRIPTION_ID <your-subscription-id>

# Edit infra/main.bicepparam to reference your gallery image
# Set diskType: 'ephemeral' in the vmTemplate parameter

azd up
```

See `avd-deployment/README.md` for complete deployment instructions.

## Technical Details

### AIB Build VM Sizing
When `--disk-size` is specified, the script automatically sets the build VM's `osDiskSizeGB` to the target size + 20 GB buffer. This provides enough space for:
- Initial OS installation (~40-60 GB)
- CompactOS compression operations
- Disk shrinking operations
- AIB temporary files

### Disk Shrinking Process
The shrink operation happens in this order:
1. **CompactOS**: Reduces file sizes through compression
2. **Disk Cleanup**: Removes Windows Update files, temp files, etc.
3. **Defragmentation**: Consolidates free space to the end of the disk
4. **Partition Shrink**: Uses DISKPART to resize the partition

### Safety Margins
The shrink script includes safety checks:
- Calculates minimum required size (used space + 5 GB buffer)
- Fails with clear error if target size is too small
- Validates successful shrink before completing

### Image Naming Convention
Images are automatically named with size suffixes:
- Base image: `avd-win11-25h2-compact-1`
- 64 GB variant: `avd-win11-25h2-compact-1-64gb`
- 127 GB variant: `avd-win11-25h2-compact-1-127gb`
- 254 GB variant: `avd-win11-25h2-compact-1-254gb`

This allows you to maintain multiple size variants of the same base image in your gallery.

## Troubleshooting

### Build Fails with "Target size too small"
- The OS after compression still exceeds your target size
- Try a larger target size (e.g., 127 GB instead of 64 GB)
- Check the AIB logs in the staging resource group for actual disk usage

### Ephemeral OS Deployment Fails
- Verify the image size is smaller than the VM's temp storage
- Check that the VM SKU supports ephemeral OS disks (requires Premium Storage support)
- Ensure `diffDiskPlacement: 'CacheDisk'` is set in your Bicep template

### Image Build Takes Too Long
- Disk shrinking and defragmentation can add 10-20 minutes to build time
- This is normal and only happens during image build, not VM deployment
- Consider using larger VM SKU for AIB build (default: Standard_D4ds_v5)

## Cost Optimization
Using size-optimized images with ephemeral OS disks can reduce AVD costs:
- **D2d_v5 (64 GB image)**: ~$140/month per VM (East US)
- **D4d_v5 (127 GB image)**: ~$280/month per VM
- **D8d_v5 (254 GB image)**: ~$560/month per VM

Compare to D4s_v5 with managed disk (~$350/month) - save 20% by using D2d_v5 with ephemeral OS.

## References
- [Azure Ephemeral OS Disks](https://learn.microsoft.com/azure/virtual-machines/ephemeral-os-disks)
- [Windows CompactOS](https://learn.microsoft.com/windows-hardware/manufacture/desktop/compact-os)
- [Azure Image Builder](https://learn.microsoft.com/azure/virtual-machines/image-builder-overview)
- [AVD Sizing Guidance](https://learn.microsoft.com/azure/virtual-desktop/remote-desktop-workloads)
