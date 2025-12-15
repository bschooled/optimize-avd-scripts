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

# Continue on non-fatal errors - only stop for critical failures
$ErrorActionPreference = 'Continue'

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
        Write-Log "FATAL: This script must be run as Administrator" "ERROR"
        exit 1
    }
}

function Get-OSDrive {
    $os = Get-WmiObject -Class Win32_OperatingSystem
    return $os.SystemDrive
}

function Invoke-DiskCleanup {
    Write-Log "Running Disk Cleanup to free space..."
    
    try {
        # Run Windows Disk Cleanup
        $cleanmgrKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches'
        
        # Enable all cleanup options
        $volumeCaches = Get-ChildItem -Path $cleanmgrKey -ErrorAction SilentlyContinue
        if ($volumeCaches) {
            foreach ($cache in $volumeCaches) {
                try {
                    Set-ItemProperty -Path $cache.PSPath -Name StateFlags0001 -Value 2 -ErrorAction SilentlyContinue
                } catch {
                    # Ignore individual cache setting errors
                }
            }
            
            # Run cleanup
            $cleanmgrProcess = Start-Process -FilePath cleanmgr.exe -ArgumentList '/sagerun:1' -Wait -NoNewWindow -PassThru
            if ($cleanmgrProcess.ExitCode -eq 0) {
                Write-Log "Disk cleanup completed successfully"
            } else {
                Write-Log "Disk cleanup completed with exit code: $($cleanmgrProcess.ExitCode)" "WARN"
            }
        } else {
            Write-Log "Could not access volume cache registry keys - skipping cleanup" "WARN"
        }
    } catch {
        Write-Log "Disk cleanup failed (non-fatal): $($_.Exception.Message)" "WARN"
        Write-Log "Continuing with disk shrink operation..." "INFO"
    }
}

function Optimize-Disk {
    param([string]$DriveLetter)
    
    Write-Log "Defragmenting and optimizing $DriveLetter..."
    
    try {
        # Defrag and consolidate free space
        Optimize-Volume -DriveLetter $DriveLetter.TrimEnd(':') -Defrag -SlabConsolidate -ErrorAction Stop
        Write-Log "Disk optimization completed successfully"
    } catch {
        Write-Log "Defrag failed (non-fatal): $($_.Exception.Message)" "WARN"
        Write-Log "This may reduce the amount of space that can be reclaimed, but shrink will still be attempted" "WARN"
    }
}

