#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Configures a Windows image for Azure Virtual Desktop use.

.DESCRIPTION
    Prepares a Windows image for AVD by configuring required settings for both
    single-session and multi-session hosts. Based on official Microsoft documentation:
    https://learn.microsoft.com/azure/virtual-desktop/set-up-customize-master-image
    https://learn.microsoft.com/azure/virtual-desktop/deploy-windows-11-multi-session

.PARAMETER SessionType
    Type of AVD session host: SingleSession or MultiSession (default: auto-detect)

.EXAMPLE
    .\configure-avd-image.ps1
    .\configure-avd-image.ps1 -SessionType MultiSession
#>

param(
    [Parameter()]
    [ValidateSet('SingleSession', 'MultiSession', 'Auto')]
    [string]$SessionType = 'Auto'
)

$ErrorActionPreference = 'Continue'

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    Write-Output $logMessage
}

function Test-Admin {
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    Write-Log "ERROR: This script must be run as Administrator" "ERROR"
    exit 1
}

Write-Log "========================================" "INFO"
Write-Log "AVD Image Configuration Script" "INFO"
Write-Log "========================================" "INFO"
Write-Log ""

# Detect session type if Auto
if ($SessionType -eq 'Auto') {
    try {
        $editionId = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').EditionID
        if ($editionId -match 'ServerRdsh|EnterpriseMultiSession') {
            $SessionType = 'MultiSession'
            Write-Log "Detected Multi-Session OS (EditionID: $editionId)" "INFO"
        } else {
            $SessionType = 'SingleSession'
            Write-Log "Detected Single-Session OS (EditionID: $editionId)" "INFO"
        }
    } catch {
        Write-Log "Could not detect session type, defaulting to MultiSession" "WARN"
        $SessionType = 'MultiSession'
    }
} else {
    Write-Log "Session type specified: $SessionType" "INFO"
}

Write-Log ""
Write-Log "Applying configurations for: $SessionType" "INFO"
Write-Log ""

# ============================================================================
# 1. Detect and Repair SxS Stack Package / AVD Host Pool Health
# ============================================================================
Write-Log "Step 1: Checking AVD host pool membership and SxS Network Stack..." "INFO"

# Check if this node is registered to an AVD host pool
$isHostPoolMember = $false
$hostPoolInfo = $null
$needsReregistration = $false

try {
    # Check for AVD Agent registry key to determine host pool membership
    $avdAgentKey = 'HKLM:\SOFTWARE\Microsoft\RDInfraAgent'
    if (Test-Path $avdAgentKey) {
        $isHostPoolMember = $true
        Write-Log "  Node is registered to an AVD host pool" "INFO"
        
        # Get host pool information from registry
        try {
            $hostPoolInfo = @{
                IsRegistered = (Get-ItemProperty -Path $avdAgentKey -Name 'IsRegistered' -ErrorAction SilentlyContinue).IsRegistered
                RegistrationToken = (Get-ItemProperty -Path $avdAgentKey -Name 'RegistrationToken' -ErrorAction SilentlyContinue).RegistrationToken
            }
            
            # Check health status via RDAgent service
            $rdAgentService = Get-Service -Name 'RDAgentBootLoader' -ErrorAction SilentlyContinue
            if ($null -eq $rdAgentService) {
                Write-Log "  RDAgentBootLoader service not found - host is unhealthy" "WARN"
                $needsReregistration = $true
            } elseif ($rdAgentService.Status -ne 'Running') {
                Write-Log "  RDAgentBootLoader service is $($rdAgentService.Status) - host is unhealthy" "WARN"
                $needsReregistration = $true
            } else {
                # Check if agent can communicate with AVD service
                $rdAgentLog = "C:\Program Files\Microsoft RDInfra\AgentInstall.txt"
                if (Test-Path $rdAgentLog) {
                    $recentErrors = Select-String -Path $rdAgentLog -Pattern "ERROR|FAIL" -SimpleMatch -ErrorAction SilentlyContinue | Select-Object -Last 5
                    if ($recentErrors) {
                        Write-Log "  Recent errors found in AVD Agent logs - host may be unhealthy" "WARN"
                        $needsReregistration = $true
                    }
                }
            }
        } catch {
            Write-Log "  Error checking host pool health: $($_.Exception.Message)" "WARN"
            $needsReregistration = $true
        }
    } else {
        Write-Log "  Node is not registered to an AVD host pool" "INFO"
    }
} catch {
    Write-Log "  Error checking AVD host pool membership: $($_.Exception.Message)" "WARN"
}

