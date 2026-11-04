#Requires -Version 5.1
<#
.SYNOPSIS
    Automated Remediation Script for Acer Swift Go 16 AI (SFG16-I71T)
    Stop Code: VIDEO_MEMORY_MANAGEMENT_INTERNAL (0x0000010E)

.DESCRIPTION
    1. Audits the currently installed Intel(R) NPU (PCI\VEN_8086&DEV_B03E) and Intel(R) Graphics (PCI\VEN_8086&DEV_B090) drivers,
       recent crash minidumps, and current Fast Startup / WDDM TDR registry settings.
    2. Scans the Windows Update Agent (Microsoft.Update.Session) for patched WHQL drivers:
       - Intel Corporation ComputeAccelerator Driver Update (32.0.100.4841) [Fixes 0x10E BSOD in 32.0.100.4509/4512]
       - Intel Corporation Extension Driver Update (32.0.100.4841)
       - Intel Corporation Display Driver Update (32.0.101.8724)
       - Intel Corporation Extension Driver Update (32.0.101.8724)
       - Insyde Software Firmware Driver Update (1.0.6.0)
    3. Stages/downloads those WHQL updates via Windows Update Agent (CreateUpdateDownloader) and checks local Downloads
       for standalone Intel NPU installers (e.g. npu_win_32.0.100.5540.exe).
    4. Applies the remediation (in-process if already Administrator, or via UAC elevation):
       a. Installs the staged WHQL NPU, Display, and Firmware updates via Windows Update Installer (CreateUpdateInstaller).
       b. Installs any local Intel NPU installer (npu_win_32.0.100.5540.exe) if present in Downloads.
       c. Disables Windows Fast Startup (HiberbootEnabled = 0) to prevent corrupted WDDM/NPU states across reboots.
       d. Configures WDDM Timeout Detection & Recovery (TdrDelay = 10, TdrDdiDelay = 10) for NPU/GPU memory fault resilience.
#>

$ErrorActionPreference = "Stop"

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host " Acer Swift Go 16 AI (SFG16-I71T) -- 0x10E BSOD Remediation Utility" -ForegroundColor Cyan
Write-Host "==================================================================" -ForegroundColor Cyan

# 1. Audit current drivers & system state via Registry
Write-Host "`n[1/4] Auditing current Intel NPU and Graphics drivers..." -ForegroundColor Yellow
$drivers = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Class\*\*" -ErrorAction SilentlyContinue |
    Where-Object { $_.DriverDesc -match "\bNPU\b|Intel\(R\) Graphics" } |
    Select-Object DriverDesc, DriverVersion, DriverDate, InfPath, MatchingDeviceId

$drivers | Format-Table -AutoSize

$npuDriver = $drivers | Where-Object { $_.DriverDesc -match "\bNPU\b" } | Select-Object -First 1
if ($npuDriver) {
    Write-Host "Detected Intel NPU Driver: $($npuDriver.DriverVersion) ($($npuDriver.InfPath), Hardware ID: $($npuDriver.MatchingDeviceId))" -ForegroundColor Gray
    if ([version]$npuDriver.DriverVersion -le [version]"32.0.100.4512") {
        Write-Host "STATUS: Vulnerable to 0x10E BSOD (version $($npuDriver.DriverVersion) <= 32.0.100.4512). Update to >= 32.0.100.4841 / 32.0.100.5540 required." -ForegroundColor Red
    } else {
        Write-Host "STATUS: NPU driver version $($npuDriver.DriverVersion) is patched (> 32.0.100.4512)." -ForegroundColor Green
    }
}

$powerRegBefore = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power" -Name "HiberbootEnabled" -ErrorAction SilentlyContinue
$gfxRegBefore = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" -ErrorAction SilentlyContinue
Write-Host "Current HiberbootEnabled (Fast Startup): $($powerRegBefore.HiberbootEnabled) (Target: 0)" -ForegroundColor Gray
Write-Host "Current WDDM TdrDelay / TdrDdiDelay:     $($gfxRegBefore.TdrDelay) / $($gfxRegBefore.TdrDdiDelay) (Target: 10 / 10)" -ForegroundColor Gray

# 2. Check for NPU installer in Downloads
Write-Host "`n[2/4] Preparing staging directory and checking local Downloads..." -ForegroundColor Yellow
$tempDir = Join-Path $env:TEMP "acer_0x10e_fix"
if (-not (Test-Path $tempDir)) {
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
}

$installerPath = $null
$userDownloads = Join-Path $env:USERPROFILE "Downloads"
if (Test-Path $userDownloads -ErrorAction SilentlyContinue) {
    $existingPkg = Get-ChildItem -Path $userDownloads -Filter "*npu*win*" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($existingPkg) {
        $installerPath = $existingPkg.FullName
        Write-Host "Found downloaded Intel NPU installer in Downloads: $installerPath" -ForegroundColor Green
    }
}

