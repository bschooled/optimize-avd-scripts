#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Shrinks the OS disk to a target size for ephemeral OS disk VMs.

.DESCRIPTION
    This script shrinks the Windows OS partition and disk to fit within
    the specified size, optimized for Azure ephemeral OS disks.
    
    It performs:
    1. Disk cleanup to remove unnecessary files
    2. Defragmentation to consolidate free space
    3. Volume shrink to target size
    4. Partition resize

.PARAMETER TargetSizeGB
    Target size in GB for the OS disk (e.g., 64, 127, 254)

.EXAMPLE
    .\shrink-os-disk.ps1 -TargetSizeGB 64
#>

param(
    [Parameter(Mandatory=$true)]
    [int]$TargetSizeGB
)

$ErrorActionPreference = 'Stop'

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    Write-Host $logMessage
    Add-Content -Path "C:\Deployer\shrink-os-disk.log" -Value $logMessage
}

function Assert-Admin {
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "This script must be run as Administrator"
    }
}

function Get-OSDrive {
    $os = Get-WmiObject -Class Win32_OperatingSystem
    return $os.SystemDrive
}

function Invoke-DiskCleanup {
    Write-Log "Running Disk Cleanup to free space..."
    
    # Run Windows Disk Cleanup
    $cleanmgrKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches'
    
    # Enable all cleanup options
    $volumeCaches = Get-ChildItem -Path $cleanmgrKey
    foreach ($cache in $volumeCaches) {
        Set-ItemProperty -Path $cache.PSPath -Name StateFlags0001 -Value 2 -ErrorAction SilentlyContinue
    }
    
    # Run cleanup
    Start-Process -FilePath cleanmgr.exe -ArgumentList '/sagerun:1' -Wait -NoNewWindow
    
    Write-Log "Disk cleanup completed"
}

function Optimize-Disk {
    param([string]$DriveLetter)
    
    Write-Log "Defragmenting and optimizing $DriveLetter..."
    
    try {
        # Defrag and consolidate free space
        Optimize-Volume -DriveLetter $DriveLetter.TrimEnd(':') -Defrag -SlabConsolidate -Verbose
        Write-Log "Disk optimization completed"
    } catch {
        Write-Log "Defrag warning: $($_.Exception.Message)" "WARN"
        # Continue even if defrag fails
    }
}

function Get-PartitionInfo {
    param([string]$DriveLetter)
    
    $partition = Get-Partition -DriveLetter $DriveLetter.TrimEnd(':')
    $volume = Get-Volume -DriveLetter $DriveLetter.TrimEnd(':')
    
    $sizeGB = [math]::Round($partition.Size / 1GB, 2)
    $usedGB = [math]::Round(($volume.Size - $volume.SizeRemaining) / 1GB, 2)
    $freeGB = [math]::Round($volume.SizeRemaining / 1GB, 2)
    
    return @{
        Partition = $partition
        Volume = $volume
        SizeGB = $sizeGB
        UsedGB = $usedGB
        FreeGB = $freeGB
    }
}

function Shrink-OSPartition {
    param(
        [string]$DriveLetter,
        [int]$TargetSizeGB
    )
    
    Write-Log "Starting OS partition shrink to ${TargetSizeGB} GB..."
    
    $info = Get-PartitionInfo -DriveLetter $DriveLetter
    
    Write-Log "Current partition size: $($info.SizeGB) GB"
    Write-Log "Used space: $($info.UsedGB) GB"
    Write-Log "Free space: $($info.FreeGB) GB"
    
    # Calculate target size in bytes (leave 2GB buffer for filesystem overhead)
    $targetSizeBytes = ($TargetSizeGB * 1GB)
    $currentSizeBytes = $info.Partition.Size
    $usedBytes = $info.Volume.Size - $info.Volume.SizeRemaining
    
    # Validate we have enough space
    $minRequiredGB = [math]::Ceiling($usedBytes / 1GB) + 5  # Used space + 5GB buffer
    if ($TargetSizeGB -lt $minRequiredGB) {
        throw "Target size ${TargetSizeGB}GB is too small. Minimum required: ${minRequiredGB}GB (used: $($info.UsedGB)GB + 5GB buffer)"
    }
    
    if ($currentSizeBytes -le $targetSizeBytes) {
        Write-Log "Current size ($($info.SizeGB)GB) is already at or below target (${TargetSizeGB}GB). No shrink needed." "INFO"
        return
    }
    
    # Calculate shrink amount
    $shrinkBytes = $currentSizeBytes - $targetSizeBytes
    $shrinkMB = [math]::Floor($shrinkBytes / 1MB)
    
    Write-Log "Shrinking partition by $([math]::Round($shrinkBytes / 1GB, 2)) GB ($shrinkMB MB)..."
    
    try {
        # Use DISKPART for more reliable shrinking
        $diskpartScript = @"
select volume $($DriveLetter.TrimEnd(':'))
shrink desired=$shrinkMB minimum=$shrinkMB
exit
"@
        
        $scriptPath = "C:\Deployer\diskpart_shrink.txt"
        $diskpartScript | Out-File -FilePath $scriptPath -Encoding ASCII
        
        $result = diskpart /s $scriptPath 2>&1
        Write-Log "DISKPART output: $result"
        
        Remove-Item -Path $scriptPath -Force -ErrorAction SilentlyContinue
        
        # Verify shrink
        Start-Sleep -Seconds 5
        $newInfo = Get-PartitionInfo -DriveLetter $DriveLetter
        Write-Log "New partition size: $($newInfo.SizeGB) GB"
        Write-Log "New free space: $($newInfo.FreeGB) GB"
        
        if ($newInfo.SizeGB -gt ($TargetSizeGB + 2)) {
            Write-Log "Warning: Partition size $($newInfo.SizeGB)GB is larger than target ${TargetSizeGB}GB" "WARN"
        } else {
            Write-Log "Partition successfully shrunk to target size" "INFO"
        }
        
    } catch {
        Write-Log "Error during shrink: $($_.Exception.Message)" "ERROR"
        throw
    }
}

# Main execution
try {
    Write-Log "=== Starting OS Disk Shrink Process ==="
    Write-Log "Target size: ${TargetSizeGB} GB"
    
    Assert-Admin
    
    $osDrive = Get-OSDrive
    Write-Log "OS Drive: $osDrive"
    
    # Step 1: Disk Cleanup
    Write-Log "Step 1: Disk Cleanup"
    Invoke-DiskCleanup
    
    # Step 2: Optimize/Defrag
    Write-Log "Step 2: Disk Optimization"
    Optimize-Disk -DriveLetter $osDrive
    
    # Wait for disk operations to settle
    Start-Sleep -Seconds 10
    
    # Step 3: Shrink partition
    Write-Log "Step 3: Shrink Partition"
    Shrink-OSPartition -DriveLetter $osDrive -TargetSizeGB $TargetSizeGB
    
    Write-Log "=== OS Disk Shrink Process Completed Successfully ===" "INFO"
    
    # Final disk info
    $finalInfo = Get-PartitionInfo -DriveLetter $osDrive
    Write-Log "Final partition size: $($finalInfo.SizeGB) GB"
    Write-Log "Final used space: $($finalInfo.UsedGB) GB"
    Write-Log "Final free space: $($finalInfo.FreeGB) GB"
    
    exit 0
    
} catch {
    Write-Log "FATAL ERROR: $($_.Exception.Message)" "ERROR"
    Write-Log $_.ScriptStackTrace "ERROR"
    exit 1
}
