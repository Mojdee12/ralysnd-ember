# Ember Windows Parity Port — Running Log

Branch: **parity-220** (off map-control-210 @ 04e11e3). Target: Android
src2 @ 2.2.0+2037 (builds through 2036 + the 2037 DNS-over-TCP tree
state) → Windows 2.2.0+2038.

## Owner orders

- 2026-11-12 07:08 — FULL PARITY: everything the Android app has
  gained goes to Windows, all engines, all features, the mobile Map
  Control appearance; Mozilla (Kumiho) FIRST and exactly the same
  source. Supersedes the 2026-11-01 Mozilla+V2Ray+Psiphon scope cut.
- 2026-11-12 07:12 (additional direction, owner asleep, no questions):
  ALL engines must be implemented CORRECTLY and completely on Windows
  ("همشون باید درست پیاده کنی"), obsessive strictness. The Windows
  version is "LML" (the MLM/armanlife base lineage of this codebase) —
  engine sources MAY and SHOULD be taken from its GitHub, and the
  working app's engine wiring analyzed/reverse-engineered (open-source
  code study, config formats, IPC/service layout — not cracking closed
  binaries; closed parts to be named in the audit with the closest open
  equivalent used). For every blocked engine, a working open-source
  Windows implementation must be looked for first (upstream
  armanlife/firefox-vpn-client, getlantern desktop/radiance, Psiphon
  tunnel-core, wireguard-windows/Wintun, OpenVPN community binaries).
  Licenses respected and credited. Strictness bar: no placeholder
  toggles, no dead buttons, nothing shipped that isn't wired
  end-to-end. An engine that truly cannot be completed ships
  DISABLED-with-explanation or not at all, and the audit says exactly
  what's missing. Standing no-regression + Map Control appearance
  rules apply.

## What was done (commits on parity-220)

1. **f217b22 — Mozilla/Kumiho core (FIRST, per the order).** The core
   diff src2↔win was purely additive: synced internal/fxa (incl.
   oauth.go + tests), internal/controlplane/bootstrap, internal/service/
   bootstrap_api, internal/accounts/passfile, config + guardian + proxy
   bootstrap support. Gates: go build ./... ✓, GOOS=windows build ✓,
   go vet ✓, go test (fxa/controlplane/config/accounts/guardian) ✓.
2. **c83872d — Dart feature port (2032–2037) + Windows backends.**
   Mozilla: core_api/models/signin_dialog synced; browser sign-in on
   Windows via flutter_inappwebview (WebView2) implementing the same
   Kumiho success-redirect contract (webview_flutter has no Windows
   implementation; webview_windows 0.4.0 is Dart-3-incompatible);
   MozillaBootstrap adapted (donors Psiphon / V2Ray / WARP+ / relay).
   Xray stack synced (models/builder/parser/codec/sub/exit-info + new
   pure-Dart files); Windows platform backend extended with the full
   controller contract (underlay args, setOnWarp, rotateConfig,
   tunnelCheck, measureDelayEx, endurance, networkFingerprint,
   validateConfig via `xray run -test`); frozen ping auto-sort +
   green/yellow restored after the sync. EmberWarp + Aether Windows
   backends written from the Android Kotlin contracts (identity dirs,
   env, stage parser rule-for-rule, registration ladder, hand-written
   SOCKS5 trace). Psiphon 2034 controller (exit-country) over the
   existing Windows sidecar backend. Lantern: 2034 controller over an
   honest unavailable state (core is an Android .so — see audit).
   Pages ported: aether, openvpn, wireguard, warp settings, licenses,
   CF scanner; Android build20xx tests copied.
3. **3763baf — OpenVPN + WARP+ Windows backends.** OpenVPN drives the
   official openvpn.exe sidecar; the credential vault is DPAPI
   CurrentUser via PowerShell ProtectedData with read-back
   verification (build 2027 semantics); file picker via the Windows
   dialog. WARP+ drives warp-plus.exe with the Android service's argv
   contract; "connected" only on a warp=on trace through its SOCKS.
