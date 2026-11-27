/// The Ember shell: the four mockup tabs under the floating bottom
/// navigation, the engines behind one mode switch, and the
/// arbitration that keeps exactly one tunnel up.
///
/// On Windows (desktop: true) the same pages and arbitration sit
/// in the Map Control shell instead (2.1.0): the dotted world map
/// IS the window, the engines switch from the glass chips at the
/// top right, and one wide glass control bar floats at the
/// bottom (see _buildDesktop).

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../app_info.dart';
import '../../app_settings.dart';
import '../../aether/aether_controller.dart';
import '../../core/android_core.dart';
import '../../desktop/pending_link.dart';
import '../../openvpn/openvpn_controller.dart';
import 'app_lock.dart';
import 'battery_report.dart';
import 'ember_format.dart';
import 'session_budget.dart';
import '../../openvpn/ovpn_intake.dart';
import '../../openvpn/ovpn_link.dart';
import '../../core/core_controller.dart';
import '../../core/models.dart';
import '../../features.dart';
import '../../l10n/app_localizations.dart';
import '../../lantern/lantern_controller.dart';
import '../../psiphon/psiphon_controller.dart';
import '../../psiphon/psiphon_platform.dart';
import '../../warp/warp_controller.dart';
import '../../xray/exit_info.dart' as xray_exit;
import '../../xray/xray_controller.dart';
import '../../xray/xray_models.dart';
import '../../xray/xray_platform.dart';
import '../widgets.dart' hide regionName;
import 'ember_accounts.dart';
import 'ember_format.dart';
import 'ember_home.dart';
import 'ember_servers.dart';
import 'ember_settings.dart';
import 'ember_theme.dart';
import 'lantern_pages.dart';
import 'aether_pages.dart';
import 'map_mozilla.dart';
import 'mozilla_bootstrap.dart';
import 'openvpn_pages.dart';
import 'wireguard_pages.dart';
import 'map_widgets.dart';
import 'profile_country.dart';
import 'psiphon_pages.dart';
import 'warp_pages.dart';
import 'world_map.dart';

class EmberShell extends StatefulWidget {
  const EmberShell({
    super.key,
    required this.core,
    required this.settings,
    this.banner,
    this.noCore,
    this.desktop = false,
  });

  final CoreController core;
  final AppSettings settings;
  final Widget? banner;
  final Widget? noCore;

  /// The Windows Fluent shell (rail + glass) instead of the phone
  /// shell (bottom navigation).
  final bool desktop;

  @override
  State<EmberShell> createState() => _EmberShellState();
}

