
<# 
Windows 11 Enterprise multi‑session (standalone) audit — PS 5.1 compatible
- Detects AVD Agent/Boot Loader, FSLogix, join state, and key multi‑session/RDP settings.
- No PS 7 operators; prints plain text via Out-String for Azure Run Command.
#>

$Report = New-Object System.Collections.Generic.List[object]

function Add-Result {
    param(
        [string]$Category,
        [string]$Name,
        [string]$State,
        [string]$Details = ""
    )
    $Report.Add([pscustomobject]@{
        Category = $Category
        Check    = $Name
        State    = $State
        Details  = $Details
    })
}

Write-Output "*** Multi-session standalone audit (PS 5.1) ***"

# 1) OS Edition & Build
try {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $productName = $cv.ProductName
    $editionId   = $cv.EditionID
    $releaseId   = $cv.ReleaseId
    $ubr         = $cv.UBR
    Add-Result 'OS' 'Edition' 'OK' ("{0} (EditionID={1})" -f $productName,$editionId)
    Add-Result 'OS' 'Build'   'OK' ("Version={0} (ReleaseId={1}, UBR={2})" -f $os.Version,$releaseId,$ubr)
} catch {
    Add-Result 'OS' 'Edition/Build' 'ERROR' $_.Exception.Message
}

# 2) Join State (Entra/AD/Workgroup)
try {
    $dsOut = dsregcmd /status 2>$null
    $ds = [string]$dsOut
    $aadJoined    = ($ds -match 'AzureAdJoined\s*:\s*YES')
    $aadPrt       = ($ds -match 'AzureAdPrt\s*:\s*YES')
    $domainJoined = ($ds -match 'DomainJoined\s*:\s*YES')
    Add-Result 'Identity' 'AzureAdJoined' ($(if ($aadJoined) {'YES'} else {'NO'})) ("PRT=" + ($(if ($aadPrt){'YES'}else{'NO'})))
    Add-Result 'Identity' 'DomainJoined'  ($(if ($domainJoined){'YES'} else {'NO'})) ""
    if(-not $aadJoined -and -not $domainJoined){
        Add-Result 'Identity' 'Workgroup' 'YES' 'VM is non‑domain/non‑Entra (Workgroup)'
    }
} catch {
    Add-Result 'Identity' 'dsregcmd' 'ERROR' 'Failed to query dsregcmd /status'
}

# 3) AVD Agent & Boot Loader presence + version
$agentExePaths = @(
    "$env:ProgramFiles\Microsoft RDInfra\RDInfraAgent\rdagent.exe",
    "C:\Program Files\Microsoft RDInfra\RDInfraAgent\rdagent.exe"
)
$bootExePaths = @(
    "$env:ProgramFiles\Microsoft RDInfra\RDInfraAgent\rdbootloader.exe",
    "C:\Program Files\Microsoft RDInfra\RDInfraAgent\rdbootloader.exe",
    "C:\Program Files\Microsoft RDInfra\RemoteDesktop\rdbootloader.exe"
)

function Get-FileVersionSafe([string]$p) {
    if ([string]::IsNullOrWhiteSpace($p)) { return $null }
    if (Test-Path $p) { (Get-Item $p).VersionInfo.FileVersion } else { $null }
}

# pick first existing path
$agentPath = ($agentExePaths | Where-Object { Test-Path $_ } | Select-Object -First 1)
$bootPath  = ($bootExePaths  | Where-Object { Test-Path $_ } | Select-Object -First 1)

$agentVer  = Get-FileVersionSafe $agentPath
$bootVer   = Get-FileVersionSafe $bootPath

Add-Result 'AVD Agent'     'Executable' ($(if ($agentPath){'FOUND'}else{'MISSING'})) ($(if ($agentPath){$agentPath}else{''}))
Add-Result 'AVD Agent'     'Version'    ($(if ($agentVer){'OK'}else{'UNKNOWN'}))    ($(if ($agentVer){$agentVer}else{'Not installed'}))
Add-Result 'AVD BootLoader' 'Executable' ($(if ($bootPath){'FOUND'}else{'MISSING'})) ($(if ($bootPath){$bootPath}else{''}))
Add-Result 'AVD BootLoader' 'Version'    ($(if ($bootVer){'OK'}else{'UNKNOWN'}))    ($(if ($bootVer){$bootVer}else{'Not installed'}))

# Services (names vary by build)
$svcNames = @('RDAgent','RDAgentBootLoader','RdAgent','RdInfraAgent')
foreach($svc in $svcNames){
    $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
    Add-Result 'AVD Services' $svc ($(if ($s){$s.Status}else{'NOT INSTALLED'})) ($(if ($s){$s.DisplayName}else{''}))
}

# Registry footprint
$rdReg = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\RdInfraAgent' -ErrorAction SilentlyContinue
Add-Result 'AVD Agent' 'Registry HKLM:\SOFTWARE\Microsoft\RdInfraAgent' ($(if ($rdReg){'FOUND'}else{'MISSING'})) ''