4. **0e0ee15 — Shell wiring.** Desktop modes extended: 3 Lantern,
   4 WARP+, 5 WireGuard, 6 OpenVPN, 7 WARP (Aether), 8 MASQUE (3/4
   keep their desktop meanings; Android numbers its own shell
   differently). Engine chips, bars and actors for every engine;
   single-engine arbitration extended to all controllers; Mozilla
   bootstrap runs inside the desktop Mozilla toggle and its card sits
   in Mozilla Accounts; new engine pages float in a glass panel at
   the window's left in the desktop Map Control language.
5. **d7e950e — Editor/settings/pause.** Profile editor synced (2036
   Hy2 congestion, ECH, TLS tricks, AmneziaWG read-only fields,
   fallback-group editing); settings gained the DNS transport chips
   (DoH/DoQ/TCP-2037), resolution-order line, ad-block / DNS group /
   DNS fallback (2032/2033); desktop pause + auto-resume strip (2033)
   above the bottom bar.
6. **a568f3b — Subscription + V2Ray panel actions.** Accounts synced
   (keep-only-fastest #16 with dry-run confirm, share-sub-as-one-QR
   #29 — showSubscriptionQr added to the Windows qr_pages in its own
   idiom); desktop V2Ray panel gained keep-working-only and the 2035
   fallback-group card.
7. **86e4f45 — CF clean-IP scanner entry** on the desktop V2Ray panel.
8. **31ab436 — Version 2.2.0+2038 + sidecars + licenses.** The fetch
   script now BUILDS xray.exe from the pinned patterniha fork source
   (12fd84e, hash-pinned) instead of downloading the stock core
   (which silently no-opped dialMode/Finalmask/+one); warp-plus
   v1.2.6 built from its pinned source archive; aether.exe built from
   the pinned Aether commit when a Rust+mingw toolchain is present
   (loud warning otherwise); openvpn.exe extracted from the official
   MSI after Authenticode verification. build-windows.ps1 stages the
   warp/aether/openvpn folders like the others. Licenses page:
   Kumiho (MIT), warp-plus (MIT), OpenVPN community (GPL-2.0),
   Wintun, flutter_inappwebview (MIT) added.

## Build proofs on this machine (Linux VM, cross-compiled)

- Patched Xray: patterniha/xray-core @ 12fd84e → PE32+ x86-64
  xray.exe (31,487,488 B) ✓
- warp-plus v1.2.6 (local source) → PE32+ warp-plus.exe
  (21,118,464 B) ✓
- Aether (patterniha/Aether @ d58f9d5) → x86_64-pc-windows-gnu:
  see PARITY-AUDIT.md for the outcome.
- Psiphon tunnel-core Windows build: pre-existing pinned pipeline
  (Go 1.26.8) in the fetch script, unchanged.

## Notes / decisions

- Desktop mode numbering extends the 2.1.0 tree's (Lantern 3,
  WARP+ 4) with 5–8; the persisted desktop emberMode values keep
  their meanings. Android's shell numbers OpenVPN/WireGuard/WARP/
  MASQUE 4–7 — the trees share settings *fields*, not mode numbers;
  emberMode is a per-platform UI state.
- webview_windows (0.4.0) was rejected: its pubspec caps the Dart
  SDK below 3.0. flutter_inappwebview 6.1.5 (WebView2 on Windows,
  SDK ^3.5.0) implements the identical interception contract.
- The Windows Xray sidecar through 2.1.0 was the STOCK XTLS build —
  the parity port replaces it with the same patched fork Android
  runs, so finalmask/dialMode/+one mean the same on both platforms.

## CI (GitHub Actions, ember-windows workflow, branch parity-220)

- Run 43154951181 — Fetch sidecars FAILED at the new aether
  section: cargo exists on windows-latest, but cc-rs could not
  find `x86_64-w64-mingw32-ar`; the section's `throw` killed the
  step. Fix (180bedf): a failed/absent aether toolchain is a loud
  warning, never a pipeline kill; the mingw bin folder is located
  and prepended to PATH.
- Run 43155682428 — aether warned correctly; the OpenVPN download
  then failed: swupdate.openvpn.net serves a splash page to
  datacenter IPs (this VM and CI alike). Fix (4776ec4): the MSI
  now comes from build.openvpn.net (OpenVPN 2.6.23-I002),
  hash-pinned (31809e97…) AND Authenticode-verified.
