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
#   Psiphon tunnel-core v2.0.43 (source archive)
#     https://github.com/Psiphon-Labs/psiphon-tunnel-core/archive/refs/tags/v2.0.43.zip
#     SHA-256 5cbcc4c080dee50009acc9a779e4923eaf5aa3926d0e4545b432155c56f2be77
#     (GitHub's archive of the tag, hashed 2026-11-28; if GitHub ever
#     regenerates its archives this check fails loudly, on purpose)
#   warp-plus: RETIRED in the service rebuild (2026-11-28) —
#     WARP is a WireGuard profile minted by the service's own
#     registration; no warp-plus sidecar is fetched or shipped.
#   usque v4.2.1 (the MASQUE core; MIT) — built from the pinned
#     vendored fork at vendor\usque (tag v4.2.1, commit
#     6aa03fc97d12848dce34eedbd187fb1077b5d1ea; see its PIN file)
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
#   OpenVPN 2.6.23-I002 amd64 MSI (the OpenVPN engine's sidecar)
#     https://build.openvpn.net/downloads/releases/OpenVPN-2.6.23-I002-amd64.msi
#     SHA-256 31809e97debe44c12be06ed892c2a43e55b67b31cb852827b7ec8f2d6c0b8dc6
#     (hashed 2026-11-12 from the project's own build host;
#     swupdate.openvpn.net serves a splash page to datacenter
#     IPs, CI runners included, so it cannot be the source. The
#     Authenticode signature is verified as well before
#     openvpn.exe is pulled out with an administrative install.)
#   Go 1.26.8 — for the Psiphon build ONLY (see the build site):
#     https://go.dev/dl/go1.26.8.windows-amd64.zip
#     SHA-256 b92c3b2adae85a11ba71fe7216daf0d84e82af4c8ab6c5625807f28622043a59
#     (go.dev's official release index, checked 2026-11-01)
#
# Full-parity sidecars (2.2.0+2040 — the SubprocessCore helper
# family Android drives through SubprocessCore.kt; on Windows
# subprocess_windows.dart drives the same binaries):
#   sing-box v1.14.4 official windows-amd64 zip (TUIC / Snell /
#     NaiveProxy / ShadowTLS / Tailscale / OpenConnect — the
#     exact release Android's libsingbox.so comes from)
#     https://github.com/SagerNet/sing-box/releases/download/v1.14.4/sing-box-1.14.4-windows-amd64.zip
#     SHA-256 99185d75d314a07dbba4a130c8ad986cbeb629a07927975636b341ca61f991df
#     (hashed 2026-11-27 from the official release)
#   hiddify-sing-box @ 1614c5edb52dd44a4cc079201ba1e790fdfad8a0
#     (the Sudoku engine: Android's libsudokubox.so source,
#     built here with the with_sudoku tag per
#     engines/sudokubox/PROVENANCE.md; CGO off, as the recipe's
#     own host build proved)
#     https://github.com/hiddify/hiddify-sing-box/archive/1614c5ed.zip
#     SHA-256 667e69f52e192e513d199822c1584b34ad77b91eccecc5e020a17e19d1ec6569
#     (GitHub's archive of the commit, hashed 2026-11-27)
#   mieru v3.39.0 official windows-amd64 zip (the exact release
#     Android's libmieru.so comes from)
#     https://github.com/enfein/mieru/releases/download/v3.39.0/mieru_3.39.0_windows_amd64.zip
#     SHA-256 e753d403d0e0b684df47441c2e3f648c4d3b2b7075d2035fc7dd1cb2a1d7c35b
#     (matches the release's own .sha256.txt, checked 2026-11-27)
#   dnscrypt-proxy 2.1.20 official win64 zip (the exact release
#     Android's libdnscrypt.so comes from)
#     https://github.com/DNSCrypt/dnscrypt-proxy/releases/download/2.1.20/dnscrypt-proxy-win64-2.1.20.zip
#     SHA-256 9e498cb9bdbae57756db19ce516362ac307e9340a6996214964cfcc7c489abc3
#     (hashed 2026-11-27 from the official release)
#   wstunnel v11.1.0 official windows-amd64 tar.gz (the exact
#     release Android's libwstunnel.so comes from)
#     https://github.com/erebe/wstunnel/releases/download/v11.1.0/wstunnel_11.1.0_windows_amd64.tar.gz
#     SHA-256 b271d076fbba92fe3d8c9b7612bf17f4ac905d68614a6c40debd73107883d75e
#     (matches the release's checksums.txt, checked 2026-11-27)
#   dnstt @ 17aa1fed864cd5493e3d09a14df1b8b5cc1df123 (Mygod
#     mirror of David Fifield's dnstt — Android's libdnstt.so
#     source per engines/dnstt/BUILD-RECIPE.md; the client is
#     pure Go, built here with the ambient Go, CGO off; the
#     Windows cross-build of this exact tree is proven)
#     https://github.com/Mygod/dnstt/archive/17aa1fe.zip
#     SHA-256 d3ef9b061438a5fcfe23e028428ffcb18f9fcf969f17299a524ea4bc7ad29053
#     (GitHub's archive of the commit, hashed 2026-11-27)
#   olcrtc @ f3ad8fb7c0d0fa981423f83269526fa94077c23d
#     (openlibrecommunity/olcrtc master snapshot — Android's
#     libolcrtc.so source per engines/olcrtc/PROVENANCE.md;
#     built here with the ambient Go and the recipe's
#     -checklinkname=0; the Windows cross-build of this exact
#     tree is proven)
#     https://github.com/openlibrecommunity/olcrtc/archive/f3ad8fb.zip
#     SHA-256 2773a64637bcb91c95cbfc1a9ead47f231edc12314ae7f747e74aeb0994f4e83
#     (GitHub's archive of the commit, hashed 2026-11-27)
#   radiance (Lantern) @ e28b97171b177fda824f06644c45a4c73df7782b
#     (the pin Lantern v10.0.5-beta.1's go.mod carries —
#     the daemon, built here FULL-VPN with radiance's own
#     tag set under its declared Go 1.26.10 toolchain; see
#     the build block for the recipe and the proof)
#     https://github.com/getlantern/radiance/archive/e28b97171b177fda824f06644c45a4c73df7782b.zip
#     SHA-256 831f4190419979a0bab356c5d7acaa907dc638ba57ef228d6b49c9667fe2a4bf
#     (GitHub's archive of the commit, hashed 2026-11-28)
#   ByeDPI (ciadpi) @ e2684772fbda45f2ff4fc220922a010370534216
#     ("Fix Windows build", post-v0.17.3 — Android's
#     libzapret.so source per engines/byedpi/PROVENANCE.md;
#     built here with the provisioned mingw-w64 below via the
#     upstream Makefile's windows target)
#     https://github.com/hufrea/ByeDPI/archive/e2684772.zip
#     SHA-256 4e0821f55cb7c8010fd7021589764c3935550e7467c80ae94243728566e7eb19
#     (GitHub's archive of the commit, hashed 2026-11-27)
#   AmneziaWG for Windows 3.1.0 amd64 MSI (the WireGuard
#     engine's native backend: the wireguard-windows fork
#     whose config parser accepts BOTH plain WireGuard and
#     AmneziaWG junk parameters — the 2104-class route;
#     extracted + Authenticode-verified like OpenVPN)
#     https://github.com/amnezia-vpn/amneziawg-windows-client/releases/download/3.1.0/amneziawg-amd64-3.1.0.msi
#     SHA-256 a1b48ea8699cd347832a3691d832004574ef8ad65bcf887611ac8acb99b7de8b
#     (hashed 2026-11-27 from the official release)
#
# Provisioned toolchains (the aether + ciadpi builds stopped
# depending on the runner's own Rust/mingw layout — the
# 2.2.0 CI runs proved that layout cannot complete them):
#   winlibs mingw-w64 (GCC 16.2.0, x86_64 posix-seh msvcrt)
#     https://github.com/brechtsanders/winlibs_mingw/releases/download/16.2.0posix-23.1.3-14.0.0-msvcrt-r3/winlibs-x86_64-posix-seh-gcc-16.2.0-mingw-w64msvcrt-14.0.0-r3.zip
#     SHA-256 62af32ea58acdea1318ea5dd8eb7017eaee694dd40b269d52a59c769dcfefb82
#     (matches the release's own .sha256, checked 2026-11-27)
#   NASM 2.16.03 win64 (BoringSSL's assembler)
#     https://www.nasm.us/pub/nasm/releasebuilds/2.16.03/win64/nasm-2.16.03-win64.zip
#     SHA-256 3ee4782247bcb874378d02f7eab4e294a84d3d15f3f6ee2de2f47a46aa7226e6
#     (complete-download verified against the server's
#     Content-Length + archive test, 2026-11-27)
#
# Every download is hash-checked before anything is unpacked; a
# mismatch stops the build. Re-running replaces the sidecars.
#Requires -Version 7
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$dest = Join-Path $root 'tools\sidecars\xray'
$psiDest = Join-Path $root 'tools\sidecars\psiphon'
$usqueDest = Join-Path $root 'tools\sidecars\usque'
$aetherDest = Join-Path $root 'tools\sidecars\aether'
$ovpnDest = Join-Path $root 'tools\sidecars\openvpn'
$singboxDest = Join-Path $root 'tools\sidecars\singbox'
$sudokuDest = Join-Path $root 'tools\sidecars\sudokubox'
$zapretDest = Join-Path $root 'tools\sidecars\zapret'
$mieruDest = Join-Path $root 'tools\sidecars\mieru'
$dnscryptDest = Join-Path $root 'tools\sidecars\dnscrypt'
$dnsttDest = Join-Path $root 'tools\sidecars\dnstt'
$wstunnelDest = Join-Path $root 'tools\sidecars\wstunnel'
$olcrtcDest = Join-Path $root 'tools\sidecars\olcrtc'
$wireguardDest = Join-Path $root 'tools\sidecars\wireguard'
$lanternDest = Join-Path $root 'tools\sidecars\lantern'
$radianceSrcDir = Join-Path $root 'tools\radiance-src' # legacy (2040 lantern-bridge); unused by the service build
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

    # (warp-plus was built here until the service rebuild
    # retired it — WARP is a service-minted WireGuard profile
    # now; see the header note.)

    # Provisioned toolchains for the two native builds below
    # (aether's Rust/cc-rs and ciadpi's C): the runner's own
    # mingw layout could not complete either in the 2.2.0 CI
    # runs (cc-rs never found a prefixed archiver), so the
    # script now downloads its own pinned winlibs mingw-w64
    # + NASM and puts them on PATH. A provisioning failure is
    # a loud warning, not a pipeline kill — both builds keep
    # their warn-and-continue contract.
    $provisionedMingwBin = $null
    try {
        $winlibsZip = Join-Path $tmp 'winlibs.zip'
        Get-Verified `
            'https://github.com/brechtsanders/winlibs_mingw/releases/download/16.2.0posix-23.1.3-14.0.0-msvcrt-r3/winlibs-x86_64-posix-seh-gcc-16.2.0-mingw-w64msvcrt-14.0.0-r3.zip' `
            '62af32ea58acdea1318ea5dd8eb7017eaee694dd40b269d52a59c769dcfefb82' `
            $winlibsZip
        $winlibsDir = Join-Path $tmp 'winlibs'
        Expand-Archive -Path $winlibsZip -DestinationPath $winlibsDir -Force
        $candidateBin = Join-Path $winlibsDir 'mingw64\bin'
        if ((Test-Path (Join-Path $candidateBin 'x86_64-w64-mingw32-gcc.exe')) -and
            (Test-Path (Join-Path $candidateBin 'x86_64-w64-mingw32-g++.exe'))) {
            $provisionedMingwBin = $candidateBin
        }
        $nasmZip = Join-Path $tmp 'nasm.zip'
        Get-Verified `
            'https://www.nasm.us/pub/nasm/releasebuilds/2.16.03/win64/nasm-2.16.03-win64.zip' `
            '3ee4782247bcb874378d02f7eab4e294a84d3d15f3f6ee2de2f47a46aa7226e6' `
            $nasmZip
        $nasmDir = Join-Path $tmp 'nasm'
        Expand-Archive -Path $nasmZip -DestinationPath $nasmDir -Force
        $nasmBin = Get-ChildItem $nasmDir -Recurse -Filter 'nasm.exe' |
            Select-Object -First 1 -ExpandProperty DirectoryName
        $env:PATH = "$provisionedMingwBin;$nasmBin;$env:PATH"
        Write-Host "Provisioned toolchain: mingw at $provisionedMingwBin, NASM at $nasmBin"
    } catch {
        Write-Warning "Toolchain provisioning failed ($($_.Exception.Message)) — the aether and ciadpi builds will warn and skip."
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
    # The full prefixed mingw-w64 tool set (gcc/g++/ar) must be on
    # PATH for cc-rs. The provisioned toolchain above is the
    # primary source (its layout is pinned and known); the
    # ambient hunt below stays as a fallback for dev machines.
    $mingwBin = $provisionedMingwBin
    $gccCmd = Get-Command x86_64-w64-mingw32-gcc -ErrorAction SilentlyContinue
    if ($gccCmd -and (Get-Command x86_64-w64-mingw32-ar -ErrorAction SilentlyContinue)) {
        $mingwBin = Split-Path -Parent $gccCmd.Source
    } else {
        # A candidate counts only with the FULL prefixed set
        # (gcc + g++ + ar) — Git's own mingw64 folder has the
        # unprefixed names only, which is what starved cc-rs of
        # its archiver on the CI runner.
        foreach ($candidate in @(
            'C:\msys64\mingw64\bin',
            'C:\mingw64\bin',
            'C:\ProgramData\chocolatey\lib\mingw\tools\install\mingw64\bin',
            'C:\tools\mingw64\bin',
            'C:\Program Files\mingw-w64\mingw64\bin'
        )) {
            if ((Test-Path (Join-Path $candidate 'x86_64-w64-mingw32-gcc.exe')) -and
                (Test-Path (Join-Path $candidate 'x86_64-w64-mingw32-ar.exe'))) {
                $mingwBin = $candidate
                break
            }
        }
    }
    if ($cargo -and $mingwBin) {
        $env:PATH = "$mingwBin;$env:PATH"

        $aetherDir = Join-Path $tmp 'aether'
        Expand-Archive -Path $aetherZip -DestinationPath $aetherDir -Force
        $aetherSrc = Get-ChildItem $aetherDir -Directory | Select-Object -First 1
        $crate = Join-Path $aetherSrc.FullName 'aether'
        New-Item -ItemType Directory -Force $aetherDest | Out-Null
        Push-Location $crate
        try {
            # The archiver's name differs by distribution:
            # classic mingw-w64 ships x86_64-w64-mingw32-ar.exe,
            # winlibs ships ar.exe (plus the gcc-ar wrapper).
            # cc-rs takes the full path either way.
            $arExe = Join-Path $mingwBin 'x86_64-w64-mingw32-ar.exe'
            if (-not (Test-Path $arExe)) { $arExe = Join-Path $mingwBin 'ar.exe' }
            $env:CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER = (Join-Path $mingwBin 'x86_64-w64-mingw32-gcc.exe')
            $env:CC_x86_64_pc_windows_gnu = (Join-Path $mingwBin 'x86_64-w64-mingw32-gcc.exe')
            $env:CXX_x86_64_pc_windows_gnu = (Join-Path $mingwBin 'x86_64-w64-mingw32-g++.exe')
            $env:AR_x86_64_pc_windows_gnu = $arExe
            # boring-sys drives CMake: left to itself it picks
            # the "MSYS Makefiles" generator on the CI runner
            # and a stale C:\mingw64 make that cannot read the
            # generated build files (CI run 46054304209). The
            # MinGW Makefiles generator + the winlibs
            # mingw32-make first on PATH is the working pair.
            $env:CMAKE_GENERATOR = 'MinGW Makefiles'
            & rustup target add x86_64-pc-windows-gnu
            & cargo build --release --locked --target x86_64-pc-windows-gnu --bin aether
            if ($LASTEXITCODE -ne 0) {
                # NOT a throw: a failed optional engine build must
                # not kill the whole sidecar fetch. The app
                # reports EmberWarp/MASQUE unavailable without
                # their core — loudly, here and in the app.
                Write-Warning 'aether build failed on this machine — the EmberWarp and MASQUE engines will report unavailable in this package.'
            } else {
                Copy-Item (Join-Path $crate 'target\x86_64-pc-windows-gnu\release\aether.exe') $aetherDest -Force
            }
        } finally {
            Pop-Location
            Remove-Item Env:CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER, Env:CC_x86_64_pc_windows_gnu, Env:CXX_x86_64_pc_windows_gnu, Env:AR_x86_64_pc_windows_gnu, Env:CMAKE_GENERATOR -ErrorAction SilentlyContinue
        }
    } else {
        Write-Warning 'No Rust/mingw toolchain on this machine: aether.exe not built — the EmberWarp and MASQUE engines will report unavailable. (Install rustup + mingw-w64 + NASM and re-run.)'
    }

    # openvpn.exe: the official MSI, Authenticode-verified, then
    # an administrative install extracts the program files.
    $ovpnMsi = Join-Path $tmp 'OpenVPN-2.6.23-I002-amd64.msi'
    Get-Verified `
        'https://build.openvpn.net/downloads/releases/OpenVPN-2.6.23-I002-amd64.msi' `
        '31809e97debe44c12be06ed892c2a43e55b67b31cb852827b7ec8f2d6c0b8dc6' `
        $ovpnMsi
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
    $psiZip = Join-Path $tmp 'psiphon-tunnel-core-2.0.43.zip'
    Get-Verified `
        'https://github.com/Psiphon-Labs/psiphon-tunnel-core/archive/refs/tags/v2.0.43.zip' `
        '5cbcc4c080dee50009acc9a779e4923eaf5aa3926d0e4545b432155c56f2be77' `
        $psiZip
    $psiDir = Join-Path $tmp 'psiphon'
    Expand-Archive -Path $psiZip -DestinationPath $psiDir -Force
    $psiSrc = Join-Path $psiDir 'psiphon-tunnel-core-2.0.43'
    New-Item -ItemType Directory -Force $psiDest | Out-Null
    $psiExe = Join-Path $psiDest 'psiphon-core.exe'
    # The build's Go is pinned EXACTLY to go1.26.10 — never the
    # ambient toolchain. tunnel-core's vendored psiphon-tls
    # mirrors crypto/tls internals via unsafe and panics at init
    # ("tls: ConnectionState is not equal to tls.ConnectionState:
    # struct field count mismatch") when built with any other Go;
    # the ambient Go (the app core's 1.27.x) produced a
    # psiphon-core.exe that could never start at all, on any
    # machine. Upstream's own pin for v2.0.43 is go1.26.10 in both
    # places that state it: the go.mod toolchain line and
    # ConsoleClient/Dockerfile's GOVERSION. GOTOOLCHAIN=local
    # keeps the build on it. (The pin discipline was verified
    # 2026-11-01 on v2.0.42 with Linux twins of both toolchains:
    # go1.27.2 → the panic, verbatim; the pinned Go → init,
    # listeners and notices as normal.)
    $goZip = Join-Path $tmp 'go1.26.10.windows-amd64.zip'
    Get-Verified `
        'https://go.dev/dl/go1.26.10.windows-amd64.zip' `
        '7ecd2d7260e82c59bcbd7f1077a07cee2dea607295b858df67195a1e4e09629b' `
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
        # No AdditionalParameters: the MLM identity set the
        # app ships since the W2 Psiphon port carries none
        # (the constant no longer exists in the bootstrap).
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

    # ---- Full-parity sidecars (2.2.0+2040) -------------------
    # The SubprocessCore helper family. Release binaries are
    # extracted; source pins are built with the ambient Go
    # (the workflow pins it via core/go.mod) or the
    # provisioned mingw above. A failed OPTIONAL build warns
    # and continues (the app reports that helper unavailable);
    # a hash mismatch still stops everything, as everywhere
    # in this script.

    # sing-box.exe (+ libcronet.dll, which its naive/ccm
    # outbounds load from the same folder): the official
    # v1.14.4 windows-amd64 release.
    $singboxZip = Join-Path $tmp 'sing-box-windows.zip'
    Get-Verified `
        'https://github.com/SagerNet/sing-box/releases/download/v1.14.4/sing-box-1.14.4-windows-amd64.zip' `
        '99185d75d314a07dbba4a130c8ad986cbeb629a07927975636b341ca61f991df' `
        $singboxZip
    $singboxDir = Join-Path $tmp 'sing-box'
    Expand-Archive -Path $singboxZip -DestinationPath $singboxDir -Force
    New-Item -ItemType Directory -Force $singboxDest | Out-Null
    Copy-Item (Join-Path $singboxDir 'sing-box-1.14.4-windows-amd64\sing-box.exe') $singboxDest -Force
    Copy-Item (Join-Path $singboxDir 'sing-box-1.14.4-windows-amd64\libcronet.dll') $singboxDest -Force

    # sudokubox.exe: the hiddify-sing-box fork built with the
    # sudoku tag (engines/sudokubox/PROVENANCE.md recipe,
    # CGO off as its host proof ran). A build failure warns:
    # Sudoku profiles then report their engine unavailable.
    # The source comes from a GIT CLONE, not the archive zip:
    # the fork's go.mod replaces psiphon-tls with
    # ./replace/psiphon-tls, a directory GitHub's archive of
    # this commit does not carry (proven 2026-11-27 — the
    # archive build dies on the missing replace path). The
    # clone is pinned to the same commit; -mod=mod lets the
    # build complete the fork's go.sum for Windows-only deps
    # (winipcfg) inside the scratch tree.
    $sudokuSrc = Join-Path $tmp 'sudoku\hiddify-sing-box'
    New-Item -ItemType Directory -Force (Join-Path $tmp 'sudoku') | Out-Null
    & git clone --quiet https://github.com/hiddify/hiddify-sing-box.git $sudokuSrc
    if ($LASTEXITCODE -ne 0) {
        Write-Warning 'sudokubox source clone failed — Sudoku profiles will report their engine unavailable in this package.'
    } else {
        & git -C $sudokuSrc checkout --quiet '1614c5edb52dd44a4cc079201ba1e790fdfad8a0'
        # The fork's replace/ tree is git SUBMODULES
        # (hiddify/psiphon-tls and friends) — a plain clone
        # leaves them empty and the build dies reading
        # replace/psiphon-tls/go.mod (CI run 46055590275).
        & git -C $sudokuSrc submodule update --init --recursive --quiet
    }
    New-Item -ItemType Directory -Force $sudokuDest | Out-Null
    Push-Location $sudokuSrc
    try {
        $env:GOOS = 'windows'
        $env:GOARCH = 'amd64'
        $env:CGO_ENABLED = '0'
        $env:GOFLAGS = '-mod=mod'
        & go build -trimpath -tags 'with_utls badlinkname tfogo_checklinkname0 with_sudoku' `
            -ldflags '-s -w -checklinkname=0 -X github.com/sagernet/sing-box/constant.Version=1614c5e' `
            -o (Join-Path $sudokuDest 'sudokubox.exe') ./cmd/sing-box
        if ($LASTEXITCODE -ne 0) {
            Write-Warning 'sudokubox build failed on this machine — Sudoku profiles will report their engine unavailable in this package.'
        }
    } finally {
        Pop-Location
        Remove-Item Env:GOOS, Env:GOARCH, Env:CGO_ENABLED, Env:GOFLAGS -ErrorAction SilentlyContinue
    }

    # mieru.exe: the official v3.39.0 windows-amd64 release.
    $mieruZip = Join-Path $tmp 'mieru-windows.zip'
    Get-Verified `
        'https://github.com/enfein/mieru/releases/download/v3.39.0/mieru_3.39.0_windows_amd64.zip' `
        'e753d403d0e0b684df47441c2e3f648c4d3b2b7075d2035fc7dd1cb2a1d7c35b' `
        $mieruZip
    $mieruDir = Join-Path $tmp 'mieru'
    Expand-Archive -Path $mieruZip -DestinationPath $mieruDir -Force
    New-Item -ItemType Directory -Force $mieruDest | Out-Null
    Copy-Item (Join-Path $mieruDir 'mieru.exe') $mieruDest -Force

    # dnscrypt-proxy.exe: the official 2.1.20 win64 release.
    $dnscryptZip = Join-Path $tmp 'dnscrypt-win64.zip'
    Get-Verified `
        'https://github.com/DNSCrypt/dnscrypt-proxy/releases/download/2.1.20/dnscrypt-proxy-win64-2.1.20.zip' `
        '9e498cb9bdbae57756db19ce516362ac307e9340a6996214964cfcc7c489abc3' `
        $dnscryptZip
    $dnscryptDir = Join-Path $tmp 'dnscrypt'
    Expand-Archive -Path $dnscryptZip -DestinationPath $dnscryptDir -Force
    New-Item -ItemType Directory -Force $dnscryptDest | Out-Null
    Copy-Item (Join-Path $dnscryptDir 'win64\dnscrypt-proxy.exe') $dnscryptDest -Force

    # wstunnel.exe: the official v11.1.0 windows-amd64
    # release (a tar.gz — bsdtar, in-box on Windows 10+).
    $wstunnelTar = Join-Path $tmp 'wstunnel-windows.tar.gz'
    Get-Verified `
        'https://github.com/erebe/wstunnel/releases/download/v11.1.0/wstunnel_11.1.0_windows_amd64.tar.gz' `
        'b271d076fbba92fe3d8c9b7612bf17f4ac905d68614a6c40debd73107883d75e' `
        $wstunnelTar
    $wstunnelDir = Join-Path $tmp 'wstunnel'
    New-Item -ItemType Directory -Force $wstunnelDir | Out-Null
    & tar -xzf $wstunnelTar -C $wstunnelDir
    if ($LASTEXITCODE -ne 0) { throw 'wstunnel archive extraction failed' }
    New-Item -ItemType Directory -Force $wstunnelDest | Out-Null
    Copy-Item (Join-Path $wstunnelDir 'wstunnel.exe') $wstunnelDest -Force

    # dnstt-client.exe: built from the pinned source with
    # the ambient Go (pure Go client, CGO off).
    $dnsttZip = Join-Path $tmp 'dnstt-src.zip'
    Get-Verified `
        'https://github.com/Mygod/dnstt/archive/17aa1fe.zip' `
        'd3ef9b061438a5fcfe23e028428ffcb18f9fcf969f17299a524ea4bc7ad29053' `
        $dnsttZip
    $dnsttDir = Join-Path $tmp 'dnstt'
    Expand-Archive -Path $dnsttZip -DestinationPath $dnsttDir -Force
    $dnsttSrc = Join-Path $dnsttDir 'dnstt-17aa1fed864cd5493e3d09a14df1b8b5cc1df123\dnstt-client'
    New-Item -ItemType Directory -Force $dnsttDest | Out-Null
    Push-Location $dnsttSrc
    try {
        $env:GOOS = 'windows'
        $env:GOARCH = 'amd64'
        $env:CGO_ENABLED = '0'
        & go build -trimpath -ldflags '-s -w' -o (Join-Path $dnsttDest 'dnstt-client.exe') .
        if ($LASTEXITCODE -ne 0) { throw 'dnstt-client build failed' }
    } finally {
        Pop-Location
        Remove-Item Env:GOOS, Env:GOARCH, Env:CGO_ENABLED -ErrorAction SilentlyContinue
    }

    # olcrtc.exe: built from the pinned snapshot with the
    # ambient Go and the recipe's -checklinkname=0
    # (engines/olcrtc/PROVENANCE.md).
    $olcrtcZip = Join-Path $tmp 'olcrtc-src.zip'
    Get-Verified `
        'https://github.com/openlibrecommunity/olcrtc/archive/f3ad8fb.zip' `
        '2773a64637bcb91c95cbfc1a9ead47f231edc12314ae7f747e74aeb0994f4e83' `
        $olcrtcZip
    $olcrtcDir = Join-Path $tmp 'olcrtc'
    Expand-Archive -Path $olcrtcZip -DestinationPath $olcrtcDir -Force
    $olcrtcSrc = Join-Path $olcrtcDir 'olcrtc-f3ad8fb7c0d0fa981423f83269526fa94077c23d'
    New-Item -ItemType Directory -Force $olcrtcDest | Out-Null
    Push-Location $olcrtcSrc
    try {
        $env:GOOS = 'windows'
        $env:GOARCH = 'amd64'
        $env:CGO_ENABLED = '0'
        & go build -p 2 -trimpath -ldflags '-s -w -checklinkname=0' -o (Join-Path $olcrtcDest 'olcrtc.exe') ./cmd/olcrtc
        if ($LASTEXITCODE -ne 0) { throw 'olcrtc build failed' }
    } finally {
        Pop-Location
        Remove-Item Env:GOOS, Env:GOARCH, Env:CGO_ENABLED -ErrorAction SilentlyContinue
    }

    # lanternd.exe (the Lantern engine, service rebuild):
    # the radiance daemon at the pin Lantern v10.0.5-beta.1
    # itself carries (its go.mod: radiance
    # e28b97171b177fda824f06644c45a4c73df7782b), built
    # FULL-VPN — radiance's own daemon tag set, NO `novpn`:
    # radiance owns its TUN (sing-tun + Wintun) and serves
    # its control API on its named pipe; the Ember service
    # supervises it (with _LANTERND_CHILD=1) and is the
    # pipe's only caller. The 2040 novpn build +
    # lantern-bridge stdio shim are gone.
    # TOOLCHAIN: this pin's sing-box-minimal predates
    # Go 1.27 (its v2rayhttp linkname breaks at link time
    # from a clean cache), so the build runs under
    # radiance's own declared toolchain, Go 1.26.10, via
    # GOTOOLCHAIN — proven host-side 2026-11-28 (binary
    # 68,995,584 B, sha256 69efa166…). Warns instead of
    # failing: without it the Lantern engine reports
    # unavailable in-app.
    $radianceZip = Join-Path $tmp 'radiance-src.zip'
    Get-Verified `
        'https://github.com/getlantern/radiance/archive/e28b97171b177fda824f06644c45a4c73df7782b.zip' `
        '831f4190419979a0bab356c5d7acaa907dc638ba57ef228d6b49c9667fe2a4bf' `
        $radianceZip
    $radianceDir = Join-Path $tmp 'radiance'
    Expand-Archive -Path $radianceZip -DestinationPath $radianceDir -Force
    $radianceSrc = Join-Path $radianceDir 'radiance-e28b97171b177fda824f06644c45a4c73df7782b'
    New-Item -ItemType Directory -Force $lanternDest | Out-Null
    Push-Location $radianceSrc
    try {
        $env:GOOS = 'windows'
        $env:GOARCH = 'amd64'
        $env:CGO_ENABLED = '0'
        $env:GOTOOLCHAIN = 'go1.26.10'
        $buildTime = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        & go build -p 2 -trimpath -tags 'with_gvisor,with_quic,with_dhcp,with_wireguard,with_utls,with_acme,with_clash_api' -ldflags "-s -w -X github.com/getlantern/radiance/common.Commit=e28b971 -X github.com/getlantern/radiance/common.BuildTime=$buildTime" -o (Join-Path $lanternDest 'lanternd.exe') ./cmd/lanternd
        if ($LASTEXITCODE -ne 0) {
            Write-Warning 'lanternd build failed on this machine — the Lantern engine will report unavailable in this package.'
        }
    } finally {
        Pop-Location
        Remove-Item Env:GOOS, Env:GOARCH, Env:CGO_ENABLED, Env:GOTOOLCHAIN -ErrorAction SilentlyContinue
    }
    # wintun.dll beside lanternd.exe (audit C2): radiance's
    # sing-tun loads wintun.dll BY NAME from the daemon's own
    # folder — the same Wintun 0.14.1 distribution copy the
    # xray and wireguard sections stage. Without it Lantern
    # authenticates and answers status but can never raise
    # its TUN on a clean install.
    Copy-Item (Join-Path $wintunDir 'wintun\bin\amd64\wintun.dll') $lanternDest -Force
    # usque.exe (the MASQUE core, MIT): built from the
    # pinned vendored fork at vendor\usque (v4.2.1). Its
    # go.mod asks for Go 1.26.3; the ambient toolchain
    # (1.27.x) builds it — proven host-side 2026-11-28
    # (13,139,456 B, sha256 6b5db810…). Warns instead of
    # failing: EmberWarp/MASQUE then fall back to aether.
    $usqueSrc = Join-Path $root 'vendor\usque'
    if (Test-Path (Join-Path $usqueSrc 'go.mod')) {
        New-Item -ItemType Directory -Force $usqueDest | Out-Null
        Push-Location $usqueSrc
        try {
            $env:GOOS = 'windows'
            $env:GOARCH = 'amd64'
            $env:CGO_ENABLED = '0'
            & go build -p 2 -trimpath -ldflags '-s -w' -o (Join-Path $usqueDest 'usque.exe') .
            if ($LASTEXITCODE -ne 0) {
                Write-Warning 'usque build failed on this machine — MASQUE will fall back to aether in this package.'
            }
        } finally {
            Pop-Location
            Remove-Item Env:GOOS, Env:GOARCH, Env:CGO_ENABLED -ErrorAction SilentlyContinue
        }
    } else {
        Write-Warning 'vendor\usque is missing — MASQUE will fall back to aether in this package.'
    }

    # ciadpi.exe (the Zapret desync proxy): built from the
    # pinned ByeDPI source with the provisioned mingw via
    # the upstream Makefile's windows target. Warns instead
    # of failing when no mingw is available (the DPI Lab's
    # zap candidates then report unavailable).
    $byedpiZip = Join-Path $tmp 'byedpi-src.zip'
    Get-Verified `
        'https://github.com/hufrea/ByeDPI/archive/e2684772.zip' `
        '4e0821f55cb7c8010fd7021589764c3935550e7467c80ae94243728566e7eb19' `
        $byedpiZip
    if ($provisionedMingwBin) {
        $byedpiDir = Join-Path $tmp 'byedpi'
        Expand-Archive -Path $byedpiZip -DestinationPath $byedpiDir -Force
        $byedpiSrc = Join-Path $byedpiDir 'ByeDPI-e2684772fbda45f2ff4fc220922a010370534216'
        New-Item -ItemType Directory -Force $zapretDest | Out-Null
        Push-Location $byedpiSrc
        try {
            $mingwMake = Join-Path $provisionedMingwBin 'mingw32-make.exe'
            $mingwGcc = Join-Path $provisionedMingwBin 'x86_64-w64-mingw32-gcc.exe'
            & $mingwMake windows "CC=$mingwGcc"
            if ($LASTEXITCODE -ne 0 -or -not (Test-Path (Join-Path $byedpiSrc 'ciadpi.exe'))) {
                Write-Warning 'ciadpi build failed on this machine — the DPI Lab zap candidates will report unavailable in this package.'
            } else {
                Copy-Item (Join-Path $byedpiSrc 'ciadpi.exe') $zapretDest -Force
            }
        } finally {
            Pop-Location
        }
    } else {
        Write-Warning 'No provisioned mingw: ciadpi.exe not built — the DPI Lab zap candidates will report unavailable.'
    }

    # amneziawg.exe (+ its wintun.dll): the official AmneziaWG
    # 3.1.0 MSI, Authenticode-verified, then an administrative
    # install extracts the program files (the OpenVPN route).
    $awgMsi = Join-Path $tmp 'amneziawg-amd64-3.1.0.msi'
    Get-Verified `
        'https://github.com/amnezia-vpn/amneziawg-windows-client/releases/download/3.1.0/amneziawg-amd64-3.1.0.msi' `
        'a1b48ea8699cd347832a3691d832004574ef8ad65bcf887611ac8acb99b7de8b' `
        $awgMsi
    $awgSig = Get-AuthenticodeSignature $awgMsi
    # The 3.1.0 MSI's signer is the Amnezia project's legal
    # entity "Privacy Technologies OU" (verified from the CI
    # log of run 46055590275: Status Valid, subject
    # "CN=Privacy Technologies OU, O=Privacy Technologies OU,
    # S=Harjumaa, C=EE") — the sha256 pin above is the primary
    # check; this is the second factor.
    if ($awgSig.Status -ne 'Valid' -or $awgSig.SignerCertificate.Subject -notmatch 'Privacy Technologies') {
        throw "AmneziaWG MSI signature check failed: $($awgSig.Status) / $($awgSig.SignerCertificate.Subject)"
    }
    $awgExtract = Join-Path $tmp 'amneziawg-extract'
    $awgProc = Start-Process msiexec.exe -ArgumentList '/a', $awgMsi, '/qn', "TARGETDIR=$awgExtract" -Wait -PassThru -NoNewWindow
    if ($awgProc.ExitCode -ne 0) { throw "AmneziaWG MSI extraction failed ($($awgProc.ExitCode))" }
    $awgExe = Get-ChildItem $awgExtract -Recurse -Filter 'amneziawg.exe' | Select-Object -First 1
    if (-not $awgExe) { throw 'amneziawg.exe not found in the extracted MSI' }
    New-Item -ItemType Directory -Force $wireguardDest | Out-Null
    Copy-Item $awgExe.FullName $wireguardDest -Force
    $awgWintun = Get-ChildItem $awgExtract -Recurse -Filter 'wintun.dll' | Select-Object -First 1
    if ($awgWintun) {
        Copy-Item $awgWintun.FullName $wireguardDest -Force
    } else {
        # The fork loads wintun.dll from its own folder; fall
        # back to the Wintun distribution fetched above.
        Copy-Item (Join-Path $wintunDir 'wintun\bin\amd64\wintun.dll') $wireguardDest -Force
    }
} finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

