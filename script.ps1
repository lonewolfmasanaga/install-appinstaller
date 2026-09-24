<#
    Fix-MSIX.ps1  (hardened)
    Installs Microsoft App Installer + dependencies on Windows 11 LTSC.
    Handles: VCLibs, UI.Xaml, Windows App Runtime. No hardcoded package names.
    Must be run as Administrator.
#>

[CmdletBinding()]
param([switch]$Force)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

function Write-Step { param($m) Write-Host "`n>>> $m" -ForegroundColor Cyan }
function Write-Ok   { param($m) Write-Host "  [OK]  $m" -ForegroundColor Green }
function Write-Warn { param($m) Write-Host "  [!]   $m" -ForegroundColor Yellow }
function Write-Fail { param($m) Write-Host "  [X]   $m" -ForegroundColor Red }

# ---- Admin check ------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) { Write-Fail "Run as Administrator."; Read-Host; exit 1 }

Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "   App Installer / MSIX Fix - Windows 11 LTSC"     -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan

# ---- Step 1: sideloading ---------------------------------------------------
Write-Step "Step 1/5  Enabling sideloading"
try {
    $reg = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Appx"
    if (-not (Test-Path $reg)) { New-Item -Path $reg -Force | Out-Null }
    Set-ItemProperty -Path $reg -Name "AllowAllTrustedApps" -Value 1 -Type DWord -Force
    Write-Ok "AllowAllTrustedApps = 1"
} catch { Write-Warn "Registry tweak failed: $_" }

# ---- Step 2: existing check (with -AllUsers fallback) ----------------------
Write-Step "Step 2/5  Checking for existing App Installer"
try {
    $existing = Get-AppxPackage -AllUsers -Name "Microsoft.DesktopAppInstaller" -ErrorAction SilentlyContinue
} catch {
    Write-Warn "-AllUsers not supported, checking current user only"
    $existing = Get-AppxPackage -Name "Microsoft.DesktopAppInstaller" -ErrorAction SilentlyContinue
}
if ($existing) {
    Write-Warn "Already installed (version $($existing.Version))."
    if (-not $Force) {
        if ((Read-Host "Reinstall anyway? (y/N)") -ne 'y') { Write-Ok "Exiting."; exit 0 }
    }
}

# ---- Step 3: GitHub release (with rate-limit handling) ---------------------
Write-Step "Step 3/5  Fetching latest winget-cli release"
try {
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/microsoft/winget-cli/releases/latest" `
        -Headers @{ 'User-Agent' = 'PS-Script' }
} catch {
    Write-Fail "GitHub API failed (rate limit?). Download manually:"
    Write-Host "  https://github.com/microsoft/winget-cli/releases/latest"
    Read-Host; exit 1
}

$msixBundleAsset = $release.assets | Where-Object { $_.name -like '*.msixbundle' } | Select-Object -First 1
$depsZipAsset    = $release.assets | Where-Object { $_.name -like '*Dependencies.zip' } | Select-Object -First 1

if (-not $msixBundleAsset) { Write-Fail "No .msixbundle in release."; exit 1 }
Write-Ok "Found winget-cli $($release.tag_name)"