class _EmberShellState extends State<EmberShell>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  int _tab = 0;
  late final XrayController _xray = XrayController();
  late final PsiphonController _psiphon = PsiphonController();
  late final LanternController _lantern = LanternController();
  late final WarpController _warp = WarpController();
  late final OpenVpnController _openvpn = OpenVpnController();
  late final AetherController _aetherWarp = AetherController('cfwarp');
  late final AetherController _aetherMasque = AetherController('masque');

  /// The Mozilla bootstrap handoff (build 2034, parity port): on
  /// connect, if the stored Guardian pass is missing or stale and
  /// a donor is configured, the donor engine fetches a fresh pass
  /// through itself before Mozilla starts. Donors on Windows:
  /// Psiphon, V2Ray, WARP+ (warp-plus, SOCKS 8086) or a relay URL.
  late final MozillaBootstrap _bootstrap = MozillaBootstrap(
    core: core,
    settings: widget.settings,
    psiphon: _psiphon,
    xray: _xray,
    warp: _warp,
  );

  // Pause with auto-resume (build 2033, parity port): the engine
  // the pause belongs to, when it ends, and its timers. In-memory
  // only — a process exit ends the pause, exactly as on Android.
  int? _pausedEngine;
  DateTime? _resumeAt;
  Timer? _pauseTimer;
  Timer? _pauseTicker;
  bool _defaultsApplied = false;

  /// The exit pin's pulse on the desktop map (1.6 s cycle); runs
  /// only while an engine is connected with a known exit.
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );

  /// The Mozilla locations' country codes, for the map pins
  /// behind the desktop Servers panel (loaded on entry).
  Set<String> _serverPins = const {};
  bool _pinsLoading = false;

  Future<void> _loadServerPins() async {
    if (_pinsLoading) return;
    _pinsLoading = true;
    try {
      final list = await core.call((api) => api.locations());
      if (mounted) {
        setState(
          () => _serverPins = {
            for (final loc in list.locations)
              if (loc.code.isNotEmpty) loc.code,
          },
        );
      }
    } catch (_) {
      // No pins: the map keeps just the home marker and the exit.
    } finally {
      _pinsLoading = false;
    }
  }

  CoreController get core => widget.core;

  /// The engine the panel shows: 0 = Mozilla, 1 = V2Ray, 2 = Psiphon,
  /// 3 = Lantern, 4 = WARP+ (persisted). Platforms that do not offer
  /// an engine never land on it (features.dart).
  int get mode => Features.clampMode(widget.settings.emberMode);
  set mode(int value) => widget.settings.update(emberMode: value);

  @override
  void initState() {
    super.initState();
    // W1: the desktop capture choice (XraySettings.tunCapture)
    // reaches the Windows Xray backend through the facade
    // resolver — the synced 2157 controller no longer passes it
    // (Android's VpnService has no such choice). Set once here,
    // where the live settings object lives; the resolver reads
    // it fresh on every connect.
    if (Platform.isWindows) {
      XrayPlatform.tunCaptureResolver = () => _xray.settings.tunCapture;
    }
    _xray.stopOtherEngine = () async {
      await _stopMozilla();
      await _stopPsiphon();
      await _stopLantern();
      await _stopWarp();
    };
    _psiphon.stopOtherEngine = () async {
      await _stopMozilla();
      if (_xray.state.running) await _xray.disconnect();
      await _stopLantern();
      await _stopWarp();
    };
    _lantern.stopOtherEngine = () async {
      await _stopMozilla();
      if (_xray.state.running) await _xray.disconnect();
      await _stopPsiphon();
      await _stopWarp();
    };
    _warp.stopOtherEngine = () async {
      await _stopMozilla();
      if (_xray.state.running) await _xray.disconnect();
      await _stopPsiphon();
      await _stopLantern();
    };
    // The controllers' stores live behind the platform backends.
    // Xray's backend exists on Android and Windows (M2), so its
    // controller loads on both; Psiphon/Lantern/WARP still load only
    // on Android (their Windows backends are later milestones — the
    // controllers simply stay in their stopped, empty state), and
    // the Android-only defaults stay on Android.
    if (Platform.isAndroid || Platform.isWindows) {
      unawaited(_xray.load());
    }
    if (Platform.isWindows) {
      // The desktop Psiphon page binds the controller's settings
      // and regions; load its store like Xray's (Android loads it
      // in its own block below).
      unawaited(_psiphon.load());
    }
    if (widget.desktop) {
      unawaited(_applyDesktopDefaults());
      unawaited(_applyDesktopTransportDefault());
    }
    if (Platform.isWindows) {
      _psiphon.load();
      _lantern.load();
      _warp.load();
      _openvpn.load();
      _aetherWarp.load();
      _aetherMasque.load();
    }
    if (Platform.isAndroid) {
      _psiphon.load();
      _lantern.load();
      _warp.load();
      AndroidCore.loadMode();
      _applyEmber2Defaults();
      // Keep the controllers' view of their services fresh on return.
      unawaited(_xray.refreshState());
    }
    _startShotHarness();
    // ovpn:// links (build 2157's feature pick 1, W2 port):
    // the shell owns the OpenVPN controller, so it serves the
    // intake seam the paste sheet / QR scan offer ovpn links
    // to, and it drains links the OS handed the process (a
    // protocol activation — see desktop/pending_link.dart).
    if (Platform.isWindows) {
      OvpnLinkIntake.handler = _importOvpnLink;
      WidgetsBinding.instance.addObserver(this);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_drainPendingLink());
      });
    }
    _careTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted) _careTick();
    });
  }

  /// The app lock's session flag (Android's shell rule):
  /// one unlock per process, re-locked when the app leaves
  /// the foreground.
  bool _unlocked = false;
  bool get _lockedNow => widget.settings.appLockEnabled && !_unlocked;

  void _onUnlocked() {
    setState(() => _unlocked = true);
    unawaited(_drainPendingLink());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_drainPendingLink());
    }
    if ((state == AppLifecycleState.paused ||
            state == AppLifecycleState.hidden) &&
        widget.settings.appLockEnabled &&
        _unlocked) {
      setState(() => _unlocked = false);
    }
  }

  /// A link the OS handed the app (ovpn:// activation):
  /// route it through the same intake as a pasted link.
  Future<void> _drainPendingLink() async {
    // Behind the lock nothing imports (Android audit #5);
    // the link stays queued for the unlock.
    if (_lockedNow) return;
    final link = await PendingLink.take();
    if (link == null || !mounted) return;
    if (isOvpnLink(link)) await _importOvpnLink(link);
  }

  /// An ovpn:// / openvpn:// link (Android build 2157's
  /// wording and flow): the payload form imports directly;
  /// the official import-profile form downloads its profile
  /// first (https only, the file intake's 256 KB cap). The
  /// profile lands through the OpenVPN controller's own
  /// import path, on the OpenVPN list.
  Future<bool> _importOvpnLink(String link) async {
    if (!mounted) return false;
    final payload = parseOvpnLink(link);
    if (payload == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('That link is not an OpenVPN profile link'),
        ),
      );
      return false;
    }
    final name = payload.name.isEmpty ? 'Imported profile' : payload.name;
    String text;
    switch (payload) {
      case OvpnLinkText t:
        text = t.text;
      case OvpnLinkFetch(:final url):
        final fetched = await fetchOvpnProfileText(url);
        if (!mounted) return false;
        if (fetched == null || !isOvpnProfileText(fetched)) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Could not download that OpenVPN profile'),
            ),
          );
          return false;
        }
        text = fetched;
    }
    try {
      await _openvpn.importProfile(name, text);
    } catch (e) {
      if (!mounted) return false;
      final raw = e is StateError ? e.message : '$e';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            raw == 'not-an-ovpn-profile'
                ? 'That link does not carry an OpenVPN profile'
                : raw.startsWith('core-rejected:')
                    ? 'OpenVPN rejected the profile: '
                        '${raw.substring('core-rejected:'.length)}'
                    : 'Import failed: $raw',
          ),
        ),
      );
      return false;
    }
    if (!mounted) return true;
    setState(() {
      mode = 6; // OpenVPN on Windows' numbering.
      _tab = 1;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Imported $name')),
    );
    return true;
  }

  // ── SCREENSHOT HARNESS (win-work copy only) ─────────────────────
  // When EMBER_SHOT_DIR is set, cycle the shell through its main
  // pages on a timer (Mozilla home → V2Ray → Psiphon → Servers →
  // Settings, ~6 s each) and write the current page's name to
  // $EMBER_SHOT_DIR/current.txt at every step, so an outside capture
  // script can photograph each page deterministically. The variable
  // is never set in normal use; the harness is then fully inert.
  final List<Timer> _shotTimers = [];

  void _startShotHarness() {
    final dir = Platform.environment['EMBER_SHOT_DIR'];
    if (dir == null || dir.isEmpty) return;
    const steps = <({int mode, int tab, String name})>[
      (mode: 0, tab: 0, name: 'mozilla'),
      (mode: 1, tab: 0, name: 'v2ray'),
      (mode: 2, tab: 0, name: 'psiphon'),
      (mode: 0, tab: 1, name: 'servers'),
      (mode: 0, tab: 3, name: 'settings'),
    ];
    for (var i = 0; i < steps.length; i++) {
      final step = steps[i];
      _shotTimers.add(
        Timer(Duration(seconds: 5 + 6 * i), () {
          if (!mounted) return;
          setState(() {
            mode = step.mode;
            _tab = step.tab;
          });
          try {
            File('$dir/current.txt').writeAsStringSync(step.name);
          } catch (_) {
            // A failed marker must never disturb the app.
          }
        }),
      );
    }
    // With EMBER_SHOT_CONNECTED=1 the captures show the CONNECTED,
    // populated state (hero session values, exit location, the ON
    // pill) that the disconnected rounds never exercised. The seed
    // is fabricated demo data, re-applied on a fast timer because
    // the core's own poll keeps replacing the Mozilla status with
    // the real (off) one; each re-application rebuilds the shell
    // with the seeded values.
    if (Platform.environment['EMBER_SHOT_CONNECTED'] == '1') {
      _shotTimers.add(
        Timer.periodic(const Duration(milliseconds: 500), (_) {
          if (!mounted) return;
          _seedConnectedShotState();
          setState(() {});
        }),
      );
    }
  }

  /// The fabricated connected state for the screenshot harness
  /// (see _startShotHarness). Demo values only — no real account,
  /// server, or traffic is involved.
  void _seedConnectedShotState() {
    final now = DateTime.now();
    final startedAt = now.subtract(const Duration(minutes: 12, seconds: 34));
    core.status = CoreStatus.fromJson({
      'state': {
        'phase': 'running',
        'message': 'Connected',
        'since': startedAt.toIso8601String(),
      },
      'proxy': {
        'listen': '127.0.0.1:1080',
        'country_code': 'DE',
        'country_name': 'Germany',
        'city_name': 'Frankfurt',
        'started_at': startedAt.toIso8601String(),
        'transport': 'h2',
      },
      'active_account': {
        'id': 'shot',
        'name': 'Demo Account',
        'email': 'demo@example.com',
        'enabled': true,
        'active': true,
        'status': 'ready',
        'usage': {
          'unlimited': false,
          'limit_bytes': 53687091200,
          'remaining_bytes': 38654705664,
        },
      },
      'exit': {
        'ipv4': '85.214.132.10',
        'country_code': 'DE',
        'country_name': 'Germany',
        'city': 'Frankfurt',
        'network': 'Mozilla',
      },
      'system_proxy': 'tun',
      'system_proxy_supported': true,
      'tun_supported': true,
      'tun': {'state': 'on', 'installed': true},
      'selection': 'DE',
      'accounts': {'total': 1},
    });
    if (_xray.profiles.isEmpty) {
      _xray.profiles.addAll([
        Profile(
            id: 'shot-de',
            name: 'Frankfurt — VLESS',
            protocol: Protocol.vless,
            address: 'de1.demo.net',
            port: 443,
            uuidOrPassword: '00000000-0000-4000-8000-000000000001',
            network: 'tcp',
            security: 'reality',
          )
          ..delayMs = 86
          ..totalUpBytes = 12992256
          ..totalDownBytes = 155189248,
        Profile(
            id: 'shot-nl',
            name: 'Amsterdam — VMess',
            protocol: Protocol.vmess,
            address: 'nl1.demo.net',
            port: 443,
            uuidOrPassword: '00000000-0000-4000-8000-000000000002',
            network: 'ws',
            security: 'tls',
          )
          ..delayMs = 142
          ..totalUpBytes = 3145728
          ..totalDownBytes = 41943040,
        Profile(
          id: 'shot-us',
          name: 'New York — Trojan',
          protocol: Protocol.trojan,
          address: 'us1.demo.net',
          port: 443,
          uuidOrPassword: 'demo-password',
          network: 'tcp',
          security: 'tls',
        )..delayMs = 231,
      ]);
      _xray.selectedProfileId = 'shot-de';
    }
    _xray.state = XrayState(
      running: true,
      name: 'Frankfurt — VLESS',
      sinceMs: startedAt.millisecondsSinceEpoch,
      upBytes: 52428800,
      downBytes: 377487360,
    );
    _xray.upRate = 184320;
    _xray.downRate = 1258291;
    _xray.exitInfo = const xray_exit.ExitInfo(
      ip: '85.214.132.10',
      countryCode: 'DE',
      countryEn: 'Germany',
      city: 'Frankfurt',
    );
    _psiphon.state = PsiphonState(
      running: true,
      connected: true,
      vpnMode: true,
      sinceMs: startedAt.millisecondsSinceEpoch,
      upBytes: 8388608,
      downBytes: 96468992,
      region: 'DE',
      clientAddress: '85.214.132.10',
      regions: const ['DE', 'NL', 'US'],
    );
  }

  @override
  void dispose() {
    _careTimer?.cancel();
    _batteryTracker?.closeOpen(DateTime.now().millisecondsSinceEpoch);
    if (Platform.isWindows) {
      WidgetsBinding.instance.removeObserver(this);
      if (OvpnLinkIntake.handler == _importOvpnLink) {
        OvpnLinkIntake.handler = null;
      }
    }
    _pulse.dispose();
    for (final t in _shotTimers) {
      t.cancel();
    }
    _xray.dispose();
    _psiphon.dispose();
    _lantern.dispose();
    _warp.dispose();
    _pauseTimer?.cancel();
    _pauseTicker?.cancel();
    _openvpn.dispose();
    _aetherWarp.dispose();
    _aetherMasque.dispose();
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
    widget.settings.update(ember2DefaultsApplied: true);
  }

  bool _desktopDefaultsApplied = false;

  /// The desktop counterpart of [_applyEmber2Defaults] for the
  /// Mozilla capture mode (Part B): the Go core's factory default
  /// system_proxy.mode is "clear" — proxy-only, so a fresh Windows
  /// install connects and pings while NO system traffic flows (the
  /// first on-PC failure). Once per install, when the core first
  /// answers and is not running: if the TUN service is installed
  /// and the mode is still "clear", switch it to TUN. When the
  /// service is not installed the mode is left alone — the desktop
  /// Mozilla home shows the mode and the TUN install note, so the
  /// state is never silent. The flag is desktop-only
  /// (AppSettings.desktopDefaultsApplied); the Android flag and
  /// path are untouched.
  Future<void> _applyDesktopDefaults() async {
    if (widget.settings.desktopDefaultsApplied || _desktopDefaultsApplied) {
      return;
    }
    _desktopDefaultsApplied = true;
    // The Mozilla core needs a moment to answer after launch.
    for (var i = 0; i < 30 && core.status == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    final status = core.status;
    if (status == null || status.state.phase == Phase.running) {
      // Nothing answered, or a tunnel is already up (auto-connect):
      // keep the flag unset so a later launch tries again.
      _desktopDefaultsApplied = false;
      return;
    }
    try {
      if (status.tunSupported &&
          (status.tun?.installed ?? false) &&
          status.systemProxy == 'clear') {
        await core.setSystemProxy('tun');
      }
    } catch (_) {
      _desktopDefaultsApplied = false;
      return;
    }
    widget.settings.update(desktopDefaultsApplied: true);
  }

  bool _desktopTransportApplied = false;

  /// The desktop Mozilla transport default, pinned once (2.0.5):
  /// proxy.transport = "h2". The core's factory default is already
  /// "h2", but an install that ever saved "h3" (the Settings
  /// protocol choice presents H3 first) pays for it on every
  /// connect on a UDP-hostile network: the H3 session attempt runs
  /// under the core's whole 20 s connect timeout (config.
  /// ConnectTimeout) across the server's addresses before the
  /// engine falls back to H2 — the ~20 s desktop connect delay,
  /// while Android (H2) connects at once. Pin H2 once, while the
  /// engine is not running; afterwards the Settings choice owns
  /// the value (AppSettings.desktopTransportPinned). Desktop only —
  /// the Android defaults path never calls this.
  Future<void> _applyDesktopTransportDefault() async {
    if (widget.settings.desktopTransportPinned || _desktopTransportApplied) {
      return;
    }
    _desktopTransportApplied = true;
    // The Mozilla core needs a moment to answer after launch.
    for (var i = 0; i < 30 && core.status == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    final status = core.status;
    if (status == null || status.state.phase == Phase.running) {
      // Nothing answered, or a tunnel is already up: keep the flag
      // unset so a later launch tries again.
      _desktopTransportApplied = false;
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
      _desktopTransportApplied = false;
      return;
    }
    widget.settings.update(desktopTransportPinned: true);
  }

  /// The Xray engine's arbitration hook: Mozilla goes fully off first.
  Future<void> _stopMozilla() async {
    if (core.status?.state.phase == Phase.running ||
        core.status?.state.phase == Phase.starting) {
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
    if (_psiphon.state.running) await _psiphon.disconnect();
  }

  /// The Lantern engine goes off (the other engines' hooks pass
  /// through here).
  Future<void> _stopLantern() async {
    if (_lantern.state.running) await _lantern.disconnect();
  }

  /// The WARP+ engine goes off (the other engines' hooks pass
  /// through here).
  Future<void> _stopWarp() async {
    if (_warp.state.active) await _warp.disconnect();
  }

  /// The OpenVPN engine goes off.
  Future<void> _stopOpenVpn() async {
    if (_openvpn.state.running) await _openvpn.disconnect();
  }

  /// Both Aether engines go off (standalone WARP + MASQUE).
  Future<void> _stopAether() async {
    if (_aetherWarp.state.running) await _aetherWarp.disconnect();
    if (_aetherMasque.state.running) await _aetherMasque.disconnect();
  }

  // ── W5 care apparatus: the session data budget (Android
  // build 2095 feature 7) and the battery-report sampler
  // (build 2105), ported onto this shell's engine model.
  // One 5 s timer drives both; each costs a field read
  // while its setting is off.

  Timer? _careTimer;
  bool _budgetWarned = false;
  bool _budgetDisconnecting = false;
  int? _budgetLastUsedBytes;
  int? _budgetUnmeasurableNotedFor;
  BatteryLog? _batteryLog;
  BatterySessionTracker? _batteryTracker;
  bool _batteryLogLoading = false;
  bool _batteryTickBusy = false;

  static const _careEngineNames = {
    0: 'Mozilla',
    1: 'V2Ray',
    2: 'Psiphon',
    3: 'Lantern',
    4: 'WARP+',
    5: 'WireGuard',
    6: 'OpenVPN',
    7: 'EmberWarp',
    8: 'MASQUE',
  };

  /// Session bytes (up + down) for the engine running in
  /// [m]; null when that engine reports no session totals
  /// (the M19 rule: unknown, never 0).
  int? _sessionUsedBytes(int m) {
    switch (m) {
      case 0:
        final t = core.status?.traffic;
        return t == null ? null : t.up + t.down;
      case 1:
      case 5:
        return _xray.state.upBytes + _xray.state.downBytes;
      case 2:
        return _psiphon.state.upBytes + _psiphon.state.downBytes;
      case 3:
        return _lantern.state.countersReported
            ? _lantern.state.upBytes + _lantern.state.downBytes
            : null;
      case 4:
        return _warp.state.upBytes + _warp.state.downBytes;
      case 6:
        // The Windows OpenVPN backend reports no byte
        // counters — unmeasurable, honestly.
        return null;
      case 7:
        return _aetherWarp.upBytes + _aetherWarp.downBytes;
      case 8:
        return _aetherMasque.upBytes + _aetherMasque.downBytes;
      default:
        return null;
    }
  }

  Future<void> _disconnectEngine(int m) async {
    switch (m) {
      case 0:
        await _stopMozilla();
      case 1:
      case 5:
        if (_xray.state.running) await _xray.disconnect();
      case 2:
        await _stopPsiphon();
      case 3:
        await _stopLantern();
      case 4:
        await _stopWarp();
      case 6:
        if (_openvpn.state.connected) await _openvpn.disconnect();
      case 7:
        if (_aetherWarp.state.running) await _aetherWarp.disconnect();
      case 8:
        if (_aetherMasque.state.running) await _aetherMasque.disconnect();
    }
  }

  void _careTick() {
    _budgetTick();
    unawaited(_batteryTick());
  }

  /// The data-budget tick: warns once at 80% of the cap
  /// and disconnects the running engine at the cap (once
  /// per exceeded episode; a counter drop re-arms — a new
  /// session began inside one tick).
  void _budgetTick() {
    final capMb = widget.settings.sessionBudgetMb;
    final running = _connectedEngine;
    if (capMb <= 0 || running == null) {
      _budgetWarned = false;
      _budgetUnmeasurableNotedFor = null;
      _budgetDisconnecting = false;
      _budgetLastUsedBytes = null;
      return;
    }
    final used = _sessionUsedBytes(running);
    if (used != null) {
      final last = _budgetLastUsedBytes;
      if (last != null && used < last) {
        _budgetDisconnecting = false;
        _budgetWarned = false;
      }
      _budgetLastUsedBytes = used;
    }
    if (used == null) {
      if (_budgetUnmeasurableNotedFor != running && mounted) {
        _budgetUnmeasurableNotedFor = running;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'The data budget cannot be measured on '
              '${_careEngineNames[running] ?? 'this engine'} — '
              'the cap will not apply to this session.',
            ),
          ),
        );
      }
      return;
    }
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
        if (_budgetDisconnecting) return;
        _budgetDisconnecting = true;
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Data budget reached — disconnecting.'),
            ),
          );
        }
        unawaited(_disconnectEngine(running));
      case BudgetVerdict.ok:
        _budgetWarned = false;
    }
  }

  /// The battery sampler: while the report is enabled,
  /// each tick notes the connected engine into the session
  /// tracker, which records the battery level at each
  /// session's edges. Toggling off closes any open session.
  Future<void> _batteryTick() async {
    if (_batteryTickBusy) return;
    _batteryTickBusy = true;
    try {
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
      final running = _connectedEngine;
      String? label = running == null ? null : _careEngineNames[running];
      // A standalone EmberWarp session rides the Xray
      // section but keeps its own name (Android's doctrine).
      if (running == 1 && _xray.state.running && _xray.warpSession) {
        label = 'EmberWarp';
      }
      final reading = await readBatteryStatus();
      if (!mounted) return;
      _batteryTracker?.note(
        engine: label,
        nowMs: DateTime.now().millisecondsSinceEpoch,
        reading: reading,
      );
    } finally {
      _batteryTickBusy = false;
    }
  }

  /// The Mozilla engine's matching hook, used by the home page:
  /// all other engines go off before Mozilla starts.
  Future<void> stopXray() async {
    if (_xray.state.running) await _xray.disconnect();
    await _stopPsiphon();
    await _stopLantern();
    await _stopWarp();
    await _stopOpenVpn();
    await _stopAether();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    if (_lockedNow) {
      return AppLockPage(settings: widget.settings, onUnlocked: _onUnlocked);
    }
    if (widget.noCore != null) {
      return Scaffold(
        body: EmberBackground(child: SafeArea(child: widget.noCore!)),
      );
    }
    final v2ray = mode == 1;
    final psiphonMode = mode == 2;
    final lanternMode = mode == 3;
    final warpMode = mode == 4;
    final wireguardMode = mode == 5;
    final openvpnMode = mode == 6;
    final aetherWarpMode = mode == 7;
    final masqueMode = mode == 8;
    final pages = [
      EmberHome(
        core: core,
        xray: _xray,
        psiphon: _psiphon,
        lantern: _lantern,
        warp: _warp,
        mode: mode,
        onModeChanged: (m) => setState(() => mode = m),
        onOpenServers: () => setState(() {
          _tab = 1;
          if (widget.desktop) unawaited(_loadServerPins());
        }),
        onOpenAccounts: () => setState(() => _tab = 2),
        stopOtherEngine: stopXray,
        hideModeSwitch: widget.desktop,
        desktop: widget.desktop,
        openvpn: _openvpn,
        aetherWarp: _aetherWarp,
        aetherMasque: _aetherMasque,
      ),
      // In Psiphon mode the Servers tab is the exit-region list and
      // the Accounts tab the no-account status page; Lantern mode
      // swaps in its own fixed server view and status page; WARP
      // mode shows its setup summary and status page.
      if (psiphonMode)
        PsiphonRegionsView(psiphon: _psiphon)
      else if (lanternMode)
        LanternServersView(lantern: _lantern)
      else if (warpMode)
        WarpServersView(warp: _warp)
      else if (wireguardMode)
        WireGuardServersView(xray: _xray)
      else if (openvpnMode)
        OpenVpnServersView(openvpn: _openvpn)
      else if (aetherWarpMode)
        AetherServersView(controller: _aetherWarp)
      else if (masqueMode)
        AetherServersView(controller: _aetherMasque)
      else
        EmberServers(
          core: core,
          xray: _xray,
          v2ray: v2ray,
          onOpenAccounts: () => setState(() => _tab = 2),
          desktop: widget.desktop,
        ),
      if (psiphonMode)
        PsiphonAboutView(psiphon: _psiphon)
      else if (lanternMode)
        LanternAboutView(lantern: _lantern)
      else if (warpMode)
        WarpAboutView(warp: _warp)
      else if (wireguardMode)
        WireGuardAboutView(xray: _xray)
      else if (openvpnMode)
        OpenVpnStatusView(openvpn: _openvpn)
      else if (aetherWarpMode)
        AetherAboutView(controller: _aetherWarp)
      else if (masqueMode)
        AetherAboutView(controller: _aetherMasque)
      else
        EmberAccounts(
          core: core,
          xray: _xray,
          v2ray: v2ray,
          bootstrap: _bootstrap,
        ),
      EmberSettings(
        core: core,
        xray: _xray,
        psiphon: _psiphon,
        lantern: _lantern,
        warp: _warp,
        openvpn: _openvpn,
        aetherWarp: _aetherWarp,
        aetherMasque: _aetherMasque,
        settings: widget.settings,
        desktop: widget.desktop,
      ),
    ];
    if (widget.desktop) return _buildDesktop(l, pages);
    return Scaffold(
      backgroundColor: Ember.bg,
      body: EmberBackground(
        child: SafeArea(
          bottom: false,
          child: Column(
            children: [
              if (widget.banner != null) widget.banner!,
              Expanded(
                child: IndexedStack(index: _tab, children: pages),
              ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: EmberBackground(
        child: SafeArea(
          top: false,
          child: EmberBottomNav(
            index: _tab,
            onChanged: (i) => setState(() => _tab = i),
            items: [
              (Icons.home_rounded, l.navHome),
              (Icons.public_rounded, l.navServers),
              (
                Icons.people_rounded,
                v2ray ? l.navSubscriptions : l.navAccounts,
              ),
              (Icons.settings_rounded, l.navSettings),
            ],
          ),
        ),
      ),
    );
  }

  /// The Map Control desktop shell (2.1.0, the approved dark
  /// samples): the dotted world map IS the window — deep navy
  /// backdrop, the home marker and (while connected) the glowing
  /// exit pin with its arc — and everything else floats over it:
  /// the brand panel top-left, the engine chips top-right (they
  /// are the navigation), the pages' own panels, and the wide
  /// glass control bar at the bottom, which always describes the
  /// live tunnel (or the current page's engine when none is up).
  Widget _buildDesktop(AppLocalizations l, List<Widget> pages) {
    // The Servers tab only exists as its own view in Mozilla
    // mode (the locations panel); in the other modes the tab
    // lands back on the engine home (V2Ray's configs panel and
    // Psiphon's region chips ARE their servers views).
    final shownTab = (_tab == 1 && mode != 0 && mode < 5) ? 0 : _tab;
    return Scaffold(
      backgroundColor: MapUi.baseTop,
      body: ListenableBuilder(
        listenable: Listenable.merge([
          core,
          _xray,
          _psiphon,
          _lantern,
          _warp,
          _openvpn,
          _aetherWarp,
          _aetherMasque,
        ]),
        builder: (context, _) {
          final bar = _barModel(l);
          final actors = _actors(context, l, bar.engine);
          // The pulse runs only while there is a lit exit pin.
          if (actors.connected && actors.selected != null) {
            if (!_pulse.isAnimating) _pulse.repeat();
          } else if (_pulse.isAnimating) {
            _pulse.stop();
          }
          return Stack(
            children: [
              // The backdrop (W1 recomposition, owner order
              // 2026-11-27 — «map control خودمون باشه»): the
              // shipped Map Control's own backdrop, the same
              // MapBackdropVisual the Android Home paints — base
              // gradient, the baked FINE-halftone field
              // (map_backdrop_home.webp) laid out by the shared
              // MapViewTransform cover projection, the top shade
              // and the Home faint scrim. The 2038 desktop stack
              // (navy gradient + live dot painter with grid + the
              // coarse 3600px PNG bake + vignette) is retired:
              // the map on this window is the app's own map, not
              // a reinterpretation of it.
              const Positioned.fill(child: MapBackdropVisual(faint: true)),
              // The map actors: pins, the arc, the home marker —
              // only ever from derivable data (see _actors),
              // drawn by the shipped MapActorsPainter in its
              // Home (filament) language: the hollow-ring home
              // marker, the thin filament arc with its nodes,
              // the pulsing exit pin.
              Positioned.fill(
                child: RepaintBoundary(
                  child: CustomPaint(
                    painter: MapActorsPainter(
                      pins: actors.pins,
                      selected: actors.selected,
                      connected: actors.connected,
                      homeLabel: actors.homeLabel,
                      exitBadge: actors.selectedLabel.isEmpty
                          ? null
                          : actors.selectedLabel,
                      pulseAnim: _pulse,
                      filament: true,
                      repaint: _pulse,
                    ),
                  ),
                ),
              ),
              // The pages float over the map.
              Positioned.fill(
                child: IndexedStack(
                  index: shownTab,
                  children: [
                    pages[0],
                    if (mode == 0)
                      MapServersPanel(
                        core: core,
                        onClose: () => setState(() => _tab = 0),
                      )
                    else
                      pages[1],
                    _accountsPanel(pages[2]),
                    pages[3],
                  ],
                ),
              ),
              if (widget.banner != null)
                Positioned(
                  top: 16,
                  left: 300,
                  right: 300,
                  child: widget.banner!,
                ),
              // The header (W1 recomposition): the shipped
              // Home's own header — the EMBER wordmark with its
              // orange dot at the left; at the right, the
              // protection state (dot + tracked micro-label)
              // and, in Mozilla mode, the Account action under
              // it. The 2038 glass brand panel and the vertical
              // engine-chip stack are retired: the switcher is
              // the shipped Home's chip row, down with the bar.
              Positioned(
                top: 20,
                left: 24,
                right: 24,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'EMBER',
                          style: TextStyle(
                            fontSize: 21,
                            fontWeight: FontWeight.w300,
                            letterSpacing: 6,
                            color: MapUi.text,
                          ),
                        ),
                        SizedBox(width: 8),
                        DecoratedBox(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Ember.orange,
                          ),
                          child: SizedBox(width: 6, height: 6),
                        ),
                      ],
                    ),
                    const Spacer(),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            DecoratedBox(
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: bar.on
                                    ? const Color(0xFF3DDC84)
                                    : const Color(0xFF6E6E73),
                              ),
                              child: const SizedBox(width: 7, height: 7),
                            ),
                            const SizedBox(width: 7),
                            Text(
                              bar.on ? 'PROTECTED' : 'NOT PROTECTED',
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 2.2,
                                color: MapUi.dim,
                              ),
                            ),
                          ],
                        ),
                        if (mode == 0) ...[
                          const SizedBox(height: 4),
                          GestureDetector(
                            onTap: () => setState(() => _tab = 2),
                            child: const Text(
                              'Account',
                              style: TextStyle(
                                fontSize: 12,
                                color: Ember.orange,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              // The pause strip (build 2033, parity port): while
              // an engine is up it offers Pause with the four
              // durations; while paused it counts down with
              // Resume now / Cancel.
              if (_pausedEngine != null || bar.on)
                Positioned(
                  // Above the W1 bottom stack (switcher row +
                  // slim bar + gaps ≈ 195 px from the bottom).
                  bottom: 206,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: _pausedEngine != null
                        ? MapGlass(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 8,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  'Paused · resumes in $_pauseCountdown',
                                  style: Ember.body,
                                ),
                                const SizedBox(width: 10),
                                TextButton(
                                  onPressed: () => _resumePause(bar.onToggle),
                                  child: const Text('Resume now'),
                                ),
                                TextButton(
                                  onPressed: _cancelPause,
                                  child: const Text('Cancel'),
                                ),
                              ],
                            ),
                          )
                        : PopupMenuButton<Duration>(
                            tooltip: 'Pause',
                            onSelected: (d) =>
                                _pauseConnection(bar.engine, bar.onToggle, d),
                            itemBuilder: (context) => [
                              for (final (label, d) in const [
                                ('Pause for 5 minutes', Duration(minutes: 5)),
                                ('Pause for 15 minutes', Duration(minutes: 15)),
                                ('Pause for 30 minutes', Duration(minutes: 30)),
                                ('Pause for 1 hour', Duration(hours: 1)),
                              ])
                                PopupMenuItem(value: d, child: Text(label)),
                            ],
                            child: const MapGlass(
                              padding: EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 8,
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.pause_rounded,
                                    size: 16,
                                    color: MapUi.text,
                                  ),
                                  SizedBox(width: 6),
                                  Text(
                                    'Pause',
                                    style: TextStyle(color: MapUi.text),
                                  ),
                                ],
                              ),
                            ),
                          ),
                  ),
                ),
              // The bottom stack (W1 recomposition): the
              // shipped Home's engine switcher directly above
              // the shipped slim control bar — one centred
              // column, tray width capped at 720 on the desktop
              // canvas. The 2038 wide glass MapBottomBar and the
              // top-right chip stack are retired.
              Positioned(
                bottom: 22,
                left: 0,
                right: 0,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // The switcher: while an engine is connected
                    // it is the shipped quiet line — the engine
                    // names joined by '·', the connected one in
                    // orange; otherwise the one row of compact
                    // hairline chips, flexed by name length, the
                    // current engine in orange.
                    Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 720),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 24),
                          child: bar.connectedEngine != null
                              ? Text.rich(
                                  TextSpan(
                                    children: [
                                      for (
                                        var i = 0;
                                        i < Features.engineModes.length;
                                        i++
                                      )
                                        TextSpan(
                                          text:
                                              _engineLabel(
                                                l,
                                                Features.engineModes[i],
                                              ) +
                                              (i ==
                                                      Features
                                                              .engineModes
                                                              .length -
                                                          1
                                                  ? ''
                                                  : '  ·  '),
                                          style: TextStyle(
                                            color:
                                                Features.engineModes[i] ==
                                                    bar.connectedEngine
                                                ? Ember.orange
                                                : MapUi.dim,
                                          ),
                                        ),
                                    ],
                                  ),
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(fontSize: 12),
                                )
                              : Row(
                                  children: [
                                    for (
                                      var i = 0;
                                      i < Features.engineModes.length;
                                      i++
                                    ) ...[
                                      if (i > 0) const SizedBox(width: 4),
                                      Expanded(
                                        flex:
                                            _engineLabel(
                                              l,
                                              Features.engineModes[i],
                                            ).length +
                                            2,
                                        child: GestureDetector(
                                          onTap: () => setState(() {
                                            final m = Features.engineModes[i];
                                            if (_pausedEngine != null &&
                                                m != _pausedEngine) {
                                              _cancelPause();
                                            }
                                            if (m != 0) _bootstrap.cancel();
                                            mode = m;
                                            _tab = 0;
                                          }),
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(
                                              vertical: 7,
                                            ),
                                            alignment: Alignment.center,
                                            decoration: BoxDecoration(
                                              color: const Color(0xFF141518),
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                              border: Border.all(
                                                color:
                                                    mode ==
                                                            Features
                                                                .engineModes[i] &&
                                                        _tab != 3
                                                    ? Ember.orange
                                                    : MapUi.line,
                                              ),
                                            ),
                                            child: Text(
                                              _engineLabel(
                                                l,
                                                Features.engineModes[i],
                                              ),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontSize: 11,
                                                color:
                                                    mode ==
                                                            Features
                                                                .engineModes[i] &&
                                                        _tab != 3
                                                    ? Ember.orange
                                                    : MapUi.dim,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 720),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 24),
                          child: _DesktopControlBar(
                            busy: bar.busy,
                            onToggle: bar.onToggle,
                            stateWord: bar.stateWord,
                            segments: bar.segments,
                            microLine: bar.microLine,
                            onSettings: () => setState(() => _tab = 3),
                            onServers: () => setState(() => _tab = 1),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  String _engineLabel(AppLocalizations l, int m) => switch (m) {
    0 => l.modeMozilla,
    1 => l.modeV2ray,
    2 => l.modePsiphon,
    3 => l.modeLantern,
    5 => 'WireGuard',
    6 => 'OpenVPN',
    7 => 'WARP',
    8 => 'MASQUE',
    _ => l.modeWarp,
  };

  /// The Accounts page inside a floating glass panel.
  Widget _accountsPanel(Widget page) => Padding(
    padding: const EdgeInsets.fromLTRB(24, 96, 24, 118),
    child: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620),
        child: MapGlass(padding: const EdgeInsets.all(6), child: page),
      ),
    ),
  );

  /// Whether engine [m]'s tunnel is up (its own truth — the
  /// chips light per engine, whatever page is showing).
  bool _engineConnected(int m) => switch (m) {
    0 =>
      core.status?.state.phase == Phase.running ||
          core.status?.state.phase == Phase.starting,
    1 => _xray.state.running,
    2 => _psiphon.state.connected,
    3 => _lantern.state.running,
    4 => _warp.state.active,
    5 => _xray.state.running,
    6 => _openvpn.state.connected,
    7 => _aetherWarp.state.connected,
    8 => _aetherMasque.state.connected,
    _ => false,
  };

  /// The engine whose tunnel is actually up, if any. The
  /// current page's engine wins when its own tunnel is up —
  /// the same precedence the bottom bar uses — so the chips
  /// and the bar always agree about which engine is THE
  /// connected one.
  int? get _connectedEngine {
    if (_engineConnected(mode)) return mode;
    if (core.status?.state.phase == Phase.running ||
        core.status?.state.phase == Phase.starting) {
      return 0;
    }
    if (_xray.state.running) return 1;
    if (_psiphon.state.running) return 2;
    if (_lantern.state.running) return 3;
    if (_warp.state.active) return 4;
    if (_openvpn.state.connected) return 6;
    if (_aetherWarp.state.connected) return 7;
    if (_aetherMasque.state.connected) return 8;
    return null;
  }

  /// Everything the bottom bar shows, for the bar's engine (the
  /// connected one, else the current page's): state, toggle,
  /// segments, and the honesty-ruled micro-line. Only values the
  /// app truly knows ever appear; the rest read "—".
  ({
    int engine,
    int? connectedEngine,
    bool on,
    bool busy,
    String stateWord,
    Color stateColor,
    List<({String label, String value, int flex})> segments,
    String microLine,
    VoidCallback onToggle,
  })
  _barModel(AppLocalizations l) {
    final connected = _connectedEngine;
    // The current page's engine wins when its own tunnel is up
    // (the normal case — arbitration keeps exactly one tunnel);
    // otherwise the bar describes whichever engine is connected,
    // and only then the page's engine.
    final engine = _engineConnected(mode) ? mode : (connected ?? mode);
    switch (engine) {
      case 1:
        final xray = _xray;
        final running = xray.state.running;
        final selected = xray.selected;
        final exit = xray.exitInfo;
        final profileCode = selected == null
            ? null
            : profileCountryCode(selected);
        final location = exit != null
            ? (exit.city.isNotEmpty
                  ? '${exit.displayName} • ${exit.city}'
                  : exit.displayName)
            : (profileCode != null
                  ? (xray_exit.englishCountryNames[profileCode] ?? profileCode)
                  : '—');
        final latency = selected != null && selected.delayMs >= 0
            ? 'LATENCY ${latDigits(selected.delayMs)}ms • '
            : '';
        return (
          engine: 1,
          connectedEngine: connected,
          on: running,
          busy: xray.connecting,
          stateWord: running ? 'Connected' : 'Not connected',
          stateColor: running ? MapUi.text : MapUi.dim,
          segments: [
            (label: 'ACTIVE CONFIG', value: selected?.name ?? '—', flex: 5),
            (label: 'LOCATION', value: location, flex: 5),
            (label: 'EXIT IP', value: exit?.ip ?? '—', flex: 4),
            (label: 'UP', value: running ? fmtRate(xray.upRate) : '—', flex: 3),
            (
              label: 'DOWN',
              value: running ? fmtRate(xray.downRate) : '—',
              flex: 3,
            ),
          ],
          microLine:
              '$latency${selected?.protocol.label.toUpperCase() ?? 'V2RAY'}',
          onToggle: () => unawaited(_toggleXray(l)),
        );
      case 2:
        final psiphon = _psiphon;
        final state = psiphon.state;
        final on = state.connected;
        final exit = psiphon.exitInfo;
        final regionCode = on && state.region.isNotEmpty
            ? state.region
            : psiphon.settings.region;
        final egressIp = exit?.ip.isNotEmpty == true
            ? exit!.ip
            : (state.clientAddress.isNotEmpty ? state.clientAddress : '—');
        final session = on && state.sinceMs > 0
            ? fmtDuration(
                DateTime.now().difference(
                  DateTime.fromMillisecondsSinceEpoch(state.sinceMs),
                ),
              )
            : '—';
        return (
          engine: 2,
          connectedEngine: connected,
          on: on,
          busy: psiphon.connecting || (state.running && !on),
          stateWord: on
              ? 'Connected via Psiphon'
              : (state.running ? 'Connecting…' : 'Not connected'),
          stateColor: on ? MapUi.text : MapUi.dim,
          segments: [
            (
              label: 'EXIT REGION',
              value: regionCode.isEmpty
                  ? l.psiphonRegionAuto
                  : regionName(regionCode),
              flex: 5,
            ),
            (label: 'EXIT IP', value: egressIp, flex: 4),
            (
              label: 'UP',
              value: state.running ? fmtRate(psiphon.upRate) : '—',
              flex: 3,
            ),
            (
              label: 'DOWN',
              value: state.running ? fmtRate(psiphon.downRate) : '—',
              flex: 3,
            ),
            (label: 'SESSION', value: session, flex: 3),
          ],
          microLine: 'PSIPHON',
          onToggle: () => unawaited(_togglePsiphon(l)),
        );
      case 3:
        final lantern = _lantern;
        final lOn = lantern.state.running;
        return (
          engine: 3,
          connectedEngine: connected,
          on: lOn,
          busy: lantern.connecting,
          stateWord: lOn ? 'Connected' : 'Not connected',
          stateColor: lOn ? MapUi.text : MapUi.dim,
          segments: [
            (
              label: 'STATUS',
              value: lantern.state.error ?? (lOn ? 'Connected' : '—'),
              flex: 5,
            ),
          ],
          microLine: 'LANTERN',
          onToggle: () => unawaited(_toggleLantern(l)),
        );
      case 4:
        final warpPlus = _warp;
        final wOn = warpPlus.state.connected;
        final wExit = warpPlus.exitInfo;
        return (
          engine: 4,
          connectedEngine: connected,
          on: wOn,
          busy: warpPlus.connecting,
          stateWord: wOn ? 'Connected' : 'Not connected',
          stateColor: wOn ? MapUi.text : MapUi.dim,
          segments: [
            (label: 'EXIT IP', value: wExit?.ip ?? '—', flex: 4),
            (label: 'COUNTRY', value: wExit?.countryCode ?? '—', flex: 3),
            (label: 'UP', value: wOn ? fmtRate(warpPlus.upRate) : '—', flex: 3),
            (
              label: 'DOWN',
              value: wOn ? fmtRate(warpPlus.downRate) : '—',
              flex: 3,
            ),
          ],
          microLine: 'WARP+',
          onToggle: () => unawaited(_toggleWarpPlus(l)),
        );
      case 5:
        final wgSelected = _xray.selected;
        final wgOn = _xray.state.running;
        return (
          engine: 5,
          connectedEngine: connected,
          on: wgOn,
          busy: _xray.connecting,
          stateWord: wgOn ? 'Connected' : 'Not connected',
          stateColor: wgOn ? MapUi.text : MapUi.dim,
          segments: [
            (label: 'ACTIVE CONFIG', value: wgSelected?.name ?? '—', flex: 5),
            (label: 'UP', value: wgOn ? fmtRate(_xray.upRate) : '—', flex: 3),
            (
              label: 'DOWN',
              value: wgOn ? fmtRate(_xray.downRate) : '—',
              flex: 3,
            ),
          ],
          microLine: 'WIREGUARD',
          onToggle: () => unawaited(_toggleXray(l)),
        );
      case 6:
        final ovpn = _openvpn;
        final oOn = ovpn.state.connected;
        return (
          engine: 6,
          connectedEngine: connected,
          on: oOn,
          busy: ovpn.connecting,
          stateWord: oOn ? 'Connected' : 'Not connected',
          stateColor: oOn ? MapUi.text : MapUi.dim,
          segments: [
            (
              label: 'PROFILE',
              value: ovpn.state.profileName.isNotEmpty
                  ? ovpn.state.profileName
                  : '—',
              flex: 5,
            ),
            (
              label: 'EXIT IP',
              value: ovpn.state.exitIp.isNotEmpty ? ovpn.state.exitIp : '—',
              flex: 4,
            ),
            (label: 'UP', value: oOn ? fmtRate(ovpn.upRate) : '—', flex: 3),
            (label: 'DOWN', value: oOn ? fmtRate(ovpn.downRate) : '—', flex: 3),
          ],
          microLine: 'OPENVPN',
          onToggle: () => unawaited(_toggleOpenVpn(l)),
        );
      case 7:
      case 8:
        final aether = engine == 7 ? _aetherWarp : _aetherMasque;
        final aState = aether.state;
        final aOn = aState.connected;
        return (
          engine: engine,
          connectedEngine: connected,
          on: aOn,
          busy: aether.connecting,
          stateWord: aOn
              ? 'Connected'
              : aState.running
              ? 'Connecting…'
              : 'Not connected',
          stateColor: aOn ? MapUi.text : MapUi.dim,
          segments: [
            (
              label: 'SERVER',
              value: aState.server.isNotEmpty ? aState.server : '—',
              flex: 5,
            ),
            (
              label: 'RTT',
              value: aState.rtt.isNotEmpty ? aState.rtt : '—',
              flex: 3,
            ),
            (
              label: 'PROFILE',
              value: aState.profile.isNotEmpty ? aState.profile : '—',
              flex: 4,
            ),
          ],
          microLine: engine == 7 ? 'WARP' : 'MASQUE',
          onToggle: () => unawaited(_toggleAether(l, aether)),
        );
      default:
        final status = core.status;
        final phase = status?.state.phase;
        final running = phase == Phase.running;
        final exit = status?.exit;
        final proxy = status?.proxy;
        final usage = status?.activeAccount?.usage;
        final location = exit != null
            ? (exit.city.isNotEmpty
                  ? '${exit.city} • ${exit.countryName}'
                  : exit.countryName)
            : proxy != null
            ? (proxy.cityName.isNotEmpty
                  ? '${proxy.cityName} • ${proxy.countryName}'
                  : proxy.countryName)
            : '—';
        final testMs = status?.lastTest?.totalMs ?? 0;
        return (
          engine: 0,
          connectedEngine: connected,
          on: running,
          busy: phase == Phase.starting,
          stateWord: running
              ? 'Connected'
              : phase == Phase.starting
              ? 'Connecting…'
              : 'Not connected',
          stateColor: running ? MapUi.text : MapUi.dim,
          segments: [
            (label: 'LOCATION', value: location, flex: 1),
            (label: 'EXIT IP', value: exit?.ipv4 ?? '—', flex: 1),
            (
              label: 'QUOTA USED',
              value: usage == null || usage.unlimited
                  ? '—'
                  : fmtBytes(usage.usedBytes),
              flex: 1,
            ),
            (
              label: 'QUOTA LEFT',
              value: usage == null
                  ? '—'
                  : usage.unlimited
                  ? 'Unlimited'
                  : fmtBytes(usage.remainingBytes),
              flex: 1,
            ),
          ],
          microLine:
              '${running && testMs > 0 ? 'LATENCY ${latDigits(testMs)}ms • ' : ''}MOZILLA',
          onToggle: () => unawaited(_toggleMozilla()),
        );
    }
  }

  /// The map's actors for the bar's engine: the pins, the lit
  /// exit, and its label — strictly from derivable data (a
  /// profile's claimed country, a through-tunnel exit lookup, the
  /// core's selection, the locations list). An engine whose exit
  /// country is unknown gets no pin and no arc.
  ({
    Set<String> pins,
    String? selected,
    bool connected,
    String homeLabel,
    String selectedLabel,
  })
  _actors(BuildContext context, AppLocalizations l, int engine) {
    final homeLabel =
        ('${l.mapHome} • ${localizedCountryName(context, 'IR', 'Iran')}')
            .toUpperCase();
    switch (engine) {
      case 1:
        final xray = _xray;
        final pins = <String>{
          for (final profile in xray.profiles)
            if (profileCountryCode(profile) != null)
              profileCountryCode(profile)!,
        };
        final exitCode = xray.state.running ? xray.exitInfo?.countryCode : null;
        if (exitCode != null && exitCode.isNotEmpty) pins.add(exitCode);
        final selectedProfile = xray.selected;
        final profileCode = selectedProfile == null
            ? null
            : profileCountryCode(selectedProfile);
        final selected = (exitCode != null && exitCode.isNotEmpty)
            ? exitCode
            : profileCode;
        final exitCity = xray.exitInfo?.city ?? '';
        final countryName = selected == null
            ? ''
            : (xray_exit.englishCountryNames[selected] ?? selected);
        return (
          pins: pins,
          selected: selected,
          connected: xray.state.running && selected != null,
          homeLabel: homeLabel,
          // The pin badge carries the full "COUNTRY • CITY"
          // when the exit lookup named a city (the Mozilla
          // badge's format); the bare country otherwise.
          selectedLabel: selected == null
              ? ''
              : (exitCode != null && exitCode.isNotEmpty && exitCity.isNotEmpty
                        ? '$countryName • $exitCity'
                        : countryName)
                    .toUpperCase(),
        );
      case 2:
        final state = _psiphon.state;
        final code = state.connected
            ? (_psiphon.exitInfo?.countryCode ??
                  (state.region.isNotEmpty ? state.region : null))
            : null;
        return (
          pins: const {},
          selected: code,
          connected: state.connected && code != null,
          homeLabel: homeLabel,
          selectedLabel: code == null
              ? ''
              : (xray_exit.englishCountryNames[code] ?? code).toUpperCase(),
        );
      default:
        final status = core.status;
        final running = status?.state.phase == Phase.running;
        final code = running
            ? (status?.exit?.countryCode ??
                  status?.proxy?.countryCode ??
                  ((status?.selection ?? '').isNotEmpty &&
                          status?.selection != 'fastest'
                      ? status?.selection
                      : null))
            : null;
        final exit = status?.exit;
        return (
          pins: _tab == 1 ? _serverPins : const {},
          selected: code,
          connected: running && code != null,
          homeLabel: homeLabel,
          selectedLabel: code == null
              ? ''
              : (exit != null && exit.city.isNotEmpty
                        ? '${exit.countryName} • ${exit.city}'
                        : (xray_exit.englishCountryNames[code] ??
                              status?.proxy?.countryName ??
                              code))
                    .toUpperCase(),
        );
    }
  }

  /// The Mozilla bar toggle: off when running; when off, the
  /// other engines stop first (the shell's arbitration), then
  /// the core starts.
  Future<void> _toggleMozilla() async {
    final phase = core.status?.state.phase;
    if (phase == Phase.running) {
      await runShowingErrors(context, () => core.setOn(false));
    } else if (phase == Phase.off || phase == Phase.waiting || phase == null) {
      await runShowingErrors(context, () async {
        // Build 2034 bootstrap handoff (parity port): a stale or
        // missing Guardian pass is fetched through the configured
        // donor first; the donor stops before Mozilla starts.
        final verdict = await _bootstrap.prepareIfNeeded();
        if (verdict.cancelled) return;
        if (!verdict.proceed) {
          throw StateError(verdict.message ?? 'Bootstrap failed');
        }
        await stopXray();
        await core.setOn(true);
      });
    }
  }

  /// Disconnects [engine] via its bar toggle and schedules the
  /// reconnect (build 2033 parity): the toggle callback is the
  /// bar's own, so pause/resume ride the exact connect path.
  void _pauseConnection(int engine, VoidCallback toggle, Duration d) {
    setState(() {
      _pausedEngine = engine;
      _resumeAt = DateTime.now().add(d);
    });
    _pauseTimer?.cancel();
    _pauseTimer = Timer(d, () {
      _pauseTicker?.cancel();
      _pauseTicker = null;
      final e = _pausedEngine;
      _pausedEngine = null;
      _resumeAt = null;
      if (!mounted || e == null) return;
      setState(() {});
      if (_connectedEngine != null) return; // something else is up
      _barModel(AppLocalizations.of(context)).onToggle();
    });
    _pauseTicker?.cancel();
    _pauseTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    toggle();
  }

  void _resumePause(VoidCallback toggle) {
    final e = _pausedEngine;
    if (e == null) return;
    _pauseTimer?.cancel();
    _pauseTimer = null;
    _pauseTicker?.cancel();
    _pauseTicker = null;
    setState(() {
      _pausedEngine = null;
      _resumeAt = null;
    });
    if (_connectedEngine != null) return;
    _barModel(AppLocalizations.of(context)).onToggle();
  }

  void _cancelPause() {
    _pauseTimer?.cancel();
    _pauseTimer = null;
    _pauseTicker?.cancel();
    _pauseTicker = null;
    _pausedEngine = null;
    _resumeAt = null;
  }

  String get _pauseCountdown {
    final at = _resumeAt;
    if (at == null) return '';
    final left = at.difference(DateTime.now());
    if (left.isNegative) return '0:00';
    final mm = left.inMinutes;
    final ss = (left.inSeconds % 60).toString().padLeft(2, '0');
    return '$mm:$ss';
  }

  /// The Lantern bar toggle (on Windows the engine reports its
  /// unavailable state — the toggle surfaces that error honestly).
  Future<void> _toggleLantern(AppLocalizations l) async {
    try {
      if (_lantern.state.running) {
        await _lantern.disconnect();
      } else {
        await _lantern.connect();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  /// The WARP+ (warp-plus) bar toggle.
  Future<void> _toggleWarpPlus(AppLocalizations l) async {
    try {
      if (_warp.state.active) {
        await _warp.disconnect();
      } else {
        await _warp.connect();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  /// The OpenVPN bar toggle.
  Future<void> _toggleOpenVpn(AppLocalizations l) async {
    try {
      if (_openvpn.state.running) {
        await _openvpn.disconnect();
      } else {
        await _openvpn.connect();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  /// The Aether engines' bar toggle (standalone WARP + MASQUE).
  Future<void> _toggleAether(AppLocalizations l, AetherController a) async {
    try {
      if (a.state.running) {
        await a.disconnect();
      } else {
        await a.connect();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  /// The V2Ray bar toggle, with the desktop page's error words.
  Future<void> _toggleXray(AppLocalizations l) async {
    try {
      if (_xray.state.running) {
        await _xray.disconnect();
      } else {
        await _xray.connect();
      }
    } on StateError catch (e) {
      if (!mounted) return;
      final message = switch (e.message) {
        'no-profile' => l.noProfileSelected,
        'unsupported' => l.unsupportedProtocol,
        _ => l.startFailed,
      };
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  /// The Psiphon bar toggle.
  Future<void> _togglePsiphon(AppLocalizations l) async {
    try {
      if (_psiphon.state.running) {
        await _psiphon.disconnect();
      } else {
        await _psiphon.connect();
      }
    } on StateError {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(l.startFailed)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }
}

/// The desktop shell's control bar (W1 recomposition): the
/// shipped Map Control's slim bar — the same composition the
/// Android Home's _ShellControlBar renders in its quiet form —
/// carried on the desktop canvas. The telemetry cells exactly as
/// the shell's bar model settled them, the state word verbatim
/// as a tracked micro-label with the micro-line verbatim at the
/// right, a hairline, then the control row: the round Settings
/// and Locations buttons flanking the pill. The pill follows the
/// shipped 2148 ruling: a settled Connected word fills it ORANGE
/// with dark text; every other settled state is the neutral dark
/// pill (hairline rim, light text, orange glyph); busy keeps the
/// dark pill with its spinner.
class _DesktopControlBar extends StatelessWidget {
  const _DesktopControlBar({
    required this.busy,
    required this.onToggle,
    required this.stateWord,
    required this.segments,
    required this.microLine,
    required this.onSettings,
    required this.onServers,
  });

  final bool busy;
  final VoidCallback? onToggle;
  final String stateWord;
  final List<({String label, String value, int flex})> segments;
  final String microLine;
  final VoidCallback onSettings;
  final VoidCallback onServers;

  bool get _pillConnected => stateWord.startsWith('Connected');

  String get _actionWord {
    if (!busy) {
      if (stateWord == 'Not connected') return 'CONNECT';
      if (stateWord.startsWith('Connected')) {
        return 'DISCONNECT';
      }
    }
    return stateWord.toUpperCase();
  }

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

  @override
  Widget build(BuildContext context) => Container(
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
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < segments.length; i++) ...[
              if (i > 0) const SizedBox(width: 10),
              Expanded(
                flex: segments[i].flex,
                child: MapBarCell(
                  label: segments[i].label,
                  value: segments[i].value,
                ),
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
}