Write-Host "Sidecars in $dest (Xray-core v26.10.21, Wintun 0.14.1):"
Get-ChildItem $dest | ForEach-Object { Write-Host ("  {0} ({1:N1} MB)" -f $_.Name, ($_.Length / 1MB)) }
Write-Host "Sidecars in $psiDest (Psiphon tunnel-core v2.0.43 ConsoleClient):"
Get-ChildItem $psiDest | ForEach-Object { Write-Host ("  {0} ({1:N1} MB)" -f $_.Name, ($_.Length / 1MB)) }
Write-Host "Sidecars in $usqueDest (usque v4.2.1, if built):"
Get-ChildItem $usqueDest -ErrorAction SilentlyContinue | ForEach-Object { Write-Host ("  {0} ({1:N1} MB)" -f $_.Name, ($_.Length / 1MB)) }
Write-Host "Sidecars in $aetherDest (Aether d58f9d5, if built):"
Get-ChildItem $aetherDest -ErrorAction SilentlyContinue | ForEach-Object { Write-Host ("  {0} ({1:N1} MB)" -f $_.Name, ($_.Length / 1MB)) }
Write-Host "Sidecars in $ovpnDest (OpenVPN 2.6.23):"
Get-ChildItem $ovpnDest | ForEach-Object { Write-Host ("  {0} ({1:N1} MB)" -f $_.Name, ($_.Length / 1MB)) }
foreach ($pair in @(
    @($singboxDest, 'sing-box v1.14.4'),
    @($sudokuDest, 'sudokubox (hiddify-sing-box 1614c5e, with_sudoku)'),
    @($zapretDest, 'ciadpi (ByeDPI e2684772)'),
    @($mieruDest, 'mieru v3.39.0'),
    @($dnscryptDest, 'dnscrypt-proxy 2.1.20'),
    @($dnsttDest, 'dnstt-client 17aa1fe'),
    @($wstunnelDest, 'wstunnel v11.1.0'),
    @($olcrtcDest, 'olcrtc f3ad8fb'),
    @($wireguardDest, 'AmneziaWG 3.1.0'),
    @($lanternDest, 'radiance lanternd e28b971 (full-VPN)')
)) {
    Write-Host "Sidecars in $($pair[0]) ($($pair[1])):"
    Get-ChildItem $pair[0] -ErrorAction SilentlyContinue | ForEach-Object { Write-Host ("  {0} ({1:N1} MB)" -f $_.Name, ($_.Length / 1MB)) }
}