- Run 43156736178 — Fetch sidecars PASSED in full (patched xray
  built, warp-plus built, psiphon built + init smoke passed,
  openvpn extracted; aether warned — its ring build script still
  fails on the runner's mingw layout). Build step FAILED:
  flutter_inappwebview_windows 6.1.5 uses <experimental/coroutine>,
  a hard error (STL1011) on the runner's newest MSVC. Fix
  (2efc2b7): _SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS
  defined at directory level in app/windows/CMakeLists.txt.
  (Also hardened in 3440f57: the mingw candidate must contain the
  full prefixed gcc/g++/ar set, passed to cargo/cc as full paths.)
- Run 43159480548 — all fixes in; result recorded below when done.

## Local Aether cross-build attempts (Linux VM → windows-gnu)

1. No NASM → BoringSSL cmake died at enable_language(ASM_NASM).
2. NASM installed → BoringSSL's generated Windows NASM sources
   fail ("unable to open include file `thread'") — its
   MSVC-oriented asm pipeline doesn't survive the mingw cross.
3. OPENSSL_NO_ASM forced via a CMake toolchain file → the same
   NASM objects were still generated/built (boring-sys only takes
   the NO_ASM path itself when the HOST is Windows).
   Conclusion: aether.exe is a Windows-host build (the CI route);
   from Linux it stays unbuilt, and both the script and the app
   say so out loud rather than shipping a stub.
- Run 43159480548 — **SUCCESS**: Fetch sidecars ✓, Build ✓,
  artifact uploaded. Artifact `ember-windows` (121,208,632 B):
  Ralysnd-Ember-2.2.0-Windows-Setup-x64.exe (47,456,641 B) and
  Ralysnd-Ember-2.2.0-Windows-x64.zip (74,691,165 B), copied to
  ~/workspace/ember-app/pkg-win-2038/. Verified inside the zip:
  ralysnd-ember.exe, core/firefox-vpn-core.exe + ember-tun-bridge,
  xray/xray.exe (31,508,992 B — the patched fork build) + wintun +
  geo data, psiphon/psiphon-core.exe (22,495,232 B),
  warp/warp-plus.exe (21,625,344 B), openvpn/openvpn.exe
  (1,063,104 B, extracted from the verified MSI),
  flutter_inappwebview_windows_plugin.dll + WebView2Loader.dll.
  NO aether/ folder: the runner's Rust/mingw layout still does
  not complete the Aether build (cc-rs/ring toolchain mismatch —
  runs 43154951181/43155682428/43156736178 logs), so this package's
  EmberWarp and MASQUE engines report unavailable, exactly as the
  script's warning and the app's own state say. Everything else
  is present and wired.

## W1 — 2.2.0+2039 (2026-11-27): the new face + the great Dart sync

Owner activation 2026-11-27 19:39 + design ruling 19:40 (the
Windows appearance must FULLY match the new Android app) +
Home-render rejection 19:51 ("it must be OUR OWN Map Control").
Plan + renders: ~/workspace/ember-app/windows-parity/ (plan.md,
w1-progress.md, renders/win-home-mapcontrol-2026-11-27.*).

- **Face.** The desktop shell is recomposed onto the shipped
  Map Control: the app's own baked backdrop asset
  (map_backdrop_home.webp, replacing win's coarse
  map_backdrop.png, removed), MapActorsPainter filament pins/
  arc, the shipped EMBER header + protection state, the
  shipped chip-row engine switcher, and the shipped slim bar
  (cells + hairline + round buttons + the 2148 orange pill).
  The 2038 navy-gradient/grid backdrop, glass brand panel and
  wide glass bar are retired. Servers = Android 2157's page
  (desktop padding flag); Settings = win's panel page
  reordered to the approved arrangement. Mode numbering stays
  WINDOWS' (0 Mozilla … 8 MASQUE) — src2's shell/home were NOT
  copied (they would corrupt persisted modes).
- **Stack sync (2039→2157, Dart + Go).** xray_controller and
  the whole portable xray stack at 2157 (config builder, chain/
  underlays, DNS presets/transports incl. DoH default, DPI
  Lab + ByeDPI/zapret args, dnstt/wstunnel/olcrtc args, Senpai,
  sudoku, mieru, smart groups, problem report, traffic
  history, clash import, sandbox/service checks, ping sweep);
  xray_platform.dart rewritten as win's backend architecture
  carrying the 2157 facade contract, with REAL Windows
  implementations for dnsPing (wire/DoT/DoH, direct + through
  SOCKS/HTTP), speedTestUp, sandboxTest, serviceCheck;
  AmneziaWG start refuses honestly on Windows (falls back to
  the plain WG leg, as an Android engine failure does).
  Go core synced (2105 Mozilla pack + 2152 renewal repair).
  Model merges keep win-only fields (desktop defaults/
  transport pins, allowInsecure, tunCapture + its migration);
  win-only helpers reinstated (delaySortRank, locationPingRank,
  fallbackGroupKey, protectedShareExpiryHint, ExitInfo.city).
  l10n union-merged (15 locales) + gen-l10n.
- **Compile-only passengers (pages arrive in their phases):**
  regionhop_client (+ PUBLIC PLACEHOLDER defaults — never the
  real panel file), urnetwork_client, dpi_lab, problem_report.
  UR engine glue and the RegionHop page: W3. Psiphon stack
  mirror, OpenVPN ovpn://: W2. Accounts page NOT ported
  (Android's is webview_flutter sign-in; Windows keeps its
  WebView2 flow).
- **Updater.** githubRepo repointed armanlife →
  Mojdee12/ralysnd-ember, and the latest-release fallback now
  requires the release to carry this system's file (the repo's
  latest is usually an Android vNNNN build, which must never
  be offered to the Windows app). Pinned by a new test.