# 4) FSLogix
$fsSvc = Get-Service -Name 'frxsvc' -ErrorAction SilentlyContinue
Add-Result 'FSLogix' 'Service frxsvc' ($(if ($fsSvc){$fsSvc.Status}else{'NOT INSTALLED'})) ($(if ($fsSvc){$fsSvc.DisplayName}else{''}))
$fsRoot = 'HKLM:\SOFTWARE\FSLogix'
$fsReg  = Get-Item $fsRoot -ErrorAction SilentlyContinue
Add-Result 'FSLogix' 'Registry HKLM:\SOFTWARE\FSLogix' ($(if ($fsReg){'FOUND'}else{'MISSING'})) ''

function Get-FSVal($name) {
    try { (Get-ItemProperty $fsRoot).$name } catch { $null }
}
if ($fsReg) {
    $enabled = Get-FSVal 'Enabled'
    $vhdLocs = Get-FSVal 'VHDLocations'
    $flip    = Get-FSVal 'FlipFlopProfileDirectory'
    Add-Result 'FSLogix' 'Enabled (Enable=1)' ($(if ($enabled -eq 1){'TRUE'}else{'FALSE/NotSet'})) ("Value: " + ($enabled))
    Add-Result 'FSLogix' 'VHDLocations'       ($(if ($vhdLocs){'SET'}else{'NOT SET'}))        ($vhdLocs)
    Add-Result 'FSLogix' 'FlipFlopProfileDirectory' ($(if ($flip -eq 1){'TRUE'}else{'FALSE/NotSet'})) ("Value: " + ($flip))
}

# 5) Multi‑session/RDP toggles
try {
    $tsKey   = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
    $tsProps = Get-ItemProperty $tsKey
    $fSingle = $tsProps.fSingleSessionPerUser
    $state   = if ($fSingle -eq 0) { 'OK (0)' } else { "WARNING ($fSingle)" }
    Add-Result 'RDP Config' 'fSingleSessionPerUser' $state '0 allows multiple sessions'
} catch {
    Add-Result 'RDP Config' 'fSingleSessionPerUser' 'ERROR' 'Cannot read Terminal Server key'
}

try {
    $animKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    $animVal = (Get-ItemProperty $animKey -ErrorAction SilentlyContinue).EnableFirstLogonAnimation
    if ($null -eq $animVal) { $animStr = 'NotSet' }
    elseif ($animVal -eq 0) { $animStr = 'Disabled (0)' }
    else { $animStr = "Enabled ($animVal)" }
    Add-Result 'Profile Init' 'EnableFirstLogonAnimation' 'INFO' $animStr
} catch {
    Add-Result 'Profile Init' 'EnableFirstLogonAnimation' 'ERROR' 'Cannot read policy key'
}

# 6) Event sampling (brief)
function Sample-Events($logname, $provider, $count=100) {
    try {
        Get-WinEvent -LogName $logname -MaxEvents $count |
            Where-Object { $_.ProviderName -like ("*" + $provider + "*") } |
            Select-Object TimeCreated, ProviderName, Id, LevelDisplayName, Message
    } catch { @() }
}
$fsEvents = Sample-Events 'Application' 'FSLogix'
$rdEvents = Sample-Events 'Application' 'RdInfra'  # generic agent provider filter
Add-Result 'Diagnostics' 'FSLogix Events (last 100)'  ($(if ($fsEvents.Count){'FOUND'}else{'NONE'})) ($fsEvents.Count.ToString())
Add-Result 'Diagnostics' 'AVD Agent Events (last 100)' ($(if ($rdEvents.Count){'FOUND'}else{'NONE'})) ($rdEvents.Count.ToString())

# 7) Print results as plain text (for Azure Run Command)
Write-Output ""
Write-Output "================================================================================"
Write-Output "                    AVD MULTI-SESSION VALIDATION REPORT"
Write-Output "================================================================================"
Write-Output ""

# Group by category and output in a readable format
$categories = $Report | Group-Object -Property Category | Sort-Object Name

foreach ($cat in $categories) {
    Write-Output ""
    Write-Output "--- $($cat.Name) ---"
    Write-Output ""
    
    foreach ($item in ($cat.Group | Sort-Object Check)) {
        $line = "  [{0}] {1}" -f $item.State, $item.Check
        if ($item.Details) {
            $line += " : $($item.Details)"
        }
        Write-Output $line
    }
}

Write-Output ""
Write-Output "================================================================================"
Write-Output "Validation complete."
Write-Output "================================================================================"
Write-Output ""

# Summary of critical issues
$issues = $Report | Where-Object { $_.State -in @('MISSING','WARNING','ERROR') }
if ($issues.Count -gt 0) {
    Write-Output ""
    Write-Output "ATTENTION: Found $($issues.Count) items requiring attention:"
    foreach ($issue in $issues) {
        Write-Output "  - [$($issue.Category)] $($issue.Check): $($issue.State)"
    }
    Write-Output ""
}
