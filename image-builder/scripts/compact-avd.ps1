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

# MMAgent cmdlets may not be supported on all editions/configurations
# Wrap in try-catch to prevent script failure
try {
    if ($mmSettings.ApplicationLaunchPrefetching) { 
        Enable-MMAgent -ApplicationLaunchPrefetching -ErrorAction Stop 
        Write-Host "  Enabled ApplicationLaunchPrefetching" -ForegroundColor Gray
    }
} catch { 
    Write-Host "  ApplicationLaunchPrefetching not supported: $($_.Exception.Message)" -ForegroundColor Yellow 
}

try {
    if ($mmSettings.ApplicationPreLaunch) { 
        Enable-MMAgent -ApplicationPreLaunch -ErrorAction Stop 
        Write-Host "  Enabled ApplicationPreLaunch" -ForegroundColor Gray
    }
} catch { 
    Write-Host "  ApplicationPreLaunch not supported: $($_.Exception.Message)" -ForegroundColor Yellow 
}

try {
    if ($mmSettings.MemoryCompression) { 
        Enable-MMAgent -MemoryCompression -ErrorAction Stop 
        Write-Host "  Enabled MemoryCompression" -ForegroundColor Gray
    }
} catch { 
    Write-Host "  MemoryCompression not supported: $($_.Exception.Message)" -ForegroundColor Yellow 
}

try {
    if ($mmSettings.OperationAPI) { 
        Enable-MMAgent -OperationAPI -ErrorAction Stop 
        Write-Host "  Enabled OperationAPI" -ForegroundColor Gray
    }
} catch { 
    Write-Host "  OperationAPI not supported: $($_.Exception.Message)" -ForegroundColor Yellow 
}

try {
    if ($mmSettings.PageCombining) { 
        Enable-MMAgent -PageCombining -ErrorAction Stop 
        Write-Host "  Enabled PageCombining" -ForegroundColor Gray
    }
} catch { 
    Write-Host "  PageCombining not supported: $($_.Exception.Message)" -ForegroundColor Yellow 
}

try {
    if ($mmSettings.MaxOperationAPIFiles) { 
        Set-MMAgent -MaxOperationAPIFiles $mmSettings.MaxOperationAPIFiles -ErrorAction Stop 
        Write-Host "  Set MaxOperationAPIFiles to $($mmSettings.MaxOperationAPIFiles)" -ForegroundColor Gray
    }
} catch { 
    Write-Host "  MaxOperationAPIFiles not supported: $($_.Exception.Message)" -ForegroundColor Yellow 
}

try {
    Write-Host "Final MMAgent state:" -ForegroundColor Green
    Get-MMAgent | Format-List
} catch {
    Write-Host "Could not retrieve MMAgent state (not supported on this system)" -ForegroundColor Yellow
}

Write-Host "Compact image customization complete." -ForegroundColor Green