# If host is unhealthy, remove and prepare for re-registration
if ($isHostPoolMember -and $needsReregistration) {
    Write-Log "  Host is unhealthy - initiating removal and re-registration process" "WARN"
    
    try {
        # Step 1: Uninstall AVD Agent components
        Write-Log "  Step 1.1: Removing AVD Agent Boot Loader..." "INFO"
        $bootLoader = Get-WmiObject -Class Win32_Product | Where-Object { $_.Name -like "*Remote Desktop Agent Boot Loader*" }
        if ($bootLoader) {
            $bootLoader.Uninstall() | Out-Null
            Write-Log "  AVD Agent Boot Loader uninstalled" "INFO"
        }
        
        Write-Log "  Step 1.2: Removing AVD Agent..." "INFO"
        $agent = Get-WmiObject -Class Win32_Product | Where-Object { $_.Name -like "*Remote Desktop Services Infrastructure Agent*" }
        if ($agent) {
            $agent.Uninstall() | Out-Null
            Write-Log "  AVD Agent uninstalled" "INFO"
        }
        
        # Step 2: Clean up registry keys
        Write-Log "  Step 1.3: Cleaning registry keys..." "INFO"
        Remove-Item -Path 'HKLM:\SOFTWARE\Microsoft\RDInfraAgent' -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -Path 'HKLM:\SOFTWARE\Microsoft\RDMonitoringAgent' -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log "  Registry cleaned" "INFO"
        
        # Step 3: Remove SxS package if present
        Write-Log "  Step 1.4: Removing SxS Network Stack package..." "INFO"
        Uninstall-Package -Name "Remote Desktop Services SxS Network Stack" -AllVersions -Force -ErrorAction SilentlyContinue
        Write-Log "  SxS package removed" "INFO"
        
        Write-Log "  Host successfully removed from AVD - ready for re-registration" "INFO"
        Write-Log "  NOTE: Use Azure CLI or Portal to remove session host from host pool if still listed" "WARN"
        Write-Log "  Command: az desktopvirtualization sessionhost delete --host-pool-name <pool> --name <host> --resource-group <rg>" "INFO"
        
    } catch {
        Write-Log "  ERROR during AVD removal: $($_.Exception.Message)" "ERROR"
    }
}

# Check SxS package status
try {
    $sxsPackage = Get-Package -Name "Remote Desktop Services SxS Network Stack" -ErrorAction SilentlyContinue
    
    if ($null -eq $sxsPackage) {
        Write-Log "  SxS package not found - will be installed with AVD agent" "INFO"
    } else {
        Write-Log "  SxS package found: $($sxsPackage.Name) v$($sxsPackage.Version)" "INFO"
        
        # Check if package is broken by verifying registry keys
        $sxsRegPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\RDMS'
        $isBroken = $false
        
        if (Test-Path $sxsRegPath) {
            try {
                $rdmsService = Get-Service -Name 'RDMS' -ErrorAction SilentlyContinue
                if ($null -eq $rdmsService) {
                    Write-Log "  RDMS service not found - SxS package may be broken" "WARN"
                    $isBroken = $true
                }
            } catch {
                Write-Log "  Error checking RDMS service: $($_.Exception.Message)" "WARN"
                $isBroken = $true
            }
        } else {
            Write-Log "  SxS registry path missing - package is broken" "WARN"
            $isBroken = $true
        }
        
        if ($isBroken) {
            Write-Log "  SxS package is broken - removing for reinstallation" "WARN"
            try {
                Uninstall-Package -Name "Remote Desktop Services SxS Network Stack" -AllVersions -Force -ErrorAction Stop
                Write-Log "  Successfully uninstalled broken SxS package" "INFO"
            } catch {
                Write-Log "  ERROR uninstalling SxS: $($_.Exception.Message)" "ERROR"
            }
        } else {
            Write-Log "  SxS package is healthy" "INFO"
        }
    }
} catch {
    Write-Log "  ERROR checking SxS package: $($_.Exception.Message)" "WARN"
}