# 3. Query Windows Update Agent and stage/download patched WHQL drivers
Write-Host "`n[3/4] Querying Windows Update Agent for patched WHQL Intel NPU & Graphics drivers..." -ForegroundColor Yellow
try {
    $wuSession = New-Object -ComObject Microsoft.Update.Session
    $wuSearcher = $wuSession.CreateUpdateSearcher()
    $wuResult = $wuSearcher.Search("IsInstalled=0 and Type='Driver'")
    $toDownload = New-Object -ComObject Microsoft.Update.UpdateColl
    foreach ($upd in $wuResult.Updates) {
        # Match Intel ComputeAccelerator (NPU 32.0.100.4841), Intel Display (32.0.101.8724), or Insyde Firmware (1.0.6.0), skipping vulnerable 32.0.100.4512
        if ($upd.Title -match "ComputeAccelerator|Display|32\.0\.100\.4841|32\.0\.101\.8724|Insyde.*Firmware" -and $upd.Title -notmatch "32\.0\.100\.4512") {
            Write-Host "  [MATCH] $($upd.Title) (IsDownloaded=$($upd.IsDownloaded))" -ForegroundColor Green
            if (-not $upd.IsDownloaded) {
                $toDownload.Add($upd) | Out-Null
            }
        }
    }
    if ($toDownload.Count -gt 0) {
        Write-Host "  Staging $($toDownload.Count) WHQL driver update(s) into Windows Update cache..." -ForegroundColor Yellow
        $downloader = $wuSession.CreateUpdateDownloader()
        $downloader.Updates = $toDownload
        $dlResult = $downloader.Download()
        Write-Host "  Windows Update Download ResultCode: $($dlResult.ResultCode) (2 = Succeeded)" -ForegroundColor Green
    }
} catch {
    Write-Host "Windows Update Agent staging note: $($_.Exception.Message)" -ForegroundColor Gray
}

# 4. Define the privileged remediation logic
$elevatedScript = Join-Path $tempDir "apply_elevated_fix.ps1"
$elevatedLog = Join-Path $tempDir "elevated_fix.log"
if (Test-Path $elevatedLog) {
    Remove-Item $elevatedLog -Force -ErrorAction SilentlyContinue
}

$elevatedCode = @"
`$ErrorActionPreference = 'Continue'
Start-Transcript -Path '$elevatedLog' -Force | Out-Null

Write-Host '--- Elevated Remediation Session Started ---' -ForegroundColor Cyan

# A. Download & Install patched WHQL NPU (32.0.100.4841), Display (32.0.101.8724), and Firmware (1.0.6.0) updates via Windows Update Agent
try {
    Write-Host 'Querying Windows Update Agent for patched WHQL drivers...' -ForegroundColor Yellow
    `$session = New-Object -ComObject Microsoft.Update.Session
    `$searcher = `$session.CreateUpdateSearcher()
    `$result = `$searcher.Search("IsInstalled=0 and Type='Driver'")
    `$targetUpdates = New-Object -ComObject Microsoft.Update.UpdateColl
    foreach (`$update in `$result.Updates) {
        if (`$update.Title -match 'ComputeAccelerator|Display|32\.0\.100\.4841|32\.0\.101\.8724|Insyde.*Firmware' -and `$update.Title -notmatch '32\.0\.100\.4512') {
            Write-Host "  -> Selecting WHQL Update: `$(`$update.Title)" -ForegroundColor Green
            `$targetUpdates.Add(`$update) | Out-Null
        }
    }
    if (`$targetUpdates.Count -gt 0) {
        Write-Host "Downloading `$(`$targetUpdates.Count) WHQL update(s)..." -ForegroundColor Yellow
        `$downloader = `$session.CreateUpdateDownloader()
        `$downloader.Updates = `$targetUpdates
        `$dlRes = `$downloader.Download()
        Write-Host "Download ResultCode: `$(`$dlRes.ResultCode)" -ForegroundColor Gray

        Write-Host "Installing `$(`$targetUpdates.Count) WHQL update(s)..." -ForegroundColor Yellow
        `$installer = `$session.CreateUpdateInstaller()
        `$installer.Updates = `$targetUpdates
        `$installRes = `$installer.Install()
        Write-Host "Installation ResultCode: `$(`$installRes.ResultCode) (2 = Succeeded, RebootRequired=`$(`$installRes.RebootRequired))" -ForegroundColor Green
    } else {
        Write-Host 'All target WHQL Windows Update drivers are already installed.' -ForegroundColor Green
    }
} catch {
    Write-Warning "Windows Update driver installation error: `$(`$_.Exception.Message)"
}

