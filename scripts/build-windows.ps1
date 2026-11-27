# Builds the Windows app (Electron shell + Go service + engine
# sidecars) into dist\:
# - Ralysnd-Ember-<version>\: "Ralysnd Ember.exe" (the Electron
#   shell, electron-builder's win-unpacked output), core\
#   (firefox-vpn-core.exe — the Mozilla engine's core;
#   firefox-vpn-tun.exe — the TUN service the bridge holds
#   sessions with; ember-tun-bridge.exe — the proxy-mode TUN
#   helper; ember-service.exe — the Ember service: supervisor
#   of the engines and owner of the TUN/OpenVPN/Lantern/WARP
#   drivers, serving the shell over its named pipe), and one
#   folder per engine sidecar beside the app;
# - Ralysnd-Ember-<version>-Windows-x64.zip: the portable app;
# - Ralysnd-Ember-<version>-Windows-Setup-x64.exe: the installer
#   (app\windows\installer\firefox-vpn.iss, Inno Setup 6), which
#   also registers the Ember service (core\ember-service.exe
#   install, self-elevating).
# The version is "major.minor.patch" from electron\package.json,
# or -AppVersion; a dist folder that already exists is refused.
# The cores get the public half of the update signing key
# (scripts\signing-key.ps1) as before.
# PowerShell 7: Windows PowerShell 5.1 writes zip paths with backslashes.
#Requires -Version 7
param([string]$AppVersion, [int]$BuildNumber = 2041)
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$pkg = Get-Content "$root\electron\package.json" -Raw | ConvertFrom-Json
$version = $pkg.version
if ($AppVersion) { $version = $AppVersion }
$out = "$root\dist\Ralysnd-Ember-$version"
if (Test-Path $out) { throw "$out already exists; bump the version in electron\package.json" }

