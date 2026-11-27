/// The Ember shell, Map Control edition (2.2.0): the baked
/// dotted world map as the ground, the floating brand panel and
/// engine chips as the navigation, the live map actors (home
/// marker, exit pin, arc) over the map, the pages floating in
/// glass panels, and the wide bottom control bar that drives
/// whichever engine the chips have chosen. Exactly one tunnel
/// is ever up: the arbitration hooks below are unchanged from
/// the pre-reskin shell.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;

import '../../aether/aether_controller.dart';
import '../../app_settings.dart';
import '../../core/android_core.dart';
import '../../core/core_controller.dart';
import '../../core/system_ui_flight.dart';
import '../../core/models.dart';
import '../../lantern/lantern_controller.dart';
import '../../l10n/app_localizations.dart';
import '../../net/network_info.dart';
import '../../openvpn/openvpn_controller.dart';
import '../../psiphon/psiphon_controller.dart';
import '../../urnetwork/ur_engine_controller.dart';
import '../../xray/fallback_groups.dart';
import '../../xray/wg_conf.dart';
import '../../xray/xray_controller.dart';
import '../../xray/xray_models.dart';
import 'aether_pages.dart';
import 'app_lock.dart';
import 'battery_report.dart';
import 'ember_accounts.dart';
import 'mozilla_bootstrap.dart';
import 'qr_pages.dart';
import 'session_budget.dart';
import 'emergency.dart';
import 'ember_format.dart';
import 'ember_home.dart';
import 'ember_servers.dart';
import 'ember_settings.dart';
import 'ember_theme.dart';
import 'ember_updater.dart';
import 'lantern_pages.dart';
import 'map_widgets.dart';
import 'openvpn_pages.dart';
import 'profile_country.dart';
import 'psiphon_pages.dart';
import 'urnetwork_engine_pages.dart';
import 'wireguard_pages.dart';
import 'world_map.dart';

/// Build 2083: which Xray section a session lights. WireGuard
/// is a section over the shared Xray core (build 2032), so both
/// section chips used to read the same engine state and lit
/// together on ANY session (owner screenshot, 2026-11-15: a
/// VLESS session showed V2Ray and WireGuard ACTIVE at once).
/// The split follows the session profile's protocol.
bool xraySectionActive({
  required bool running,
  required bool connecting,
  required bool sessionIsWireGuard,
  required bool wireGuardSection,
}) {
  if (!running && !connecting) return false;
  return wireGuardSection == sessionIsWireGuard;
}

/// The app lock's re-lock grace (build 2095, whole-app
/// journey audit #4: "short grace allowed"): a brief
/// backgrounding — a system picker, a permission dialog, a
/// quick app switch — does not re-lock; a real one does.
const Duration relockGrace = Duration(seconds: 30);

/// Build 2095 (audit #4): the pure re-lock decision — the
/// lock re-arms when the app was backgrounded at least the
/// grace span. Pinned by tests.
/// Build 2097 (IMP-1): a backgrounding that belongs to a
/// system-UI flight the app itself launched (a file
/// picker, the gallery picker, the document creator)
/// NEVER re-locks, however long the user browses — build
/// 2095's re-lock disposed the importing page mid-pick and
/// the completed pick was discarded at the page's
/// `context.mounted` check, which is how WireGuard and
/// OpenVPN file imports silently died on any pick slower
/// than the 30 s grace.
bool relockDue({
  required DateTime backgroundedAt,
  required DateTime resumedAt,
  Duration grace = relockGrace,
  bool systemUiFlight = false,
}) =>
    !systemUiFlight && resumedAt.difference(backgroundedAt) >= grace;

class EmberShell extends StatefulWidget {
  const EmberShell({
    super.key,
    required this.core,
    required this.settings,
    this.banner,
    this.noCore,
  });

  final CoreController core;
  final AppSettings settings;
  final Widget? banner;
  final Widget? noCore;

  @override
  State<EmberShell> createState() => _EmberShellState();
}

class _EmberShellState extends State<EmberShell> with WidgetsBindingObserver {
  int _tab = 0;

  /// The app lock's session state (build 2075): false while
  /// a PIN is set and not yet entered this launch.
  bool _unlocked = false;

  /// Build 2095 (whole-app journey audit #4): when the app
  /// last left the foreground — the re-lock decision's input.
  DateTime? _backgroundedAt;

  /// Build 2097 (IMP-1): whether that backgrounding belonged
  /// to a system-UI flight (see [relockDue]).
  bool _bgWasSystemUiFlight = false;

  /// Build 2095 (whole-app journey audit #5): actions that
  /// arrived while the app was locked. They never execute
  /// behind the lock page; they queue here and replay once
  /// after the unlock.
  /// Build 2096 (post-2095 audit L24): per-kind QUEUES —
  /// build 2095's single slots overwrote each other, so
  /// of two shortcut taps behind the lock only the second
  /// ever replayed.
  final List<String> _pendingShortcutIds = [];
  final List<OvpnIntentFile> _pendingOvpnFiles = [];

  /// Build 2095 (whole-app journey audit #38): config
  /// links that arrived behind the app lock.
  final List<String> _pendingDeepLinks = [];
  bool _pendingRotate = false;
  bool _pendingAutoConnect = false;
  int? _pendingResumeMode;

  /// True while the lock page is (or should be) up.
  bool get _lockedNow => widget.settings.appLockEnabled && !_unlocked;
  late final XrayController _xray = XrayController();
  late final PsiphonController _psiphon = PsiphonController();
  late final LanternController _lantern = LanternController();
  late final OpenVpnController _openvpn = OpenVpnController();
  // Build 2032: the ralysnd Aether engines — the standalone
  // WARP slot and the MASQUE slot.
  late final AetherController _warp = AetherController('cfwarp');
  late final AetherController _masque = AetherController('masque');
  // Build 2156: the URnetwork engine (SDK DeviceLocal core
  // in the :urnetwork process; the build-2154 accounts are
  // its sign-in — no login UI of its own).
  late final UrEngineController _ur = UrEngineController();

  /// The Mozilla bootstrap helper (build 2034): runs the
  /// one-handoff pass fetch before a Mozilla connect when the
  /// region blocks Guardian and no stored pass is valid.
  late final MozillaBootstrap _bootstrap = MozillaBootstrap(
    core: core,
    settings: widget.settings,
    psiphon: _psiphon,
    xray: _xray,
    warp: _warp,
  );
  bool _defaultsApplied = false;
  bool _mozBusy = false;

  // Build 2147 (fix item #23): the build 2075 compact-rail
  // mechanism is gone — the non-Home header no longer stacks
  // the chips in a column at all (see _header), so there is
  // no short-window fold left to compute.

  // Pause with auto-resume (build 2033): the mode whose
  // connection is paused, when it comes back, and the timers
  // that drive the countdown and the resume. In-memory only —
  // if the app process dies, the pause dies with it and the
  // engine simply stays off (nothing is faked with a native
  // alarm the tree does not have).
  int? _pausedMode;
  DateTime? _resumeAt;

  /// Build 2092 (item 33): the 1 s pause-countdown tick. It
  /// used to setState the whole shell every second; now only
  /// the countdown Text listens to it.
  final ValueNotifier<int> _pauseTick = ValueNotifier<int>(0);
  Timer? _pauseTimer;
  Timer? _pauseTicker;

  CoreController get core => widget.core;

  /// Whether the app is in the foreground, for the poll
  /// cadence feed (build 2050, audit §3 battery): every engine
  /// controller polls at its live 2 s cadence only while this
  /// is true, and the Mozilla core poller also keys on the
  /// engine on stage. Tunnels behave identically either way —
  /// only the UI-side supervision slows down.
  bool _foreground = true;

  /// Pushes the cadence state into every controller.
  void _applyCadence() {
    _xray.setForeground(_foreground);
    _psiphon.setForeground(_foreground);
    _lantern.setForeground(_foreground);
    _openvpn.setForeground(_foreground);
    _warp.setForeground(_foreground);
    _masque.setForeground(_foreground);
    _ur.setForeground(_foreground);
    core.setForeground(_foreground);
    core.setEngineFocus(mode == 0);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _applyCadence();
    // Build 2095 (whole-app journey audit #4): the lock
    // re-arms after a real backgrounding. It used to be
    // one-unlock-per-process: _unlocked was set once and
    // never reset, despite the Settings copy "a PIN asked
    // when the app opens".
    if (state == AppLifecycleState.paused) {
      _backgroundedAt = DateTime.now();
      // Build 2098 (post-2097 audit L28): the snapshot is
      // the flight's say over THIS backgrounding — a live
      // flight suppresses the re-lock, a stranded one
      // (stranded pick, IMP-R) no longer does.
      _bgWasSystemUiFlight = SystemUiFlight.suppressesRelock;
    } else if (state == AppLifecycleState.resumed) {
      final bg = _backgroundedAt;
      _backgroundedAt = null;
      final wasFlight = _bgWasSystemUiFlight;
      _bgWasSystemUiFlight = false;
      if (bg != null &&
          _unlocked &&
          widget.settings.appLockEnabled &&
          relockDue(
            backgroundedAt: bg,
            resumedAt: DateTime.now(),
            systemUiFlight: wasFlight,
          )) {
        setState(() => _unlocked = false);
      }
      // Build 2116 (B7-1): re-arbitrate against the native
      // VPN-slot claim — an engine may have been started
      // (or resurrected) while the app was away.
      unawaited(_reArbitrateFromClaim());
    }
    // Build 2055 (audit B-M1): leaving the foreground lands
    // any debounced stats totals — a backgrounded app may be
    // killed before the next 30 s write, and the disconnect
    // flush never runs for a killed process.
    if (!_foreground) unawaited(_xray.flushStatsOnBackground());
  }

  /// The engine the panel shows: 0 = Mozilla, 1 = V2Ray,
  /// 2 = Psiphon, 3 = Lantern, 4 = OpenVPN (persisted). 2024:
  /// Lantern is back as mode 3; 2025: OpenVPN takes mode 4 —
  /// the slot WARP held before 2023, so a stored 4 from that
  /// era now opens OpenVPN, the same benign resurrection
  /// Lantern's 3 had. Build 2032 adds 5 = WireGuard (the Xray
  /// carrier's own section), 6 = WARP and 7 = MASQUE (the
  /// ralysnd Aether engines). Build 2156 adds 8 = URnetwork
  /// (the SDK engine). A stored value outside 0..8 reads as
  /// Mozilla here too (AppSettings.load already clamps it),
  /// never a dead page.
  int get mode {
    final m = widget.settings.emberMode;
    return m >= 0 && m <= 8 ? m : 0;
  }

  set mode(int value) => widget.settings.update(emberMode: value);