# Download latest AVD installers
Write-Log "  Downloading latest AVD installers..." "INFO"
try {
    $agentPath = "C:\Windows\Temp\RDAgent.msi"
    $bootloaderPath = "C:\Windows\Temp\RDBootloader.msi"
    
    Write-Log "  Downloading AVD Agent..." "INFO"
    Invoke-WebRequest -Uri "https://query.prod.cms.rt.microsoft.com/cms/api/am/binary/RWrmXv" -OutFile $agentPath -UseBasicParsing
    Write-Log "  AVD Agent downloaded to $agentPath" "INFO"
    
    Write-Log "  Downloading AVD Boot Loader..." "INFO"
    Invoke-WebRequest -Uri "https://query.prod.cms.rt.microsoft.com/cms/api/am/binary/RWrxrH" -OutFile $bootloaderPath -UseBasicParsing
    Write-Log "  AVD Boot Loader downloaded to $bootloaderPath" "INFO"
    
    if ($needsReregistration) {
        Write-Log "" "INFO"
        Write-Log "  ============================================" "WARN"
        Write-Log "  RE-REGISTRATION REQUIRED" "WARN"
        Write-Log "  ============================================" "WARN"
        Write-Log "  This host was removed from the AVD host pool." "WARN"
        Write-Log "" "INFO"
        Write-Log "  To re-register, obtain a registration token and run:" "INFO"
        Write-Log "  1. Get registration token from Azure Portal or CLI:" "INFO"
        Write-Log "     az desktopvirtualization hostpool update --name <pool> --resource-group <rg> --registration-info expiration-time='<future-date>' registration-token-operation='Update'" "INFO"
        Write-Log "" "INFO"
        Write-Log "  2. Install AVD Agent with token:" "INFO"
        Write-Log "     msiexec /i C:\Windows\Temp\RDAgent.msi REGISTRATIONTOKEN=<token> /qn /norestart" "INFO"
        Write-Log "" "INFO"
        Write-Log "  3. Install Boot Loader:" "INFO"
        Write-Log "     msiexec /i C:\Windows\Temp\RDBootloader.msi /qn /norestart" "INFO"
        Write-Log "  ============================================" "WARN"
        Write-Log "" "INFO"
    } else {
        Write-Log "  AVD installers ready at C:\Windows\Temp\" "INFO"
        Write-Log "  NOTE: Installation requires REGISTRATIONTOKEN during host pool join" "INFO"
    }
    
} catch {
    Write-Log "  ERROR downloading AVD installers: $($_.Exception.Message)" "ERROR"
    Write-Log "  Continuing with configuration" "WARN"
}

# ============================================================================
# 2. Configure RDP and Multi-Session Settings
# ============================================================================
Write-Log ""
Write-Log "Step 2: Configuring RDP and session settings..." "INFO"

try {
    $tsKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
    
    if ($SessionType -eq 'MultiSession') {
        # Allow multiple sessions per user (required for multi-session)
        Write-Log "  Setting fSingleSessionPerUser = 0 (allow multiple sessions)" "INFO"
        Set-ItemProperty -Path $tsKey -Name 'fSingleSessionPerUser' -Value 0 -Type DWord -Force
    } else {
        # Single-session: one session per user
        Write-Log "  Setting fSingleSessionPerUser = 1 (single session per user)" "INFO"
        Set-ItemProperty -Path $tsKey -Name 'fSingleSessionPerUser' -Value 1 -Type DWord -Force
    }
    
    # Enable RDP (required for AVD)
    Write-Log "  Enabling Remote Desktop" "INFO"
    Set-ItemProperty -Path $tsKey -Name 'fDenyTSConnections' -Value 0 -Type DWord -Force
    
    # Set RDP authentication level (Network Level Authentication)
    Write-Log "  Configuring RDP authentication (NLA)" "INFO"
    Set-ItemProperty -Path "$tsKey\WinStations\RDP-Tcp" -Name 'UserAuthentication' -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
    
    # Configure RDP keep-alive
    Write-Log "  Configuring RDP keep-alive settings" "INFO"
    Set-ItemProperty -Path "$tsKey\WinStations\RDP-Tcp" -Name 'KeepAliveTimeout' -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
    
    Write-Log "  RDP configuration complete" "INFO"
} catch {
    Write-Log "  ERROR configuring RDP settings: $($_.Exception.Message)" "ERROR"
}

# ============================================================================
# 3. Disable First Logon Animation (improves user experience)
# ============================================================================
Write-Log ""
Write-Log "Step 3: Disabling first logon animation..." "INFO"

try {
    $policyKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    if (-not (Test-Path $policyKey)) {
        New-Item -Path $policyKey -Force | Out-Null
    }
    Set-ItemProperty -Path $policyKey -Name 'EnableFirstLogonAnimation' -Value 0 -Type DWord -Force
    Write-Log "  First logon animation disabled" "INFO"
} catch {
    Write-Log "  ERROR disabling first logon animation: $($_.Exception.Message)" "WARN"
}

