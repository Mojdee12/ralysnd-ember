# Ember Windows Parity Audit — Android src2 (2.2.0+2037) → Windows (2.2.0+2038)

Branch `parity-220`. Method: full diff inventory of `core/` and
`app/lib` between the trees, grouped (a) portable as-is,
(b) portable with platform adaptation, (c) needs a Windows native
equivalent, (d) Windows-only to preserve — then the port, per the
owner's 2026-11-12 orders (full parity; Mozilla/Kumiho first; all
engines implemented correctly and completely; upstream sources studied
and used; no placeholder toggles or dead buttons — an engine that
cannot be completed ships disabled-with-explanation).

## Per-engine verdicts

| Engine | Verdict | How it runs on Windows |
|---|---|---|
| **Mozilla (Kumiho)** | ✅ Full parity | The Go core is platform-identical — fxa/oauth.go (Fenix client `a2270f727f45f648`, PKCE S256, grant walker with host failover + Fastly solver, /v1/token refresh), controlplane bootstrap, passfile, Guardian — synced unchanged. Browser sign-in: flutter_inappwebview (WebView2) intercepts the same `accounts.firefox.com/oauth/success/<client-id>` redirect (webview_flutter has no Windows impl; webview_windows 0.4.0 caps Dart <3.0). Serverless bootstrap Prepare with Psiphon/V2Ray/WARP+ donors + Cloudflare relay fields, card in Mozilla Accounts, handoff inside the desktop connect toggle. |
| **V2Ray / Xray** | ✅ Full parity | Whole Dart stack synced (2032–2037 incl. fallback groups, Hy2 congestion, ECH, TLS tricks, DoQ + DNS-over-TCP, anti-filter, CF scanner). Windows backend extended to the full controller contract (underlays via config dialerProxy, warp chaining, rotate, tunnel check, endurance, fingerprint, `xray run -test` validation). **Sidecar fixed:** through 2.1.0 the fetch script shipped the STOCK XTLS binary — dialMode/Finalmask/+one silently no-opped. It now builds the pinned patterniha fork @ 12fd84e, the same core Android runs (cross-build proven: PE32+ xray.exe). TUN via the existing ember-tun-bridge; frozen ping auto-sort + green/yellow preserved exactly. |
| **Psiphon** | ✅ Full parity | 2034 controller (exit-country selection restarts a running tunnel) over the pre-existing Windows backend; sidecar = tunnel-core v2.0.42 ConsoleClient built by the pinned script (Go 1.26.8 — other Go versions panic at init, documented in the script). |
| **WireGuard** | ✅ Full parity | Same route as Android: profiles run through the Xray wireguard outbound (pure-Dart .conf parser, peer fallback groups, AmneziaWG params preserved + badged). The 2034 atomic-store fix (serialized tmp+rename writes, per-entry decode) came with the synced Xray stack. Native wireguard.exe/Wintun is not the app's route on either platform. |
| **WARP+ (warp-plus)** | ✅ Full parity | New Windows backend drives `warp\warp-plus.exe` with the Android service's argv contract (bind/cache-dir/dns/scan/gool/cfon/endpoint); identity persists in its cache dir; "connected" is claimed only on a warp=on Cloudflare trace through its own SOCKS (hand-written SOCKS5 client). Binary: bepass-org/warp-plus v1.2.6, built from the hash-pinned source archive in the fetch script (cross-build proven: PE32+). |
| **EmberWarp** | ✅ Backend complete; binary toolchain-gated | Dart backend implements EmberWarpCore's contract exactly (identity/staging/work dirs, reprovision env, SOCKS readiness, refusal-line staging, renew/settle, PID reaper; session SOCKS 20850 via TunBridge/proxy). The binary is the patterniha/Aether Rust core @ d58f9d5 (AGPL-3.0) — the fetch script builds it for x86_64-pc-windows-gnu when Rust+mingw+NASM are present and warns loudly otherwise; without it the engine reports unavailable honestly (the Android backends' own `available` semantics). Cross-build from this Linux VM: see "Aether build" below. |
| **MASQUE (Aether)** | ✅ Same as EmberWarp | Second slot of the same backend/binary (SOCKS 20810), its own identity dir and env profile (firewall noise defaults, MASQUE_HTTP2/fragmentation). |
| **OpenVPN** | ✅ Full parity (with a platform caveat) | New Windows backend drives the official `openvpn\openvpn.exe`: session config + `windows-driver wintun`, phase parsing from its log output, AUTH_FAILED surfacing, TCP/UDP-reset server ping, credential vault = DPAPI CurrentUser (PowerShell ProtectedData) with read-back verification — the build-2027 "counts only when it reads back" rule. Caveat, stated in the backend and here: openvpn.exe needs administrator rights (or the OpenVPN Interactive Service installed) to create its adapter and set routes; without elevation the connect fails with that explanation, never silently. Sidecar: official 2.6.23 MSI from build.openvpn.net, hash-pinned + Authenticode-verified, openvpn.exe extracted by administrative install. |
| **Lantern** | ⛔ Disabled with explanation | The app's Lantern core exists only as an Android library (liblantern.so from the ralysnd tree); there is no Windows build of that core in any upstream this codebase draws from. The 2034 controller + pages are ported, and the Windows backend returns an explicit unavailable state with the reason on every surface (no dead toggle: connect reports the explanation). **Unblock path:** a getlantern/radiance Go sidecar behind the same facade (radiance is Lantern's current open-source core and targets Windows) — a project of its own (auth/API contract work), not a stub to fake tonight. |

## Diff inventory (summary)