function Get-PartitionInfo {
    param([string]$DriveLetter)
    
    try {
        $partition = Get-Partition -DriveLetter $DriveLetter.TrimEnd(':') -ErrorAction Stop
        $volume = Get-Volume -DriveLetter $DriveLetter.TrimEnd(':') -ErrorAction Stop
        
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
    } catch {
        Write-Log "FATAL: Could not retrieve partition information for ${DriveLetter}: $($_.Exception.Message)" "ERROR"
        exit 1
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
    
    # Validate we have enough space with safety buffer
    $minRequiredGB = [math]::Ceiling($usedBytes / 1GB) + 5  # Used space + 5GB buffer
    if ($TargetSizeGB -lt $minRequiredGB) {
        Write-Log "FATAL: Target size ${TargetSizeGB}GB is too small" "ERROR"
        Write-Log "FATAL: Minimum required: ${minRequiredGB}GB (used: $($info.UsedGB)GB + 5GB safety buffer)" "ERROR"
        Write-Log "FATAL: Either increase --disk-size parameter or reduce the image size by removing components" "ERROR"
        exit 1
    }
    
    if ($currentSizeBytes -le $targetSizeBytes) {
        Write-Log "Current size ($($info.SizeGB)GB) is already at or below target (${TargetSizeGB}GB)" "INFO"
        Write-Log "No shrink needed - continuing successfully" "INFO"
        return
    }
    
    # Calculate shrink amount
    $shrinkBytes = $currentSizeBytes - $targetSizeBytes
    $shrinkMB = [math]::Floor($shrinkBytes / 1MB)
    
    Write-Log "Will shrink partition by $([math]::Round($shrinkBytes / 1GB, 2)) GB ($shrinkMB MB)..."
    
    try {
        # Use DISKPART for more reliable shrinking
        $diskpartScript = @"
select volume $($DriveLetter.TrimEnd(':'))
shrink desired=$shrinkMB minimum=$shrinkMB
exit
"@
        
        $scriptPath = "C:\Deployer\diskpart_shrink.txt"
        $diskpartScript | Out-File -FilePath $scriptPath -Encoding ASCII -Force
        
        Write-Log "Executing DISKPART shrink operation (this may take several minutes)..."
        $diskpartOutput = diskpart /s $scriptPath 2>&1 | Out-String
        $diskpartExitCode = $LASTEXITCODE
        
        Write-Log "DISKPART output: $diskpartOutput"
        
        # Clean up script file
        try {
            Remove-Item -Path $scriptPath -Force -ErrorAction SilentlyContinue
        } catch {
            # Ignore cleanup errors
        }
        
        # Check if DISKPART succeeded
        if ($diskpartExitCode -ne 0) {
            Write-Log "FATAL: DISKPART failed with exit code: $diskpartExitCode" "ERROR"
            Write-Log "FATAL: Shrink operation failed - this is a critical error" "ERROR"
            exit 1
        }
        
        if ($diskpartOutput -match "error|failed|cannot" -and $diskpartOutput -notmatch "DiskPart successfully") {
            Write-Log "FATAL: DISKPART reported errors in output" "ERROR"
            Write-Log "FATAL: Shrink operation may have failed - check output above" "ERROR"
            exit 1
        }
        
        # Verify shrink
        Write-Log "Waiting for disk operations to complete..."
        Start-Sleep -Seconds 5
        
        try {
            $newInfo = Get-PartitionInfo -DriveLetter $DriveLetter
            Write-Log "New partition size: $($newInfo.SizeGB) GB" "INFO"
            Write-Log "New used space: $($newInfo.UsedGB) GB" "INFO"
            Write-Log "New free space: $($newInfo.FreeGB) GB" "INFO"
            
            # Validate shrink was successful (allow 2GB tolerance for rounding)
            if ($newInfo.SizeGB -gt ($TargetSizeGB + 2)) {
                Write-Log "WARNING: Partition size $($newInfo.SizeGB)GB is larger than target ${TargetSizeGB}GB" "WARN"
                Write-Log "WARNING: This may indicate the shrink did not complete as expected" "WARN"
                Write-Log "WARNING: However, this may be acceptable depending on your requirements" "WARN"
            } else {
                Write-Log "Partition successfully shrunk to approximately target size" "INFO"
            }
        } catch {
            Write-Log "WARNING: Could not verify new partition size: $($_.Exception.Message)" "WARN"
            Write-Log "WARNING: Shrink may have completed but verification failed" "WARN"
        }
        
    } catch {
        Write-Log "FATAL: Exception during shrink operation: $($_.Exception.Message)" "ERROR"
        Write-Log "FATAL: Stack trace: $($_.ScriptStackTrace)" "ERROR"
        exit 1
    }
}

# Main execution
try {
    Write-Log "=== Starting OS Disk Shrink Process ==="
    Write-Log "Target size: ${TargetSizeGB} GB"
    
    Assert-Admin
    
    $osDrive = Get-OSDrive
    Write-Log "OS Drive: $osDrive"
    
    # Get initial disk information
    try {
        $initialInfo = Get-PartitionInfo -DriveLetter $osDrive
        Write-Log "Initial partition size: $($initialInfo.SizeGB) GB"
        Write-Log "Initial used space: $($initialInfo.UsedGB) GB"
        Write-Log "Initial free space: $($initialInfo.FreeGB) GB"
    } catch {
        Write-Log "FATAL: Could not read initial disk information" "ERROR"
        exit 1
    }
    
    # Step 1: Disk Cleanup (non-fatal)
    Write-Log "Step 1: Disk Cleanup"
    Invoke-DiskCleanup
    
    # Step 2: Optimize/Defrag (non-fatal)
    Write-Log "Step 2: Disk Optimization"
    Optimize-Disk -DriveLetter $osDrive
    
    # Wait for disk operations to settle
    Write-Log "Waiting for disk operations to complete..."
    Start-Sleep -Seconds 10
    
    # Step 3: Shrink partition (FATAL if this fails)
    Write-Log "Step 3: Shrink Partition"
    Shrink-OSPartition -DriveLetter $osDrive -TargetSizeGB $TargetSizeGB
    
    Write-Log "=== OS Disk Shrink Process Completed Successfully ===" "INFO"
    
    # Final disk info
    try {
        $finalInfo = Get-PartitionInfo -DriveLetter $osDrive
        Write-Log "=== Final Disk State ===" "INFO"
        Write-Log "Final partition size: $($finalInfo.SizeGB) GB" "INFO"
        Write-Log "Final used space: $($finalInfo.UsedGB) GB" "INFO"
        Write-Log "Final free space: $($finalInfo.FreeGB) GB" "INFO"
        
        # Calculate space saved
        if ($initialInfo) {
            $spaceSaved = $initialInfo.SizeGB - $finalInfo.SizeGB
            Write-Log "Space saved: $([math]::Round($spaceSaved, 2)) GB" "INFO"
        }
    } catch {
        Write-Log "WARNING: Could not retrieve final partition information" "WARN"
    }
    
    Write-Log "Disk shrink operation completed - image build can continue" "INFO"
    exit 0
    
} catch {
    Write-Log "FATAL ERROR: Unexpected exception in main execution" "ERROR"
    Write-Log "Exception: $($_.Exception.Message)" "ERROR"
    Write-Log "Stack trace: $($_.ScriptStackTrace)" "ERROR"
    Write-Log "The disk shrink operation has failed - image build cannot continue" "ERROR"
    exit 1
}