# ============================================================================
# 4. Configure Time Zone Redirection
# ============================================================================
Write-Log ""
Write-Log "Step 4: Enabling time zone redirection..." "INFO"

try {
    $tzKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
    if (-not (Test-Path $tzKey)) {
        New-Item -Path $tzKey -Force | Out-Null
    }
    Set-ItemProperty -Path $tzKey -Name 'fEnableTimeZoneRedirection' -Value 1 -Type DWord -Force
    Write-Log "  Time zone redirection enabled" "INFO"
} catch {
    Write-Log "  ERROR enabling time zone redirection: $($_.Exception.Message)" "WARN"
}

# ============================================================================
# 5. Configure Windows Update for AVD
# ============================================================================
Write-Log ""
Write-Log "Step 5: Configuring Windows Update settings..." "INFO"

try {
    $wuKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
    if (-not (Test-Path $wuKey)) {
        New-Item -Path $wuKey -Force | Out-Null
    }
    
    # Configure to download but not auto-install (managed via update management)
    Set-ItemProperty -Path $wuKey -Name 'AUOptions' -Value 3 -Type DWord -Force
    Set-ItemProperty -Path $wuKey -Name 'NoAutoUpdate' -Value 0 -Type DWord -Force
    
    Write-Log "  Windows Update configured for managed updates" "INFO"
} catch {
    Write-Log "  ERROR configuring Windows Update: $($_.Exception.Message)" "WARN"
}

# ============================================================================
# 6. Disable Storage Sense (can interfere with profile management)
# ============================================================================
Write-Log ""
Write-Log "Step 6: Disabling Storage Sense..." "INFO"

try {
    $ssKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\StorageSense'
    if (-not (Test-Path $ssKey)) {
        New-Item -Path $ssKey -Force | Out-Null
    }
    Set-ItemProperty -Path $ssKey -Name 'AllowStorageSenseGlobal' -Value 0 -Type DWord -Force
    Write-Log "  Storage Sense disabled" "INFO"
} catch {
    Write-Log "  ERROR disabling Storage Sense: $($_.Exception.Message)" "WARN"
}

# ============================================================================
# 7. Configure Power Settings (prevent sleep/hibernate)
# ============================================================================
Write-Log ""
Write-Log "Step 7: Configuring power settings..." "INFO"

try {
    # Set power plan to High Performance
    Write-Log "  Setting power plan to High Performance" "INFO"
    powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c 2>&1 | Out-Null
    
    # Disable sleep and hibernate
    Write-Log "  Disabling sleep and hibernate" "INFO"
    powercfg /change standby-timeout-ac 0 2>&1 | Out-Null
    powercfg /change standby-timeout-dc 0 2>&1 | Out-Null
    powercfg /change hibernate-timeout-ac 0 2>&1 | Out-Null
    powercfg /change hibernate-timeout-dc 0 2>&1 | Out-Null
    
    # Disable fast startup (can cause issues with AVD)
    $powerKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
    Set-ItemProperty -Path $powerKey -Name 'HiberbootEnabled' -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
    
    Write-Log "  Power settings configured" "INFO"
} catch {
    Write-Log "  ERROR configuring power settings: $($_.Exception.Message)" "WARN"
}

# ============================================================================
# 8. Configure FSLogix (if installed)
# ============================================================================
Write-Log ""
Write-Log "Step 8: Configuring FSLogix..." "INFO"

$fslogixInstalled = Get-Service -Name 'frxsvc' -ErrorAction SilentlyContinue