  /// Build 2133: the V2Ray servers surface is a dedicated
  /// full-screen page now (the owner's approved full
  /// tab), pushed over the shell from the V2Ray entry
  /// points. Other modes keep the Servers tab — their
  /// lists live there (Mozilla locations, Psiphon
  /// regions, Lantern's list).
  void _openServersTab() {
    if (mode == 1) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => V2RayPage(
            xray: _xray,
            psiphon: _psiphon,
            onOpenAccounts: () => setState(() => _tab = 2),
          ),
        ),
      );
    } else {
      setState(() => _tab = 1);
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _applyCadence();
    // Build 2098 (post-2097 audit §7, item U-A): while an
    // Xray session is up, the updater reaches GitHub through
    // the session's own local HTTP inbound instead of only
    // connecting directly — the direct check is the first
    // thing a filtered network eats (see ember_updater.dart).
    EmberUpdater.instance?.localProxyResolver = () =>
        _xray.state.running ? '127.0.0.1:${_xray.settings.httpPort}' : null;
    // Build 2098 (verification V-3): the credentials for
    // that proxy when the session's inbound demands them —
    // the config builder's own selection, mirrored (the LAN
    // login when it is ready, else the local-proxy login).
    EmberUpdater.instance?.localProxyCredentialsResolver = () {
      final s = _xray.settings;
      final ready =
          s.lanShareAuthReady || (!s.lanShareEnabled && s.localProxyAuthReady);
      if (!ready) return null;
      return s.lanShareAuthReady
          ? (user: s.lanShareUser, pass: s.lanSharePass)
          : (user: s.localProxyUser, pass: s.localProxyPass);
    };
    _xray.stopOtherEngine = () async {
      await _stopMozilla(cascadeFrom: 'v2ray');
      await _stopPsiphon();
      await _stopLantern();
      await _stopOpenVpn();
      await _stopAether();
      await _stopUr();
    };
    // Build 2116 (audit AB-04): Mozilla pass boundaries
    // land in the connect journal the Diagnostics export
    // carries.
    core.journalLine = (line) => _xray.diagnostics.add('mozilla', line);
    // The chain underlay (build 2029A) starts with the Psiphon
    // engine's own settings — region, upstream, protocols —
    // so the Psiphon page stays the one place they are chosen.
    _xray.underlayParams = () => (
      region: _psiphon.settings.region,
      upstream: _psiphon.settings.upstream,
      protocols: _psiphon.settings.protocols.toList(),
    );
    // Launcher shortcuts (build 2093): the starred configs
    // publish as long-press app-icon shortcuts while the switch
    // in Settings is on — the same callback shape as the tunnel
    // MTU and the local DNS below.
    _xray.launcherShortcutsEnabled =
        () => widget.settings.launcherShortcutsEnabled;
    // The global tunnel MTU (build 2038, queue 2f) lives in the
    // Xray settings; the other engines read it at connect time
    // through these callbacks, so a change in Settings applies
    // to the next connect without an app restart.
    _psiphon.tunnelMtu = () => _xray.settings.tunnelMtu;
    _lantern.tunnelMtu = () => _xray.settings.tunnelMtu;
    _warp.tunnelMtu = () => _xray.settings.tunnelMtu;
    _masque.tunnelMtu = () => _xray.settings.tunnelMtu;
    // Build 2156: the URnetwork engine reads the same
    // globals at connect time, and its accounts are the
    // build-2154 URnetwork accounts the Xray controller
    // owns (labels + ids; the keys stay in the vault).
    _ur.tunnelMtu = () => _xray.settings.tunnelMtu;
    _ur.killSwitchEnabled = () => _xray.settings.killSwitch;
    _ur.accountsProvider = () => _xray.urAccounts;
    // Build 2097 (post-2096 audit C7): the kill switch
    // reaches the Aether slots' TUN starts the same way —
    // its Settings copy has promised WARP coverage since
    // build 2063, but the value never left the Xray path.
    _warp.killSwitchEnabled = () => _xray.settings.killSwitch;
    _masque.killSwitchEnabled = () => _xray.settings.killSwitch;
    // Build 2125 (audit A25-15 / P-22): the Aether TUN
    // starts take the user's tunnel DNS and IPv6 choices
    // from the same Xray settings, like the MTU and the
    // kill switch above — up to 2124 they silently ran on
    // the platform defaults (1.1.1.1, IPv6 on).
    _warp.tunDns = () => _xray.settings.localDns;
    _warp.tunIpv6 = () => _xray.settings.ipv6Route;
    _masque.tunDns = () => _xray.settings.localDns;
    _masque.tunIpv6 = () => _xray.settings.ipv6Route;
    // Build 2126 (audit A26-30): the Aether TUN-DNS
    // family guard's substitution note lands in the
    // shared diagnostics journal.
    _warp.dnsGuardNote = (m) => _xray.diagnostics.add('dns', m, ok: false);
    _masque.dnsGuardNote = (m) => _xray.diagnostics.add('dns', m, ok: false);
    // The tunnel DNS (build 2057, audit §6 engine low) lives in
    // the Xray settings too; Psiphon and Lantern read it at
    // connect time through these callbacks, so a change in
    // Settings applies to the next connect without an app
    // restart — neither tunnel silently keeps 1.1.1.1 anymore.
    _psiphon.localDns = () => _xray.settings.localDns;
    // Build 2125 (audit A25-04 / plan S-4): the kill
    // switch reaches the standalone Psiphon TUN start the
    // same way — up to 2124 it enforced only in
    // XrayVpnService, so a dead Psiphon session silently
    // returned the device to direct traffic.
    _psiphon.killSwitchEnabled = () => _xray.settings.killSwitch;
    _lantern.localDns = () => _xray.settings.localDns;
    // Build 2125 (audit A25-04): the kill switch reaches
    // the Lantern TUN start the same way.
    _lantern.killSwitchEnabled = () => _xray.settings.killSwitch;
    // Build 2057 (audit F-M4): Psiphon's TUN captures IPv6 only
    // when the Xray settings say so (ipv6Route) — same callback
    // shape as the MTU/DNS above, read at connect time.
    _psiphon.tunnelIpv6 = () => _xray.settings.ipv6Route;
    _psiphon.stopOtherEngine = () async {
      await _stopMozilla(cascadeFrom: 'psiphon');
      if (_xray.state.running || _xray.connecting) await _xray.disconnect();
      await _stopLantern();
      await _stopOpenVpn();
      await _stopAether();
      await _stopUr();
    };
    _lantern.stopOtherEngine = () async {
      await _stopMozilla(cascadeFrom: 'lantern');
      if (_xray.state.running || _xray.connecting) await _xray.disconnect();
      await _stopPsiphon();
      await _stopOpenVpn();
      await _stopAether();
      await _stopUr();
    };
    _openvpn.stopOtherEngine = () async {
      await _stopMozilla(cascadeFrom: 'openvpn');
      if (_xray.state.running || _xray.connecting) await _xray.disconnect();
      await _stopPsiphon();
      await _stopLantern();
      await _stopAether();
      await _stopUr();
    };
    _ur.stopOtherEngine = () async {
      await _stopMozilla(cascadeFrom: 'urnetwork');
      if (_xray.state.running || _xray.connecting) await _xray.disconnect();
      await _stopPsiphon();
      await _stopLantern();
      await _stopOpenVpn();
      await _stopAether();
    };
    // Build 2125 (audit A25-04): the kill switch reaches
    // the OpenVPN TUN start the same way.
    _openvpn.killSwitchEnabled = () => _xray.settings.killSwitch;
    _warp.stopOtherEngine = () async {
      await _stopMozilla(cascadeFrom: 'warp');
      if (_xray.state.running || _xray.connecting) await _xray.disconnect();
      await _stopPsiphon();
      await _stopLantern();
      await _stopOpenVpn();
      await _stopUr();
      if (_masque.state.running || _masque.tunRunning) {
        await _masque.disconnect();
      }
    };
    _masque.stopOtherEngine = () async {
      await _stopMozilla(cascadeFrom: 'masque');
      if (_xray.state.running || _xray.connecting) await _xray.disconnect();
      await _stopPsiphon();
      await _stopLantern();
      await _stopOpenVpn();
      await _stopUr();
      if (_warp.state.running || _warp.tunRunning) {
        await _warp.disconnect();
      }
    };
    unawaited(
      _xray.load().then((_) {
        // The Mozilla connect path (AndroidCore.setOn) cannot take
        // the MTU as an argument — CoreController's turnOn is (bool)
        // and shared with desktop — so the shell mirrors the loaded
        // value into AndroidCore.tunnelMtu (build 2038, queue 2f);
        // the settings page keeps it in sync on every change.
        AndroidCore.tunnelMtu.value = _xray.settings.tunnelMtu;
        // Build 2127 (H4): the same mirror for the kill
        // switch (the Mozilla engine's hold reads it).
        AndroidCore.killSwitch.value = _xray.settings.killSwitch;
        // Build 2093: the starred set becomes the shortcut set
        // once the profiles are loaded.
        unawaited(_xray.syncLauncherShortcuts());
        // Build 2147 (feature #21b): the one-time seeding of
        // the built-in default subscriptions.
        unawaited(_xray.seedDefaultSubscriptions2147());
      }),
    );
    _psiphon.load();
    _lantern.load();
    _openvpn.load();
    _warp.load();
    _masque.load();
    _ur.load();
    // Build 2065: per-network winner memory, auto-connect
    // triggers and the scheduled-health tick all ride the
    // platform network callback armed here.
    _armNetworkTracking();
    _applyEmber2Defaults();
    // Build 2112: the upstream-connections pin runs AFTER the
    // transport pin, not beside it — editSettings is a
    // read-modify-write over the core's settings document, and
    // two one-time pins editing it concurrently could each
    // write back a copy missing the other's change.
    unawaited(
      _applyTransportDefault().then(
        (_) => _applyUpstreamConnectionsDefault(),
      ),
    );
    // Keep the controllers' view of their services fresh on return.
    unawaited(_xray.refreshState());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pauseTimer?.cancel();
    _pauseTicker?.cancel();
    _pauseTick.dispose();
    _netSub?.cancel();
    _rotateSub?.cancel();
    _screenOffSub?.cancel();
    _ovpnFileSub?.cancel();
    _shortcutSub?.cancel();
    _deepLinkSub?.cancel();
    _healthTimer?.cancel();
    widget.settings.removeListener(_syncBudgetTimer);
    _budgetTimer?.cancel();
    // Build 2105: land the open battery session, if any —
    // its end level stays unknown rather than guessed.
    // Build 2116 (B13-3, 2105-R6): dispose cannot await
    // the async store write, so the final record is taken
    // from the tracker and written synchronously — it
    // used to be losable whenever the process died before
    // the unawaited rename landed.
    final batteryRecord = _batteryTracker?.takeOpen(
      DateTime.now().millisecondsSinceEpoch,
    );
    if (batteryRecord != null) {
      try {
        _batteryLog?.addSync(batteryRecord);
      } catch (_) {
        // Teardown hygiene only — a failed final write
        // must never break dispose.
      }
    }
    _xray.dispose();
    _psiphon.dispose();
    _lantern.dispose();
    _openvpn.dispose();
    _warp.dispose();
    _masque.dispose();
    _ur.dispose();
    super.dispose();
  }

  /// Ember 2's baked-in first-run defaults, applied once per install:
  /// VPN mode (not proxy), smart routing off, encrypted DNS on — the
  /// three settings behind the "sites do not open" reports on v1.
  /// Applied only while neither engine is connected.
  Future<void> _applyEmber2Defaults() async {
    if (widget.settings.ember2DefaultsApplied || _defaultsApplied) return;
    _defaultsApplied = true;
    // The Mozilla core needs a moment to answer after launch.
    for (var i = 0; i < 30 && core.status == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    try {
      if (core.status?.state.phase != Phase.running) {
        // 1. The connection mode: VPN.
        await AndroidCore.setMode('vpn');
        // 2. Smart routing off, 3. DoH defaults in place.
        await core.editSettings((config) {
          final routing = config['routing'];
          if (routing is Map<String, Object?>) {
            routing['enabled'] = false;
          }
          final dns = config['dns'];
          if (dns is Map<String, Object?>) {
            final servers = dns['servers'];
            final list = servers is List ? servers : const [];
            final encrypted =
                list.isNotEmpty &&
                list.every(
                  (s) =>
                      s.toString().startsWith('https://') ||
                      s.toString().startsWith('tls://'),
                );
            if (!encrypted) {
              dns['servers'] = [
                'https://1.1.1.1/dns-query',
                'https://8.8.8.8/dns-query',
                'https://9.9.9.9/dns-query',
              ];
            }
          }
        });
      }
    } catch (_) {
      // A core that is not answering keeps its settings; the flag stays
      // unset so the next launch tries again.
      _defaultsApplied = false;
      return;
    }
    // Build 2057 (audit F-H10): this runs from an async continuation
    // (core-status waits + platform calls) that the test clock — and
    // on a slow device, a frame boundary — can land inside a build,
    // and notifyListeners() mid-build throws "setState() called
    // during build" on the shell's ListenableBuilders. The flag is
    // bookkeeping; apply it after the current frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.settings.update(ember2DefaultsApplied: true);
    });
  }

  bool _transportApplied = false;

  /// The Mozilla transport default, pinned once (2024 — the
  /// desktop 2.0.5 pin brought to Android): proxy.transport =
  /// "h2". The core's factory default is already "h2" (its
  /// config defaults set it), but an install whose SAVED core
  /// config says "h3" — the Settings transport choice writes it,
  /// and its unset state displays as h3 — pays for it on every
  /// connect on a UDP-hostile network: the H3 (QUIC) session
  /// attempt runs under the core's whole 20 s ConnectTimeout
  /// across the server's addresses before the engine falls back
  /// to H2. That is the owner's ~10 s Android connect. Pin H2
  /// once, while the engine is not running; afterwards the
  /// Settings choice owns the value (AppSettings.transportPinned).
  Future<void> _applyTransportDefault() async {
    if (widget.settings.transportPinned || _transportApplied) return;
    _transportApplied = true;
    // The Mozilla core needs a moment to answer after launch.
    for (var i = 0; i < 30 && core.status == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    final status = core.status;
    if (status == null || status.state.phase == Phase.running) {
      // Nothing answered, or a tunnel is already up: keep the flag
      // unset so a later launch tries again.
      _transportApplied = false;
      return;
    }
    try {
      await core.editSettings((config) {
        final proxy = config['proxy'];
        if (proxy is Map<String, Object?>) {
          proxy['transport'] = 'h2';
        }
      });
    } catch (_) {
      _transportApplied = false;
      return;
    }
    // Build 2057 (audit F-H10): same mid-build notify hazard as
    // _applyEmber2Defaults above — the flag is bookkeeping, so it
    // lands after the current frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.settings.update(transportPinned: true);
    });
  }

  bool _upstreamConnectionsApplied = false;

  /// The Mozilla session pool, pinned once (build 2112 —
  /// mozilla-fix-plan.md, fix A): proxy.upstream_connections
  /// = 4. The core ships the value at its desktop default of
  /// 1 — ONE H2 session carrying every app on the phone, its
  /// stream ceiling set by the server; saturation waits (a
  /// tunnel can sit 10 s for a free stream) and single-session
  /// rebuild churn follow, and sites fail while the tunnel
  /// shows connected — the shape the owner proved against
  /// Arman VPN on 2026-11-18. The core's pool machinery for
  /// >1 already exists and round-robins on the TUN path; only
  /// the value was wrong for a phone. The core's own Default()
  /// is 4 from this build, but an install whose SAVED core
  /// config says 1 keeps 1 — so pin it once here, while the
  /// engine is not running; afterwards the core config owns
  /// the value (AppSettings.upstreamConnectionsPinned).
  Future<void> _applyUpstreamConnectionsDefault() async {
    if (widget.settings.upstreamConnectionsPinned ||
        _upstreamConnectionsApplied) {
      return;
    }
    _upstreamConnectionsApplied = true;
    // The Mozilla core needs a moment to answer after launch.
    for (var i = 0; i < 30 && core.status == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    final status = core.status;
    if (status == null || status.state.phase == Phase.running) {
      // Nothing answered, or a tunnel is already up: keep the flag
      // unset so a later launch tries again.
      _upstreamConnectionsApplied = false;
      return;
    }
    try {
      await core.editSettings((config) {
        final proxy = config['proxy'];
        if (proxy is Map<String, Object?>) {
          proxy['upstream_connections'] = 4;
        }
      });
    } catch (_) {
      _upstreamConnectionsApplied = false;
      return;
    }
    // Build 2057 (audit F-H10): same mid-build notify hazard as
    // _applyTransportDefault above — the flag is bookkeeping, so
    // it lands after the current frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.settings.update(upstreamConnectionsPinned: true);
    });
  }

  /// The Xray engine's arbitration hook: Mozilla goes fully off first.
  ///
  /// [cascadeFrom] names the engine whose stopOtherEngine
  /// hook is calling (build 2098 verification, iteration
  /// 2): when the Mozilla bootstrap itself is starting that
  /// very engine as its donor, the hook call is the donor's
  /// own cascade and must not cancel the prepare; a cascade
  /// from any OTHER engine — or a direct call, which passes
  /// null — cancels it. See MozillaBootstrap.cancelFromCascade.
  Future<void> _stopMozilla({String? cascadeFrom}) async {
    // Build 2098 (post-2097 audit M17): cancel any in-flight
    // bootstrap preparation FIRST. The stop used to no-op
    // through the whole bootstrap window (nothing was
    // running or starting yet), so a Stop or engine switch
    // during preparation let the bootstrap finish and
    // complete a connect the user had already abandoned.
    // cancel() only bumps the bootstrap's generation — the
    // in-flight prepareIfNeeded returns cancelled at its
    // next check (donor and relay branches alike).
    // Build 2098 verification V-1: through the CASCADE entry
    // (cancelFromCascade), not a bare cancel() — _stopMozilla
    // is also what a donor engine's stopOtherEngine hook
    // calls while the bootstrap itself is starting that
    // donor, and a bare cancel there aborted every
    // engine-donor bootstrap. Genuine stops keep their own
    // direct cancel() calls (_disconnectMode case 0, the
    // chip switch, the shortcut handlers).
    _bootstrap.cancelFromCascade(cascadeFrom);
    // Build 2097 (post-2096 audit C-L2): an in-flight setOn
    // counts too — the stop used to no-op during the
    // toggle's own await (phase not yet starting), and the
    // toggle then completed behind the stopper's back. The
    // setOn below supersedes it via the core's generation
    // guard, so the in-flight call bails at its next poll.
    if (core.status?.state.phase == Phase.running ||
        core.status?.state.phase == Phase.starting ||
        core.switchingProxy) {
      await core.setOn(false);
      for (var i = 0; i < 30; i++) {
        if (core.status?.state.phase == Phase.off ||
            core.status?.state.phase == Phase.waiting) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
  }

  /// The Psiphon engine goes off (the other engines' hooks pass
  /// through here).
  Future<void> _stopPsiphon() async {
    // Build 2095: the connecting window counts too — a chip
    // switch mid-connect must stop the attempt, and the
    // controller's disconnect is the same call the power
    // capsule already makes in that window.
    if (_psiphon.state.running || _psiphon.connecting) {
      await _psiphon.disconnect();
    }
  }

  /// The Lantern engine goes off (the other engines' hooks pass
  /// through here).
  Future<void> _stopLantern() async {
    // Build 2096 (post-2095 audit H6): the connecting
    // window counts too, as it already did for Psiphon
    // and Aether — an engine mid-connect when another
    // engine starts must be stopped, or its connect
    // completes alongside the new one. (Every Xray hook
    // above gained the same `|| _xray.connecting`.)
    if (_lantern.state.running ||
        _lantern.state.coreRunning ||
        _lantern.connecting) {
      await _lantern.disconnect();
    }
  }

  /// The OpenVPN engine goes off (the other engines' hooks
  /// pass through here).
  Future<void> _stopOpenVpn() async {
    // Build 2096 (audit H6): connecting counts too.
    if (_openvpn.state.running || _openvpn.connecting) {
      await _openvpn.disconnect();
    }
  }

  /// Both Aether slots go off (the other engines' hooks pass
  /// through here; each slot's own hook spares itself).
  Future<void> _stopAether() async {
    // Build 2095: connecting counts too (see _stopPsiphon).
    if (_warp.state.running || _warp.tunRunning || _warp.connecting) {
      await _warp.disconnect();
    }
    if (_masque.state.running || _masque.tunRunning || _masque.connecting) {
      await _masque.disconnect();
    }
  }

  /// The URnetwork engine goes off (the other engines'
  /// hooks pass through here).
  Future<void> _stopUr() async {
    // The connecting window counts too (build 2096, H6).
    if (_ur.state.running || _ur.connecting) {
      await _ur.disconnect();
    }
  }

  /// The Mozilla engine's matching hook, used by the home page:
  /// all other engines go off before Mozilla starts.
  Future<void> stopXray() async {
    if (_xray.state.running || _xray.connecting) await _xray.disconnect();
    await _stopPsiphon();
    await _stopLantern();
    await _stopOpenVpn();
    await _stopAether();
    await _stopUr();
  }

  // ------------------------------------------------------------ toggles
  // The bottom bar's power capsule drives the current engine.
  // These are the home pages' old toggles, moved here unchanged
  // in behavior (same arbitration, same error faces).

  /// Build 2095 (whole-app journey audit #25): shows the
  /// VPN-permission sentence when [e] is a denial — the
  /// Mozilla path throws [VpnNotAllowed], every other
  /// engine's channel answers with the `vpn_denied` error
  /// code — and returns true when it did, so the toggle
  /// skips its generic start-failed line. The user is told
  /// they denied the permission, which is the one start
  /// failure they can fix with a tap.
  bool _showVpnDenied(BuildContext context, Object e) {
    final denied =
        e is VpnNotAllowed ||
        (e is PlatformException && e.code == 'vpn_denied');
    if (!denied || !context.mounted) return false;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppLocalizations.of(context).vpnNotAllowed)),
    );
    return true;
  }

  Future<void> _toggleMozilla(BuildContext context) async {
    final on = core.status?.state.phase == Phase.running;
    setState(() => _mozBusy = true);
    try {
      if (!on) {
        // Build 2034: the bootstrap handoff runs BEFORE Mozilla
        // takes over — the donor engine connects, the core
        // fetches and stores a Guardian pass through it, the
        // donor stops, and only then does Mozilla connect,
        // directly, on the stored pass.
        // Build 2152 (DART-2): snapshot the gate BEFORE the
        // call — donor chosen AND the stored pass below the
        // freshness floor is exactly prepareIfNeeded's own
        // early-return condition (the same shared predicate,
        // passReady), so a proceed verdict after this
        // snapshot can only mean a handoff actually ran.
        // That is how the shell, which owns the journal
        // wiring, learns a floor-triggered refresh happened
        // without giving MozillaBootstrap journal access.
        final floorRefresh =
            _bootstrap.donor != 'off' && !_bootstrap.passReady;
        final verdict = await _bootstrap.prepareIfNeeded();
        if (verdict.cancelled) return;
        if (!verdict.proceed) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(verdict.message ?? 'Bootstrap failed')),
            );
          }
          return;
        }
        if (floorRefresh) {
          // Through the same producer the pass-boundary
          // lines use: core.journalLine, wired above to the
          // diagnostics journal as source 'mozilla'.
          core.journalLine?.call(
            'Mozilla pass refreshed before connecting — '
            'the stored pass was close to expiry.',
          );
        }
        await stopXray();
      }
      await core.setOn(!on);
    } catch (e) {
      if (context.mounted && _showVpnDenied(context, e)) return;
      // Build 2070 (review §3.4): a plain line, not the raw
      // exception — the technical detail lives in the core's
      // own log and, for native failures, in crash.log.
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).startFailed)),
        );
        _offerAlternative(context, 0, '$e');
      }
    } finally {
      if (mounted) setState(() => _mozBusy = false);
    }
  }

  Future<void> _toggleXray(BuildContext context) async {
    final l = AppLocalizations.of(context);
    try {
      if (_xray.state.running) {
        await _xray.disconnect();
      } else {
        await _xray.connect();
        // Build 2065 (item 4): a connect that stays up and
        // carries traffic becomes this network's winner.
        unawaited(_recordXrayWinnerDelayed());
      }
    } on StateError catch (e) {
      if (!context.mounted) return;
      final message = switch (e.message) {
        'no-profile' => l.noProfileSelected,
        'unsupported' => l.unsupportedProtocol,
        // Build 2127 (H2): the Sudoku engine switch is
        // off — say so plainly (Map Control copy is
        // literal English, the l10n precedent for the
        // engine-specific refusals).
        'quarantined' =>
          'This config is quarantined — restore it from the '
              'quarantine list in Settings to connect it again.',
        'sudoku-off' =>
          'Sudoku is off — enable it in Settings to connect this profile.',
        // Build 2147 (feature #6): the SSH engine switch is
        // off — the same plain-words refusal.
        'ssh-off' =>
          'SSH is off — enable it in Settings to connect this profile.',
        // Build 2127 (H1): the session dials through the
        // Zapret desync proxy (a DPI Lab win) and the proxy
        // would not start — the connect failed loudly
        // rather than blackholing through a dead port.
        'zapret-start' =>
          'The Zapret desync proxy could not start — this '
              'connection needs it (a DPI Lab strategy won '
              'on this network).',
        _ => l.startFailed,
      };
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
      _offerAlternative(context, 1, e.message);
    } catch (e) {
      if (context.mounted && _showVpnDenied(context, e)) return;
      // Build 2070 (review §3.4): the technical detail is
      // journaled — it lands in diagnostics.log, the log
      // viewer's first section — and the snackbar shows the
      // plain line instead of the raw exception.
      _xray.diagnostics.add('start', '$e', ok: false);
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(l.startFailed)));
        _offerAlternative(context, 1, '$e');
      }
    }
  }

  Future<void> _toggleLantern(BuildContext context) async {
    try {
      if (_lantern.state.running) {
        await _lantern.disconnect();
      } else {
        await _lantern.connect();
      }
    } on StateError catch (e) {
      if (!context.mounted) return;
      // Loud failure, by design: the platform's own words (the
      // core's error or the service's) reach the user, not a
      // generic line — the log tail is on the Lantern page.
      final message = _lantern.lastError ?? e.message;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            message.length > 160 ? '${message.substring(0, 160)}…' : message,
          ),
        ),
      );
      _offerAlternative(context, 3, message);
    } catch (e) {
      if (context.mounted && _showVpnDenied(context, e)) return;
      // Build 2070 (review §3.4): a plain line, not the raw
      // exception — the detail stays in the controller's
      // lastError and the engine's log page.
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).startFailed)),
        );
        // Build 2096 (post-2095 audit L8): the smart
        // alternative is offered from the generic catch
        // too, not only the StateError branch.
        _offerAlternative(context, 3, '$e');
      }
    }
  }

  /// The URnetwork engine's toggle (build 2156): the
  /// Lantern shape — loud failure with the platform's own
  /// words, the log tail on the engine's page.
  Future<void> _toggleUr(BuildContext context) async {
    try {
      if (_ur.state.running) {
        await _ur.disconnect();
      } else {
        await _ur.connect();
      }
    } on StateError catch (e) {
      if (!context.mounted) return;
      final message = _ur.lastError ?? e.message;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            message.length > 160 ? '${message.substring(0, 160)}…' : message,
          ),
        ),
      );
      _offerAlternative(context, 8, message);
    } catch (e) {
      if (context.mounted && _showVpnDenied(context, e)) return;
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).startFailed)),
        );
        _offerAlternative(context, 8, '$e');
      }
    }
  }

  Future<void> _toggleOpenVpn(BuildContext context) async {
    try {
      if (_openvpn.state.running) {
        await _openvpn.disconnect();
      } else {
        await connectOpenVpnWithPrompt(context, _openvpn);
      }
    } on StateError catch (e) {
      if (!context.mounted) return;
      // Loud failure, like Lantern's: the platform's own words
      // reach the user; the log tail is on the OpenVPN page.
      final message = _openvpn.lastError ?? e.message;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            message.length > 160 ? '${message.substring(0, 160)}…' : message,
          ),
        ),
      );
      _offerAlternative(context, 4, message);
    } catch (e) {
      if (context.mounted && _showVpnDenied(context, e)) return;
      // Build 2070 (review §3.4): a plain line, not the raw
      // exception — the detail stays in the controller's
      // lastError and the engine's log page.
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).startFailed)),
        );
        // Build 2096 (post-2095 audit L8): the smart
        // alternative is offered from the generic catch
        // too, not only the StateError branch.
        _offerAlternative(context, 4, '$e');
      }
    }
  }

  /// The WireGuard section's toggle: the Xray engine's, except
  /// a WireGuard selection connects with peer fallback.
  Future<void> _toggleWireGuard(BuildContext context) async {
    final l = AppLocalizations.of(context);
    final selected = _xray.selected;
    try {
      if (_xray.state.running) {
        await _xray.disconnect();
      } else if (selected != null && selected.protocol == Protocol.wireguard) {
        await _xray.connectWireGuardWithFallback(selected);
      } else {
        // Build 2095 (whole-app journey audit #2): no fall-
        // through to _toggleXray — the WireGuard screen's
        // power button must never connect a V2Ray profile
        // and light the V2Ray section from here.
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Select a WireGuard config first')),
          );
        }
      }
    } on StateError catch (e) {
      if (context.mounted) {
        // Build 2074 (audit item 6): the plain-sentence pattern
        // like the sibling toggles — the raw StateError message
        // (unbounded, possibly platform-localised) no longer
        // reaches the SnackBar; only the one known code keeps
        // its own plain sentence, everything else is the
        // shared start-failed line.
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              e.message == 'wg-all-peers-failed'
                  ? 'No peer of this config carried traffic'
                  : l.startFailed,
            ),
          ),
        );
        _offerAlternative(context, 5, e.message);
      }
    } catch (e) {
      if (context.mounted && _showVpnDenied(context, e)) return;
      // Build 2070 (review §3.4): a plain line, not the raw
      // exception — the detail stays in the controller's
      // lastError and the engine's log page.
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).startFailed)),
        );
        // Build 2096 (post-2095 audit L8): the smart
        // alternative is offered from the generic catch
        // too, not only the StateError branch.
        _offerAlternative(context, 5, '$e');
      }
    }
  }

  Future<void> _toggleAether(
    BuildContext context,
    AetherController controller,
  ) async {
    try {
      if (controller.tunRunning || controller.state.running) {
        await controller.disconnect();
      } else {
        await controller.connect();
      }
    } on StateError catch (e) {
      if (!context.mounted) return;
      final message = controller.lastError ?? e.message;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            message.length > 160 ? '${message.substring(0, 160)}…' : message,
          ),
        ),
      );
      _offerAlternative(context, controller == _warp ? 6 : 7, message);
    } catch (e) {
      if (context.mounted && _showVpnDenied(context, e)) return;
      // Build 2070 (review §3.4): a plain line, not the raw
      // exception — the detail stays in the controller's
      // lastError and the engine's log page.
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).startFailed)),
        );
        // Build 2096 (post-2095 audit L8): the smart
        // alternative is offered from the generic catch
        // too, not only the StateError branch.
        _offerAlternative(context, controller == _warp ? 6 : 7, '$e');
      }
    }
  }

  Future<void> _togglePsiphon(BuildContext context) async {
    final l = AppLocalizations.of(context);
    try {
      if (_psiphon.state.running) {
        await _psiphon.disconnect();
      } else {
        await _psiphon.connect();
      }
    } on StateError catch (e) {
      if (context.mounted) {
        // Build 2095 (whole-app journey audit #26): the
        // controller's own plain-language reason reaches the
        // user (truncated like the sibling toggles), not only
        // the generic start-failed line — Lantern/OpenVPN/
        // Aether already did this; Psiphon swallowed it.
        final message = _psiphon.lastError ?? e.message;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              message.length > 160 ? '${message.substring(0, 160)}…' : message,
            ),
          ),
        );
      }
    } catch (e) {
      if (context.mounted && _showVpnDenied(context, e)) return;
      // Build 2070 (review §3.4): a plain line, not the raw
      // exception — the detail stays in the controller's
      // lastError and the engine's log page.
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(l.startFailed)));
      }
    }
  }

  // -------------------------------------------------------------- state

  /// Build 2083: the Xray session's section, by the session
  /// profile's protocol — see [xraySectionActive].
  bool get _xraySessionIsWireGuard =>
      _xray.sessionProfile?.protocol == Protocol.wireguard;

  bool _engineActive(int m) {
    // Build 2092 (UI audit 2026-11-16 items 5, 35): ACTIVE
    // means connected — nothing else. Connecting has its own
    // half state (_engineConnecting, the chip's dimmed-ember
    // treatment); the chips used to light ACTIVE for the
    // whole connecting window while the bar said
    // "Connecting…". A standalone EmberWarp session
    // (warpSession) lights NEITHER Xray section: the underlay
    // is WARP's session, and sessionProfile is null for it.
    switch (m) {
      case 0:
        return core.status?.state.phase == Phase.running;
      case 1:
        return xraySectionActive(
          running: _xray.state.running && !_xray.warpSession,
          connecting: false,
          sessionIsWireGuard: _xraySessionIsWireGuard,
          wireGuardSection: false,
        );
      case 2:
        return _psiphon.state.connected;
      case 3:
        return _lantern.state.connected;
      case 4:
        return _openvpn.state.connected;
      case 5:
        return xraySectionActive(
          running: _xray.state.running && !_xray.warpSession,
          connecting: false,
          sessionIsWireGuard: _xraySessionIsWireGuard,
          wireGuardSection: true,
        );
      case 6:
        return _warp.connected;
      case 7:
        return _masque.connected;
      case 8:
        return _ur.state.connected;
    }
    return false;
  }

  /// Build 2092 (item 35): the connecting half state, per
  /// engine — the window the bottom bar calls "Connecting…".
  bool _engineConnecting(int m) {
    switch (m) {
      case 0:
        // Build 2097 (post-2096 audit C-L2): a setOn in
        // flight counts too — the phase only flips to
        // starting once the core picks the request up, and
        // the toggle's own await used to be invisible here,
        // so cross-engine arbitration could start a second
        // engine over a Mozilla that was mid-toggle.
        // Build 2098 (post-2097 audit M17): the bootstrap
        // preparation window counts too — it can run for up
        // to ~150 s before any setOn exists, and arbitration
        // used to see Mozilla as fully idle throughout it.
        return core.switchingProxy ||
            core.status?.state.phase == Phase.starting ||
            _bootstrap.busy;
      case 1:
        return xraySectionActive(
          running: false,
          connecting: _xray.connecting,
          sessionIsWireGuard: _xraySessionIsWireGuard,
          wireGuardSection: false,
        );
      case 2:
        return _psiphon.connecting ||
            (_psiphon.state.running && !_psiphon.state.connected);
      case 3:
        return _lantern.connecting ||
            ((_lantern.state.running || _lantern.state.coreRunning) &&
                !_lantern.state.connected);
      case 4:
        // Build 2096 (audit H6): the controller's busy
        // window (credential prompt, validation, start)
        // is a connecting window too — chip-tap
        // arbitration could not see it before.
        return _openvpn.connecting ||
            (_openvpn.state.running && !_openvpn.state.connected);
      case 5:
        return xraySectionActive(
          running: false,
          connecting: _xray.connecting,
          sessionIsWireGuard: _xraySessionIsWireGuard,
          wireGuardSection: true,
        );
      case 6:
        return _warp.connecting ||
            (_warp.state.running && !_warp.connected);
      case 7:
        return _masque.connecting ||
            (_masque.state.running && !_masque.connected);
      case 8:
        return _ur.connecting ||
            (_ur.state.running && !_ur.state.connected);
    }
    return false;
  }

  void _chipTap(int m) {
    // Switching to a different engine abandons a pending
    // pause-resume (build 2033): the timer must never connect
    // an engine the user has navigated away from.
    if (_pausedMode != null && m != _pausedMode) _cancelPause();
    // Same rule for a Mozilla bootstrap handoff (build 2034):
    // navigating away cancels it, and its cleanup stops the
    // donor it started.
    if (m != 0) _bootstrap.cancel();
    // Build 2095 (whole-app journey audit #1): switching to a
    // DIFFERENT engine stops the one that is running. The tap
    // used to navigate only — the old tunnel kept carrying
    // the device's traffic while the new screen's bar read
    // "Not connected" and its power button connected a second
    // engine over the live one. Moving between the V2Ray and
    // WireGuard sections (one engine) stops nothing.
    final running = _runningMode;
    if (running != null && running != m && !_sameXraySection(running, m)) {
      // Build 2096 (post-2095 audit M24): the stop joins
      // the serialization queue — unqueued, it raced the
      // power tap that followed the chip tap, and the
      // toggle evaluated state before the stop landed
      // (the "tap power twice" swallow).
      unawaited(_serialized(() => _disconnectMode(running)));
    }
    setState(() {
      if (m == mode && _tab != 0) {
        _tab = 0;
      } else {
        mode = m;
        if (_tab == 3) _tab = 0;
      }
    });
    _applyCadence();
  }

  // ------------------------------------------------------ pause (2033)

  /// The current mode's own power toggle — the same matched
  /// connect/disconnect pair the bottom bar drives.
  /// Build 2095 (feature 7): session bytes (up + down) for
  /// the engine running in [mode]; null when that engine
  /// does not report session totals.
  int? _sessionUsedBytes(int mode) {
    switch (mode) {
      case 0:
        final t = core.status?.traffic;
        return t == null ? null : t.up + t.down;
      case 1:
      case 5:
        return _xray.state.upBytes + _xray.state.downBytes;
      case 2:
        return _psiphon.state.upBytes + _psiphon.state.downBytes;
      case 3:
        // Build 2096 (post-2095 audit M19): engines whose
        // state carries no counters report null (unknown),
        // not 0 — 0 made the verdict permanently "ok" and
        // the cap silently inert on those engines.
        return _lantern.state.countersReported
            ? _lantern.state.upBytes + _lantern.state.downBytes
            : null;
      case 4:
        return _openvpn.state.countersReported
            ? _openvpn.state.upBytes + _openvpn.state.downBytes
            : null;
      case 6:
        return _warp.upBytes + _warp.downBytes;
      case 7:
        return _masque.upBytes + _masque.downBytes;
      case 8:
        // Build 2156: the same M19 rule as Lantern — no
        // counters in the snapshot, no verdict.
        return _ur.state.countersReported
            ? _ur.state.upBytes + _ur.state.downBytes
            : null;
      default:
        return null;
    }
  }

  /// Build 2105: the battery-report sampler. While the
  /// report is enabled, each tick notes the connected engine
  /// (if any) into the session tracker, which records the
  /// battery level at each session's edges (battery_report
  /// .dart). Disabled costs one field read; the log and the
  /// tracker are built lazily on the first enabled tick, and
  /// toggling off closes any open session.
  BatteryLog? _batteryLog;
  BatterySessionTracker? _batteryTracker;
  bool _batteryLogLoading = false;

  bool _batteryTickBusy = false;

  Future<void> _batteryTick() async {
    // One tick at a time: the ticks are unawaited on a 5 s
    // timer, and a battery read stalled past one interval
    // would otherwise let two ticks note() engines out of
    // order (a stale label closing the new engine's session).
    // A sampler skips a beat; it never queues them.
    if (_batteryTickBusy) return;
    _batteryTickBusy = true;
    try {
      await _batteryTickInner();
    } finally {
      _batteryTickBusy = false;
    }
  }

  Future<void> _batteryTickInner() async {
    if (!widget.settings.batteryReportEnabled) {
      _batteryTracker?.closeOpen(DateTime.now().millisecondsSinceEpoch);
      _batteryTracker = null;
      return;
    }
    if (_batteryTracker == null) {
      if (_batteryLogLoading) return;
      _batteryLogLoading = true;
      try {
        _batteryLog ??= await BatteryLog.loadDefault();
      } catch (_) {
        // The load is retried on a later tick (BatteryLog does
        // not cache the failure); the flag must reset either
        // way or no tick would ever retry.
        _batteryLogLoading = false;
        return;
      }
      _batteryLogLoading = false;
      _batteryTracker = BatterySessionTracker(
        onSession: (record) {
          final log = _batteryLog;
          if (log != null) unawaited(log.add(record));
        },
      );
    }
    String? label;
    for (var m = 0; m <= 8; m++) {
      if (_engineActive(m)) {
        label = _engineLabel(m);
        break;
      }
    }
    // A standalone EmberWarp session lights neither Xray
    // section (see _engineActive) but is a running engine. It
    // keeps its own name (build 2071's doctrine): folding it
    // into the Aether WARP row would misattribute its drain.
    if (label == null && _xray.state.running && _xray.warpSession) {
      label = 'EmberWarp';
    }
    final reading = await readBatteryStatus();
    if (!mounted) return;
    _batteryTracker?.note(
      engine: label,
      nowMs: DateTime.now().millisecondsSinceEpoch,
      reading: reading,
    );
  }

  /// Build 2095 (feature 7): the data-budget tick — warns
  /// once at 80% of the cap and disconnects the running
  /// engine at the cap. Off (cap 0) costs one field read.
  void _budgetTick() {
    final capMb = widget.settings.sessionBudgetMb;
    final mode = _runningMode;
    if (capMb <= 0 || mode == null) {
      _budgetWarned = false;
      _budgetUnmeasurableNotedFor = null;
      _budgetDisconnecting = false;
      _budgetLastUsedBytes = null;
      return;
    }
    final used = _sessionUsedBytes(mode);
    if (used != null) {
      // Build 2098 (post-2097 audit L26): a counter DROP
      // means the session restarted — the disconnect this
      // tick chain issued (or the user) ended one session
      // and a new one began inside a single 5 s tick, so no
      // tick ever saw "no session" and cleared the episode
      // flags; the new session's own exceed then hit the
      // still-set _budgetDisconnecting and never fired.
      // Session counters are cumulative and monotonic
      // within a session, so a drop is a new episode:
      // re-arm both once-flags.
      final last = _budgetLastUsedBytes;
      if (last != null && used < last) {
        _budgetDisconnecting = false;
        _budgetWarned = false;
      }
      _budgetLastUsedBytes = used;
    }
    if (used == null) {
      // Build 2096 (post-2095 audit M19): say once per
      // session that the cap cannot be measured on this
      // engine, instead of silently never applying it.
      if (_budgetUnmeasurableNotedFor != mode && mounted) {
        _budgetUnmeasurableNotedFor = mode;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'The data budget cannot be measured on '
              '${emergencyModeNames[mode] ?? 'this engine'} — '
              'the cap will not apply to this session.',
            ),
          ),
        );
      }
      return;
    }
    // A measurable reading re-arms the unmeasurable note
    // (build 2097, audit L-k).
    _budgetUnmeasurableNotedFor = null;
    switch (sessionBudgetVerdict(usedBytes: used, capMb: capMb)) {
      case BudgetVerdict.warn:
        if (!_budgetWarned && mounted) {
          _budgetWarned = true;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Data budget: ${fmtBytes(used)} of '
                '${latDigits(capMb)} MB used this session',
              ),
            ),
          );
        }
      case BudgetVerdict.exceeded:
        _budgetWarned = false;
        // Build 2097 (post-2096 audit L-n): once per
        // exceeded episode — build 2096 re-showed the
        // message and re-issued the disconnect on every
        // 5 s tick while the stop was still in flight.
        if (_budgetDisconnecting) return;
        _budgetDisconnecting = true;
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Data budget reached — disconnecting.'),
            ),
          );
        }
        // Build 2098 (post-2097 audit L27): through the
        // shell's serializer, like every other disconnect
        // the shell issues — the raw unawaited call used to
        // race a toggle the user tapped in the same moment.
        unawaited(_serialized(() => _disconnectMode(mode)));
      case BudgetVerdict.ok:
        // Build 2096 (post-2095 audit M25): the warn-once
        // flag resets when the verdict returns to ok —
        // build 2095 only reset it on the exceeded path,
        // so raising the cap mid-session silenced the 80%
        // warning for the new cap entirely.
        _budgetWarned = false;
    }
  }

  /// Build 2095 (feature 9): when a connect failure looks
  /// like blocking, offer the likely-working alternative
  /// with one tap. Never auto-connects — the tap is the
  /// user's.
  void _offerAlternative(
    BuildContext context,
    int failedMode,
    String errorText,
  ) {
    final alt = alternativeForFailure(failedMode, errorText);
    if (alt == null || !context.mounted) return;
    final (altMode, label) = alt;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text(
          'This failure looks like blocking — another engine may pass.',
        ),
        duration: const Duration(seconds: 8),
        action: SnackBarAction(
          label: label,
          onPressed: () {
            _chipTap(altMode);
            unawaited(_powerToggle(context, altMode));
          },
        ),
      ),
    );
  }

  /// Build 2095 (feature 1): one emergency attempt — stop
  /// whatever holds the tunnel, toggle [m], then poll for
  /// the engine's own active signal as the proof. The
  /// logic lives in [runEmergencyAttempt] (emergency.dart)
  /// so it is testable without the shell; build 2096
  /// (post-2095 audit H7/H8/L2) repaired it there: the
  /// proof credits either Xray section, a cancel acts on
  /// an in-flight toggle, and the proof must hold.
  Future<bool> _emergencyAttempt(BuildContext context, int m) =>
      runEmergencyAttempt(
        mode: m,
        runningMode: _runningMode,
        disconnectMode: _disconnectMode,
        toggle: (mode) => _toggleForMode(context, mode),
        engineActive: _engineActive,
        cancelled: () => _emergencyCancel,
        onXraySection: (s) => _emergencyXraySection = s,
      );

  /// Build 2095 (feature 1): the emergency walk — engines
  /// in [emergencyModeOrder] until one proves a connect.
  /// Psiphon is skipped (parked). Cancellable throughout.
  Future<void> _runEmergency() =>
      _serialized(_runEmergencyInner);

  Future<void> _runEmergencyInner() async {
    if (_emergencyRunning) return;
    // Build 2098 (post-2097 audit L29): a tap while an
    // engine runs used to no-op silently — the button
    // looked dead. It says why now.
    if (_runningMode != null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Emergency connect needs every engine off — '
              'disconnect the running one first.',
            ),
          ),
        );
      }
      return;
    }
    _emergencyRunning = true;
    _emergencyCancel = false;
    _emergencyXraySection = 1;
    final progress = ValueNotifier<String>('Starting…');
    var dialogOpen = true;
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          title: Text('Emergency connect', style: Ember.heading),
          content: ValueListenableBuilder<String>(
            valueListenable: progress,
            builder: (_, v, _) => Text(v, style: Ember.body),
          ),
          actions: [
            TextButton(
              onPressed: () {
                // Build 2096 (post-2095 audit L1): Cancel
                // only FLAGS the cancel — the walk below is
                // the single pop site. Build 2095 popped
                // here AND after the walk; when the walk
                // returned before whenComplete fired, the
                // second pop removed the route UNDER the
                // dialog. With H8 the flagged cancel unwinds
                // the in-flight attempt promptly, so the
                // dialog closes a moment later, once.
                _emergencyCancel = true;
                progress.value = 'Stopping…';
              },
              child: const Text('Cancel'),
            ),
          ],
        ),
      ).whenComplete(() => dialogOpen = false),
    );
    final winner = await runEmergencyWalk(
      order: emergencyModeOrder,
      cancelled: () => _emergencyCancel,
      onTry: (m) => progress.value =
          'Trying ${emergencyModeNames[m]}…\n'
          'Psiphon is skipped — its connection work is parked.',
      attempt: (m) => _emergencyAttempt(context, m),
      // Build 2098 (post-2097 audit L5): a winner cancelled
      // in its final moment is disconnected, not declared.
      disconnectMode: (m) => _disconnectMode(m),
    );
    if (dialogOpen && mounted) Navigator.of(context).pop();
    _emergencyRunning = false;
    if (!mounted) return;
    // Build 2096 (audit H7): report the section that
    // actually lit — a WireGuard config can win under the
    // V2Ray attempt and vice versa.
    final winnerMode = winner == null
        ? null
        : (winner == 1 || winner == 5)
            ? _emergencyXraySection
            : winner;
    if (winnerMode != null) {
      _chipTap(winnerMode);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Connected via ${emergencyModeNames[winnerMode]}'),
        ),
      );
    } else if (!_emergencyCancel) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'No engine connected — check your configs and the network.',
          ),
        ),
      );
    }
  }

  Future<void> _toggleForMode(BuildContext context, int m) {
    switch (m) {
      case 0:
        return _toggleMozilla(context);
      case 1:
        return _toggleXray(context);
      case 2:
        return _togglePsiphon(context);
      case 3:
        return _toggleLantern(context);
      case 4:
        return _toggleOpenVpn(context);
      case 5:
        return _toggleWireGuard(context);
      case 6:
        return _toggleAether(context, _warp);
      case 7:
        return _toggleAether(context, _masque);
      case 8:
        return _toggleUr(context);
    }
    return Future<void>.value();
  }

  bool get _anyEngineActive =>
      _engineActive(0) ||
      _engineActive(1) ||
      _engineActive(2) ||
      _engineActive(3) ||
      _engineActive(4) ||
      // Build 2083: case 5 is disjoint from case 1 since the
      // chip split, so it must be counted here explicitly.
      _engineActive(5) ||
      _engineActive(6) ||
      _engineActive(7) ||
      _engineActive(8);

  /// Build 2095 (verification loop, third-pass audit 2.2
  /// shell half): an engine CONNECTING counts for the
  /// auto-connect / resume / chain decisions too — those
  /// guards used to see only connected engines, so a
  /// pause timer expiring during a manual connect queued
  /// a toggle that switched the just-established session
  /// straight back off. (The serialization queue and the
  /// controllers' re-entry guards already prevented two
  /// tunnels; this closes the toggle-semantics hole.)
  bool get _anyEngineConnecting =>
      _engineConnecting(0) ||
      _engineConnecting(1) ||
      _engineConnecting(2) ||
      _engineConnecting(3) ||
      _engineConnecting(4) ||
      _engineConnecting(5) ||
      _engineConnecting(6) ||
      _engineConnecting(7) ||
      _engineConnecting(8);

  /// Build 2095 (whole-app journey audit #1): the mode whose
  /// engine is actually carrying (or starting) a session, or
  /// null when nothing is up. The Aether slots are checked
  /// before the Xray engine: their TUN rides the shared VPN
  /// service, and their own controllers are the authority on
  /// their sessions. Modes 1 and 5 are the same Xray engine —
  /// the session profile's protocol decides which section
  /// owns it; a standalone EmberWarp session (warpSession)
  /// belongs to neither section but IS a running Xray engine,
  /// reported as 1 so a chip switch or the power capsule
  /// stops it instead of leaving it running behind another
  /// screen's "Not connected" bar.
  int? get _runningMode {
    if (_engineActive(0) || _engineConnecting(0)) return 0;
    if (_engineActive(6) || _engineConnecting(6)) return 6;
    if (_engineActive(7) || _engineConnecting(7)) return 7;
    if (_xray.state.running || _xray.connecting) {
      if (_xray.warpSession) return 1;
      return _xraySessionIsWireGuard ? 5 : 1;
    }
    if (_engineActive(2) || _engineConnecting(2)) return 2;
    if (_engineActive(3) || _engineConnecting(3)) return 3;
    if (_engineActive(4) || _engineConnecting(4)) return 4;
    if (_engineActive(8) || _engineConnecting(8)) return 8;
    return null;
  }

  /// Build 2116 (B7-1, AB-08): foreground re-arbitration
  /// against the native VPN-slot claim. Engine starts that
  /// bypass Dart (the QS tile, an Xray notification resume,
  /// a WG Tunnel resurrection) claim the slot natively; when
  /// the app returns to the foreground the shell makes its
  /// mode agree with the slot's owner:
  ///   - the claimed engine is verifiably live (per the
  ///     controllers' own state, via [_runningMode]) and is
  ///     not the mode on screen → the shell adopts its mode;
  ///   - nothing is live → the marker outlived its session
  ///     (a killed process) and is cleared, so it cannot
  ///     mislead the next native start;
  ///   - a DIFFERENT engine is live → the shell does NOT
  ///     switch away from the live session, but the marker
  ///     itself is stale and is CORRECTED to name the live
  ///     engine (build 2125, audit A25-17 / P-24): up to
  ///     2124 this branch fell through doing nothing, so
  ///     every later native reader of the marker (the WG
  ///     stand-down, the next claim's displacement) acted
  ///     on the wrong owner until some start overwrote it.
  Future<void> _reArbitrateFromClaim() async {
    final owner = await EngineClaimChannel.owner();
    if (owner == null || !mounted) return;
    const families = <String, Set<int>>{
      'mozilla': {0},
      'xray': {1, 5, 6, 7},
      // Build 2119 (audit F-04): the XrayVpnService-hosted
      // kinds claim under their own names now — the
      // standalone WARP session is mode 6's engine, the
      // Aether tunnel serves the WARP/MASQUE modes.
      'warp': {6},
      'aether': {6, 7},
      'wireguard': {5},
      'psiphon': {2},
      'lantern': {3},
      'openvpn': {4},
      // Build 2156: the URnetwork engine claims under its
      // EngineClaim name, like the other own-process engines.
      'urnetwork': {8},
    };
    final family = families[owner];
    if (family == null) {
      await EngineClaimChannel.clear();
      return;
    }
    if (family.contains(mode)) return;
    final running = _runningMode;
    if (running != null && family.contains(running)) {
      setState(() => mode = running);
    } else if (running == null) {
      await EngineClaimChannel.clear();
    } else {
      // Build 2125 (audit A25-17 / P-24): a different
      // engine is verifiably live while the marker names
      // [owner] — the marker is stale. The shell stays on
      // the live session (no mode switch), and the marker
      // is corrected to the live engine's claim name so
      // native readers stop acting on the lie.
      final liveName = _liveClaimName;
      if (liveName != null && liveName != owner) {
        await EngineClaimChannel.setOwner(liveName);
      }
    }
  }

  /// Build 2125 (audit A25-17 / P-24): the EngineClaim
  /// name of the engine verifiably live right now, per the
  /// same controller evidence [_runningMode] reads — or
  /// null when nothing is live. The Xray carrier's three
  /// hosted kinds are told apart by the session flags (the
  /// WG Tunnel backend reports through the Xray state as
  /// `awgSession`; a standalone EmberWarp session is
  /// `warpSession`), and the Aether slots both claim
  /// AETHER natively.
  String? get _liveClaimName {
    // Build 2126 (audit A26-14): ACTIVE only — a merely
    // CONNECTING engine does not count as live here. The
    // 2125 getter counted connecting too, so the marker
    // could be rewritten to an engine that then never
    // established, naming a dead engine as the slot's
    // owner. A connecting engine claims for itself in
    // its own start path; this rewrite exists to correct
    // the marker toward a session that verifiably runs.
    if (_engineActive(0)) return 'mozilla';
    if (_engineActive(6)) return 'aether';
    if (_engineActive(7)) return 'aether';
    if (_xray.state.running) {
      if (_xray.awgSession) return 'wireguard';
      if (_xray.warpSession) return 'warp';
      return 'xray';
    }
    if (_engineActive(2)) return 'psiphon';
    if (_engineActive(3)) return 'lantern';
    if (_engineActive(4)) return 'openvpn';
    if (_engineActive(8)) return 'urnetwork';
    return null;
  }

  /// Modes 1 and 5 are one engine (the Xray carrier's two
  /// sections): moving between them, or powering one while
  /// the other section's session runs, is the SAME engine.
  static bool _sameXraySection(int a, int b) =>
      (a == 1 || a == 5) && (b == 1 || b == 5);

  // ------------------------------------- build 2065: fallback chain
  // (item 5), per-network winner memory (item 4), auto-connect
  // triggers (item 14), scheduled subscription health (item 12).

  StreamSubscription<NetworkIdentity>? _netSub;
  StreamSubscription<void>? _rotateSub;
  StreamSubscription<void>? _screenOffSub;
  StreamSubscription<OvpnIntentFile>? _ovpnFileSub;
  StreamSubscription<String>? _shortcutSub;
  StreamSubscription<String>? _deepLinkSub;
  Timer? _healthTimer;
  // Build 2095 (feature 7): the session data budget tick.
  Timer? _budgetTimer;
  bool _budgetWarned = false;

  /// Build 2098 (post-2097 audit L26): the previous
  /// tick's session byte count — a drop means the
  /// session restarted inside one tick (see _budgetTick).
  int? _budgetLastUsedBytes;

  /// Build 2096 (audit M19): the unmeasurable-budget
  /// note fires once per session. Build 2097 (post-2096
  /// audit L-k): keyed by MODE, not a bare bool — build
  /// 2096 reset it only on the no-session early return,
  /// so a direct engine switch (the running mode never
  /// read null between ticks) carried the note's
  /// suppression into the next session, which then never
  /// got its note. A measurable reading clears it too.
  int? _budgetUnmeasurableNotedFor;

  /// Build 2097 (post-2096 audit L-n): a budget-exceeded
  /// disconnect is in flight — the tick must not re-show
  /// the message and re-issue the disconnect every 5 s
  /// until the engine reports off.
  bool _budgetDisconnecting = false;
  // Build 2095 (feature 1): emergency-walk state.
  bool _emergencyRunning = false;
  bool _emergencyCancel = false;

  /// Build 2096 (post-2095 audit H7): the Xray section an
  /// emergency attempt actually lit (1 V2Ray / 5 WireGuard)
  /// — a WireGuard config connects under either attempt.
  int _emergencyXraySection = 1;
  String _currentNetworkKey = '';

  /// The cross-engine chain's live status line, shown above the
  /// power bar while a chain run is in flight (and briefly after).
  String _chainStatus = '';
  bool _chainRunning = false;

  static String _engineLabel(int m) => switch (m) {
    0 => 'Mozilla',
    1 => 'V2Ray',
    2 => 'Psiphon',
    3 => 'Lantern',
    4 => 'OpenVPN',
    5 => 'WireGuard',
    6 => 'WARP',
    7 => 'MASQUE',
    8 => 'URnetwork',
    _ => 'Engine',
  };

  // Build 2095 (third-pass audit 2.3): shell-level connect
  // serialization. Two top-level connect entries landing in
  // the same frame (a shortcut tap racing auto-connect, a
  // notification rotate racing a power tap) each passed
  // their own "nothing is running" check and interleaved
  // at the controller awaits — the native services got
  // concurrent start requests for two engines. Top-level
  // entries now chain through one queue; the internals
  // (_toggleForMode, chain steps, emergency attempts) call
  // the un-queued helpers directly, so nothing deadlocks.
  Future<void> _connectQueue = Future<void>.value();

  Future<T> _serialized<T>(Future<T> Function() op) {
    final run = _connectQueue.then((_) => op());
    _connectQueue = run.then((_) {}, onError: (_) {});
    return run;
  }

  /// The power capsule's single entry point (build 2065): a
  /// power-off always goes to the current engine's own toggle; a
  /// power-on routes through the fallback chain when the owner
  /// enabled it and the current engine is part of the chain.
  Future<void> _powerToggle(BuildContext context, int m) =>
      _serialized(() => _powerToggleInner(context, m));

  Future<void> _powerToggleInner(BuildContext context, int m) async {
    if (_chainRunning) return;
    // Build 2095 (whole-app journey audit #1): the capsule
    // acts on the engine that is actually running. When a
    // DIFFERENT engine holds the tunnel, power disconnects
    // THAT engine — it used to toggle the selected mode,
    // which connected a second engine over the live one and
    // left the bar claiming "Not connected" for a screen
    // whose traffic still flowed through the old tunnel.
    final running = _runningMode;
    if (running != null) {
      if (running == m || _sameXraySection(running, m)) {
        await _toggleForMode(context, m);
      } else {
        await _disconnectMode(running);
      }
      return;
    }
    final s = widget.settings;
    if (s.fallbackChainEnabled && s.fallbackChain.contains(m)) {
      await _connectWithChain(context);
      return;
    }
    await _toggleForMode(context, m);
  }

  /// One engine's raw connect with a hard budget. Returns true
  /// only when the engine reports itself up afterwards. A connect
  /// that outlives its budget is treated as failed and stopped by
  /// the caller before the next engine starts (single-engine
  /// rule). The chain advances on CONNECT failure only — a tunnel
  /// that drops later belongs to auto-reconnect and the kill
  /// switch, not to the chain.
  /// Build 2095 (third-pass audit 2.4): runs one engine's
  /// connect under a budget COOPERATIVELY. The old
  /// .timeout() wrapper abandoned the future at the budget
  /// while the connect kept running underneath — its late
  /// setOn could land after the next engine started. On
  /// budget expiry this disconnects the engine (which bumps
  /// its generation, cancelling the attempt) and waits for
  /// the abandoned future to actually settle, bounded by a
  /// second 10 s window, before reporting failure.
  Future<bool> _connectWithBudget(
    int m,
    Future<void> connect,
    Duration budget,
  ) async {
    var done = false;
    Object? error;
    unawaited(
      connect.then(
        (_) => done = true,
        onError: (Object e) {
          done = true;
          error = e;
        },
      ),
    );
    final sw = Stopwatch()..start();
    while (!done && sw.elapsed < budget) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    if (!done) {
      await _disconnectMode(m);
      final sw2 = Stopwatch()..start();
      while (!done && sw2.elapsed < const Duration(seconds: 10)) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
    return done && error == null;
  }

  Future<bool> _tryConnectMode(int m) async {
    try {
      switch (m) {
        case 0:
          if (!await _connectWithBudget(
            m,
            core.setOn(true),
            const Duration(seconds: 45),
          )) {
            return false;
          }
          for (var i = 0; i < 20; i++) {
            if (core.status?.state.phase == Phase.running) return true;
            if (core.status?.state.phase == Phase.off) break;
            await Future<void>.delayed(const Duration(milliseconds: 500));
          }
          return core.status?.state.phase == Phase.running;
        case 1:
        case 5:
          if (!await _connectWithBudget(
            m,
            _xray.connect(),
            const Duration(seconds: 60),
          )) {
            return false;
          }
          return _xray.state.running;
        case 2:
          if (!await _connectWithBudget(
            m,
            _psiphon.connect(),
            const Duration(seconds: 150),
          )) {
            return false;
          }
          return _psiphon.state.running;
        case 3:
          if (!await _connectWithBudget(
            m,
            _lantern.connect(),
            const Duration(seconds: 90),
          )) {
            return false;
          }
          return _lantern.state.running;
        case 4:
          if (!await _connectWithBudget(
            m,
            _openvpn.connect(),
            const Duration(seconds: 60),
          )) {
            return false;
          }
          return _openvpn.state.running;
        case 6:
          if (!await _connectWithBudget(
            m,
            _warp.connect(),
            const Duration(seconds: 60),
          )) {
            return false;
          }
          return _warp.connected;
        case 7:
          if (!await _connectWithBudget(
            m,
            _masque.connect(),
            const Duration(seconds: 60),
          )) {
            return false;
          }
          return _masque.connected;
      }
    } catch (_) {
      return false;
    }
    return false;
  }

  Future<void> _disconnectMode(int m) async {
    try {
      switch (m) {
        case 0:
          // Build 2097 (post-2096 audit N1): cancel an
          // in-flight bootstrap preparation too — _stopMozilla
          // no-ops while the core is neither running nor
          // starting (the donor handoff is still running),
          // and the toggle then proceeded to setOn AFTER the
          // stop. The bootstrap's generation check turns the
          // cancel into a cancelled verdict, and the toggle
          // returns before setOn.
          _bootstrap.cancel();
          await _stopMozilla();
        case 1:
        case 5:
          // Build 2095: connecting counts too — disconnect()
          // is generation-guarded, so calling it mid-connect
          // aborts the attempt instead of letting it complete
          // behind the screen the user switched to.
          if (_xray.state.running || _xray.connecting) {
            await _xray.disconnect();
          }
        case 2:
          await _stopPsiphon();
        case 3:
          await _stopLantern();
        case 4:
          await _stopOpenVpn();
        case 6:
        case 7:
          await _stopAether();
        case 8:
          await _stopUr();
      }
    } catch (_) {
      // A failed stop must not wedge the chain; the next engine's
      // own stopOtherEngine arbitration is the backstop.
    }
  }

  /// The cross-engine fallback run (build 2065, item 5): tries the
  /// owner's chain starting from the selected engine, each with
  /// its own budget, until one connects. Bounded by the chain
  /// length — no loops.
  Future<void> _connectWithChain(BuildContext context) async {
    if (_chainRunning || _anyEngineActive || _anyEngineConnecting) return;
    final chain = widget.settings.fallbackChain;
    if (chain.isEmpty) return;
    final start = mode;
    final idx = chain.indexOf(start);
    final order = idx >= 0
        ? [...chain.sublist(idx), ...chain.sublist(0, idx)]
        : [...chain];
    _chainRunning = true;
    try {
      for (var i = 0; i < order.length; i++) {
        final m = order[i];
        if (!mounted) return;
        setState(() {
          mode = m;
          // Build 2074 (audit item 27): the counts route
          // through latDigits like every displayed number.
          _chainStatus =
              'Fallback chain: trying ${_engineLabel(m)} '
              '(${latDigits(i + 1)} of ${latDigits(order.length)}) — '
              '${order.map(_engineLabel).join(' → ')}';
        });
        _applyCadence();
        final ok = await _tryConnectMode(m);
        if (ok) {
          if (mounted) {
            setState(
              () => _chainStatus =
                  'Fallback chain: connected via ${_engineLabel(m)}',
            );
          }
          if (m == 1 || m == 5) unawaited(_recordXrayWinnerDelayed());
          return;
        }
        await _disconnectMode(m);
      }
      if (mounted) {
        setState(
          () => _chainStatus =
              'Fallback chain: every engine failed on this network',
        );
      }
    } finally {
      _chainRunning = false;
    }
  }

  /// Records the Xray winner for the current network once the
  /// tunnel has had time to prove it carries traffic (item 4).
  Future<void> _recordXrayWinnerDelayed() async {
    await Future<void>.delayed(const Duration(seconds: 10));
    if (!mounted) return;
    final st = _xray.state;
    if (st.running &&
        st.upBytes + st.downBytes > 0 &&
        _currentNetworkKey.isNotEmpty) {
      await _xray.rememberWinnerForNetwork(_currentNetworkKey);
    }
  }

  bool _isTrustedNetwork(NetworkIdentity id) =>
      id.isWifi &&
      id.ssid.isNotEmpty &&
      widget.settings.trustedSsids.contains(id.ssid);

  /// Applies a network identity: keys the winner memories,
  /// preselects the remembered Xray profile, and fires the
  /// auto-connect triggers the owner enabled (item 14).
  /// Build 2125 (audit A25-29 / P-34): arms the 5 s
  /// budget/battery timer while either feature is on and
  /// disarms it when both are off. Called at start and on
  /// every settings change.
  void _syncBudgetTimer() {
    final needed =
        widget.settings.sessionBudgetMb > 0 ||
        widget.settings.batteryReportEnabled;
    if (needed && _budgetTimer == null) {
      _budgetTimer = Timer.periodic(const Duration(seconds: 5), (_) {
        _budgetTick();
        // Build 2105: the battery sampler rides the same
        // 5 s tick (its own toggle gates it; off costs one
        // read).
        unawaited(_batteryTick());
      });
    } else if (!needed && _budgetTimer != null) {
      _budgetTimer?.cancel();
      _budgetTimer = null;
    }
  }

  /// Build 2125 (audit A25-45 / P-49): network-change
  /// handling is SERIALIZED on its own queue — up to 2124
  /// two runs could overlap (Wi-Fi↔mobile flapping), and
  /// the slower, old-network run could land last and key
  /// the per-network winner memories / preselection to
  /// the network just left. The queue is DEDICATED: the
  /// body calls _autoConnect, which serializes on
  /// _connectQueue — sharing that queue would deadlock.
  Future<void> _networkQueue = Future<void>.value();

  Future<void> _handleNetwork(
    NetworkIdentity id, {
    required bool initial,
  }) {
    final run = _networkQueue.then(
      (_) => _handleNetworkInner(id, initial: initial),
    );
    _networkQueue = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<void> _handleNetworkInner(
    NetworkIdentity id, {
    required bool initial,
  }) async {
    final changed = !initial && id.key != _currentNetworkKey;
    _currentNetworkKey = id.key;
    _psiphon.settings.networkKey = id.key;
    // Build 2066: edge results measured on the old network are
    // void on the new one — the next Psiphon connect re-probes
    // before feeding anything to the core at probability 1.0.
    if (changed) unawaited(_psiphon.invalidateEdgeResults());
    _xray.preselectForNetwork(id.key);
    // Routing by network type (build 2075, feature item 26):
    // the active preset follows the transport when enabled.
    unawaited(_xray.applyRoutingForNetwork(id));
    unawaited(_xray.maybeRunScheduledHealth());
    final s = widget.settings;
    if (!s.emberAutoConnect ||
        _anyEngineActive ||
        _anyEngineConnecting ||
        _chainRunning) {
      return;
    }
    if (initial) {
      final booted = await NetworkInfoService.consumeBootPending();
      if (booted && s.autoConnectOnBoot) {
        await _autoConnect();
        return;
      }
      if (s.autoConnectOnUntrustedWifi && id.isWifi && !_isTrustedNetwork(id)) {
        await _autoConnect();
      }
      return;
    }
    if (changed &&
        ((s.autoConnectOnNetworkChange && !_isTrustedNetwork(id)) ||
            // Build 2095 (V2Ray journey audit #2): the
            // untrusted-Wi-Fi trigger is evaluated on network
            // CHANGES too — it used to be read only in the
            // initial branch above, so joining an untrusted
            // Wi-Fi while the app was already running never
            // fired unless the separate network-change
            // toggle was also on.
            (s.autoConnectOnUntrustedWifi &&
                id.isWifi &&
                !_isTrustedNetwork(id)))) {
      await _autoConnect();
    }
  }

  Future<void> _autoConnect() => _serialized(_autoConnectInner);

  Future<void> _autoConnectInner() async {
    if (!mounted || _anyEngineActive || _anyEngineConnecting || _chainRunning) {
      return;
    }
    // Build 2095 (whole-app journey audit #5): an automatic
    // connect never starts behind the lock page; it replays
    // after the unlock if nothing is running by then.
    if (_lockedNow) {
      _pendingAutoConnect = true;
      return;
    }
    final s = widget.settings;
    if (s.fallbackChainEnabled && s.fallbackChain.contains(mode)) {
      await _connectWithChain(context);
    } else {
      await _toggleForMode(context, mode);
    }
  }

  /// The V2Ray notification's Switch-server action (build
  /// 2075, feature item 12): switch the live V2Ray session
  /// to the next member of its fallback group — seamlessly
  /// when the session can rotate, through a full connect
  /// otherwise. Engines without rotation still reach this
  /// handler when their notification carries the action —
  /// since build 2104 the AmneziaWG notification carries
  /// Switch-server too, and for such a session the switch
  /// below takes the full-connect path (verification
  /// iteration 2, L7: the previous "Disconnect only" claim
  /// went stale with the WG Tunnel port).
  Future<void> _notificationRotate() =>
      _serialized(_notificationRotateInner);

  Future<void> _notificationRotateInner() async {
    // Build 2095 (whole-app journey audit #5): a notification
    // action never executes behind the lock page.
    if (_lockedNow) {
      _pendingRotate = true;
      return;
    }
    // Build 2096 (post-2095 audit M7): the connecting
    // guard the verification-pass record claimed for this
    // decision point — a background notification action
    // never fights an in-flight connect.
    if (_anyEngineConnecting) return;
    if (!_xray.state.running) return;
    // Build 2106 (journey audit F-03): the switch is
    // anchored to the LIVE session's profile, never the UI
    // selection — builds ≤2105 keyed off _xray.selected, so
    // a selection changed after connecting computed the
    // switch against the wrong server entirely.
    final current = _xray.sessionProfile;
    if (current == null) {
      // A session with no Xray/WireGuard profile of its
      // own (a standalone WARP session) has nothing to
      // switch to — say so (build 2106, verification
      // iteration 1, L4) instead of returning silently;
      // builds ≤2105 keyed off the selection here and
      // could hijack the session into an unrelated
      // connect.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Server switching is not available for this session',
            ),
          ),
        );
      }
      return;
    }
    if (current.protocol == Protocol.wireguard) {
      // A WireGuard session switches WITHIN its own peer
      // group (the imported config's sibling peers — the
      // same group the connect-time peer walk walks), never
      // the app-wide subscription fallback order: that order
      // could jump the user to an unrelated V2Ray profile,
      // or claim "No other server in this group" while WG
      // peers exist (build 2106, F-03). The step is the
      // group's NEXT peer, cyclically (verification L3).
      final nextWg = nextWgPeer(_xray.profiles, current);
      if (nextWg == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No other server in this group')),
          );
        }
        return;
      }
      if (await _xray.switchServer(nextWg)) return;
      _xray.select(nextWg);
      await _xray.connect();
      return;
    }
    final candidates = _xray.fallbackCandidates(current);
    if (candidates.isEmpty) {
      // Build 2095 (whole-app journey audit #22): the tap
      // used to just open the app and silently do nothing
      // for a profile with no fallback group — say so.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No other server in this group')),
        );
      }
      return;
    }
    final next = candidates.first;
    if (await _xray.switchServer(next)) return;
    _xray.select(next);
    await _xray.connect();
  }

  /// An .ovpn file opened with / shared to Ember (build 2085,
  /// audit F-H15): switch to the OpenVPN list and import it
  /// through the same path the file/paste buttons use, so the
  /// user sees the imported profile (or the named failure).
  /// Switching engines abandons a pending pause-resume and a
  /// Mozilla bootstrap handoff, exactly as a manual engine
  /// switch does (see _chipTap).
  /// Build 2095 (whole-app journey audit #38): a config
  /// link opened from another app routes through the same
  /// import paths as a scan — and queues behind the lock
  /// like every other non-UI entry point (audit #5).
  Future<void> _importDeepLink(String link) async {
    if (_lockedNow) {
      _pendingDeepLinks.add(link);
      return;
    }
    await importScannedCode(context, _xray, link);
  }

  Future<void> _importOpenVpnIntent(OvpnIntentFile file) async {
    if (!mounted) return;
    // Build 2095 (whole-app journey audit #5): an incoming
    // file never imports behind the lock page; it replays
    // after the unlock.
    if (_lockedNow) {
      _pendingOvpnFiles.add(file);
      return;
    }
    if (file.isError) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ovpnIntakeErrorText(file.error!))),
      );
      return;
    }
    // Build 2102 (wg-ipv6-import-diagnosis.md, I1): the
    // intake is content-routed — a shared/opened WireGuard
    // .conf goes to the WireGuard importer, not the OpenVPN
    // one. Builds ≤2101 forwarded EVERY file here, so a
    // .conf shared from Telegram/Files landed on the
    // OpenVPN tab and failed with "Import failed". The gate
    // is the shared isWgConfText — the same rule the scan
    // intake (importScannedCode) routes by.
    if (isWgConfText(file.content)) {
      if (_pausedMode != null) _cancelPause();
      _bootstrap.cancel();
      setState(() {
        mode = 5;
        _tab = 1;
      });
      var base = file.name;
      final lower = base.toLowerCase();
      if (lower.endsWith('.conf') || lower.endsWith('.ovpn')) {
        base = base.substring(0, base.length - 5);
      }
      if (base.trim().isEmpty) base = 'WireGuard';
      await importWgConfText(
        context,
        _xray,
        file.content,
        suggestedName: base,
      );
      return;
    }
    if (_pausedMode != null) _cancelPause();
    _bootstrap.cancel();
    setState(() {
      mode = 4;
      _tab = 1;
    });
    await importOpenVpnText(context, _openvpn, file.name, file.content);
  }

  /// A launcher-shortcut tap (build 2093): connect straight to
  /// the starred config it names. A stale shortcut (its profile
  /// is gone) republishes and does nothing — the tap never
  /// connects to the wrong profile. An already-connected target
  /// is a no-op; a live or in-flight V2Ray session switches
  /// through select() (a _toggleXray here would disconnect it);
  /// any other engine stops through the Xray connect's own
  /// stopOtherEngine hook, exactly as a manual V2Ray connect does.
  Future<void> _connectFromShortcut(String profileId) =>
      _serialized(() => _connectFromShortcutInner(profileId));

  Future<void> _connectFromShortcutInner(String profileId) async {
    if (!mounted) return;
    // Build 2095 (whole-app journey audit #5): a shortcut
    // tap never connects behind the lock page; it replays
    // after the unlock.
    if (_lockedNow) {
      _pendingShortcutIds.add(profileId);
      return;
    }
    Profile? target;
    for (final p in _xray.profiles) {
      if (p.id == profileId) {
        target = p;
        break;
      }
    }
    if (target == null) {
      unawaited(_xray.syncLauncherShortcuts());
      return;
    }
    if (_xray.state.running && _xray.sessionProfile?.id == profileId) {
      return;
    }
    if (_pausedMode != null) _cancelPause();
    _bootstrap.cancel();
    setState(() {
      mode = 1;
      _tab = 0;
    });
    _applyCadence();
    if (_xray.state.running || _xray.connecting) {
      _xray.select(target);
      return;
    }
    _xray.select(target);
    await _toggleXray(context);
  }

  void _armNetworkTracking() {
    _netSub = NetworkInfoService.changes.listen((id) {
      if (mounted) unawaited(_handleNetwork(id, initial: false));
    });
    // The V2Ray notification's Switch-server action (build
    // 2075, feature item 12).
    _rotateSub = NetworkInfoService.rotateRequests.listen((_) {
      if (mounted) unawaited(_notificationRotate());
    });
    // Build 2136 (item 1): stop-on-sleep — a screen-off
    // broadcast disconnects the running engine when the
    // owner opted in. Off (the default), the broadcast is
    // ignored and sleep behaviour is 2135's exactly.
    _screenOffSub = NetworkInfoService.screenOffRequests.listen((_) {
      if (!mounted) return;
      final running = _runningMode;
      if (_xray.settings.stopVpnOnSleep && running != null) {
        unawaited(_serialized(() => _disconnectMode(running)));
      }
    });
    // "Open with Ember" / share-to-Ember for an .ovpn file
    // (build 2085, audit F-H15).
    _ovpnFileSub = NetworkInfoService.openOvpnFiles.listen((file) {
      if (mounted) unawaited(_importOpenVpnIntent(file));
    });
    // A launcher-shortcut tap (build 2093): connect straight
    // to the starred config it names.
    _deepLinkSub = NetworkInfoService.deepLinks.listen((link) {
      if (mounted) unawaited(_importDeepLink(link));
    });
    _shortcutSub = NetworkInfoService.shortcutConnectRequests.listen((id) {
      if (mounted) unawaited(_connectFromShortcut(id));
    });
    _healthTimer = Timer.periodic(const Duration(minutes: 30), (_) {
      unawaited(_xray.maybeRunScheduledHealth());
    });
    // Build 2125 (audit A25-29 / P-34): the budget/battery
    // timer is armed only while one of its two features
    // is on — both default OFF, and up to 2124 the 5 s
    // timer woke ~17k times a day for the process's whole
    // life doing two no-op checks. Settings changes
    // re-evaluate it.
    _syncBudgetTimer();
    widget.settings.addListener(_syncBudgetTimer);
    // Build 2095 (feature 5): sync the widget's lock
    // marker with the stored setting at every start.
    unawaited(
      AndroidCore.setWidgetLock(widget.settings.appLockEnabled),
    );
    unawaited(
      NetworkInfoService.current().then((id) {
        if (mounted) unawaited(_handleNetwork(id, initial: true));
      }),
    );
  }

  /// The unlock (build 2095, whole-app journey audit #5):
  /// actions that arrived behind the lock page replay
  /// here — build 2096 (audit L24) made them per-kind
  /// queues that ALL replay (shortcuts, then files, then
  /// deep links); a queued rotate runs when a V2Ray
  /// session is live; a queued auto-connect / pause-resume
  /// runs only when nothing was queued and nothing is
  /// running by then.
  void _onUnlocked() {
    setState(() => _unlocked = true);
    // Build 2096 (post-2095 audit L24): every queued
    // action replays, in arrival order per kind —
    // shortcuts first (the most explicit taps), then
    // .ovpn files, then deep links.
    final shortcuts = List.of(_pendingShortcutIds);
    _pendingShortcutIds.clear();
    final files = List.of(_pendingOvpnFiles);
    _pendingOvpnFiles.clear();
    final deepLinks = List.of(_pendingDeepLinks);
    _pendingDeepLinks.clear();
    final rotate = _pendingRotate;
    _pendingRotate = false;
    final autoConnect = _pendingAutoConnect;
    _pendingAutoConnect = false;
    final resumeMode = _pendingResumeMode;
    _pendingResumeMode = null;
    for (final id in shortcuts) {
      unawaited(_connectFromShortcut(id));
    }
    for (final file in files) {
      unawaited(_importOpenVpnIntent(file));
    }
    for (final link in deepLinks) {
      unawaited(_importDeepLink(link));
    }
    // Build 2096 (post-2095 audit M23): a queued rotate
    // replays only when no shortcut was queued — the
    // shortcut's connect decides the session; rotating
    // right after it would switch away from the server
    // the user just picked.
    // Build 2097 (post-2096 audit C-L4): queued .ovpn
    // files and deep links suppress the rotate the same
    // way — they are navigation actions too (an imported
    // config the user then connects), and build 2096
    // suppressed the rotate only for shortcuts, so a
    // queued import followed by a replayed rotate switched
    // the session away from what the user had just added.
    // Build 2098 (post-2097 audit L13): a queued intent
    // that the navigation actions below suppress is no
    // longer dropped SILENTLY — the suppression itself is
    // unchanged (the navigation action owns the tunnel
    // decision), but the user hears that something queued
    // behind the lock did not run.
    var skippedQueued = false;
    if (rotate && shortcuts.isEmpty && files.isEmpty && deepLinks.isEmpty) {
      unawaited(_notificationRotate());
    } else if (rotate) {
      skippedQueued = true;
    }
    // Build 2096 (audit M23): when a navigation action was
    // queued, IT owns the tunnel decision — build 2095
    // evaluated the any-engine check before the queued
    // shortcut had even started, so a pending resume /
    // auto-connect fired alongside it (two connects, the
    // second toggle-semantics one switching the first
    // straight back off).
    if (shortcuts.isNotEmpty || files.isNotEmpty || deepLinks.isNotEmpty) {
      if (resumeMode != null || autoConnect) skippedQueued = true;
      if (skippedQueued && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'An action queued behind the lock was skipped — '
              'the config you opened comes first.',
            ),
          ),
        );
      }
      return;
    }
    if (_anyEngineActive || _anyEngineConnecting || _chainRunning) return;
    if (resumeMode != null) {
      // Build 2097 (post-2096 audit C-L16): the queued
      // resume is an ensure-ON intent, re-evaluated when it
      // executes — not a bare toggle.
      unawaited(_serialized(() => _ensureModeOn(context, resumeMode)));
    } else if (autoConnect) {
      unawaited(_autoConnect());
    }
  }

  /// Build 2097 (post-2096 audit C-L16): intent-carrying
  /// engine actions for the QUEUED paths. A queued entry
  /// used to execute a bare toggle with its guards evaluated
  /// at ENQUEUE time — by execution time the world had moved
  /// (the user connected the paused engine by hand during a
  /// long queue wait) and the "resume" toggle switched it
  /// straight back OFF; the pause's disconnect had the
  /// mirror-image flip. These re-evaluate the intent at
  /// execution: ensure-on no-ops when the mode is already
  /// up or coming up; ensure-off no-ops when it is already
  /// down.
  Future<void> _ensureModeOn(BuildContext context, int m) async {
    if (_engineActive(m) || _engineConnecting(m)) return;
    await _toggleForMode(context, m);
  }

  Future<void> _ensureModeOff(BuildContext context, int m) async {
    if (_engineActive(m)) {
      await _toggleForMode(context, m);
      return;
    }
    // Build 2098 (post-2097 audit L4): a mode that is only
    // CONNECTING must not be delegated to its toggle —
    // the Psiphon/Lantern/OpenVPN/Aether toggles are
    // running-only (`if (running) disconnect, else
    // connect`), so in the connecting window the "ensure
    // off" intent called connect() a second time instead
    // of cancelling the attempt. _disconnectMode performs
    // the per-mode stop, which cancels in-flight attempts
    // (and, for Mozilla, the bootstrap — build 2098 M17).
    if (_engineConnecting(m)) {
      await _disconnectMode(m);
    }
  }

  /// Disconnects the current engine and schedules its return.
  Future<void> _pauseConnection(BuildContext context, Duration d) async {
    final m = mode;
    setState(() {
      _pausedMode = m;
      _resumeAt = DateTime.now().add(d);
    });
    _pauseTimer?.cancel();
    _pauseTimer = Timer(d, _onPauseTimer);
    _pauseTicker?.cancel();
    _pauseTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      // Build 2092 (item 33): tick the countdown's own
      // listenable, not the whole shell.
      if (mounted) _pauseTick.value++;
    });
    // Build 2096 (post-2095 audit M24): the pause's
    // disconnect joins the serialization queue like every
    // other engine action. Build 2097 (C-L16): as an
    // ensure-OFF intent, re-evaluated at execution.
    await _serialized(() => _ensureModeOff(context, m));
  }

  void _onPauseTimer() {
    _pauseTicker?.cancel();
    _pauseTicker = null;
    final m = _pausedMode;
    _pausedMode = null;
    _resumeAt = null;
    if (!mounted || m == null) return;
    setState(() {});
    // The user resumed by hand meanwhile, or connected
    // something else: the pause's job is done either way —
    // never toggle an engine that is already up.
    if (_anyEngineActive || _anyEngineConnecting) return;
    // Build 2095 (whole-app journey audit #5): a scheduled
    // resume never connects behind the lock page either.
    if (_lockedNow) {
      _pendingResumeMode = m;
      return;
    }
    // Build 2096 (post-2095 audit M24): serialized, like
    // every other engine action. Build 2097 (C-L16): as an
    // ensure-ON intent — the guards above ran at enqueue
    // time; the intent re-checks at execution, so a manual
    // reconnect during the queue wait is never toggled off.
    unawaited(_serialized(() => _ensureModeOn(context, m)));
  }

  /// Resume now: cancel the schedule and reconnect at once.
  void _resumePause(BuildContext context) {
    final m = _pausedMode;
    if (m == null) return;
    _pauseTimer?.cancel();
    _pauseTimer = null;
    _pauseTicker?.cancel();
    _pauseTicker = null;
    setState(() {
      _pausedMode = null;
      _resumeAt = null;
    });
    if (_anyEngineActive || _anyEngineConnecting) return;
    // Build 2096 (post-2095 audit M24): serialized, like
    // every other engine action. Build 2097 (C-L16):
    // ensure-ON intent, re-evaluated at execution.
    unawaited(_serialized(() => _ensureModeOn(context, m)));
  }

  /// Cancel the schedule; the engine stays off.
  void _cancelPause() {
    _pauseTimer?.cancel();
    _pauseTimer = null;
    _pauseTicker?.cancel();
    _pauseTicker = null;
    if (mounted) {
      setState(() {
        _pausedMode = null;
        _resumeAt = null;
      });
    } else {
      _pausedMode = null;
      _resumeAt = null;
    }
  }

  String get _pauseCountdown {
    final at = _resumeAt;
    if (at == null) return '';
    final left = at.difference(DateTime.now());
    if (left.isNegative) return '0:00';
    final mm = left.inMinutes;
    final ss = (left.inSeconds % 60).toString().padLeft(2, '0');
    // Build 2074 (audit item 27): Latin digits, like every
    // other displayed number.
    return latDigits('$mm:$ss');
  }

  /// The strip above the bottom bar (build 2033): a Pause
  /// button while the current engine is connected; the
  /// countdown with Resume/Cancel while a pause is pending
  /// for the mode on screen.
  Widget _pauseStrip(BuildContext context, {required bool engineOn}) {
    if (_pausedMode != null) {
      if (_pausedMode != mode) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.pause_circle_rounded,
              size: 17,
              color: Ember.orange,
            ),
            const SizedBox(width: 6),
            // Build 2058 (audit §5 Shell/Home): the strip was a
            // non-wrapping Row — "Paused · resumes in 59:59" +
            // two buttons overflowed a 360 px phone. The label
            // flexes and ellipsises; the actions stay put.
            Flexible(
              // Build 2092 (item 33): only this Text rebuilds
              // on the 1 s tick.
              child: ValueListenableBuilder<int>(
                valueListenable: _pauseTick,
                builder: (context, _, _) => Text(
                  'Paused · resumes in $_pauseCountdown',
                  style: Ember.caption.copyWith(color: Ember.text),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ),
            ),
            const SizedBox(width: 10),
            TextButton(
              onPressed: () => _resumePause(context),
              child: const Text('Resume now'),
            ),
            TextButton(onPressed: _cancelPause, child: const Text('Cancel')),
          ],
        ),
      );
    }
    if (!engineOn) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Align(
        alignment: Alignment.centerRight,
        child: TextButton.icon(
          onPressed: () => unawaited(_pickPauseDuration(context)),
          icon: const Icon(Icons.pause_rounded, size: 16),
          label: const Text('Pause'),
        ),
      ),
    );
  }

  Future<void> _pickPauseDuration(BuildContext context) async {
    final d = await showModalBottomSheet<Duration>(
      context: context,
      backgroundColor: Ember.surface,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Build 2058 (audit §5 Shell/Home): the sheet was a
            // bare stock list — now a titled Ember sheet with
            // the orange pause mark on every duration row.
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
              child: Row(
                children: [
                  const Icon(
                    Icons.pause_rounded,
                    size: 17,
                    color: Ember.orange,
                  ),
                  const SizedBox(width: 8),
                  Text('Pause connection', style: Ember.heading),
                ],
              ),
            ),
            for (final (label, dur) in [
              ('Pause for 5 minutes', const Duration(minutes: 5)),
              ('Pause for 15 minutes', const Duration(minutes: 15)),
              ('Pause for 30 minutes', const Duration(minutes: 30)),
              ('Pause for 1 hour', const Duration(hours: 1)),
            ])
              ListTile(
                leading: const Icon(
                  Icons.pause_rounded,
                  size: 18,
                  color: Ember.orange,
                ),
                title: Text(label, style: Ember.body),
                onTap: () => Navigator.of(sheetContext).pop(dur),
              ),
          ],
        ),
      ),
    );
    if (d == null || !context.mounted) return;
    await _pauseConnection(context, d);
  }

  /// The map actors for the current mode, derived only from real
  /// data: a chosen location, profile remarks, or a through-tunnel
  /// exit lookup. Null selection = no pin, no arc.
  ({Set<String> pins, String? selected, bool connected, String? badge})
  _actors() {
    final home = (
      pins: <String>{},
      selected: null,
      connected: false,
      badge: null,
    );
    switch (mode) {
      case 0:
        final status = core.status;
        final on = status?.state.phase == Phase.running;
        final exit = status?.exit;
        final proxy = status?.proxy;
        final code = on && exit != null && exit.countryCode.isNotEmpty
            ? exit.countryCode
            : proxy?.countryCode;
        if (code == null || code.isEmpty) return home;
        final country = on && exit != null && exit.countryName.isNotEmpty
            ? exit.countryName
            : proxy?.countryName ?? '';
        final city = on && exit != null && exit.city.isNotEmpty
            ? exit.city
            : proxy?.cityName ?? '';
        final badge = country.isEmpty
            ? null
            : (city.isEmpty ? country : '$country • $city').toUpperCase();
        return (pins: <String>{}, selected: code, connected: on, badge: badge);
      case 1:
        final pins = <String>{};
        for (final profile in _xray.profiles) {
          final code = profileDisplayCountryCode(profile);
          if (code != null) pins.add(code);
        }
        final on = _xray.state.running;
        final exitCode = on ? _xray.exitInfo?.countryCode : null;
        if (exitCode != null && exitCode.isNotEmpty) pins.add(exitCode);
        final selected = _xray.selected == null
            ? null
            : profileDisplayCountryCode(_xray.selected!);
        final active =
            selected ??
            (exitCode != null && exitCode.isNotEmpty ? exitCode : null);
        final badge = on && _xray.exitInfo != null
            ? _xray.exitInfo!.displayName.toUpperCase()
            : null;
        return (pins: pins, selected: active, connected: on, badge: badge);
      case 2:
        final state = _psiphon.state;
        final code = state.connected && state.region.isNotEmpty
            ? state.region
            : (_psiphon.settings.region.isNotEmpty
                  ? _psiphon.settings.region
                  : null);
        return (
          pins: <String>{},
          selected: code,
          connected: state.connected,
          badge: code == null
              ? null
              : 'EXIT • ${regionName(code).toUpperCase()}',
        );
      case 3:
        final state = _lantern.state;
        final code = state.connected && state.exitCode.isNotEmpty
            ? state.exitCode
            : null;
        final badge = !state.connected || state.exitLine.isEmpty
            ? null
            : 'EXIT • ${state.exitLine.toUpperCase()}';
        return (
          pins: <String>{},
          selected: code,
          connected: state.connected,
          badge: badge,
        );
      case 4:
        final state = _openvpn.state;
        // Build 2028: imported profiles carry no country —
        // the pin is the exit's code once connected, nothing
        // before (the bundled TunnelBear list that supplied a
        // per-profile code is gone).
        final code = state.connected && state.exitCode.isNotEmpty
            ? state.exitCode
            : null;
        final badge = !state.connected || state.exitCountry.isEmpty
            ? null
            : 'EXIT • ${state.exitCountry.toUpperCase()}';
        return (
          pins: <String>{},
          selected: code,
          connected: state.connected,
          badge: badge,
        );
      case 5:
        // WireGuard: V2Ray's actors, narrowed to the section —
        // pins from WG profiles' remarks, the badge from the
        // live exit lookup.
        final pins = <String>{};
        for (final profile in _xray.profiles) {
          if (profile.protocol != Protocol.wireguard) continue;
          final code = profileDisplayCountryCode(profile);
          if (code != null) pins.add(code);
        }
        final on = _xray.state.running;
        final exitCode = on ? _xray.exitInfo?.countryCode : null;
        if (exitCode != null && exitCode.isNotEmpty) pins.add(exitCode);
        final sel = _xray.selected;
        final selected = (sel != null && sel.protocol == Protocol.wireguard)
            ? profileDisplayCountryCode(sel)
            : (exitCode != null && exitCode.isNotEmpty ? exitCode : null);
        final badge = on && _xray.exitInfo != null
            ? _xray.exitInfo!.displayName.toUpperCase()
            : null;
        return (pins: pins, selected: selected, connected: on, badge: badge);
      case 6:
      case 7:
        // WARP / MASQUE: the pin is the trace's country once
        // the engine is connected and a trace has answered.
        final c = mode == 6 ? _warp : _masque;
        final t = c.exitTrace;
        final loc = (t?['loc'] ?? '').toUpperCase();
        final code = c.connected && loc.length == 2 ? loc : null;
        final badge = code == null
            ? null
            : 'EXIT • ${(t?['ip'] ?? '').isEmpty ? code : '${t!['ip']} • $code'}';
        return (
          pins: <String>{},
          selected: code,
          connected: c.connected,
          badge: badge,
        );
      case 8:
        // Build 2156: the pin is the SDK device's own exit
        // readback once connected (the Lantern shape).
        final state = _ur.state;
        final code = state.connected && state.exitCode.isNotEmpty
            ? state.exitCode
            : null;
        final badge = !state.connected || state.exitLine.isEmpty
            ? null
            : 'EXIT • ${state.exitLine.toUpperCase()}';
        return (
          pins: <String>{},
          selected: code,
          connected: state.connected,
          badge: badge,
        );
    }
    return home;
  }

  /// The bottom bar's model for the current engine: the power
  /// state, the state word, up to four telemetry cells (real
  /// backend values only; "—" where an engine has none), and the
  /// latency/engine micro-line.
  /// Build 2092 (item 33): the engine controller the actors
  /// layer reads for the current mode (see _actors).
  Listenable get _actorsListenable => switch (mode) {
    0 => core,
    1 || 5 => _xray,
    2 => _psiphon,
    3 => _lantern,
    4 => _openvpn,
    6 => _warp,
    // Build 2156: URnetwork gets its own listenable — the
    // wildcard below means MASQUE and must not swallow it.
    8 => _ur,
    _ => _masque,
  };

  ({
    bool on,
    bool busy,
    String stateWord,
    List<({String label, String value})> cells,
    String microLine,
    VoidCallback onToggle,
  })
  _barModel(BuildContext context) {
    // Build 2095 (whole-app journey audit #28): the
    // public-IP privacy switch gates every EXIT IP cell
    // below — the Ember shell used to ignore it (only the
    // stock overview page honoured it).
    final showIp = widget.settings.showPublicIp;
    switch (mode) {
      case 0:
        final status = core.status;
        final phase = status?.state.phase ?? Phase.off;
        final on = phase == Phase.running;
        final busy = _mozBusy || phase == Phase.starting;
        // Build 2087 (analysis A3): with no network at all the
        // word says so — the one state where 'Connected' is
        // flatly false, and the legacy shell's immediate
        // message. Test failures with a network present keep
        // the settled phase word (build 2057, audit F-H10);
        // the bar makes no latency claim until a test passes.
        final noNet = on && (status?.noNetwork ?? false);
        // Build 2116 (audit AB-02): the word keys on the
        // confirmation, not the phase alone — a running
        // session no test has confirmed is "Connecting…"
        // inside its confirmation window (the core's own
        // model: confirmedBy) and "Connected — not
        // answering" past it, instead of a bare "Connected"
        // a rotted session kept forever.
        final proxy = status?.proxy;
        final traffic = status?.traffic;
        final cityCountry = proxy == null
            ? ''
            : [
                if (proxy.cityName.isNotEmpty) proxy.cityName,
                if (proxy.countryName.isNotEmpty) proxy.countryName,
              ].join(' • ');
        final exitIp = status?.exit?.ipv4.isNotEmpty == true
            ? status!.exit!.ipv4
            : (status?.lastTest?.exitIpv4 ?? '');
        final test = status?.lastTest;
        final confirmed = on && (status?.confirmedBy(core.lastTest) ?? false);
        return (
          on: on,
          busy: busy,
          stateWord: noNet
              ? 'No internet connection'
              : on && !confirmed && core.runningUnconfirmed
              ? 'Connected — not answering'
              : on && !confirmed
              ? 'Connecting…'
              : on
              ? 'Connected'
              : busy
              ? 'Connecting…'
              : 'Not connected',
          cells: [
            // Build 2095 (whole-app journey audit #10):
            // LOCATION and EXIT IP are gated on `on` like
            // UP/DOWN — after a disconnect they used to keep
            // presenting the chosen location and the last
            // test's exit IP as current facts.
            (
              label: 'LOCATION',
              value: on && cityCountry.isNotEmpty ? cityCountry : '—',
            ),
            (
              label: 'EXIT IP',
              value: on && showIp && exitIp.isNotEmpty ? exitIp : '—',
            ),
            (
              label: 'UP',
              value: on && traffic != null ? fmtRate(traffic.upRate) : '—',
            ),
            (
              label: 'DOWN',
              value: on && traffic != null ? fmtRate(traffic.downRate) : '—',
            ),
          ],
          microLine: on && test != null && test.ok && test.responseMs > 0
              ? 'LATENCY ${latDigits(test.responseMs)}ms • MOZILLA'
              : 'MOZILLA',
          onToggle: () => unawaited(_powerToggle(context, mode)),
        );
      case 1:
        // Build 2092 (UI audit item 5): a standalone EmberWarp
        // session is not a V2Ray session — this bar stays dark
        // for it, and the config cell names the SESSION's
        // profile (sessionProfile), not the current selection.
        final on = _xray.state.running && !_xray.warpSession;
        final p = _xray.sessionProfile ?? _xray.selected;
        final exit = _xray.exitInfo;
        final proto = p?.protocol.label;
        // Build 2119 (audit F-02): the bar consumes
        // XrayState.verified at last. A plain-Xray session
        // proven in this process reads "Connected"; one
        // adopted after an app restart reads the honest
        // "Connected — not answering" until the adoption
        // proof passes (the 2116 Mozilla word). The
        // WireGuard protocol leg keeps "Connected": its
        // proof is the handshake, not this flag.
        final proven =
            _xray.state.verified || p?.protocol == Protocol.wireguard;
        return (
          on: on,
          busy: _xray.connecting,
          stateWord: on
              ? (proven
                    ? 'Connected'
                    : _xray.connecting
                    ? 'Connecting…'
                    : 'Connected — not answering')
              : _xray.connecting
              ? 'Connecting…'
              : 'Not connected',
          cells: [
            // Build 2027: a running core whose config is no
            // longer in the list (see the V2Ray home card)
            // reads "Running", never a contradictory "—"
            // beside a connected engine.
            (
              label: 'ACTIVE CONFIG',
              value: p?.displayName ?? (on ? 'Running' : '—'),
            ),
            (
              label: 'EXIT IP',
              value: on && showIp && exit != null && exit.ip.isNotEmpty ? exit.ip : '—',
            ),
            (label: 'UP', value: on ? fmtRate(_xray.upRate) : '—'),
            (label: 'DOWN', value: on ? fmtRate(_xray.downRate) : '—'),
          ],
          // Build 2095 (whole-app journey audit #11): the
          // number is the profile's last delay-TEST result,
          // possibly hours old — it is labelled as what it
          // is, not as the live session's latency.
          microLine: on && p != null && p.delayMs >= 0
              ? 'LAST TEST ${latDigits(p.delayMs)}ms • ${proto!.toUpperCase()}'
              : (proto?.toUpperCase() ?? 'V2RAY'),
          onToggle: () => unawaited(_powerToggle(context, mode)),
        );
      case 2:
        final state = _psiphon.state;
        final on = state.connected;
        final busy = _psiphon.connecting || (state.running && !on);
        return (
          on: on,
          busy: busy,
          stateWord: on
              ? 'Connected via Psiphon'
              : busy
              ? 'Connecting…'
              : 'Not connected',
          cells: [
            // Build 2095 (whole-app journey audit #12): EXIT
            // REGION is where the core actually landed
            // (state.region), shown only while connected —
            // it used to present the REQUESTED region (or
            // "Automatic") as fact even while disconnected.
            // UP/DOWN gate on `connected`, not `running`.
            (
              label: 'EXIT REGION',
              value: on && state.region.isNotEmpty
                  ? regionName(state.region)
                  : '—',
            ),
            (
              label: 'SESSION',
              value: state.running && state.sinceMs > 0
                  ? fmtDuration(
                      DateTime.now().difference(
                        DateTime.fromMillisecondsSinceEpoch(state.sinceMs),
                      ),
                    )
                  : '—',
            ),
            (label: 'UP', value: on ? fmtRate(_psiphon.upRate) : '—'),
            (label: 'DOWN', value: on ? fmtRate(_psiphon.downRate) : '—'),
          ],
          microLine: 'PSIPHON',
          onToggle: () => unawaited(_powerToggle(context, mode)),
        );
      case 3:
        final state = _lantern.state;
        final on = state.connected;
        final busy =
            _lantern.connecting ||
            (state.running && !on) ||
            (state.coreRunning && !on);
        return (
          on: on,
          busy: busy,
          stateWord: on
              ? 'Connected via Lantern'
              : busy
              ? 'Connecting…'
              : 'Not connected',
          cells: [
            (
              label: 'EXIT',
              value: state.exitLine.isEmpty ? '—' : state.exitLine,
            ),
            (
              label: 'SERVERS',
              value: state.servers >= 0 ? latDigits(state.servers) : '—',
            ),
            (
              label: 'UP',
              value: state.running ? fmtRate(_lantern.upRate) : '—',
            ),
            (
              label: 'DOWN',
              value: state.running ? fmtRate(_lantern.downRate) : '—',
            ),
          ],
          microLine: 'LANTERN',
          onToggle: () => unawaited(_powerToggle(context, mode)),
        );
      case 4:
        final state = _openvpn.state;
        final on = state.connected;
        final busy = _openvpn.connecting || (state.running && !on);
        final p = _openvpn.selected;
        return (
          on: on,
          busy: busy,
          stateWord: on
              ? 'Connected via OpenVPN'
              : busy
              ? 'Connecting…'
              : 'Not connected',
          cells: [
            (label: 'PROFILE', value: p?.name ?? '—'),
            (
              label: 'EXIT IP',
              value: on && showIp && state.exitIp.isNotEmpty ? state.exitIp : '—',
            ),
            (
              label: 'UP',
              value: state.running ? fmtRate(_openvpn.upRate) : '—',
            ),
            (
              label: 'DOWN',
              value: state.running ? fmtRate(_openvpn.downRate) : '—',
            ),
          ],
          microLine: 'OPENVPN',
          onToggle: () => unawaited(_powerToggle(context, mode)),
        );
      case 5:
        // Build 2092 (item 5): same session-truth as case 1 —
        // the CONFIG cell reads the session's profile, and a
        // standalone EmberWarp session lights nothing here.
        final on = _xray.state.running && !_xray.warpSession;
        final p = _xray.sessionProfile ?? _xray.selected;
        final wg = p != null && p.protocol == Protocol.wireguard ? p : null;
        final exit = _xray.exitInfo;
        // Build 2119 (audit F-02): same verified
        // consumption as the V2Ray bar — a non-WireGuard
        // session adopted unproven in this process does
        // not read bare "Connected" here either.
        final proven =
            _xray.state.verified || p?.protocol == Protocol.wireguard;
        return (
          on: on,
          busy: _xray.connecting,
          stateWord: on
              ? (proven
                    ? 'Connected'
                    : _xray.connecting
                    ? 'Connecting…'
                    : 'Connected — not answering')
              : _xray.connecting
              ? 'Connecting…'
              : 'Not connected',
          cells: [
            (label: 'CONFIG', value: wg?.displayName ?? (on ? 'Running' : '—')),
            (
              label: 'EXIT IP',
              value: on && showIp && exit != null && exit.ip.isNotEmpty ? exit.ip : '—',
            ),
            (label: 'UP', value: on ? fmtRate(_xray.upRate) : '—'),
            (label: 'DOWN', value: on ? fmtRate(_xray.downRate) : '—'),
          ],
          microLine: 'WIREGUARD',
          onToggle: () => unawaited(_powerToggle(context, mode)),
        );
      case 6:
      case 7:
        final c = mode == 6 ? _warp : _masque;
        final state = c.state;
        final on = c.connected;
        final busy = c.connecting || (state.running && !on);
        final t = c.exitTrace;
        return (
          on: on,
          busy: busy,
          stateWord: on
              ? 'Connected via ${mode == 6 ? 'WARP' : 'MASQUE'}'
              : busy
              ? (state.stageLabel.isNotEmpty ? state.stageLabel : 'Connecting…')
              : 'Not connected',
          cells: [
            (
              label: 'ENDPOINT',
              value: state.server.isEmpty ? '—' : state.server,
            ),
            (
              label: 'EXIT IP',
              // Build 2115: a session the data proof carried
              // but no trace ever verified says so, instead of
              // the bare dash that used to mean "not connected"
              // after a teardown.
              value: on && showIp && t != null && (t['ip'] ?? '').isNotEmpty
                  ? t['ip']!
                  : on && c.exitUnverified
                  ? 'Unverified'
                  : '—',
            ),
            (label: 'UP', value: c.tunRunning ? fmtRate(c.upRate) : '—'),
            (label: 'DOWN', value: c.tunRunning ? fmtRate(c.downRate) : '—'),
          ],
          microLine: mode == 6
              ? 'WARP'
              : 'MASQUE • ${c.options.protocol.toUpperCase()}',
          onToggle: () => unawaited(_powerToggle(context, mode)),
        );
      case 8:
        // Build 2156: the URnetwork bar — the Lantern
        // shape, with the session's location in place of
        // a server count.
        final state = _ur.state;
        final on = state.connected;
        final busy = _ur.connecting || (state.running && !on);
        return (
          on: on,
          busy: busy,
          stateWord: on
              ? 'Connected via URnetwork'
              : busy
              ? 'Connecting…'
              : 'Not connected',
          cells: [
            (
              label: 'EXIT',
              value: state.exitLine.isEmpty ? '—' : state.exitLine,
            ),
            (
              label: 'LOCATION',
              value: state.reqName.isNotEmpty
                  ? state.reqName
                  : 'Best Available',
            ),
            (
              label: 'UP',
              value: state.running ? fmtRate(_ur.upRate) : '—',
            ),
            (
              label: 'DOWN',
              value: state.running ? fmtRate(_ur.downRate) : '—',
            ),
          ],
          microLine: 'URNETWORK',
          onToggle: () => unawaited(_powerToggle(context, mode)),
        );
    }
    throw StateError('unknown mode $mode');
  }

  // --------------------------------------------------------------- build

  /// Engine names by mode index (the rail's set, build 2075).
  static const _engineNames = [
    'Mozilla',
    'V2Ray',
    'Psiphon',
    'Lantern',
    'OpenVPN',
    'WireGuard',
    'WARP',
    'MASQUE',
    // Build 2156: the URnetwork engine joins the board.
    'URnetwork',
  ];

  /// The samples' engine order for the Home switcher
  /// (pro3 line / pro5 chip row), MASQUE last until build
  /// 2156 appended URnetwork after it.
  static const _homeEngineOrder = [1, 0, 3, 5, 6, 2, 4, 7, 8];

  /// Home fidelity round R1 (owner order 2026-11-23, restated
  /// 20:17 — functionality preserved, appearance rebuilt 0–100
  /// to the approved samples): on the Home tab the brand panel
  /// and the nine-chip rail LEAVE the header. The pro3/pro5
  /// header is only the tracked EMBER wordmark with its orange
  /// dot and, at the right, the protection state in tracked
  /// micro-caps. Engine switching moves to the switcher above
  /// the control bar (see _homeEngineSwitcher), wired to the
  /// same _chipTap as the rail; the rail itself is untouched
  /// on every other tab.
  Widget _homeHeader({bool backToHome = false}) {
    final protectedNow = _runningMode != null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      child: Row(
        children: [
          // Build 2148 (owner order 2026-11-24 — supersedes
          // 2147's #23 chip row and the build-2092 rail
          // constraint): on every non-Home tab the header
          // leads with a BACK control returning to the main
          // (Home) page. Engine choice lives on Home only;
          // no engine selector rides the other pages. The
          // control is a labelled pill (arrow + BACK in the
          // header's own tracked-orange label), 48 dp tall,
          // so the way back reads at a glance. Home itself
          // (backToHome false) is byte-for-byte the R1
          // header, unchanged.
          if (backToHome) ...[
            Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () => setState(() => _tab = 0),
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 15,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.arrow_back_rounded,
                        size: 18,
                        color: Ember.orange,
                      ),
                      const SizedBox(width: 6),
                      Text('BACK', style: Ember.microLabelOrange),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
          ],
          const Text(
            'EMBER',
            style: TextStyle(
              fontSize: Ember.fontDisplay,
              fontWeight: FontWeight.w300,
              letterSpacing: 6,
              color: Ember.text,
            ),
          ),
          const SizedBox(width: 5),
          Container(
            width: 6,
            height: 6,
            decoration: const BoxDecoration(
              color: Ember.orange,
              shape: BoxShape.circle,
            ),
          ),
          const Spacer(),
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              color: protectedNow
                  ? const Color(0xFF3DDC84)
                  : const Color(0xFF6E6E73),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                protectedNow ? 'PROTECTED' : 'NOT PROTECTED',
                style: Ember.microLabel,
              ),
              // Fidelity repair (post-batch-3, widget_test):
              // R1's header recomposition retired the legacy
              // header wholesale, and with it the Mozilla
              // home's one-tap Account route (the old header's
              // mode-0 Account pill) — a dropped navigation
              // contract, flagged as a concern in the R1
              // record, not an approved removal: in Mozilla
              // mode the account IS the home's subject (the
              // pro6-mozilla sample is an account surface),
              // and the Accounts tab otherwise takes a detour
              // through Servers. The route returns in the new
              // language: a quiet tracked 'Account' text action
              // under the status word, Mozilla mode only, the
              // same tab jump the pill made.
              if (mode == 0)
                InkWell(
                  onTap: () => setState(() => _tab = 2),
                  child: Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text('Account', style: Ember.microLabelOrange),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// The Home tab's engine switcher (R1), sitting directly
  /// above the control bar where the samples put it. Connected:
  /// pro3's single quiet text line — the engine names separated
  /// by middle dots, the current engine in orange. Disconnected:
  /// pro5's compact chip row — the current engine wears the
  /// orange rim and text. Every entry taps the rail's own
  /// _chipTap, so arbitration and cadence are unchanged.
  /// Build 2150 (engine appearance audit E49-12): the
  /// disconnected arm was two rows of filled chips (~78 dp)
  /// where pro5 sets ONE compact row of seven hairline
  /// chips. It is a single row now: eight chips flexed by
  /// name length at the connected arm's own type size,
  /// pro5's squarer radius, and a scale-down fit as the
  /// backstop so no width or text scale can wrap or clip
  /// the row. (The two-row form was the owner's accepted
  /// R2 composition; the audit recorded the deviation and
  /// this build's order closes it toward the sample.)
  Widget _homeEngineSwitcher({required bool anyRunning}) {
    if (anyRunning) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 2,
          runSpacing: 2,
          children: [
            for (var k = 0; k < _homeEngineOrder.length; k++) ...[
              if (k > 0)
                const Text(
                  '·',
                  style: TextStyle(
                    fontSize: Ember.fontMicro,
                    color: MapUi.faint,
                  ),
                ),
              InkWell(
                onTap: () => _chipTap(_homeEngineOrder[k]),
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 1,
                    vertical: 4,
                  ),
                  child: Text(
                    _engineNames[_homeEngineOrder[k]],
                    style: TextStyle(
                      fontSize: Ember.fontMicro,
                      // R1: a hair of tightening so all eight
                      // names hold the sample's single line at
                      // the owner's width.
                      letterSpacing: -0.4,
                      fontWeight: _homeEngineOrder[k] == mode
                          ? FontWeight.w600
                          : FontWeight.w400,
                      color: _homeEngineOrder[k] == mode
                          ? Ember.orange
                          : MapUi.dim,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      // Build 2150 (audit E49-12): one row, as pro5 — the
      // chips share the width by name length; the fit is
      // scale-down so a narrow width or a large text scale
      // shrinks the row as one piece instead of wrapping
      // it into the two-row tower the audit measured.
      child: Row(
        children: [
          for (var k = 0; k < _homeEngineOrder.length; k++) ...[
            if (k > 0) const SizedBox(width: 4),
            Expanded(
              flex: _engineNames[_homeEngineOrder[k]].length + 2,
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () => _chipTap(_homeEngineOrder[k]),
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 2,
                      vertical: 7,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF141518),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: _homeEngineOrder[k] == mode
                            ? Ember.orange
                            : MapUi.line,
                      ),
                    ),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        _engineNames[_homeEngineOrder[k]],
                        maxLines: 1,
                        style: TextStyle(
                          fontSize: Ember.fontMicro,
                          color: _homeEngineOrder[k] == mode
                              ? Ember.orange
                              : MapUi.dim,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _header() {
    // The header's status line reads every engine's live
    // state, so the header rebuilds on every engine
    // controller — not only Mozilla's (build 2025 fix: the
    // shell's own rebuild used to be the only trigger, and
    // a non-Mozilla state could sit stale until an
    // incidental rebuild). Build 2148: the chips that used
    // to be built here are gone from the non-Home header
    // (owner's navigation ruling — see the builder below);
    // the merge stays for the status line.
    return ListenableBuilder(
      listenable: Listenable.merge([
        core,
        _xray,
        _psiphon,
        _lantern,
        _openvpn,
        _warp,
        _masque,
        _ur,
      ]),
      builder: (context, _) {
        // R1 (2026-11-23): the Home tab wears the samples'
        // header (see _homeHeader).
        if (_tab == 0) return _homeHeader();
        // Build 2147 (#23) put one horizontal chip row under
        // the brand line here. Build 2148 (owner order
        // 2026-11-24, on device with screenshots) SUPERSEDES
        // it — and the build-2092 rail constraint with it:
        // the engine pages must not carry an engine selector
        // at all. Engine choice happens on the main (Home)
        // page only (Home's own switcher, untouched below);
        // every other tab's header is the same slim brand
        // line, led by the BACK control that returns to
        // Home (see _homeHeader). The Settings tab keeps its
        // close-to-Home behaviour through that same control.
        return _homeHeader(backToHome: true);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.noCore != null) {
      return Scaffold(
        backgroundColor: MapUi.baseBottom,
        body: EmberBackground(child: SafeArea(child: widget.noCore!)),
      );
    }
    // The app lock (build 2075, feature item 11): with a PIN
    // set, the shell stays behind the lock page until the
    // PIN is entered. The engines are not started by the
    // lock page; auto-connect arms only after the unlock
    // (the shell's init already ran, but every engine start
    // is user- or trigger-driven from the built UI).
    // Build 2095 (whole-app journey audit #4/#5): the lock
    // also RE-ARMS after a real backgrounding (see
    // didChangeAppLifecycleState), and non-UI entry points
    // queue behind it instead of executing (see _lockedNow).
    if (widget.settings.appLockEnabled && !_unlocked) {
      return AppLockPage(settings: widget.settings, onUnlocked: _onUnlocked);
    }
    final v2ray = mode == 1;
    final psiphonMode = mode == 2;
    final lanternMode = mode == 3;
    final openvpnMode = mode == 4;
    final wgMode = mode == 5;
    final warpMode = mode == 6;
    final masqueMode = mode == 7;
    final urMode = mode == 8;
    final pages = [
      EmberHome(
        core: core,
        xray: _xray,
        psiphon: _psiphon,
        lantern: _lantern,
        openvpn: _openvpn,
        warp: _warp,
        masque: _masque,
        ur: _ur,
        mode: mode,
        onModeChanged: (m) {
          setState(() => mode = m);
          _applyCadence();
        },
        onOpenServers: _openServersTab,
        onOpenAccounts: () => setState(() => _tab = 2),
        onPowerTap: () => unawaited(_powerToggle(context, mode)),
        stopOtherEngine: stopXray,
      ),
      // In Psiphon mode the Servers tab is the exit-region list and
      // the Accounts tab the no-account status page; Lantern mode
      // swaps in its list-state view and its own status page.
      // Build 2032: WireGuard swaps in its own configurations
      // view; WARP/MASQUE swap in the endpoint view.
      if (psiphonMode)
        PsiphonRegionsView(psiphon: _psiphon)
      else if (lanternMode)
        LanternServersView(lantern: _lantern)
      else if (openvpnMode)
        OpenVpnServersView(openvpn: _openvpn)
      else if (wgMode)
        WireGuardServersView(
          xray: _xray,
          onClose: () => setState(() => _tab = 0),
        )
      else if (warpMode)
        AetherServersView(controller: _warp)
      else if (masqueMode)
        AetherServersView(controller: _masque)
      else if (urMode)
        UrServersView(ur: _ur)
      else
        EmberServers(
          core: core,
          xray: _xray,
          v2ray: v2ray,
          onOpenAccounts: () => setState(() => _tab = 2),
          onClose: () => setState(() => _tab = 0),
          psiphon: _psiphon,
        ),
      if (psiphonMode)
        PsiphonAboutView(psiphon: _psiphon)
      else if (lanternMode)
        LanternAboutView(lantern: _lantern)
      else if (openvpnMode)
        OpenVpnStatusView(openvpn: _openvpn)
      else if (wgMode)
        WireGuardAboutView(xray: _xray)
      else if (warpMode)
        AetherAboutView(controller: _warp)
      else if (masqueMode)
        AetherAboutView(controller: _masque)
      else if (urMode)
        UrAboutView(ur: _ur)
      else
        EmberAccounts(
          core: core,
          xray: _xray,
          v2ray: v2ray,
          bootstrap: _bootstrap,
          // Build 2105 (Mozilla feature 1): the failure-screen
          // browser offer follows the owner's AppSettings toggle.
          signinBrowserFallbackOffer:
              widget.settings.signinBrowserFallbackOffer,
        ),
      EmberSettings(
        core: core,
        xray: _xray,
        psiphon: _psiphon,
        lantern: _lantern,
        openvpn: _openvpn,
        settings: widget.settings,
        // Build 2056 (audit A-H5): the WARP/MASQUE modes need
        // their controllers for their own Settings sections.
        warp: _warp,
        masque: _masque,
        bootstrap: _bootstrap,
        // Build 2156: the URnetwork engine's Settings section.
        ur: _ur,
      ),
    ];
    // Build 2050 (battery): hidden tabs get no tickers.
    // IndexedStack keeps every page mounted, so without this a
    // hidden page's perpetual animations (the Home power ring
    // above all) kept ticking — and repainting — through every
    // other tab.
    final gatedPages = [
      for (var i = 0; i < pages.length; i++)
        TickerMode(enabled: _tab == i, child: pages[i]),
    ];
    // The actors ride the map on the home page only; panels
    // elsewhere get the clean map. (Build 2149, audit
    // A48-05: the Mozilla locations surface kept the actors
    // from its sheet era — "the arc visible around the
    // sheet" — but since build 2148 it is a full-page LIST,
    // and the shipped render shows the filament arc and a
    // pulsing pin overlapping the search field and the
    // Recommended card. The samples keep the arc on the
    // Home composition; list surfaces get none.)
    final showActors = _tab == 0;
    // Build 2145 (UI-review fix A3): text-heavy surfaces get
    // the banded backdrop — the map as a faint top band, rows
    // on plain near-black (the approved pro6 settings sample).
    // Every tab past Home is a text surface; on Home itself
    // only the aether text homes (WARP / MASQUE, the surfaces
    // the review named) band — the map compositions (Mozilla,
    // V2Ray, and the other engine heroes) keep the full map.
    final bandedGround = _tab != 0 || warpMode || masqueMode;
    return Scaffold(
      backgroundColor: MapUi.baseBottom,
      body: Stack(
        children: [
          Positioned.fill(
            child: MapBackdropVisual(banded: bandedGround, faint: _tab == 0),
          ),
          if (showActors)
            Positioned.fill(
              child: ListenableBuilder(
                // Build 2092 (item 33): only the on-screen
                // mode's engine drives this layer — the merge
                // of all seven rebuilt and repainted the
                // full-screen painter on every engine's tick,
                // including the 2 s Xray stats poll while
                // another engine was on screen.
                listenable: _actorsListenable,
                builder: (context, _) {
                  final a = _actors();
                  return _ActorsLayer(
                    pins: a.pins,
                    selected: a.selected,
                    connected: a.connected,
                    badge: a.badge,
                    // R1 (pro3 home): the actors wear the
                    // filament composition. Build 2149 (audit
                    // A48-05): the layer renders on the Home
                    // tab only (see showActors above), so the
                    // filament form and the TEHRAN label are
                    // unconditional here.
                    filament: true,
                    homeLabel: 'TEHRAN',
                  );
                },
              ),
            ),
          SafeArea(
            bottom: false,
            child: Column(
              children: [
                if (widget.banner != null) widget.banner!,
                _header(),
                Expanded(
                  child: IndexedStack(index: _tab, children: gatedPages),
                ),
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                    child: ListenableBuilder(
                      listenable: Listenable.merge([
                        core,
                        _xray,
                        _psiphon,
                        _lantern,
                        _openvpn,
                        _warp,
                        _masque,
                        _ur,
                      ]),
                      builder: (context, _) {
                        final bar = _barModel(context);
                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (_chainStatus.isNotEmpty)
                              // Build 2074 (audit item 10): the
                              // chain line caps at two lines with
                              // an ellipsis so it can no longer
                              // push the bottom bar over the page;
                              // the full chain stays one tap (or
                              // long-press tooltip) away in a sheet.
                              Padding(
                                padding: const EdgeInsets.only(bottom: 6),
                                child: Tooltip(
                                  message: _chainStatus,
                                  child: GestureDetector(
                                    onTap: () {
                                      showModalBottomSheet<void>(
                                        context: context,
                                        backgroundColor: Ember.surface,
                                        builder: (sheetContext) => SafeArea(
                                          child: Padding(
                                            padding: const EdgeInsets.fromLTRB(
                                              20,
                                              18,
                                              20,
                                              18,
                                            ),
                                            child: Text(
                                              _chainStatus,
                                              style: Ember.body,
                                            ),
                                          ),
                                        ),
                                      );
                                    },
                                    child: Text(
                                      _chainStatus,
                                      style: Ember.caption,
                                      textAlign: TextAlign.center,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ),
                              ),
                            // Build 2095 (feature 1): the
                            // emergency entry — one tap,
                            // shown only while nothing runs.
                            // Build 2145 (UI-review fix A13): the
                            // floating glass pill is retired — the
                            // entry now wears the composition's own
                            // vocabulary: a flat tracked text action
                            // with a leading glyph, right-aligned
                            // over the map, same tap, same 48 dp
                            // floor.
                            if (_runningMode == null && !_emergencyRunning)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 6),
                                child: Align(
                                  alignment: Alignment.centerRight,
                                  child: Material(
                                    color: Colors.transparent,
                                    child: InkWell(
                                      onTap: () =>
                                          unawaited(_runEmergency()),
                                      borderRadius: BorderRadius.circular(8),
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 14,
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            const Icon(
                                              Icons.bolt_rounded,
                                              size: 15,
                                              color: Ember.orange,
                                            ),
                                            const SizedBox(width: 6),
                                            Text(
                                              'Emergency connect',
                                              style: Ember.microLabelOrange,
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            // R1 (pro3/pro5 home): the engine
                            // switcher lives here on the Home
                            // tab — the header rail no longer
                            // reaches into this tab.
                            if (_tab == 0)
                              _homeEngineSwitcher(
                                anyRunning: _runningMode != null,
                              ),
                            _pauseStrip(context, engineOn: bar.on && !bar.busy),
                            // Build 2144 (reskin, pro3 sample):
                            // the bottom bar is the shell's own
                            // composition now — gear round
                            // button, the flat-orange power pill
                            // carrying the bar model's existing
                            // action and state word, shield
                            // round button — with the model's
                            // telemetry cells and micro-line
                            // kept above the pill (see
                            // _ShellControlBar).
                            // R1: on the Home tab the bar goes
                            // quiet (quiet: true) — the telemetry
                            // cells and micro-line duplicate the
                            // hero block the samples compose, so
                            // only the hairline + control row
                            // remain, as in pro3.
                            _ShellControlBar(
                              busy: bar.busy,
                              onToggle: bar.onToggle,
                              stateWord: bar.stateWord,
                              cells: bar.cells,
                              microLine: bar.microLine,
                              quiet: _tab == 0,
                              onSettings: () =>
                                  setState(() => _tab = _tab == 3 ? 0 : 3),
                              onServers: _openServersTab,
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The bottom control bar (build 2144, pro3 sample): the
/// bar model's telemetry cells in one quiet row (rendered by
/// MapBarCell, so the bar's owner-ordered 10/10.5 sp type
/// exception is untouched), the latency/engine micro-line
/// right-aligned under them, then the control row — a round
/// hairline gear button (the header rail's Settings action),
/// the long flat-orange pill carrying the model's existing
/// power action and state word in black semibold, and a
/// round hairline shield button (the Locations action).
/// Busy keeps the old bar's contract: the pill will not
/// fire while the engine is mid-toggle, and shows a spinner.
///
/// Home fidelity round R2 (owner order 2026-11-23): on the
/// Home tab ([quiet]) the fat filled-orange pill is retired
/// — it was the last loud piece of the old appearance on the
/// page. The Home bar is the samples' slim bar instead: a
/// quiet dark tray with a hairline frame, the gear and
/// shield as the same quiet round marks, and the power
/// action as a hairline-outlined slim pill carrying a
/// tracked uppercase ACTION word (CONNECT / DISCONNECT,
/// pro3/pro5) with the small power glyph. Transitional and
/// honest-exception state words (Connecting…, Connected —
/// not answering, No internet connection) keep their word,
/// tracked and uppercased, so the bar loses no information;
/// busy still shows the spinner and will not fire. Every
/// other tab keeps the full bar above, byte-identical.
///
/// Fidelity repair (post-batch-3, widget_test): R1/R2's
/// quieting went one step too far — the slim tray dropped
/// the bar's claim contract wholesale (the verbatim state
/// word, the telemetry cells, the latency micro-line). On
/// most homes the page body repeats those claims, but the
/// Mozilla home is an empty map: the bar is the ONLY place
/// the state word, the exit IP and the post-test latency
/// claim exist, so dropping them changed user-visible
/// behaviour, not just composition (the contract itself is
/// builds 2057/2087/2116: 'Connected' only once a test has
/// confirmed the session, no latency claim before one
/// passes, no-network said in the word). The slim tray now
/// carries the same three in the slim language — the cells
/// as the full bar's own MapBarCell row, the state word
/// verbatim as a tracked micro-label, the micro-line
/// verbatim right-aligned — above the unchanged slim
/// control row. The pill keeps the samples' action verbs.
class _ShellControlBar extends StatelessWidget {
  const _ShellControlBar({
    required this.busy,
    required this.onToggle,
    required this.stateWord,
    required this.cells,
    required this.microLine,
    required this.onSettings,
    required this.onServers,
    this.quiet = false,
  });

  final bool busy;
  final VoidCallback? onToggle;
  final String stateWord;
  final List<({String label, String value})> cells;
  final String microLine;
  final VoidCallback onSettings;
  final VoidCallback onServers;

  /// R1 (pro3 home): the Home tab's bar — no telemetry
  /// cells, no micro-line. R2: rendered by [_slimBar], the
  /// samples' slim dark tray; the filled pill is gone.
  /// Every other tab keeps the full bar.
  final bool quiet;

  /// Build 2148 (owner device verdict on 2147, 2026-11-24):
  /// «دکمه کانکت دیسکانکت درست کن وصل میشه نارنجی شه الان
  /// فرقی نداره اصلا» — the pill wore the SAME treatment in
  /// both settled states (the full bar was filled orange
  /// even for 'Not connected'; the slim bar was the same
  /// hairline pill for CONNECT and DISCONNECT), so the
  /// button showed no visible difference between states.
  /// The ruling now, identical in both bar forms: a settled
  /// CONNECTED word ('Connected', 'Connected via …',
  /// 'Connected — not answering' — the session is up, the
  /// word itself carries any caveat) fills the pill ORANGE
  /// with dark text; every other settled state is the
  /// neutral dark pill (near-black fill, hairline rim,
  /// light text, orange glyph). Busy keeps the dark pill
  /// with its spinner — transitional, confusable with
  /// neither settled state.
  bool get _pillConnected => stateWord.startsWith('Connected');

  Widget _roundButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) => Tooltip(
    message: tooltip,
    child: Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: MapUi.line),
          ),
          child: Icon(icon, size: 20, color: MapUi.dim),
        ),
      ),
    ),
  );

  /// R2: the word the bar's action carries. The two
  /// settled states take the samples' action verbs; every
  /// other word the model can settle on (a transition)
  /// keeps its own text, tracked and uppercased — the bar
  /// must not flatten information the model carries.
  /// Build 2149 (audit A48-01): BOTH bar forms use this
  /// word — before this build only the slim bar did, and
  /// the full bar's pill still read 'Connected' where the
  /// owner's order (and the slim bar) say DISCONNECT.
  /// Build 2150 (engine appearance audit E49-17): the
  /// Connected FAMILY takes DISCONNECT, not only the two
  /// exact settled words — the pill already fills orange
  /// for any word starting with 'Connected' (_pillConnected),
  /// so in 'Connected — not answering' the orange pill
  /// carried the capitalised state text instead of the
  /// action. No information is flattened: the state word
  /// itself still renders verbatim on the bar (the slim
  /// bar's tracked line, the full bar's telemetry) — only
  /// the ACTION word is unified. ('Connecting…' is safe:
  /// it does not share the 'Connected' prefix.)
  String get _actionWord {
    if (!busy) {
      if (stateWord == 'Not connected') return 'CONNECT';
      if (stateWord.startsWith('Connected')) {
        return 'DISCONNECT';
      }
    }
    return stateWord.toUpperCase();
  }

  /// R2: the Home tab's slim bar (see the class doc): a
  /// quiet dark tray with a hairline frame, the gear and
  /// shield round marks at either end, and the power action
  /// as a slim hairline-outlined pill — tracked uppercase
  /// action text with the small power glyph (orange, the
  /// page's one accent). Same callbacks, same busy contract
  /// as the full bar: no fire mid-toggle, spinner while busy.
  Widget _slimBar() => Container(
    decoration: BoxDecoration(
      color: MapUi.card,
      borderRadius: BorderRadius.circular(24),
      border: Border.all(color: MapUi.line),
    ),
    padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Fidelity repair (see the class doc): the bar's
        // claim contract, carried in the slim language —
        // the telemetry cells exactly as the full bar
        // renders them, then the state word verbatim as a
        // tracked micro-label with the micro-line verbatim
        // at the right. Nothing here is restyled text: the
        // model's words render as the model settled them.
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < cells.length; i++) ...[
              if (i > 0) const SizedBox(width: 10),
              Expanded(
                child: MapBarCell(label: cells[i].label, value: cells[i].value),
              ),
            ],
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Flexible(
              child: Text(
                stateWord,
                style: Ember.microLabel.copyWith(color: MapUi.text),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              microLine,
              textAlign: TextAlign.right,
              style: const TextStyle(
                fontSize: Ember.fontMicro,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.8,
                color: Color(0xFF8E8E93),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Container(height: 1, color: MapUi.line),
        const SizedBox(height: 8),
        Row(
          children: [
        _roundButton(
          icon: Icons.settings_rounded,
          tooltip: 'Settings',
          onTap: onSettings,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: busy ? null : onToggle,
              borderRadius: BorderRadius.circular(999),
              child: Container(
                // Build 2147 (strict-audit F10): 46 -> 48,
                // the sample's slim-pill height.
                // Build 2148: the fill follows the state (see
                // _pillConnected) — orange while a session is
                // up, the hairline dark pill otherwise.
                height: 48,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: _pillConnected ? Ember.orange : null,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: _pillConnected
                        ? Ember.orange
                        : const Color(0x40FFFFFF),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (busy) ...[
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: _pillConnected
                              ? const Color(0xFF1A1206)
                              : Ember.orange,
                        ),
                      ),
                      const SizedBox(width: 10),
                    ] else ...[
                      Icon(
                        Icons.power_settings_new_rounded,
                        size: 16,
                        color: _pillConnected
                            ? const Color(0xFF1A1206)
                            : Ember.orange,
                      ),
                      const SizedBox(width: 10),
                    ],
                    Flexible(
                      child: Text(
                        _actionWord,
                        style: TextStyle(
                          fontSize: Ember.fontBody,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 2,
                          color: _pillConnected
                              ? const Color(0xFF1A1206)
                              : MapUi.text,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        _roundButton(
          icon: Icons.shield_rounded,
          tooltip: 'Locations',
          onTap: onServers,
        ),
          ],
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    // R2: the Home tab renders the slim bar; the full bar
    // below is every other tab's, unchanged.
    if (quiet) return _slimBar();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < cells.length; i++) ...[
              if (i > 0) const SizedBox(width: 10),
              Expanded(
                child: MapBarCell(label: cells[i].label, value: cells[i].value),
              ),
            ],
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(top: 5, right: 8),
          child: Text(
            microLine,
            textAlign: TextAlign.right,
            style: const TextStyle(
              fontSize: Ember.fontMicro,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.8,
              color: Color(0xFF8E8E93),
            ),
          ),
        ),
        const SizedBox(height: 8),
      Row(
        children: [
          _roundButton(
            icon: Icons.settings_rounded,
            tooltip: 'Settings',
            onTap: onSettings,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: busy ? null : onToggle,
                borderRadius: BorderRadius.circular(999),
                child: Container(
                  height: 52,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    // Build 2148 (see _pillConnected): the
                    // pill used to be filled orange in EVERY
                    // state — 'Not connected' rode the same
                    // orange as 'Connected'. Now orange is
                    // the connected state only; disconnected
                    // and busy wear the neutral dark pill
                    // (near-black fill, hairline rim), the
                    // same treatment as the slim bar's.
                    color: _pillConnected ? Ember.orange : MapUi.card,
                    borderRadius: BorderRadius.circular(999),
                    border: _pillConnected
                        ? null
                        : Border.all(color: const Color(0x40FFFFFF)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (busy) ...[
                        SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: _pillConnected
                                ? const Color(0xFF1A1206)
                                : Ember.orange,
                          ),
                        ),
                        const SizedBox(width: 8),
                      ] else ...[
                        // Build 2144: the samples' power glyph
                        // rides the pill beside the state word
                        // (pro5-off centres the whole state on
                        // this glyph); same icon the pre-reskin
                        // power switch carried. Build 2148:
                        // dark on the orange (connected) pill,
                        // orange on the dark pill.
                        Icon(
                          Icons.power_settings_new_rounded,
                          size: 18,
                          color: _pillConnected
                              ? const Color(0xFF1A1206)
                              : Ember.orange,
                        ),
                        const SizedBox(width: 8),
                      ],
                      Flexible(
                        child: Text(
                          // Build 2149 (audit A48-01): the
                          // action word, as the slim bar —
                          // DISCONNECT on the connected pill,
                          // not the state word 'Connected'.
                          // Caveat words ('Connected — not
                          // answering') still render verbatim
                          // via _actionWord's fall-through.
                          _actionWord,
                          style: TextStyle(
                            fontSize: Ember.fontTitle,
                            fontWeight: FontWeight.w600,
                            color: _pillConnected
                                ? const Color(0xFF1A1206)
                                : MapUi.text,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          _roundButton(
            icon: Icons.shield_rounded,
            tooltip: 'Locations',
            onTap: onServers,
          ),
        ],
      ),
      ],
    );
  }
}

/// The pulsing live-actors layer over the baked backdrop
/// (home marker, exit pin and badge, arc). Pointer-transparent:
/// it is pure decoration over the map.
class _ActorsLayer extends StatefulWidget {
  const _ActorsLayer({
    required this.pins,
    required this.selected,
    required this.connected,
    required this.badge,
    this.filament = false,
    this.homeLabel = 'HOME • IRAN',
  });

  final Set<String> pins;
  final String? selected;
  final bool connected;
  final String? badge;

  /// R1 (pro3 home): the filament arc + hollow-ring origin,
  /// Home tab only.
  final bool filament;
  final String homeLabel;

  @override
  State<_ActorsLayer> createState() => _ActorsLayerState();
}

class _ActorsLayerState extends State<_ActorsLayer>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1700),
  );

  /// The painter's repaint clock (build 2050, audit B-H4):
  /// bucketed to ~12 fps. This layer paints the FULL screen;
  /// at frame rate it repainted the whole display for the
  /// entire connected time. A 1700 ms pulse is
  /// indistinguishable at 12 fps.
  late final _BucketedRepaint _repaint = _BucketedRepaint(_pulse);

  bool _foreground = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // No _sync() here: it reads MediaQuery (disableAnimations),
    // which initState may not subscribe to — didChangeDependencies
    // runs right after initState and on every MediaQuery change.
  }

  @override
  void didUpdateWidget(_ActorsLayer old) {
    super.didUpdateWidget(old);
    _sync();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _sync();
  }

  void _sync() {
    // Build 2057 (audit F-H10): a user (or the test harness) who
    // turns animations off gets no pulse — the perpetual controller
    // otherwise never lets pumpAndSettle settle, so no widget test
    // could ever cover the connected phone shell.
    final still = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (widget.connected && widget.selected != null && _foreground && !still) {
      if (!_pulse.isAnimating) _pulse.repeat();
    } else {
      _pulse.stop();
      _pulse.value = 0;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _repaint.dispose();
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: CustomPaint(
      painter: MapActorsPainter(
        pins: widget.pins,
        selected: widget.selected,
        connected: widget.connected,
        homeLabel: widget.homeLabel,
        exitBadge: widget.badge,
        pulseAnim: _pulse,
        filament: widget.filament,
        repaint: _repaint,
      ),
      size: Size.infinite,
    ),
  );
}

/// A repaint listenable that quantizes an animation into
/// [stepsPerCycle] buckets, so a CustomPaint listening to it
/// repaints at a bounded rate instead of every frame
/// (build 2050).
class _BucketedRepaint extends ChangeNotifier {
  _BucketedRepaint(this._source) {
    _source.addListener(_onTick);
  }

  /// 20 buckets over the 1700 ms pulse cycle ≈ a 12 fps repaint.
  static const int stepsPerCycle = 20;

  final Animation<double> _source;
  int _bucket = -1;

  void _onTick() {
    final b = (_source.value * stepsPerCycle).floor();
    if (b != _bucket) {
      _bucket = b;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _source.removeListener(_onTick);
    super.dispose();
  }
}
