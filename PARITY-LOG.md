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