- **(a) Portable as-is:** the entire Go core delta (purely additive:
  fxa, controlplane, service/bootstrap_api, accounts/passfile, config/
  guardian/proxy bootstrap support — synced wholesale); pure-Dart
  Xray files (models, config_builder, link_parser, profile_codec,
  sub_fetcher, exit_info, anti_filter, cf_scanner, diagnostics,
  fallback_groups, lantern_import, scan_probes, shape_cache, shapes,
  shared_link, warp_args, wg_conf); controllers (xray, psiphon,
  lantern, aether, openvpn); pages written against the shared theme
  (aether_pages, openvpn_pages, wireguard_pages, licenses_page,
  cf_scanner_page, warp_settings_page, profile_editor); the Android
  build20xx test files.
- **(b) Portable with adaptation:** browser_signin_page (WebView2 via
  flutter_inappwebview, same contract); mozilla_bootstrap (WARP donor
  = the Windows warp-plus controller); xray_platform (union facade —
  the win TUN/port-fallback logic preserved, the controller contract
  completed); warp_platform/aether_platform/openvpn_platform/
  lantern_platform (facades with new Windows backends written from
  the Android Kotlin contracts); app_settings (merged — Windows
  desktop flags preserved, mozillaBootstrap added); ember_accounts
  (synced; bootstrap card kept); ember_settings (DNS transport/group/
  fallback added in the desktop page's own idiom); ember_shell /
  ember_home (desktop dispatch, bars, chips, arbitration extended to
  modes 5–8); map_v2ray (fallback-group card + keep-working pill
  added in desktop idiom); qr_pages (showSubscriptionQr added in the
  Windows file's own idiom).
- **(c) Needed a Windows native equivalent:** OpenVPN → openvpn.exe
  (done); WARP+ → warp-plus.exe (done); Aether/EmberWarp → aether.exe
  Rust build (backend done; binary toolchain-gated, see below);
  Lantern → no equivalent exists for this core (disabled, above).
- **(d) Windows-only, preserved untouched in behaviour:**
  core/tun_bridge.dart, core/orphan_cleanup.dart,
  psiphon/psiphon_platform_windows.dart, xray_platform_windows'
  port-fallback/TUN logic, core/cmd/ember-tun-bridge, the windows/
  runner, the desktop Map Control pages (map_mozilla/map_v2ray/
  map_psiphon/map_widgets/ember_theme), features.dart's desktop
  shell rules, and the frozen ping presentation: delay auto-sort
  fastest-first, ≤150 ms green #1E9E4A, >150 ms yellow #C99300,
  failed red (delay_sort_test.dart pins them; the one regression the
  raw sync introduced here was caught and re-merged immediately).

## Aether build (x86_64-pc-windows-gnu, from this Linux VM)

Attempted with rustup target x86_64-pc-windows-gnu + mingw-w64 13.2
+ NASM. BoringSSL (boring-sys 5.3) is the hard dependency: its
Windows-asm path assumes an MSVC preprocessing pipeline, and
boring-sys only defines OPENSSL_NO_ASM automatically when the *host*
is Windows. A CMake toolchain file forcing OPENSSL_NO_ASM for the
cross build was the next step (build in progress at audit time —
final outcome recorded in PARITY-LOG.md and the delivery report).
On a Windows host (the CI route) boring-sys takes the NO_ASM path
itself, which is why the fetch script's build is expected to
complete there; the script checks for cargo+mingw and warns instead
of failing the whole sidecar fetch when they're absent.

## Sidecars after the port (tools/sidecars → app folder)

xray\xray.exe (patched fork, built) + wintun.dll + geo data ·
psiphon\psiphon-core.exe (pinned build) · warp\warp-plus.exe
(built from pinned source) · aether\aether.exe (built when the Rust
toolchain is present) · openvpn\openvpn.exe (official MSI,
hash-pinned + Authenticode-verified extraction). All pins +
hashes are in scripts/fetch-windows-sidecars.ps1. The OpenVPN MSI
comes from build.openvpn.net (2.6.23-I002, hash-pinned and
signature-checked): swupdate.openvpn.net serves a splash page to
datacenter IPs — this VM and the CI runners alike (proven by CI
runs 43154951181/43155682428).

## Gates

- Go: `go build ./...` ✓ · `GOOS=windows go build ./...` ✓ ·
  `go vet` (fxa/controlplane/service/config/accounts/guardian/proxy) ✓ ·
  `go test` same packages ✓
- Flutter: `flutter analyze` — **0 errors** (85–88 info/warning,
  the tree's standing style baseline) ·
  `flutter test` — **+334 −8**, and the 8 failures are byte-for-byte
  the win tree's standing baseline: verified by running the same
  files on a pristine map-control-210 worktree (+59 −8, identical
  failing list: the CoreLocator data-dir test that still expects the
  upstream "Firefox VPN Client" folder name, + 7 widget_test phone-
  layout tests that already timed out before the port).
- Version: pubspec 2.2.0+2038 (above src2's 2037), app_info build
  literal 2038; build-windows.ps1 reads the version from pubspec.

## Not ported / deliberately unchanged

- Android-only surfaces with no desktop meaning: the Android VPN
  service/TUN plumbing, QS tile, Android method channels (the
  facades keep them for the shared tree's Android build).
- The desktop screenshot harness (EMBER_SHOT_*) — untouched.
- .github/workflows/windows.yml — untouched (no workflow scope);
  it is workflow_dispatch, so CI runs when the owner triggers it
  from the Actions tab (or pushes via the web UI). The branch is
  pushed and ready.