if ($fslogixInstalled) {
    Write-Log "  FSLogix service detected, configuring profile settings" "INFO"
    
    try {
        $fsKey = 'HKLM:\SOFTWARE\FSLogix\Profiles'
        if (-not (Test-Path $fsKey)) {
            New-Item -Path $fsKey -Force | Out-Null
        }
        
        # Enable FSLogix profiles (requires VHDLocations to be set by admin)
        Set-ItemProperty -Path $fsKey -Name 'Enabled' -Value 1 -Type DWord -Force
        
        # Delete local profile when VHD should apply
        Set-ItemProperty -Path $fsKey -Name 'DeleteLocalProfileWhenVHDShouldApply' -Value 1 -Type DWord -Force
        
        # Enable concurrent user sessions
        Set-ItemProperty -Path $fsKey -Name 'ConcurrentUserSessions' -Value 1 -Type DWord -Force
        
        # Set profile type to try for read-write, fallback to read-only
        Set-ItemProperty -Path $fsKey -Name 'ProfileType' -Value 3 -Type DWord -Force
        
        # Enable dynamic VHD
        Set-ItemProperty -Path $fsKey -Name 'SizeInMBs' -Value 30000 -Type DWord -Force
        Set-ItemProperty -Path $fsKey -Name 'IsDynamic' -Value 1 -Type DWord -Force
        
        # Set VHD naming pattern
        Set-ItemProperty -Path $fsKey -Name 'FlipFlopProfileDirectoryName' -Value 1 -Type DWord -Force
        
        # Volume type (VHDX)
        Set-ItemProperty -Path $fsKey -Name 'VolumeType' -Value 'VHDX' -Type String -Force
        
        Write-Log "  FSLogix profiles configured (VHDLocations must be set per environment)" "INFO"
        Write-Log "  NOTE: Set VHDLocations registry value to your file share path" "WARN"
    } catch {
        Write-Log "  ERROR configuring FSLogix: $($_.Exception.Message)" "ERROR"
    }
} else {
    Write-Log "  FSLogix not installed - skipping FSLogix configuration" "INFO"
    Write-Log "  NOTE: FSLogix is recommended for production AVD deployments" "WARN"
}

# ============================================================================
# 9. Configure Windows Defender Exclusions for AVD/FSLogix
# ============================================================================
Write-Log ""
Write-Log "Step 9: Configuring Windows Defender exclusions..." "INFO"

try {
    # FSLogix exclusions (if FSLogix is installed)
    if ($fslogixInstalled) {
        Write-Log "  Adding FSLogix exclusions to Windows Defender" "INFO"
        
        # File extensions
        Add-MpPreference -ExclusionExtension '.VHD','.VHDX','.CIM' -ErrorAction SilentlyContinue
        
        # FSLogix processes
        Add-MpPreference -ExclusionProcess '%ProgramFiles%\FSLogix\Apps\frxccd.exe' -ErrorAction SilentlyContinue
        Add-MpPreference -ExclusionProcess '%ProgramFiles%\FSLogix\Apps\frxccds.exe' -ErrorAction SilentlyContinue
        Add-MpPreference -ExclusionProcess '%ProgramFiles%\FSLogix\Apps\frxsvc.exe' -ErrorAction SilentlyContinue
    }
    
    # AVD Agent exclusions
    Write-Log "  Adding AVD Agent exclusions to Windows Defender" "INFO"
    Add-MpPreference -ExclusionProcess 'C:\Program Files\Microsoft RDInfra\RDAgent.exe' -ErrorAction SilentlyContinue
    Add-MpPreference -ExclusionProcess 'C:\Program Files\Microsoft RDInfra\RDAgentBootLoader.exe' -ErrorAction SilentlyContinue
    
    Write-Log "  Windows Defender exclusions configured" "INFO"
} catch {
    Write-Log "  ERROR configuring Defender exclusions: $($_.Exception.Message)" "WARN"
}

# ============================================================================
# 10. Optimize for Virtual Desktop Experience
# ============================================================================
Write-Log ""
Write-Log "Step 10: Optimizing for virtual desktop experience..." "INFO"

try {
    # Disable background defragmentation (handled by Azure)
    Write-Log "  Disabling automatic defragmentation" "INFO"
    Disable-ScheduledTask -TaskName 'Microsoft\Windows\Defrag\ScheduledDefrag' -ErrorAction SilentlyContinue
    
    # Disable Windows Search indexing on non-OS drives (performance)
    Write-Log "  Configuring Windows Search indexing" "INFO"
    $searchKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'
    if (-not (Test-Path $searchKey)) {
        New-Item -Path $searchKey -Force | Out-Null
    }
    Set-ItemProperty -Path $searchKey -Name 'DisableRemovableDriveIndexing' -Value 1 -Type DWord -Force
    
    # Disable Superfetch (not beneficial for VMs)
    Write-Log "  Disabling Superfetch/SysMain" "INFO"
    Stop-Service -Name 'SysMain' -Force -ErrorAction SilentlyContinue
    Set-Service -Name 'SysMain' -StartupType Disabled -ErrorAction SilentlyContinue
    
    Write-Log "  Virtual desktop optimizations applied" "INFO"
} catch {
    Write-Log "  ERROR applying optimizations: $($_.Exception.Message)" "WARN"
}

