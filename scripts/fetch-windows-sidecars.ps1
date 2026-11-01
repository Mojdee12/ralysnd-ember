# Fetches the pinned third-party sidecars of the Windows build into
# tools\sidecars\xray\, from where scripts\build-windows.ps1 copies
# them into the built app (app folder\xray\, beside the app):
#
#   xray.exe     XTLS Xray-core, official windows-amd64 release
#   geoip.dat    from the same release zip (the core finds them next
#   geosite.dat  to the config it runs, in its working folder; the
#                app also installs its own copies into the data
#                folder, these are the fallback)
#   wintun.dll   Wintun 0.14.1 (amd64), the Microsoft-signed driver
#                DLL from the official Wintun distribution — the
#                only supported way of distributing it (wintun.net);
#                xray.exe loads it from its own folder when a TUN
#                interface is created (PLAN.md §3/§6)
#
# Pinned versions (bump deliberately, with the hashes):
#   Xray-core v26.10.21
#     https://github.com/XTLS/Xray-core/releases/download/v26.10.21/Xray-windows-64.zip
#     SHA-256 fc58c39ee2f2717b4c54d28d374362389e5319b20ae44aea76ea45a5243ec827
#     (the release's own Xray-windows-64.zip.dgst, checked 2026-11-01)
#   Wintun 0.14.1
#     https://www.wintun.net/builds/wintun-0.14.1.zip
#     SHA-256 07c256185d6ee3652e09fa55c0b673e2624b565e02c4b9091c79ca7d2f24ef51
#     (wintun.net; the same hash Xray's own release pipeline pins)
#
# Every download is hash-checked before anything is unpacked; a
# mismatch stops the build. Re-running replaces the sidecars.
#Requires -Version 7
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$dest = Join-Path $root 'tools\sidecars\xray'
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) "ember-sidecars-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null

function Get-Verified([string]$Url, [string]$Sha256, [string]$OutFile) {
    Write-Host "Fetching $Url"
    Invoke-WebRequest -Uri $Url -OutFile $OutFile
    $actual = (Get-FileHash -Algorithm SHA256 $OutFile).Hash.ToLower()
    if ($actual -ne $Sha256) {
        throw "SHA-256 mismatch for $Url`n  expected $Sha256`n  actual   $actual"
    }
}

try {
    $xrayZip = Join-Path $tmp 'Xray-windows-64.zip'
    Get-Verified `
        'https://github.com/XTLS/Xray-core/releases/download/v26.10.21/Xray-windows-64.zip' `
        'fc58c39ee2f2717b4c54d28d374362389e5319b20ae44aea76ea45a5243ec827' `
        $xrayZip
    $xrayDir = Join-Path $tmp 'xray'
    Expand-Archive -Path $xrayZip -DestinationPath $xrayDir -Force

    $wintunZip = Join-Path $tmp 'wintun-0.14.1.zip'
    Get-Verified `
        'https://www.wintun.net/builds/wintun-0.14.1.zip' `
        '07c256185d6ee3652e09fa55c0b673e2624b565e02c4b9091c79ca7d2f24ef51' `
        $wintunZip
    $wintunDir = Join-Path $tmp 'wintun'
    Expand-Archive -Path $wintunZip -DestinationPath $wintunDir -Force

    New-Item -ItemType Directory -Force $dest | Out-Null
    Copy-Item (Join-Path $xrayDir 'xray.exe') $dest -Force
    Copy-Item (Join-Path $xrayDir 'geoip.dat') $dest -Force
    Copy-Item (Join-Path $xrayDir 'geosite.dat') $dest -Force
    Copy-Item (Join-Path $wintunDir 'wintun\bin\amd64\wintun.dll') $dest -Force
} finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

Write-Host "Sidecars in $dest (Xray-core v26.10.21, Wintun 0.14.1):"
Get-ChildItem $dest | ForEach-Object { Write-Host ("  {0} ({1:N1} MB)" -f $_.Name, ($_.Length / 1MB)) }
