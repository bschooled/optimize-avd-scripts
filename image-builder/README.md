# AVD Image Builder Pipeline

This folder contains the **Azure Image Builder pipeline** for creating optimized Windows 11 AVD images with CompactOS, disk shrinking, and AVD prerequisite configuration.

## Overview

The pipeline:
1. Creates a managed identity with Contributor rights to the Shared Image Gallery
2. Builds a Windows 11 25H2 Enterprise image using Azure Image Builder
3. Applies CompactOS compression and optimizations
4. Configures AVD prerequisites (RDP settings, FSLogix, Defender exclusions, etc.)
5. Optionally shrinks the OS disk to fit ephemeral OS disk constraints
6. Publishes the result to a Shared Image Gallery

## Files

- **`avd-build-pipeline-compact.sh`**: Main orchestration script
- **`scripts/compact-avd.ps1`**: CompactOS + LZX compression + MMAgent configuration
- **`scripts/configure-avd-image.ps1`**: AVD prerequisites + SxS stack detection/repair + host pool remediation guidance
- **`scripts/shrink-os-disk.ps1`**: Multi-phase disk cleanup/defrag/shrink with validation

## Quick Start

```bash
cd image-builder

./avd-build-pipeline-compact.sh \
  --image-name "win11-25h2-ent-compact" \
  --gallery "my-sig-name" \
  --resource-group "avd-image-builder-rg" \
  --location "eastus" \
  --disk-size 127
```

### Disk Size Options (for ephemeral OS VMs)

| Flag | Target Size | VM SKU | Temp Storage |
|------|-------------|--------|--------------|
| `--disk-size 64` | 64 GB | D2d_v5 | 70 GB |
| `--disk-size 127` | 127 GB | D4d_v5 | 150 GB |
| `--disk-size 254` | 254 GB | D8d_v5 | 300 GB |

When `--disk-size` is specified:
- Image definition name gets a size suffix (e.g., `win11-25h2-ent-compact-127gb`)
- OS disk is shrunk to the target size after optimization

## How It Works

### Phase 1: Resource Preparation
- Creates/validates resource group
- Creates managed identity with SIG Contributor role
- Auto-increments image version if not specified

### Phase 2: Image Template Creation
- Generates Azure Image Builder template
- Inline embeds all PowerShell scripts (no storage/SAS required)
- Creates unique staging resource group per build

### Phase 3: Build Execution
- Submits build asynchronously (`--no-wait`)
- Returns build run name for tracking

### Phase 4: Monitoring (Manual)
```bash
az image builder show-runs \
  -g avd-image-builder-rg \
  -n <template-name> \
  --output-name <run-name>
```

## Customization

### Using a Custom Script

```bash
./avd-build-pipeline-compact.sh \
  --script /path/to/my-custom-script.ps1 \
  --gallery "my-sig" \
  --location "eastus"
```

The pipeline will still run `configure-avd-image.ps1` and `shrink-os-disk.ps1` (if `--disk-size` is set) after your custom script.

### Skipping Disk Shrink

Omit `--disk-size` to skip the shrink phase entirely.

## Troubleshooting

### Build Failures

Check the build run logs:
```bash
az image builder show-runs \
  -g avd-image-builder-rg \
  -n <template-name> \
  --output-name <run-name>
```

### Permission Issues

Ensure the managed identity has:
- Contributor on the Shared Image Gallery
- Reader on the subscription (for source image lookup)

### Disk Shrink Failures

The shrink script validates available space and will fail safely if:
- Insufficient free space (< 20% buffer)
- DISKPART cannot shrink to target size

## Related Documentation

- [Disk Sizing Guide](../docs/DISK-SIZING-GUIDE.md) - Detailed guidance on ephemeral OS disk sizing
- [Deployment](../deployment/README.md) - Bicep templates for AVD infrastructure
- [Troubleshooting](../troubleshooting/README.md) - Maintenance and restore workflows
