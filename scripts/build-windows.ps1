# Builds the Windows app with its core into dist\:
# - Ralysnd-Ember-<version>\: ralysnd-ember.exe (the Flutter app),
#   core\firefox-vpn-core.exe (the Go core, which the app starts with -app),
#   core\firefox-vpn-tun.exe (the TUN service, which the app or Setup
#   installs; scripts\build-windows-tun.ps1 says how it is signed),
#   core\ember-tun-bridge.exe (the app's helper that holds a TUN
#   session with that service for the Xray and Psiphon engines),
#   xray\ (the Xray engine's sidecars) and psiphon\psiphon-core.exe
#   (the Psiphon engine's ConsoleClient), to run here;
# - Ralysnd-Ember-<version>-Windows-x64.zip: the portable app, a
#   "Ralysnd Ember" folder to unpack anywhere (or over an older one);
# - Ralysnd-Ember-<version>-Windows-Setup-x64.exe: the installer
#   (app\windows\installer\firefox-vpn.iss, Inno Setup 6).
# The app keeps its data (accounts, settings, logs) in user-data beside it.
# The zip and the installer are made from a clean copy, never with a
# user-data folder. The version is "major.minor.patch" from app\pubspec.yaml,
# or -AppVersion (to make a test release for the app's updates); a folder that
# already exists is refused, because a running build locks its files.
# The core and the TUN service get the public half of the update signing key
# (scripts\signing-key.ps1): the app installs only releases whose
# SHA256SUMS.txt its private half signed.
# PowerShell 7: Windows PowerShell 5.1 writes zip paths with backslashes.
#Requires -Version 7
param([string]$AppVersion)
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$match = Select-String -Path "$root\app\pubspec.yaml" -Pattern '^version:\s*(\d+\.\d+\.\d+)'
if (-not $match) { throw 'No version in app\pubspec.yaml' }
$version = $match.Matches[0].Groups[1].Value
if ($AppVersion) { $version = $AppVersion }
$out = "$root\dist\Ralysnd-Ember-$version"
if (Test-Path $out) { throw "$out already exists; bump the version in app\pubspec.yaml" }

