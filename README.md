# optimize-avd-scripts
Various scripts and image tweaks to optimize AVD Costs

## Compact image builder pipeline

- Bash driver: `avd-build-pipeline-compact.sh` (uses Azure CLI + Azure Image Builder)
- PowerShell customizers:
  - `compact-avd.ps1` - Enables CompactOS and system compression
  - `configure-avd-image.ps1` - Configures AVD prerequisites and optimizations
  - `shrink-os-disk.ps1` - Shrinks OS disk to target size for ephemeral OS VMs
- Validation script: `validate-multisession-avd.ps1` - Validates AVD prerequisites on deployed VMs

### Prerequisites
- Azure CLI with the `image-builder` extension (`az extension add --name image-builder`)
- Logged in with rights to create: resource group, shared image gallery, user-assigned identity
- Windows 11 25H2 AVD + M365 marketplace terms accepted for the subscription
- Python 3 (for inline script generation)
- **Note**: This script uses managed identities instead of SAS keys for authentication, making it compatible with environments where key-based storage authentication is disabled by policy

### Features
- **Parallel Resource Checking**: Validates all Azure resources (RG, gallery, identity, role assignments) simultaneously using background jobs
- **Async Build Submission**: Submits image build with `--no-wait` flag to avoid blocking the terminal
- **Unique Staging Resource Groups**: Creates timestamped staging RGs to prevent conflicts when running multiple builds
- **Automatic Cleanup**: Staging RGs are configured for automatic deletion after 1 day
- **Disk Size Optimization**: Shrinks OS disk to fit ephemeral OS VM temp storage (64GB, 127GB, or 254GB)
- **Comprehensive AVD Configuration**: Automatically configures all Microsoft-recommended AVD prerequisites:
  - RDP settings (session limits, time zone redirection)
  - FSLogix profile configuration
  - Windows Defender exclusions
  - Power management (high performance, no sleep)
  - Virtual desktop optimizations
  - Network and firewall settings
- **Flexible Image Rebuilds**: Automatically deletes and recreates image definitions to allow rebuilds with same name
- **Robust Error Handling**: Non-fatal errors (cleanup, defrag) don't stop the build; only critical failures cause exit

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

### What it does
1. **Resource Validation** (parallel):
   - Validates resource group existence
   - Validates Shared Image Gallery existence
   - Validates user-assigned managed identity existence
   - Validates role assignments on resource group
   - Validates role assignments on gallery
   - Validates managed identity on staging resource group
2. **Resource Creation** (sequential, only if needed):
   - Creates resource group if missing
   - Creates Shared Image Gallery if missing
   - Creates user-assigned managed identity if missing
   - Assigns Contributor role on resource group
   - Assigns Contributor role on gallery
3. **Image Definition Management**:
   - Deletes existing image definition if present (allows rebuilds)
   - Creates new image definition with unique SKU (includes disk size suffix if specified)
4. **Staging Resource Group**:
   - Creates unique staging RG with timestamp suffix (e.g., `IT_aib-staging_20231214_123456`)
   - Configures automatic cleanup after 1 day
   - Assigns managed identity Contributor access
5. **Image Build**:
   - Embeds all PowerShell customizers inline (base64-encoded) - no storage account required
   - Uses Windows 11 25H2 AVD + M365 marketplace image as source (minimum 127GB)
   - Executes customizations in order:
     1. CompactOS and system compression (`compact-avd.ps1`)
     2. AVD prerequisites configuration (`configure-avd-image.ps1`)
     3. Disk shrinking to target size (`shrink-os-disk.ps1`, if `--disk-size` specified)
   - Submits build asynchronously with `--no-wait` flag
   - Provides monitoring commands for checking build status
6. **Output**:
   - Distributes final image to specified Shared Image Gallery image version
   - **Uses managed identity authentication throughout** - compatible with policies that disable storage account key-based auth

### Customizations Performed (PowerShell Scripts)

#### 1. CompactOS and System Compression (`compact-avd.ps1`)
- Enables CompactOS with LZX compression algorithm
- Compresses system directories:
  - `C:\Program Files`
  - `C:\Program Files (x86)`
  - `C:\Users`
- Configures MMAgent features (with error handling):
  - ApplicationLaunchPrefetching
  - ApplicationPreLaunch
  - MaxOperationAPIFiles=8192
  - MemoryCompression
  - OperationAPI
  - PageCombining

#### 2. AVD Prerequisites Configuration (`configure-avd-image.ps1`)
Automatically detects Windows edition (SingleSession vs MultiSession) and configures:

- **RDP and Multi-Session Settings**:
  - `fSingleSessionPerUser`: 0 for MultiSession, 1 for SingleSession
  - Session time limits and reconnection policies
- **User Experience**:
  - Disables first logon animation
  - Enables time zone redirection
  - Optimizes visual effects for performance
- **Windows Update**:
  - Configures update behavior for VDI environments
- **Storage**:
  - Disables Storage Sense (conflicts with profiles)
