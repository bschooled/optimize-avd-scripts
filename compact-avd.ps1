[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Assert-Admin {
    if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
        throw 'This script must be run in an elevated session.'
    }
}

Assert-Admin

Write-Host "Enabling CompactOS" -ForegroundColor Cyan
compact.exe /compactOS:always

$compactTargets = @(
    'C:\\Program Files',
    'C:\\Program Files (x86)',
    'C:\\Users'
)

foreach ($target in $compactTargets) {
    if (Test-Path $target) {
        Write-Host "Compressing $target with LZX" -ForegroundColor Cyan
        compact.exe /c /s:"$target" /a /i /exe:lzx | Out-Null
    }
}

Write-Host "Configuring memory manager agent features" -ForegroundColor Cyan

$mmSettings = [ordered]@{
    ApplicationLaunchPrefetching = $true
    ApplicationPreLaunch         = $true
    MaxOperationAPIFiles         = 8192
    MemoryCompression            = $true
    OperationAPI                 = $true
    PageCombining                = $true
}

if ($mmSettings.ApplicationLaunchPrefetching) { Enable-MMAgent -ApplicationLaunchPrefetching }
if ($mmSettings.ApplicationPreLaunch)         { Enable-MMAgent -ApplicationPreLaunch }
if ($mmSettings.MemoryCompression)            { Enable-MMAgent -MemoryCompression }
if ($mmSettings.OperationAPI)                 { Enable-MMAgent -OperationAPI }
if ($mmSettings.PageCombining)                { Enable-MMAgent -PageCombining }
if ($mmSettings.MaxOperationAPIFiles)         { Set-MMAgent -MaxOperationAPIFiles $mmSettings.MaxOperationAPIFiles }

Write-Host "Final MMAgent state:" -ForegroundColor Green
Get-MMAgent | Format-List

Write-Host "Compact image customization complete." -ForegroundColor Green