# Inno Setup's compiler: ISCC on the PATH, else its usual places.
$iscc = (Get-Command ISCC.exe -ErrorAction SilentlyContinue).Source
if (-not $iscc) {
    $iscc = @("$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe", "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
        "$env:ProgramFiles\Inno Setup 6\ISCC.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $iscc) { throw 'Inno Setup 6 is needed for the installer (winget install JRSoftware.InnoSetup)' }

# The RegionHop defaults secret route — the same discipline
# as the Android CI (.github/workflows/android.yml): the repo
# carries only the placeholder at
# app\lib\regionhop\regionhop_defaults.dart; when the
# EMBER_REGIONHOP_DEFAULTS_B64 environment variable carries
# the real file (base64), it is written into place for this
# build only and the placeholder is restored afterwards, so
# a dev machine never keeps — or accidentally commits — the
# real panel values. The windows workflow passes the secret
# through this variable; without it the build ships the
# placeholder and the RegionHop page reports the panel as
# not configured.
$rhDefaultsPath = "$root\app\lib\regionhop\regionhop_defaults.dart"
$rhDefaultsBackup = $null
if ($env:EMBER_REGIONHOP_DEFAULTS_B64) {
    $rhDefaultsBackup = [System.IO.File]::ReadAllBytes($rhDefaultsPath)
    [System.IO.File]::WriteAllBytes(
        $rhDefaultsPath,
        [System.Convert]::FromBase64String($env:EMBER_REGIONHOP_DEFAULTS_B64))
    Write-Host 'RegionHop defaults: real file restored from EMBER_REGIONHOP_DEFAULTS_B64 for this build.'
}

Push-Location "$root\app"
try {
    # Flutter copies the assets into the build folder but never removes the
    # ones taken out of the app; start from empty copies so old files (such
    # as earlier PNG flags) do not ship.
    foreach ($stale in "build\flutter_assets", "build\windows\x64\runner\Release\data\flutter_assets") {
        if (Test-Path $stale) { Remove-Item -LiteralPath $stale -Recurse -Force }
    }
    # The packages from the local cache when it has them; from pub.dev
    # otherwise (a new machine). pub.dev refuses some requests from some
    # countries (its security advisories), which an offline get avoids.
    flutter pub get --offline
    if ($LASTEXITCODE -ne 0) { flutter pub get }
    if ($LASTEXITCODE -ne 0) { throw 'flutter pub get failed' }
    flutter build windows --release --no-pub --dart-define=APP_VERSION=$version
    if ($LASTEXITCODE -ne 0) { throw 'flutter build failed' }
} finally {
    Pop-Location
    if ($null -ne $rhDefaultsBackup) {
        [System.IO.File]::WriteAllBytes($rhDefaultsPath, $rhDefaultsBackup)
        Write-Host 'RegionHop defaults: placeholder restored.'
    }
}

New-Item -ItemType Directory -Force "$root\dist" | Out-Null
Copy-Item "$root\app\build\windows\x64\runner\Release" $out -Recurse
# Without it the window stays empty on copies of Windows that lack their own
# (app\windows\CMakeLists.txt copies it from the Windows SDK).
if (-not (Test-Path "$out\d3dcompiler_47.dll")) {
    throw 'd3dcompiler_47.dll is not in the build: install the Windows SDK (Visual Studio Installer, C++ desktop development)'
}

$public = & "$PSScriptRoot\signing-key.ps1"
Push-Location "$root\core"
try {
    # The executable's icon and version information (Windows resources).
    $env:APP_VERSION = $version
    go generate ./cmd/firefox-vpn-core
    if ($LASTEXITCODE -ne 0) { throw 'go generate failed' }
    $ldflags = "-s -w -X github.com/armanlife/firefox-vpn-client/core/internal/version.Current=$version"
    if ($public) { $ldflags += " -X github.com/armanlife/firefox-vpn-client/core/internal/signing.Key=$public" }
    go build -trimpath -ldflags $ldflags -o "$out\core\firefox-vpn-core.exe" ./cmd/firefox-vpn-core
    if ($LASTEXITCODE -ne 0) { throw 'go build failed' }
    # The TUN bridge the Xray and Psiphon backends spawn for
    # system-wide capture (it speaks to the TUN service below).
    go build -trimpath -ldflags $ldflags -o "$out\core\ember-tun-bridge.exe" ./cmd/ember-tun-bridge
    if ($LASTEXITCODE -ne 0) { throw 'go build (tun bridge) failed' }
    & "$PSScriptRoot\build-windows-tun.ps1" -Version $version -Out "$out\core" -PublicKey $public
} finally { Pop-Location }

# The Xray engine's sidecars (scripts\fetch-windows-sidecars.ps1):
# xray\xray.exe with its wintun.dll and geo data, in an xray folder
# beside the app, where the Windows Xray backend looks for them.
# Absent, the build still succeeds: the V2Ray engine then has no
# core to start (it says so), everything else works.
$sidecars = "$root\tools\sidecars\xray"
if (Test-Path "$sidecars\xray.exe") {
    New-Item -ItemType Directory -Force "$out\xray" | Out-Null
    Copy-Item "$sidecars\*" "$out\xray" -Recurse -Force
    Write-Host "Xray sidecars copied from $sidecars"
} else {
    Write-Warning "No Xray sidecars in $sidecars (run scripts\fetch-windows-sidecars.ps1 first): the V2Ray engine will have no core"
}

# The Psiphon engine's sidecar (scripts\fetch-windows-sidecars.ps1
# builds it from the pinned tunnel-core source): psiphon\psiphon-core.exe
# beside the app, where the Windows Psiphon backend looks for it.
# Absent, the build still succeeds: the Psiphon engine then has no
# core to start (it says so), everything else works.
$psiSidecar = "$root\tools\sidecars\psiphon"
if (Test-Path "$psiSidecar\psiphon-core.exe") {
    New-Item -ItemType Directory -Force "$out\psiphon" | Out-Null
    Copy-Item "$psiSidecar\*" "$out\psiphon" -Recurse -Force
    Write-Host "Psiphon sidecar copied from $psiSidecar"
} else {
    Write-Warning "No Psiphon sidecar in $psiSidecar (run scripts\fetch-windows-sidecars.ps1 first): the Psiphon engine will have no core"
}

# The parity-port engines' sidecars (2.2.0), same pattern: each
# folder beside the app, where its Windows backend looks for it.
# Absent, the build still succeeds and that engine reports it has
# no core.
$warpSidecar = "$root\tools\sidecars\warp"
if (Test-Path "$warpSidecar\warp-plus.exe") {
    New-Item -ItemType Directory -Force "$out\warp" | Out-Null
    Copy-Item "$warpSidecar\*" "$out\warp" -Recurse -Force
    Write-Host "WARP+ sidecar copied from $warpSidecar"
} else {
    Write-Warning "No warp-plus sidecar in $warpSidecar (run scripts\fetch-windows-sidecars.ps1 first): the WARP+ engine will have no core"
}
$aetherSidecar = "$root\tools\sidecars\aether"
if (Test-Path "$aetherSidecar\aether.exe") {
    New-Item -ItemType Directory -Force "$out\aether" | Out-Null
    Copy-Item "$aetherSidecar\*" "$out\aether" -Recurse -Force
    Write-Host "Aether sidecar copied from $aetherSidecar"
} else {
    Write-Warning "No aether sidecar in $aetherSidecar (run scripts\fetch-windows-sidecars.ps1 first): the EmberWarp and MASQUE engines will have no core"
}
$ovpnSidecar = "$root\tools\sidecars\openvpn"
if (Test-Path "$ovpnSidecar\openvpn.exe") {
    New-Item -ItemType Directory -Force "$out\openvpn" | Out-Null
    Copy-Item "$ovpnSidecar\*" "$out\openvpn" -Recurse -Force
    Write-Host "OpenVPN sidecar copied from $ovpnSidecar"
} else {
    Write-Warning "No OpenVPN sidecar in $ovpnSidecar (run scripts\fetch-windows-sidecars.ps1 first): the OpenVPN engine will have no core"
}

# The full-parity sidecars (2.2.0+2040), same pattern: each
# helper's folder beside the app, where subprocess_windows.dart
# looks for it (sing-box / Sudoku / Zapret / Mieru / DNSCrypt /
# DNSTT / wstunnel / OLCRTC), plus the WireGuard engine's
# native backend folder (wireguard\amneziawg.exe + wintun.dll,
# driven by the Xray platform's AWG leg). Absent, the build
# still succeeds and that helper reports unavailable.
foreach ($sc in @(
    @('singbox', 'sing-box.exe', 'the TUIC/Snell/NaiveProxy/ShadowTLS profiles will have no core'),
    @('sudokubox', 'sudokubox.exe', 'Sudoku profiles will have no core'),
    @('zapret', 'ciadpi.exe', 'the DPI Lab zap candidates and the ByeDPI hop will be unavailable'),
    @('mieru', 'mieru.exe', 'Mieru profiles will have no core'),
    @('dnscrypt', 'dnscrypt-proxy.exe', 'DNSCrypt DNS will be unavailable'),
    @('dnstt', 'dnstt-client.exe', 'DNSTT legs will be unavailable'),
    @('wstunnel', 'wstunnel.exe', 'wstunnel legs will be unavailable'),
    @('olcrtc', 'olcrtc.exe', 'OLCRTC legs will be unavailable'),
    @('wireguard', 'amneziawg.exe', 'the native WireGuard engine will fall back to the Xray route'),
    @('lantern', 'lanternd.exe', 'the Lantern engine will report unavailable')
)) {
    $scDir = "$root\tools\sidecars\$($sc[0])"
    if (Test-Path "$scDir\$($sc[1])") {
        New-Item -ItemType Directory -Force "$out\$($sc[0])" | Out-Null
        Copy-Item "$scDir\*" "$out\$($sc[0])" -Recurse -Force
        Write-Host "$($sc[0]) sidecar copied from $scDir"
    } else {
        Write-Warning "No $($sc[0]) sidecar in $scDir (run scripts\fetch-windows-sidecars.ps1 first): $($sc[2])"
    }
}

# A clean copy named as the user sees it, for the zip and the installer.
$stage = "$root\dist\.stage-$version"
$app = "$stage\Ralysnd Ember"
Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $app | Out-Null
Get-ChildItem $out -Force | Where-Object { $_.Name -notin 'user-data', 'portable' } | Copy-Item -Destination $app -Recurse
try {
    $zip = "$root\dist\Ralysnd-Ember-$version-Windows-x64.zip"
    Compress-Archive -Path $app -DestinationPath $zip -CompressionLevel Optimal -Force

    $setupName = "Ralysnd-Ember-$version-Windows-Setup-x64"
    & $iscc /Q "/DAppVersion=$version" "/DSourceDir=$app" "/DOutputDir=$root\dist" "/DOutputName=$setupName" "$root\app\windows\installer\firefox-vpn.iss"
    if ($LASTEXITCODE -ne 0) { throw 'the installer did not build' }
} finally { Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue }

Write-Host "Built $out"
foreach ($f in $zip, "$root\dist\$setupName.exe") {
    Write-Host ("Built {0} ({1:N1} MB)" -f $f, ((Get-Item $f).Length / 1MB))
}