- **Power Management**:
  - Sets High Performance power plan
  - Disables sleep and hibernation
  - Disables USB selective suspend
- **FSLogix Profiles** (if installed):
  - Enabled=1
  - VHDLocations (placeholder)
  - DeleteLocalProfileWhenVHDShouldApply=1
  - ConcurrentUserSessions=1
- **Windows Defender Exclusions**:
  - FSLogix file extensions (.VHD, .VHDX, .VHT, .CIM)
  - FSLogix processes (frxsvc.exe, frxccds.exe, frxdrv.sys)
  - AVD Agent paths
- **Virtual Desktop Optimizations**:
  - Disables scheduled defragmentation
  - Disables Superfetch
  - Disables Windows Search indexing on user profiles
- **Network Settings**:
  - Disables NetBIOS over TCP/IP
- **Firewall Rules**:
  - Ensures RDP is enabled
- **Additional Optimizations**:
  - Disables maintenance tasks
  - Configures service optimization

#### 3. Disk Shrinking (`shrink-os-disk.ps1`, when `--disk-size` specified)
- **Phase 1: Disk Cleanup** (non-fatal):
  - Removes Windows Update files
  - Clears temporary files and caches
  - Continues even if cleanup fails
- **Phase 2: Defragmentation** (non-fatal):
  - Consolidates free space
  - Moves files to beginning of disk
  - Continues even if defrag fails
- **Phase 3: Partition Shrink** (fatal if fails):
  - Uses DISKPART to shrink partition to target size
  - Validates 5GB safety buffer remains
  - Exits with error code 1 if shrink fails

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

**Note**: When rebuilding an image with the same name, the script automatically deletes the existing image definition and creates a new one. The SKU includes the disk size suffix to ensure uniqueness in Azure (e.g., `win11-25h2-ent-64gb`, `win11-25h2-ent-127gb`).

### Monitoring Build Progress

After submitting the build, the script provides commands to monitor progress:

```bash
# Check build status
az image builder show \
    --resource-group <resource-group> \
    --name <template-name> \
    --query 'lastRunStatus'

# Stream build logs (if build is running)
az image builder logs show \
    --resource-group <resource-group> \
    --name <template-name>
```

Typical build time: 45-90 minutes depending on disk size and compression operations.

### Validating Deployed Images

Use `validate-multisession-avd.ps1` to verify AVD prerequisites on a deployed VM:

```powershell
# Run locally on the VM
.\validate-multisession-avd.ps1

# Or use Azure Run Command
az vm run-command invoke \
    --resource-group <resource-group> \
    --name <vm-name> \
    --command-id RunPowerShellScript \
    --scripts @validate-multisession-avd.ps1
```

The validation script checks:
- Session type detection (SingleSession vs MultiSession)
- RDP configuration (fSingleSessionPerUser setting)
- AVD Agent installation and paths
- FSLogix installation and configuration
- Windows Defender exclusions
- Power settings and hibernation status
- Network configuration
- Disk compression status

Output is grouped by category with color-coded status indicators (✓ for OK, ✗ for issues, ⚠ for warnings).

### Troubleshooting

#### Build Fails with "Source disk size constraint"
- The Windows 11 25H2 AVD + M365 marketplace image is 127GB minimum
- Cannot shrink below this during build; shrinking happens after OS is installed
- Use `--disk-size 127` or higher

#### Staging Resource Group Already Exists
- Script creates unique staging RGs with timestamp suffix
- Old staging RGs auto-delete after 1 day
- Manually delete if needed: `az group delete --name IT_aib-staging_<timestamp> --yes --no-wait`

#### Build Logs Show Disk Shrink Failed
- Check if target size is too small (need ~5GB free space buffer)
- Verify defragmentation completed successfully
- Review full logs: `az image builder logs show --resource-group <rg> --name <template>`

#### Image Definition Already Exists Error
- Script automatically deletes existing definitions
- If deletion fails, manually delete: `az sig image-definition delete --gallery-name <gallery> --gallery-image-definition <image-def> --resource-group <rg>`

### Performance Optimizations

The script includes several optimizations to reduce execution time:

1. **Parallel Resource Validation**: All 6 resource checks run simultaneously (60% faster than sequential)
2. **Async Build Submission**: Terminal doesn't block while image builds (45-90 min saved)
3. **Efficient Script Embedding**: Base64 encoding eliminates storage account dependency
4. **Smart Error Handling**: Non-critical failures don't stop the build

### References
- Azure VM Image Builder overview: https://github.com/MicrosoftDocs/azure-compute-docs/blob/main/articles/virtual-machines/image-builder-overview.md
- Azure VM Image Builder samples: https://github.com/Azure/azvmimagebuilder
- Prepare Windows Image for AVD: https://learn.microsoft.com/azure/virtual-desktop/set-up-golden-image
- FSLogix Profile Configuration: https://learn.microsoft.com/fslogix/reference-configuration-settings
- Azure Ephemeral OS Disks: https://learn.microsoft.com/azure/virtual-machines/ephemeral-os-disks