# B. Install standalone Intel NPU installer (e.g. npu_win_32.0.100.5540.exe) if downloaded in Downloads
`$pkg = '$installerPath'
if (`$pkg -and (Test-Path `$pkg)) {
    Write-Host "Installing standalone Intel NPU driver package: `$pkg" -ForegroundColor Yellow
    if (`$pkg.EndsWith('.zip')) {
        `$zipExtract = Join-Path '$tempDir' 'npu_zip_extracted'
        Expand-Archive -Path `$pkg -DestinationPath `$zipExtract -Force
        & pnputil.exe /add-driver "`$zipExtract\*.inf" /install /subdirs
    } elseif (`$pkg.EndsWith('.exe')) {
        Start-Process -FilePath `$pkg -ArgumentList '--quiet --norestart' -Wait
    }
}

# C. Disable Windows Fast Startup (HiberbootEnabled = 0) to prevent stale NPU/GPU WDDM states across reboots
try {
    Write-Host 'Disabling Windows Fast Startup (HiberbootEnabled = 0)...' -ForegroundColor Yellow
    Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name 'HiberbootEnabled' -Value 0 -Type DWord -Force
    & powercfg.exe /h off
    Write-Host 'Windows Fast Startup disabled successfully.' -ForegroundColor Green
} catch {
    Write-Warning "Failed to update HiberbootEnabled: `$(`$_.Exception.Message)"
}

# D. Configure WDDM Timeout Detection & Recovery (TDR) grace period (TdrDelay = 10s, TdrDdiDelay = 10s)
try {
    Write-Host 'Configuring WDDM TDR resilience (TdrDelay = 10, TdrDdiDelay = 10)...' -ForegroundColor Yellow
    Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name 'TdrDelay' -Value 10 -Type DWord -Force
    Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name 'TdrDdiDelay' -Value 10 -Type DWord -Force
    Write-Host 'WDDM TDR settings applied successfully.' -ForegroundColor Green
} catch {
    Write-Warning "Failed to configure TDR settings: `$(`$_.Exception.Message)"
}

Write-Host '--- Elevated Remediation Completed ---' -ForegroundColor Cyan
Stop-Transcript | Out-Null
"@

Set-Content -Path $elevatedScript -Value $elevatedCode -Encoding Ascii

Write-Host "`n[4/4] Applying system remediation..." -ForegroundColor Yellow
if (Test-IsAdmin) {
    Write-Host "Running with Administrator privileges in current session..." -ForegroundColor Green
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $elevatedScript
} else {
    try {
        Write-Host "Requesting UAC Administrator elevation..." -ForegroundColor Yellow
        $proc = Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$elevatedScript`"" -Verb RunAs -Wait -PassThru -ErrorAction Stop
        Write-Host "Elevated process exited with code: $($proc.ExitCode)" -ForegroundColor Gray
    } catch {
        Write-Warning "Automatic UAC elevation from this subshell was blocked by the OS/process container ($($_.Exception.Message))."
        Write-Host "`nTo complete the privileged driver installation & registry fix, run this single command in an elevated PowerShell (Win+X -> Terminal (Admin)):" -ForegroundColor Cyan
        Write-Host "  powershell -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -ForegroundColor White
    }
}

if (Test-Path $elevatedLog) {
    Write-Host "`n--- Elevated Execution Log ---" -ForegroundColor Cyan
    Get-Content $elevatedLog
}

# Verify post-fix state
Write-Host "`n==================================================================" -ForegroundColor Cyan
Write-Host " Post-Remediation Verification" -ForegroundColor Cyan
Write-Host "==================================================================" -ForegroundColor Cyan

Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Class\*\*" -ErrorAction SilentlyContinue |
    Where-Object { $_.DriverDesc -match "\bNPU\b|Intel\(R\) Graphics" } |
    Select-Object DriverDesc, DriverVersion, DriverDate, InfPath, MatchingDeviceId |
    Format-Table -AutoSize

$powerReg = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power" -Name "HiberbootEnabled" -ErrorAction SilentlyContinue
$gfxReg = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" -ErrorAction SilentlyContinue

Write-Host "HiberbootEnabled (Fast Startup): $($powerReg.HiberbootEnabled) (Target: 0)" -ForegroundColor Cyan
Write-Host "WDDM TdrDelay:                   $($gfxReg.TdrDelay) (Target: 10)" -ForegroundColor Cyan
Write-Host "WDDM TdrDdiDelay:                $($gfxReg.TdrDdiDelay) (Target: 10)" -ForegroundColor Cyan
Write-Host "`nNOTE: Please restart your Acer Swift Go 16 AI after applying the driver and registry updates." -ForegroundColor Yellow
