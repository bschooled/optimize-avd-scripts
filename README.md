# Azure Virtual Desktop (AVD) Optimization Suite

A comprehensive toolkit for building, deploying, and operating **cost-optimized Azure Virtual Desktop environments** with ephemeral OS disks, CompactOS compression, and AVD Insights monitoring.

## 🚀 Quick Navigation

| Component | Description | Documentation |
|-----------|-------------|---------------|
| **[Image Builder](./image-builder/)** | Build size-optimized Windows 11 AVD images with CompactOS + disk shrinking | [Image Builder README](./image-builder/README.md) |
| **[Deployment](./deployment/)** | Bicep templates for AVD infrastructure + AVD Insights monitoring | [Deployment README](./deployment/README.md) |
| **[Troubleshooting](./troubleshooting/)** | Maintenance/restore workflows and validation scripts | [Troubleshooting README](./troubleshooting/README.md) |
| **[Monitoring](./monitoring/)** | Manual DCR setup for AVD Insights (CLI/Portal) | [Monitoring README](./monitoring/README.md) |
| **[Docs](./docs/)** | Disk sizing guides and technical references | [Disk Sizing Guide](./docs/DISK-SIZING-GUIDE.md) |

## Overview

This repository provides end-to-end automation for cost-optimized AVD deployments:

1. **Build optimized images** with CompactOS compression and configurable disk sizes (64GB, 127GB, 254GB)
2. **Deploy AVD infrastructure** with Bicep (host pools, app groups, workspaces, monitoring)
3. **Monitor with AVD Insights** using cost-optimized Data Collection Rules
4. **Troubleshoot session hosts** with maintenance/restore workflows

### Key Features

✅ **Ephemeral OS Disk Support**: Right-sized images for D2d_v5, D4d_v5, D8d_v5 VMs  
✅ **CompactOS + LZX Compression**: Reduces image size by 20-30%  
✅ **AVD Prerequisites Auto-Config**: RDP settings, FSLogix, Defender exclusions, power settings  
✅ **No SAS Keys Required**: Uses managed identities (policy-compliant)  
✅ **AVD Insights Integration**: Performance counters + event logs with cost optimization  
✅ **Operational Tooling**: Maintenance mode, restore workflows, validation scripts  

## 📦 Repository Structure

```
/
├── image-builder/           # Azure Image Builder pipeline
│   ├── avd-build-pipeline-compact.sh
│   └── scripts/
│       ├── compact-avd.ps1
│       ├── configure-avd-image.ps1
│       └── shrink-os-disk.ps1
├── deployment/              # Bicep IaC for AVD + monitoring
│   ├── infra/
│   │   ├── main.bicep
│   │   └── modules/
│   ├── AVD-INSIGHTS.md
│   └── deploy-sessionhost-with-monitoring.sh
├── troubleshooting/         # Operational scripts
│   ├── avd-troubleshoot.sh
│   └── scripts/
│       └── validate-multisession-avd.ps1
├── monitoring/              # Manual DCR setup (no Bicep)
│   ├── dce.json
│   ├── dcr.json
│   └── scripts/
└── docs/                    # Technical guides
    └── DISK-SIZING-GUIDE.md
```

## 🎯 Common Workflows

### Build a Size-Optimized AVD Image

```bash
cd image-builder

./avd-build-pipeline-compact.sh \
  --image-name "win11-25h2-compact" \
  --gallery "my-sig" \
  --resource-group "avd-image-builder-rg" \
  --location "eastus" \
  --disk-size 127  # For D4d_v5 VMs (150GB temp storage)
```

**Result**: Windows 11 25H2 image with CompactOS, AVD config, shrunk to 127GB for ephemeral OS disks.

See [Image Builder README](./image-builder/README.md) for details.

### Deploy AVD Infrastructure with Monitoring

```bash
cd deployment

azd auth login
azd up
```

**Result**: Host pool, app group, workspace, Log Analytics, DCE/DCR, diagnostic settings.

See [Deployment README](./deployment/README.md) for parameters and Bicep details.

### Troubleshoot a Session Host

**Pull for maintenance:**
```bash
cd troubleshooting

./avd-troubleshoot.sh \
  --maintenance \
  --resource-group "avd-rg" \
  --vm-name "avd-sh-0"
```

**Restore to production:**
```bash
./avd-troubleshoot.sh \
  --restore \
  --resource-group "avd-rg" \
  --vm-name "avd-sh-0"
```

See [Troubleshooting README](./troubleshooting/README.md) for workflows.

### Manually Deploy AVD Insights Monitoring

```bash
cd monitoring

./scripts/create-dce-dcr.sh \
  --location "eastus" \
  --resource-group "avd-rg" \
  --dce-name "avd-dce" \
  --dcr-name "avd-dcr" \
  --log-analytics-workspace-id "<law-resource-id>"

./scripts/associate-dcr-to-vm.sh \
  --resource-group "avd-rg" \
  --vm-name "avd-sh-0" \
  --dcr-resource-id "<dcr-resource-id>" \
  --install-ama
```

See [Monitoring README](./monitoring/README.md) for details.

## 🔧 Prerequisites

- **Azure CLI** (`az`) with `image-builder` extension
- **Azure Developer CLI** (`azd`) for Bicep deployment
- **Python 3** (for image builder script generation)
- **Azure subscription** with:
  - AVD service enabled
  - Windows 11 25H2 AVD + M365 marketplace terms accepted
  - Permissions to create: RGs, galleries, managed identities, role assignments

## 📊 Cost Optimization Features

| Feature | Savings | Implementation |
|---------|---------|----------------|
| Ephemeral OS Disks | ~70% disk cost | Image sizing + deployment param |
| CompactOS + LZX | 20-30% space | `compact-avd.ps1` |
| Right-sized VMs | Match workload | D2d_v5, D4d_v5, D8d_v5 SKUs |
| Cost-optimized DCR | Reduced ingestion | XPath filters, 90s intervals |
| Start VM on Connect | Pay only when used | Deployment Bicep param |

## 📚 Documentation

| Document | Description |
|----------|-------------|
| [Image Builder README](./image-builder/README.md) | Build pipeline usage and customization |
| [Deployment README](./deployment/README.md) | Bicep deployment and azd usage |
| [AVD Insights Guide](./deployment/AVD-INSIGHTS.md) | Monitoring setup and queries |
| [Bicep Architecture](./deployment/BICEP-FIXES.md) | Module design and scoping |
| [Troubleshooting README](./troubleshooting/README.md) | Operational workflows |
| [Monitoring README](./monitoring/README.md) | Manual DCR setup |
| [Disk Sizing Guide](./docs/DISK-SIZING-GUIDE.md) | Ephemeral OS disk planning |

## 🤝 Contributing

Contributions welcome! This repo is designed for:
- Azure administrators managing AVD environments
- DevOps engineers automating image builds
- Cost optimization teams reducing Azure spend

## 📝 License

MIT License - see [LICENSE](./LICENSE) for details.

## 🔗 References

- [Azure Virtual Desktop Documentation](https://docs.microsoft.com/azure/virtual-desktop/)
- [Azure Image Builder](https://learn.microsoft.com/azure/virtual-machines/image-builder-overview)
- [Ephemeral OS Disks](https://learn.microsoft.com/azure/virtual-machines/ephemeral-os-disks)
- [FSLogix Documentation](https://learn.microsoft.com/fslogix/)
- [AVD Insights](https://learn.microsoft.com/azure/virtual-desktop/insights)
