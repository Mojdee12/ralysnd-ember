# Fetches the pinned third-party sidecars of the Windows build into
# tools\sidecars\, from where scripts\build-windows.ps1 copies them
# into the built app (app folder\xray\ and app folder\psiphon\):
#
#   xray.exe     The PATCHED Xray-core (patterniha fork — dialMode /
#                Finalmask / +one, the same core Android ships),
#                built here from the pinned source archive. (Through
#                2.1.0 this fetched the STOCK XTLS release; the
#                phone's anti-filter features silently no-opped
#                against it, so the 2.2.0 parity port builds the
#                fork instead.)
#   geoip.dat    from the XTLS release zip (the core finds them next
#   geosite.dat  to the config it runs, in its working folder; the
#                app also installs its own copies into the data
#                folder, these are the fallback)
#   wintun.dll   Wintun 0.14.1 (amd64), the Microsoft-signed driver
#                DLL from the official Wintun distribution — the
#                only supported way of distributing it (wintun.net);
#                xray.exe loads it from its own folder when a TUN
#                interface is created (PLAN.md §3/§6)
#   psiphon-core.exe
#                The Psiphon tunnel-core ConsoleClient (GPLv3), built
#                here from the pinned source archive — Psiphon ships
#                no prebuilt Windows ConsoleClient. v2.0.42 is the
#                exact release the Android AAR wraps (the archive's
#                ConsoleClient is byte-identical to the tree the AAR
#                was built from, checked 2026-11-01).
#
# Pinned versions (bump deliberately, with the hashes):
#   patterniha/xray-core @ 12fd84e5a9d90b6c98320dc34da6208b22e374b3
#     (= XTLS v26.11.1 + dialMode/Finalmask/+one; the exact commit
#     Android build 2032+ ships)
#     https://github.com/patterniha/xray-core/archive/12fd84e.zip
#     SHA-256 127ea187f9707ae1ff45330c8653847fd2062630c7edc115248a923b3f7e452f
#     (GitHub's archive of the commit, hashed 2026-11-12; built
#     with the ambient Go — CI pins go 1.27.2 via core/go.mod)
#   Xray-core v26.10.21 release zip — GEO DATA ONLY (geoip/geosite)
#     https://github.com/XTLS/Xray-core/releases/download/v26.10.21/Xray-windows-64.zip
#     SHA-256 fc58c39ee2f2717b4c54d28d374362389e5319b20ae44aea76ea45a5243ec827
#     (the release's own Xray-windows-64.zip.dgst, checked 2026-11-01)
#   Wintun 0.14.1
#     https://www.wintun.net/builds/wintun-0.14.1.zip
#     SHA-256 07c256185d6ee3652e09fa55c0b673e2624b565e02c4b9091c79ca7d2f24ef51
#     (wintun.net; the same hash Xray's own release pipeline pins)
#   Psiphon tunnel-core v2.0.42 (source archive)
#     https://github.com/Psiphon-Labs/psiphon-tunnel-core/archive/refs/tags/v2.0.42.zip
#     SHA-256 ca901f48e7d43f92c67cd568b6d466a4cf08c8cf431c74027e75952126d882cb
#     (GitHub's archive of the tag, hashed 2026-11-01; if GitHub ever
#     regenerates its archives this check fails loudly, on purpose)
#   warp-plus v1.2.6 (source archive; the WARP+ engine's sidecar,
#     built here like Psiphon — the same version the Android app
#     bundles)
#     https://github.com/bepass-org/warp-plus/archive/refs/tags/v1.2.6.zip
#     SHA-256 39bee06a3f943a18ccab8445b80142ea21f7f8eef9db1dd1eb2996c1649a2950
#     (GitHub's archive of the tag, hashed 2026-11-12)
#   patterniha/Aether @ d58f9d568083129ce2c767c85054021eb3ee6a38
#     (the EmberWarp/MASQUE engine core, AGPL-3.0; the exact commit
#     the Android .so is built from)
#     https://github.com/patterniha/Aether/archive/d58f9d5.zip
#     SHA-256 db8c47027a6eeb24c723301a225145d7b3f7d5b96ffcfbef388f7af803f89631
#     (GitHub's archive of the commit, hashed 2026-11-12)
#     Built with cargo for x86_64-pc-windows-gnu ONLY when a Rust
#     toolchain and the mingw-w64 linker are on the machine; the
#     section warns (and the app reports the engine unavailable)
#     otherwise. BoringSSL needs NASM on PATH.
#   OpenVPN 2.6.12-I002 amd64 MSI (the OpenVPN engine's sidecar)
#     https://swupdate.openvpn.net/community/releases/OpenVPN-2.6.12-I002-amd64.msi
#     No hash pin: the file is verified by its Authenticode
#     signature (Valid, signer OpenVPN Inc.) before extraction —
#     openvpn.exe is pulled out with an administrative install.
#   Go 1.26.8 — for the Psiphon build ONLY (see the build site):
#     https://go.dev/dl/go1.26.8.windows-amd64.zip
#     SHA-256 b92c3b2adae85a11ba71fe7216daf0d84e82af4c8ab6c5625807f28622043a59
#     (go.dev's official release index, checked 2026-11-01)
#
# Every download is hash-checked before anything is unpacked; a
# mismatch stops the build. Re-running replaces the sidecars.
#Requires -Version 7
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$dest = Join-Path $root 'tools\sidecars\xray'
$psiDest = Join-Path $root 'tools\sidecars\psiphon'
$warpDest = Join-Path $root 'tools\sidecars\warp'
$aetherDest = Join-Path $root 'tools\sidecars\aether'
$ovpnDest = Join-Path $root 'tools\sidecars\openvpn'
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
    Copy-Item (Join-Path $xrayDir 'geoip.dat') $dest -Force
    Copy-Item (Join-Path $xrayDir 'geosite.dat') $dest -Force
    Copy-Item (Join-Path $wintunDir 'wintun\bin\amd64\wintun.dll') $dest -Force

    # The patched xray.exe: verify the fork's source archive, then
    # build it with the ambient Go (the workflow pins go 1.27.2
    # via core/go.mod; the fork's go.mod asks for go 1.27).
    $forkZip = Join-Path $tmp 'xray-core-patterniha.zip'
    Get-Verified `
        'https://github.com/patterniha/xray-core/archive/12fd84e.zip' `
        '127ea187f9707ae1ff45330c8653847fd2062630c7edc115248a923b3f7e452f' `
        $forkZip
    $forkDir = Join-Path $tmp 'xray-fork'
    Expand-Archive -Path $forkZip -DestinationPath $forkDir -Force
    $forkSrc = Join-Path $forkDir 'Xray-core-12fd84e5a9d90b6c98320dc34da6208b22e374b3'
    Push-Location $forkSrc
    try {
        $env:GOOS = 'windows'
        $env:GOARCH = 'amd64'
        $env:CGO_ENABLED = '0'
        & go build -trimpath -ldflags '-s -w' -o (Join-Path $dest 'xray.exe') ./main
        if ($LASTEXITCODE -ne 0) { throw 'patched xray-core build failed' }
    } finally {
        Pop-Location
        Remove-Item Env:GOOS, Env:GOARCH, Env:CGO_ENABLED -ErrorAction SilentlyContinue
    }

    # warp-plus.exe: verify the source archive, build the sidecar
    # with the same ambient Go.
    $warpZip = Join-Path $tmp 'warp-plus-1.2.6.zip'
    Get-Verified `
        'https://github.com/bepass-org/warp-plus/archive/refs/tags/v1.2.6.zip' `
        '39bee06a3f943a18ccab8445b80142ea21f7f8eef9db1dd1eb2996c1649a2950' `
        $warpZip
    $warpDir = Join-Path $tmp 'warp-plus'
    Expand-Archive -Path $warpZip -DestinationPath $warpDir -Force
    $warpSrc = Join-Path $warpDir 'warp-plus-1.2.6'
    New-Item -ItemType Directory -Force $warpDest | Out-Null
    Push-Location $warpSrc
    try {
        $env:GOOS = 'windows'
        $env:GOARCH = 'amd64'
        $env:CGO_ENABLED = '0'
        & go build -trimpath -ldflags '-s -w' -o (Join-Path $warpDest 'warp-plus.exe') ./cmd/warp-plus
        if ($LASTEXITCODE -ne 0) { throw 'warp-plus build failed' }
    } finally {
        Pop-Location
        Remove-Item Env:GOOS, Env:GOARCH, Env:CGO_ENABLED -ErrorAction SilentlyContinue
    }

    # aether.exe: verify the source archive, then build with
    # cargo for the windows-gnu target when the Rust + mingw
    # toolchains are present. Absent toolchains are a loud
    # warning, not a failure: the app reports the EmberWarp and
    # MASQUE engines unavailable without their core.
    $aetherZip = Join-Path $tmp 'aether-d58f9d5.zip'
    Get-Verified `
        'https://github.com/patterniha/Aether/archive/d58f9d5.zip' `
        'db8c47027a6eeb24c723301a225145d7b3f7d5b96ffcfbef388f7af803f89631' `
        $aetherZip
    $cargo = Get-Command cargo -ErrorAction SilentlyContinue
    $mingw = Get-Command x86_64-w64-mingw32-gcc -ErrorAction SilentlyContinue
    if ($cargo -and $mingw) {
        $aetherDir = Join-Path $tmp 'aether'
        Expand-Archive -Path $aetherZip -DestinationPath $aetherDir -Force
        $aetherSrc = Get-ChildItem $aetherDir -Directory | Select-Object -First 1
        $crate = Join-Path $aetherSrc.FullName 'aether'
        New-Item -ItemType Directory -Force $aetherDest | Out-Null
        Push-Location $crate
        try {
            $env:CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER = 'x86_64-w64-mingw32-gcc'
            $env:CC_x86_64_pc_windows_gnu = 'x86_64-w64-mingw32-gcc'
            $env:CXX_x86_64_pc_windows_gnu = 'x86_64-w64-mingw32-g++'
            $env:AR_x86_64_pc_windows_gnu = 'x86_64-w64-mingw32-ar'
            & rustup target add x86_64-pc-windows-gnu
            & cargo build --release --locked --target x86_64-pc-windows-gnu --bin aether
            if ($LASTEXITCODE -ne 0) { throw 'aether build failed' }
            Copy-Item (Join-Path $crate 'target\x86_64-pc-windows-gnu\release\aether.exe') $aetherDest -Force
        } finally {
            Pop-Location
            Remove-Item Env:CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER, Env:CC_x86_64_pc_windows_gnu, Env:CXX_x86_64_pc_windows_gnu, Env:AR_x86_64_pc_windows_gnu -ErrorAction SilentlyContinue
        }
    } else {
        Write-Warning 'No Rust/mingw toolchain on this machine: aether.exe not built — the EmberWarp and MASQUE engines will report unavailable. (Install rustup + mingw-w64 + NASM and re-run.)'
    }

    # openvpn.exe: the official MSI, Authenticode-verified, then
    # an administrative install extracts the program files.
    $ovpnMsi = Join-Path $tmp 'OpenVPN-2.6.12-I002-amd64.msi'
    Invoke-WebRequest -Uri 'https://swupdate.openvpn.net/community/releases/OpenVPN-2.6.12-I002-amd64.msi' -OutFile $ovpnMsi
    $sig = Get-AuthenticodeSignature $ovpnMsi
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'OpenVPN') {
        throw "OpenVPN MSI signature check failed: $($sig.Status) / $($sig.SignerCertificate.Subject)"
    }
    $ovpnExtract = Join-Path $tmp 'openvpn-extract'
    $msiProc = Start-Process msiexec.exe -ArgumentList '/a', $ovpnMsi, '/qn', "TARGETDIR=$ovpnExtract" -Wait -PassThru -NoNewWindow
    if ($msiProc.ExitCode -ne 0) { throw "OpenVPN MSI extraction failed ($($msiProc.ExitCode))" }
    $ovpnExe = Get-ChildItem $ovpnExtract -Recurse -Filter 'openvpn.exe' | Select-Object -First 1
    if (-not $ovpnExe) { throw 'openvpn.exe not found in the extracted MSI' }
    New-Item -ItemType Directory -Force $ovpnDest | Out-Null
    Copy-Item $ovpnExe.FullName $ovpnDest -Force

    # Psiphon: verify the source archive, then build the
    # ConsoleClient for Windows from it (the vendored tree builds
    # offline).
    $psiZip = Join-Path $tmp 'psiphon-tunnel-core-2.0.42.zip'
    Get-Verified `
        'https://github.com/Psiphon-Labs/psiphon-tunnel-core/archive/refs/tags/v2.0.42.zip' `
        'ca901f48e7d43f92c67cd568b6d466a4cf08c8cf431c74027e75952126d882cb' `
        $psiZip
    $psiDir = Join-Path $tmp 'psiphon'
    Expand-Archive -Path $psiZip -DestinationPath $psiDir -Force
    $psiSrc = Join-Path $psiDir 'psiphon-tunnel-core-2.0.42'
    New-Item -ItemType Directory -Force $psiDest | Out-Null
    $psiExe = Join-Path $psiDest 'psiphon-core.exe'
    # The build's Go is pinned EXACTLY to go1.26.8 — never the
    # ambient toolchain. tunnel-core v2.0.42's vendored psiphon-tls
    # mirrors crypto/tls internals via unsafe and panics at init
    # ("tls: ConnectionState is not equal to tls.ConnectionState:
    # struct field count mismatch") when built with any other Go;
    # the ambient Go (the app core's 1.27.x) produced a
    # psiphon-core.exe that could never start at all, on any
    # machine. Upstream's own pin is go1.26.8 in both places that
    # state it: the go.mod toolchain line and ConsoleClient/
    # Dockerfile's GOVERSION. GOTOOLCHAIN=local keeps the build on
    # it. (Verified 2026-11-01 with Linux twins of both toolchains:
    # go1.27.2 → the panic, verbatim; go1.26.8 → init, listeners
    # and notices as normal.)
    $goZip = Join-Path $tmp 'go1.26.8.windows-amd64.zip'
    Get-Verified `
        'https://go.dev/dl/go1.26.8.windows-amd64.zip' `
        'b92c3b2adae85a11ba71fe7216daf0d84e82af4c8ab6c5625807f28622043a59' `
        $goZip
    $goDir = Join-Path $tmp 'go-psiphon'
    Expand-Archive -Path $goZip -DestinationPath $goDir -Force
    $psiGo = Join-Path $goDir 'go\bin\go.exe'
    Push-Location $psiSrc
    try {
        $env:GOOS = 'windows'
        $env:GOARCH = 'amd64'
        $env:CGO_ENABLED = '0'
        $env:GOTOOLCHAIN = 'local'
        & $psiGo build -trimpath -ldflags '-s -w' -o $psiExe ./ConsoleClient
        if ($LASTEXITCODE -ne 0) { throw 'psiphon ConsoleClient build failed' }
    } finally {
        Pop-Location
        Remove-Item Env:GOOS, Env:GOARCH, Env:CGO_ENABLED, Env:GOTOOLCHAIN -ErrorAction SilentlyContinue
    }

    # Init smoke — the permanent guard for the failure above: the
    # freshly built binary must actually start, open its listeners
    # and emit notices, or the whole build fails here instead of on
    # a user's machine. The config's identity values are read from
    # the app's own bootstrap constants, so the smoke runs the real
    # configuration shape with the shipped server list.
    $smokeDir = Join-Path $tmp 'psi-smoke'
    $smokeData = Join-Path $smokeDir 'data'
    New-Item -ItemType Directory -Force $smokeData | Out-Null
    $bootstrap = Get-Content (Join-Path $root 'app\lib\psiphon\psiphon_bootstrap.dart') -Raw
    function PsiConst([string]$Name) {
        $m = [regex]::Match($bootstrap, $Name + "\s*=\s*'([^']*)'")
        if (-not $m.Success) { throw "bootstrap constant $Name not found" }
        $m.Groups[1].Value
    }
    $smokeConfig = [ordered]@{
        ClientVersion                          = PsiConst 'clientVersion'
        PropagationChannelId                   = PsiConst 'propagationChannelId'
        SponsorId                              = PsiConst 'sponsorId'
        RemoteServerListSignaturePublicKey     = PsiConst 'remoteServerListSignaturePublicKey'
        ServerEntrySignaturePublicKey          = PsiConst 'serverEntrySignaturePublicKey'
        AdditionalParameters                   = PsiConst 'additionalParameters'
        DataRootDirectory                      = $smokeData
        LocalSocksProxyPort                    = 11808
        LocalHttpProxyPort                     = 11809
        EmitDiagnosticNotices                  = $true
        EmitBytesTransferred                   = $true
        EgressRegion                           = ''
    } | ConvertTo-Json
    $smokeCfgFile = Join-Path $smokeDir 'psiphon.config'
    Set-Content -Path $smokeCfgFile -Value $smokeConfig -Encoding utf8
    $smokeOut = Join-Path $smokeDir 'out.log'
    $smokeErr = Join-Path $smokeDir 'err.log'
    $smokeProc = Start-Process -FilePath $psiExe `
        -ArgumentList '-config', $smokeCfgFile, '-serverList', (Join-Path $root 'app\assets\psiphon\embedded_servers.txt') `
        -WorkingDirectory $smokeDir `
        -RedirectStandardOutput $smokeOut -RedirectStandardError $smokeErr `
        -PassThru -NoNewWindow
    try {
        $deadline = (Get-Date).AddSeconds(45)
        $listening = $false
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 500
            $text = '' + (Get-Content $smokeOut -Raw -ErrorAction SilentlyContinue) +
                (Get-Content $smokeErr -Raw -ErrorAction SilentlyContinue)
            if ($text -match 'panic:') {
                throw "psiphon-core.exe panicked at init (wrong Go toolchain?):`n$text"
            }
            if ($text -match 'ListeningSocksProxyPort') { $listening = $true; break }
            if ($smokeProc.HasExited) { break }
        }
        if (-not $listening) {
            throw 'psiphon-core.exe did not open its SOCKS listener within 45s in the init smoke'
        }
    } finally {
        if (-not $smokeProc.HasExited) {
            Stop-Process -Id $smokeProc.Id -Force -ErrorAction SilentlyContinue
        }
    }
    Write-Host 'Psiphon init smoke passed (listener up, no panic).'
} finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