- **Defaults law.** Synced features keep Android's defaults
  (everything new OFF; DNS = v2rayNG's via the synced stack).
  One visible consequence: udpNotice now defaults OFF on
  Windows too (Android 2149); its widget test opts in.
- **Gates.** flutter analyze 0 errors. flutter test +335 −8 —
  the 8 are exactly the pre-existing baseline (CoreLocator
  data-dir + 7 widget phone-layout timeouts, verified against
  a pristine worktree); stale stack tests replaced by src2's
  current versions; share-link/TUN/speaks failures seen under
  full-suite load pass in focused runs. Go: build +
  GOOS=windows build + vet clean; TestUDPLookupAndDial fails
  identically on pristine HEAD (this VM's UDP loopback).
- Version: pubspec 2.2.0+2039, appBuildNumber '2039'.

## Full parity — 2.2.0+2040 (2026-11-27): W2–W6, one cumulative build

Owner order 2026-11-27 20:55 ("کامل با همه قابلیت های موبایل بم
بده"): the complete app at Android-2157 parity, phases W2–W6
back-to-back in ONE build. Running record:
~/workspace/ember-app/windows-parity/full-parity-progress.md.

- **W2 engines.** Psiphon: the MLM host rewritten in Dart over
  psiphon-core.exe (Android 2157's constants/strategy/watchdog
  verbatim; ConsoleClient deviations documented in-file);
  dataDir() desktop fix at the seam (the bare channel call
  threw on Windows, breaking state persistence for 21 call
  sites). WireGuard/AmneziaWG: NATIVE backend on
  amneziawg.exe (tunnel service AmneziaWGTunnel$<name>, UAPI
  handshake/byte readback; the W1 honest refusal replaced);
  OpenVPN ovpn:// links end to end (parser, shell intake,
  second-instance pending-link file, installer URL protocols);
  WARP drift resolved (both surfaces real; aether_pages
  ported to 2157).
- **W3 sources + Lantern.** SecretStore gains a DPAPI
  (CurrentUser) vault backend. 24 pages batch-ported; the
  settings Xray section replaced wholesale with Android
  2157's (new xray_section.dart). RegionHop live via the
  placeholder + CI secret route (placeholder notice in-app
  when a build carries no panel). URnetwork source page
  live (vault accounts, create-by-country, managed profiles
  through the Xray/WG engines; the vendor-SDK engine mode
  is Android-only by platform). Lantern FULLY implemented
  via radiance (novpn lanternd + a stdio JSON bridge in
  lantern-bridge/, mirrored replace pins + completed
  go.sum; SOCKS 127.0.0.1:12080 through the TUN bridge).
  Sidecar foundation: subprocess_windows.dart (the Dart twin
  of SubprocessCore.kt) behind the singbox/sudoku/zapret/
  mieru/dnscrypt/dnstt/wstunnel/olcrtc facades; fetch script
  pins for all of them + AmneziaWG MSI extraction + the
  aether Rust/mingw build.
- **W4 Iran/DPI.** DPI Lab live over the sandbox core;
  ByeDPI hop (DEFAULT OFF) via ciadpi; SNI scan + spoof;
  kill switch IMPLEMENTED for the Xray and EmberWarp paths
  (was accepted-and-ignored): an unexpected core death holds
  the TUN bridge up as a blackhole with state words.
- **W5 care pack.** Settings tail wired (Automation &
  diagnostics panel: fallback chain, auto-connect, custom
  chains, leak test, filtering probe, logs hub, daily
  problem report [DEFAULT OFF], tunnel MTU, session budget;
  settings-damage panels; Privacy & sync with app lock +
  GitHub sync). App-lock gate in the shell (PIN; re-lock on
  background; pending links queue behind it). Session budget
  watcher + battery sampler in the shell (WMI battery read).
  V2Ray home cards ported — the underlay selector was
  missing entirely and is now there (None/Psiphon/EmberWarp/
  DNSTT/OLCRTC + settings pills), plus QuickPresets, the
  EmberWarp card and the connection-check card. Profile
  editor replaced with 2157's (per-config DNS ping, mixins).
  Leak test's WebRTC probe ported to InAppWebView/WebView2.
- **W6 hardening.** A full analyze pass with a CORRECT error
  grep found 56 latent errors the phase checkpoints' broken
  grep had hidden (stale win-vintage APIs in ported pages);
  all fixed — analyze now reports 0 errors, verified. The
  sudokubox fetch switched from the GitHub archive (which
  lacks the fork's replace/psiphon-tls dir) to a pinned git
  clone + -mod=mod; the Windows build of sudokubox.exe and
  of lantern-bridge.exe are both PROVEN locally (PE32+).
  Tests: full suite +359 −9 — the 8 W1-baseline failures
  (CoreLocator + 7 widget layout timeouts) unchanged, plus
  one varying failure from a known race between the two
  OpenVPN test files over the shared resolved store on
  desktop hosts (both files pass standalone; CI does not
  run the Dart suite). New/updated suites: psiphon 9,
  awg 5, ovpn_link 14, lantern_state 6.
- **Named not-at-parity legs** (honest list, also in the
  progress file): the URnetwork vendor-SDK engine mode
  (Android-only; capability ships via managed profiles);
  the emergency-connect walk + failure-alternative offers
  (src2-shell machinery with no counterpart in this shell's
  actor model — not ported, no dead surface added); AWG
  kill switch = the tunnel service's own WFP rules (no
  post-death Ember hold; service install needs admin);
  ovpn:// protocol registration only via the installer;
  OpenVPN session bytes unmeasured (no counters in the
  Windows backend — the budget says so in-app); QR image
  decode on Windows reads as "no codes" (mobile_scanner
  has no Windows implementation; paste import is the
  route); aether.exe rides the CI Rust build — if it
  fails there, EmberWarp/MASQUE report unavailable
  honestly, as in 2038/2039.
- Version: pubspec 2.2.0+2040, appBuildNumber '2040'.
- **CI + package (2040).** Runs: 46054304209 fail (psiphon
  smoke constant + aether CMake generator), 46055590275 fail
  (sudoku submodules + AmneziaWG signer name), 46059818188
  SUCCESS (commits 585f6da + e8fd6cc + 78f0f69). Installer
  124,489,407 B sha256 3417ef58…; portable zip 225,042,781 B
  sha256 ac7b6633…. Zip inventory verified complete — every
  sidecar incl. aether.exe, lanternd + lantern-bridge,
  sudokubox, amneziawg. Packages in ~/workspace/ember-app/
  pkg-win-2040/. The windows.yml RegionHop-secret env change
  remains unapplied (workflow scope) — this package carries
  the placeholder defaults, honestly noticied in-app.