# ---- Step 4: download ------------------------------------------------------
Write-Step "Step 4/5  Downloading packages"
$tempDir = Join-Path $env:TEMP ("MSIXFix_" + [Guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
Write-Host "  Temp: $tempDir"

$downloaded = @()
$mainBundle = $null

# Main bundle
$mainBundle = Join-Path $tempDir $msixBundleAsset.name
Write-Host "  Downloading: $($msixBundleAsset.name)"
Invoke-WebRequest -Uri $msixBundleAsset.browser_download_url -OutFile $mainBundle -UseBasicParsing

# Dependencies
if ($depsZipAsset) {
    $zipPath = Join-Path $tempDir $depsZipAsset.name
    Write-Host "  Downloading: $($depsZipAsset.name)"
    Invoke-WebRequest -Uri $depsZipAsset.browser_download_url -OutFile $zipPath -UseBasicParsing
    $extractDir = Join-Path $tempDir "deps"
    Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force
    # Include .msixbundle in filter (fix #7)
    $depFiles = Get-ChildItem -Path $extractDir -Recurse -File |
        Where-Object { $_.Extension -in '.appx','.msix','.msixbundle','.exe' }
    foreach ($f in $depFiles) {
        Write-Host "    Dependency: $($f.Name)"
        $downloaded += $f.FullName
    }
    Write-Ok "Resolved $($depFiles.Count) dependency packages from release ZIP"
}
else {
    Write-Warn "No Dependencies.zip. Trying rg-adguard fallback..."
    $storeUrl = "https://www.microsoft.com/en-us/p/app-installer/9nblggh4nns1"
    try {
        $resp = Invoke-WebRequest -Uri "https://store.rg-adguard.net/api/GetFiles" `
            -Method POST -UseBasicParsing -UserAgent 'Mozilla/5.0' `
            -Body @{ type='url'; url=$storeUrl; ring='Retail'; lang='en-US' }
    } catch { Write-Fail "rg-adguard unreachable: $_"; exit 1 }

    # Cloudflare challenge detection (fix #3)
    if ($resp.Content -notmatch '<a href=') {
        Write-Fail "rg-adguard returned an HTML challenge (Cloudflare). Fallback unavailable."
        Write-Warn "Download manually from: https://github.com/microsoft/winget-cli/releases"
        exit 1
    }

    $links = @()
    foreach ($m in [regex]::Matches($resp.Content, '<a href="([^"]+)"[^>]*>([^<]+)</a>')) {
        $links += [pscustomobject]@{
            Url  = $m.Groups[1].Value.Replace('&amp;','&')
            Name = $m.Groups[2].Value
        }
    }
    $candidates = $links | Where-Object {
        $_.Name -match '_(x64|neutral)_' -and
        $_.Name -match '\.(appx|msix|msixbundle)$' -and
        $_.Name -notmatch '^Microsoft\.DesktopAppInstaller_'
    }
    $byBase = @{}
    foreach ($c in $candidates) {
        if ($c.Name -match '^(.+?)_(\d+\.\d+\.\d+\.\d+)_(.+)$') {
            $base = "$($matches[1])_$($matches[3])"; $ver = [version]$matches[2]
        } else { $base = $c.Name; $ver = [version]'0.0.0.0' }
        if (-not $byBase.ContainsKey($base) -or $byBase[$base].Ver -lt $ver) {
            $byBase[$base] = [pscustomobject]@{ Link = $c; Ver = $ver }
        }
    }
    foreach ($entry in $byBase.Values) {
        $c = $entry.Link; $dest = Join-Path $tempDir $c.Name
        Write-Host "    Dependency: $($c.Name)"
        try { Invoke-WebRequest -Uri $c.Url -OutFile $dest -UseBasicParsing -UserAgent 'Mozilla/5.0'; $downloaded += $dest }
        catch { Write-Warn "Download failed: $($c.Name)" }
    }
    Write-Ok "Resolved $($downloaded.Count) packages from rg-adguard"
}

if ($downloaded.Count -eq 0 -and -not $mainBundle) { Write-Fail "Nothing downloaded."; exit 1 }

# ---- Step 5: install -------------------------------------------------------
Write-Step "Step 5/5  Installing packages"

$frameworkPkgs = $downloaded | Where-Object { $_ -like '*.appx' -or $_ -like '*.msix' } | Sort-Object
$exePkgs       = $downloaded | Where-Object { $_ -like '*.exe' } | Sort-Object
$bundlePkgs    = @($mainBundle)

$installOrder = @($frameworkPkgs) + @($exePkgs) + @($bundlePkgs)

foreach ($pkg in $installOrder) {
    $leaf = Split-Path $pkg -Leaf
    Write-Host "  Installing: $leaf"

    if ($leaf -like '*.exe') {
        # Try --quiet first, fall back to /quiet (fix #4)
        try {
            $p = Start-Process -FilePath $pkg -ArgumentList "--quiet" -Wait -PassThru -NoNewWindow
            if ($p.ExitCode -eq 0) { Write-Ok $leaf }
            else {
                Write-Warn "Retrying with /quiet..."
                $p = Start-Process -FilePath $pkg -ArgumentList "/quiet" -Wait -PassThru -NoNewWindow
                if ($p.ExitCode -eq 0) { Write-Ok $leaf }
                else { Write-Warn "$leaf exit code: $($p.ExitCode)" }
            }
        } catch { Write-Fail "Runtime installer failed: $_" }
    }
    else {
        try {
            # Use -DependencyPath for the main bundle (fix #2)
            if ($pkg -eq $mainBundle) {
                $depPaths = @($frameworkPkgs) + @($exePkgs)
                Add-AppxPackage -Path $pkg -DependencyPath $depPaths -ErrorAction Stop
            } else {
                Add-AppxPackage -Path $pkg -ErrorAction Stop
            }
            Write-Ok $leaf
        } catch {
            # Expanded benign-error handling (fix #5)
            $benign = @('0x80073D06','0x80073CFB','0x80073D02','already installed','higher version')
            $isBenign = $false
            foreach ($b in $benign) { if ($_.Exception.Message -match $b) { $isBenign = $true; break } }
            if ($isBenign) { Write-Warn "$leaf already present" }
            else {
                Write-Warn "Add-AppxPackage failed, trying provisioning..."
                try {
                    Add-AppxProvisionedPackage -Online -PackagePath $pkg -SkipLicense | Out-Null
                    Write-Ok "Provisioned $leaf"
                } catch { Write-Fail "Could not install $leaf : $_" }
            }
        }
    }
}

# ---- Verify ----------------------------------------------------------------
$check = Get-AppxPackage -Name "Microsoft.DesktopAppInstaller"
Write-Host ""
if ($check) {
    Write-Host "==================================================" -ForegroundColor Green
    Write-Host "  SUCCESS  -  App Installer $($check.Version)"      -ForegroundColor Green
    Write-Host "==================================================" -ForegroundColor Green
    Write-Host "Open a NEW terminal and run 'winget --version' to confirm."
} else {
    Write-Fail "App Installer not registered. Reboot and rerun."
}

Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
Read-Host "`nPress Enter to close"