# ============================================================================
# 11. Configure Network Settings
# ============================================================================
Write-Log ""
Write-Log "Step 11: Configuring network settings..." "INFO"

try {
    # Enable Network Discovery
    netsh advfirewall firewall set rule group="Network Discovery" new enable=Yes 2>&1 | Out-Null
    
    # Disable NetBIOS over TCP/IP on all adapters (security)
    Write-Log "  Disabling NetBIOS over TCP/IP" "INFO"
    $adapters = Get-WmiObject Win32_NetworkAdapterConfiguration -Filter "IPEnabled=True"
    foreach ($adapter in $adapters) {
        $adapter.SetTcpipNetbios(2) | Out-Null  # 2 = Disable NetBIOS
    }
    
    Write-Log "  Network settings configured" "INFO"
} catch {
    Write-Log "  ERROR configuring network settings: $($_.Exception.Message)" "WARN"
}

# ============================================================================
# 12. Configure Firewall for AVD
# ============================================================================
Write-Log ""
Write-Log "Step 12: Configuring Windows Firewall..." "INFO"

try {
    # Ensure RDP is allowed
    Write-Log "  Ensuring RDP firewall rules are enabled" "INFO"
    Enable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue
    
    Write-Log "  Firewall rules configured" "INFO"
} catch {
    Write-Log "  ERROR configuring firewall: $($_.Exception.Message)" "WARN"
}

# ============================================================================
# 13. Set Registry Keys for AVD Optimization
# ============================================================================
Write-Log ""
Write-Log "Step 13: Applying additional AVD optimizations..." "INFO"

try {
    # Disable automatic maintenance
    Write-Log "  Disabling automatic maintenance" "INFO"
    $maintKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\Maintenance'
    if (-not (Test-Path $maintKey)) {
        New-Item -Path $maintKey -Force | Out-Null
    }
    Set-ItemProperty -Path $maintKey -Name 'MaintenanceDisabled' -Value 1 -Type DWord -Force
    
    # Configure visual effects for performance
    Write-Log "  Configuring visual effects for performance" "INFO"
    $visualKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects'
    if (-not (Test-Path $visualKey)) {
        New-Item -Path $visualKey -Force | Out-Null
    }
    Set-ItemProperty -Path $visualKey -Name 'VisualFXSetting' -Value 2 -Type DWord -Force  # Best performance
    
    Write-Log "  Additional optimizations applied" "INFO"
} catch {
    Write-Log "  ERROR applying additional optimizations: $($_.Exception.Message)" "WARN"
}

# ============================================================================
# Summary
# ============================================================================
Write-Log ""
Write-Log "========================================" "INFO"
Write-Log "AVD Image Configuration Complete" "INFO"
Write-Log "========================================" "INFO"
Write-Log ""
Write-Log "Configuration Summary:" "INFO"
Write-Log "  - Session Type: $SessionType" "INFO"
Write-Log "  - RDP: Enabled" "INFO"
Write-Log "  - Multi-Session: $(if ($SessionType -eq 'MultiSession') {'Enabled'} else {'Disabled'})" "INFO"
Write-Log "  - FSLogix: $(if ($fslogixInstalled) {'Configured (VHDLocations needs setting)'} else {'Not Installed'})" "INFO"
Write-Log "  - First Logon Animation: Disabled" "INFO"
Write-Log "  - Power Settings: Optimized for AVD" "INFO"
Write-Log "  - Windows Defender: Exclusions configured" "INFO"
Write-Log ""

if (-not $fslogixInstalled) {
    Write-Log "RECOMMENDATION: Install FSLogix for production deployments" "WARN"
    Write-Log "  Download: https://aka.ms/fslogix-latest" "INFO"
}

Write-Log ""
Write-Log "NEXT STEPS:" "INFO"
Write-Log "  1. If using FSLogix, set VHDLocations registry value to your file share" "INFO"
Write-Log "  2. Install AVD Agent and Boot Loader after joining to host pool" "INFO"
Write-Log "  3. Run Windows Update to ensure latest patches" "INFO"
Write-Log "  4. Consider running Microsoft's Virtual Desktop Optimization Tool (VDOT)" "INFO"
Write-Log "     Download: https://github.com/The-Virtual-Desktop-Team/Virtual-Desktop-Optimization-Tool" "INFO"
Write-Log ""
Write-Log "Image is now ready for Sysprep and capture or direct deployment to AVD" "INFO"
Write-Log ""

exit 0
