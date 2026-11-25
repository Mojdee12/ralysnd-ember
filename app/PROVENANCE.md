# Provenance — vendored native engines

Build 2149 (audit A43-21): this inventory lives IN the
source tree so a reader of the tree alone can trace every
native binary the app ships. The build trees and the
per-engine provenance files live in the workspace at
`~/workspace/ember-app/engines/<name>/` (NOT in this
tree); each engine's Kotlin bridge header names its
engine directory. Versions below are what the tree and
the per-engine files record; where a binary is vendored
byte-exact, its staging test pins the digest.

## jniLibs/arm64-v8a (staged binaries)

| File | What it is | Source / pin |
|---|---|---|
| libxray.so | Xray core, run as a subprocess by XrayVpnService | Xray-core HEAD, Go 1.27.1, `CGO_ENABLED=0 GOOS=android` (BUILD-LOG-2.md, architecture note) |
| libtunlink.so | TUN bridge for the Xray engine (fd passed over a unix socket) | In-tree Go program wrapping xjasonlyu/tun2socks v2 (BUILD-LOG-2.md) |
| libtun2socks.so | badvpn tun2socks, the Psiphon engine's TUN bridge | Vendored byte-exact from the MLM APK extract; digest pinned by test/psiphon_transplant_test.dart |
| libsingbox.so | sing-box sidecar (TUIC / Snell / NaiveProxy / Tailscale / OpenConnect / SSH…) | SagerNet/sing-box release **v1.14.4** official android-arm64 binary; engines/singbox/PROVENANCE.md |
| libsudokubox.so | sing-box fork binary serving ONLY Sudoku profiles | Hiddify hiddify-sing-box @ `1614c5ed`, built with the `with_sudoku` tag; engines/sudokubox/PROVENANCE.md |
| libmieru.so | Mieru client sidecar | enfein/mieru release **v3.39.0** official android-arm64 binary; engines/mieru/PROVENANCE.md |
| libdnscrypt.so | DNSCrypt proxy sidecar | DNSCrypt/dnscrypt-proxy release **2.1.20** official android-arm64 binary; engines/dnscrypt/PROVENANCE.md |
| libdnstt.so | DNSTT client sidecar | David Fifield's dnstt, built from vendored source; engines/dnstt/BUILD-RECIPE.md |
| libwstunnel.so | wstunnel client sidecar | erebe/wstunnel release **v11.1.0** official android-arm64 binary; engines/wstunnel/PROVENANCE.md |
| libzapret.so | Zapret desync proxy (DPI Lab) | hufrea/ByeDPI (ciadpi) @ `e2684772f`, built for Android arm64; engines/byedpi/PROVENANCE.md |
| libolcrtc.so | OLCRTC WebRTC tunnel client | openlibrecommunity/olcrtc, master snapshot 2026-11-22 (upstream effectively EoL — see the file); engines/olcrtc/PROVENANCE.md |
| liblantern_gojni.so | Lantern core (gomobile) | Official Lantern **v10.0.5-beta.1** `libgojni.so`, renamed, byte-exact from the official APK (build 2129 trust gate); its bridge/plugin dexes ship in assets/ (lantern-bridge.dex, lantern-plugin.dex) |
| libc++_shared.so | C++ runtime for the Lantern core | Ships byte-exact with liblantern_gojni.so from the official Lantern APK |
| libsenpai_lml.so | Senpai endpoint scanner (CF scanner) | matinsenpai/SenPaiScanner (MIT) as the LML bridge binary, byte-exact from the LML APK extract; size + sha256 prefix recorded in SenpaiCore.kt |
| libaether.so | Aether engine (MASQUE / WireGuard / WARP-in-WARP) | The owner's own Rust binary (build 2032, AetherCore.kt) |
| libemberwarp.so | EmberWarp WARP client | After the patterniha/Aether design (AGPL-3.0; license text + source link in Settings → Info / Open Source Licenses) |
| libemberopenvpn.so | OpenVPN engine core | OpenVPN 3 core rebuilt from source behind Ember's own JNI bridge (OpenVpnService.kt / OpenVpnNative.kt) |

## Libraries (android/app/libs)

| File | What it is |
|---|---|
| core.aar | The Mozilla engine's Go core: Kumiho (github.com/armanlife/firefox-vpn-client), gomobile-bound from the Go tree at `src2/core/` |
| psiphon.aar | The Psiphon engine's core: psiphontunnel-2.0.39-ns, the byte-exact AAR the MLM app ships (sha256 426c0fda…), carrying libpgjni.so (build 2091, the MLM transplant) |
| wf.jar | WireGuard/AmneziaWG backend support library for the tunnel engine (with the com.wgtunnel:backend 1.10.1 dependencies in build.gradle.kts; github.com/wgtunnel/core, MIT) |

## Documented but NOT shipped

- **libpsiphonbox.so** — the 2089/2090 Psiphon provider
  sidecar (Hiddify sing-box fork @ `1614c5ed`, engines/
  psiphonbox/PROVENANCE.md). Retired from the start path
  by the build-2091 MLM transplant; PsiphonBoxCore.kt
  stays in the tree as the documented fallback and the
  binary is deliberately absent from the APK.