Write-Host "Sidecars in $dest (Xray-core v26.10.21, Wintun 0.14.1):"
Get-ChildItem $dest | ForEach-Object { Write-Host ("  {0} ({1:N1} MB)" -f $_.Name, ($_.Length / 1MB)) }
Write-Host "Sidecars in $psiDest (Psiphon tunnel-core v2.0.42 ConsoleClient):"
Get-ChildItem $psiDest | ForEach-Object { Write-Host ("  {0} ({1:N1} MB)" -f $_.Name, ($_.Length / 1MB)) }
Write-Host "Sidecars in $warpDest (warp-plus v1.2.6):"
Get-ChildItem $warpDest | ForEach-Object { Write-Host ("  {0} ({1:N1} MB)" -f $_.Name, ($_.Length / 1MB)) }
Write-Host "Sidecars in $aetherDest (Aether d58f9d5, if built):"
Get-ChildItem $aetherDest -ErrorAction SilentlyContinue | ForEach-Object { Write-Host ("  {0} ({1:N1} MB)" -f $_.Name, ($_.Length / 1MB)) }
Write-Host "Sidecars in $ovpnDest (OpenVPN 2.6.12):"
Get-ChildItem $ovpnDest | ForEach-Object { Write-Host ("  {0} ({1:N1} MB)" -f $_.Name, ($_.Length / 1MB)) }