# Inno Setup's compiler: ISCC on the PATH, else its usual places.
$iscc = (Get-Command ISCC.exe -ErrorAction SilentlyContinue).Source
if (-not $iscc) {
    $iscc = @("$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe", "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
        "$env:ProgramFiles\Inno Setup 6\ISCC.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $iscc) { throw 'Inno Setup 6 is needed for the installer (winget install JRSoftware.InnoSetup)' }

New-Item -ItemType Directory -Force "$root\dist" | Out-Null

# --- The Electron shell ---
Push-Location "$root\electron"
try {
    if (Test-Path 'package-lock.json') { npm ci } else { npm install }
    if ($LASTEXITCODE -ne 0) { throw 'npm install failed' }
    npm run build
    if ($LASTEXITCODE -ne 0) { throw 'the Electron build failed' }
} finally { Pop-Location }
$unpacked = "$root\electron\dist\win-unpacked"
if (-not (Test-Path "$unpacked\Ralysnd Ember.exe")) { throw "electron-builder output not found at $unpacked" }
Copy-Item $unpacked $out -Recurse

# The build stamp the About page shows.
$commit = ''
try { $commit = (git -C $root rev-parse --short HEAD 2>$null) } catch {}
@{ version = $version; build = $BuildNumber; commit = "$commit" } |
    ConvertTo-Json | Set-Content "$out\resources\build.json" -Encoding utf8

# The RegionHop defaults secret route — the same discipline as
# the Android CI: the repo carries only the placeholder Dart
# file; when EMBER_REGIONHOP_DEFAULTS_B64 carries the real one
# (base64), it is decoded OUTSIDE the tree, converted to the
# shell's JSON (electron\tools\extract-regionhop-defaults.mjs)
# into the staged app only, and the temp file is deleted. The
# repo never sees the real values; without the variable the
# build ships no defaults and the RegionHop page reports the
# panel as not configured.
if ($env:EMBER_REGIONHOP_DEFAULTS_B64) {
    $tmpDart = Join-Path ([System.IO.Path]::GetTempPath()) "rh-defaults-$BuildNumber.dart"
    try {
        [System.IO.File]::WriteAllBytes($tmpDart, [System.Convert]::FromBase64String($env:EMBER_REGIONHOP_DEFAULTS_B64))
        node "$root\electron\tools\extract-regionhop-defaults.mjs" $tmpDart "$out\resources\regionhop-defaults.json"
        if ($LASTEXITCODE -ne 0) { throw 'RegionHop defaults conversion failed' }
        Write-Host 'RegionHop defaults: converted from the CI secret for this build.'
    } finally {
        Remove-Item $tmpDart -Force -ErrorAction SilentlyContinue
    }
}

# --- The Go cores + the Ember service ---
$public = & "$PSScriptRoot\signing-key.ps1"
Push-Location "$root\core"
try {
    $env:APP_VERSION = $version
    go generate ./cmd/firefox-vpn-core
    if ($LASTEXITCODE -ne 0) { throw 'go generate failed' }
    $ldflags = "-s -w -X github.com/armanlife/firefox-vpn-client/core/internal/version.Current=$version"
    if ($public) { $ldflags += " -X github.com/armanlife/firefox-vpn-client/core/internal/signing.Key=$public" }
    New-Item -ItemType Directory -Force "$out\core" | Out-Null
    go build -trimpath -ldflags $ldflags -o "$out\core\firefox-vpn-core.exe" ./cmd/firefox-vpn-core
    if ($LASTEXITCODE -ne 0) { throw 'go build (core) failed' }
    go build -trimpath -ldflags $ldflags -o "$out\core\ember-tun-bridge.exe" ./cmd/ember-tun-bridge
    if ($LASTEXITCODE -ne 0) { throw 'go build (tun bridge) failed' }
    go build -trimpath -ldflags $ldflags -o "$out\core\ember-service.exe" ./cmd/ember-service
    if ($LASTEXITCODE -ne 0) { throw 'go build (ember service) failed' }
    & "$PSScriptRoot\build-windows-tun.ps1" -Version $version -Out "$out\core" -PublicKey $public
} finally { Pop-Location }

# --- Engine sidecars (scripts\fetch-windows-sidecars.ps1) ---
# Each folder beside the app, where the shell's controllers look
# for it. Absent, the build still succeeds and that engine
# reports it has no core. warp-plus is RETIRED (WARP is a
# WireGuard profile now); usque is the MASQUE core (aether stays
# as its fallback); sing-box is the second core for the
# TUIC/Hysteria2/Naive/Snell/AnyTLS/ShadowTLS bundle.
foreach ($sc in @(
    @('xray', 'xray.exe', 'the V2Ray engine will have no core'),
    @('psiphon', 'psiphon-core.exe', 'the Psiphon engine will have no core'),
    @('aether', 'aether.exe', 'the EmberWarp/MASQUE fallback will have no core'),
    @('usque', 'usque.exe', 'the MASQUE engine will have no core'),
    @('openvpn', 'openvpn.exe', 'the OpenVPN engine will have no core'),
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

# --- Service smoke (warn, never fail the build) ---
# The service in console mode + its probe/selftest verbs prove
# the IPC round-trip and a harmless process lifecycle on the
# build machine. The SCM install/start cycle is attempted only
# when this step already runs elevated.
try {
    $svc = Start-Process "$out\core\ember-service.exe" -ArgumentList 'console' -PassThru -WindowStyle Hidden
    try {
        Start-Sleep -Seconds 2
        & "$out\core\ember-service.exe" probe
        if ($LASTEXITCODE -eq 0) { Write-Host 'SMOKE: service probe OK' } else { Write-Warning 'SMOKE: service probe FAILED' }
        & "$out\core\ember-service.exe" selftest
        if ($LASTEXITCODE -eq 0) { Write-Host 'SMOKE: service selftest OK' } else { Write-Warning 'SMOKE: service selftest FAILED' }
    } finally {
        Stop-Process -Id $svc.Id -Force -ErrorAction SilentlyContinue
    }
    $elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($elevated) {
        & "$out\core\ember-service.exe" install
        if ($LASTEXITCODE -eq 0) { Write-Host 'SMOKE: service install/start cycle OK' } else { Write-Warning 'SMOKE: service install FAILED' }
        & "$out\core\ember-service.exe" uninstall | Out-Null
    } else {
        Write-Host 'SMOKE: not elevated; the SCM install/start cycle is left to the installer on the owner''s PC.'
    }
} catch {
    Write-Warning "SMOKE: service smoke could not run: $_"
}

# --- Zip + installer from a clean copy ---
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
