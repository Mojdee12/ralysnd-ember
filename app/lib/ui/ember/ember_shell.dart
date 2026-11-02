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
import '../../core/android_core.dart';
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
import 'map_mozilla.dart';
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
    with SingleTickerProviderStateMixin {
  int _tab = 0;
  late final XrayController _xray = XrayController();
  late final PsiphonController _psiphon = PsiphonController();
  late final LanternController _lantern = LanternController();
  late final WarpController _warp = WarpController();
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
    _pulse.dispose();
    for (final t in _shotTimers) {
      t.cancel();
    }
    _xray.dispose();
    _psiphon.dispose();
    _lantern.dispose();
    _warp.dispose();
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

  /// The Mozilla engine's matching hook, used by the home page:
  /// all other engines go off before Mozilla starts.
  Future<void> stopXray() async {
    if (_xray.state.running) await _xray.disconnect();
    await _stopPsiphon();
    await _stopLantern();
    await _stopWarp();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    if (widget.noCore != null) {
      return Scaffold(
        body: EmberBackground(child: SafeArea(child: widget.noCore!)),
      );
    }
    final v2ray = mode == 1;
    final psiphonMode = mode == 2;
    final lanternMode = mode == 3;
    final warpMode = mode == 4;
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
      else
        EmberAccounts(core: core, xray: _xray, v2ray: v2ray),
      EmberSettings(
        core: core,
        xray: _xray,
        psiphon: _psiphon,
        lantern: _lantern,
        warp: _warp,
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
    final shownTab = (_tab == 1 && mode != 0) ? 0 : _tab;
    return Scaffold(
      backgroundColor: MapUi.baseTop,
      body: ListenableBuilder(
        listenable: Listenable.merge([core, _xray, _psiphon]),
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
              // The backdrop: the navy gradient + the static
              // dotted map with its faint grid, painted once
              // behind its own RepaintBoundary.
              const Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [MapUi.baseTop, MapUi.baseBottom],
                    ),
                  ),
                ),
              ),
              Positioned.fill(
                child: RepaintBoundary(
                  child: CustomPaint(
                    painter: WorldMapPainter(
                      pins: const {},
                      selected: null,
                      connected: false,
                      pulse: 0,
                      homeLabel: '',
                      faint: true,
                      darkMap: true,
                      grid: true,
                    ),
                  ),
                ),
              ),
              // The baked backdrop (fidelity round 3): the dot
              // field rendered OFFLINE at 3600x1800 with the
              // samples' full detail stack (tool/bake_backdrop.py)
              // from the same raster and the same equirect cover
              // projection the live painter uses — BoxFit.cover
              // IS that transform — so the actors above stay
              // aligned at any window size. The live painter
              // beneath is the fallback until the asset's first
              // frame decodes.
              const Positioned.fill(
                child: RepaintBoundary(
                  child: Image(
                    image: AssetImage('assets/backdrop/map_backdrop.png'),
                    fit: BoxFit.cover,
                    filterQuality: FilterQuality.medium,
                  ),
                ),
              ),
              // A gentle vignette over the dot field, so the
              // scene's weight sits at the center like the
              // samples (the actors paint above it, undimmed).
              const Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: Alignment(0, -0.08),
                      radius: 1.25,
                      colors: [Colors.transparent, Color(0x5904090E)],
                      stops: [0.55, 1],
                    ),
                  ),
                ),
              ),
              // The map actors: pins, the arc, the home marker —
              // only ever from derivable data (see _actors).
              Positioned.fill(
                child: RepaintBoundary(
                  child: CustomPaint(
                    painter: WorldMapPainter(
                      pins: actors.pins,
                      selected: actors.selected,
                      connected: actors.connected,
                      pulse: 0,
                      homeLabel: actors.homeLabel,
                      darkMap: true,
                      selectedLabel: actors.selectedLabel,
                      drawPulse: false,
                      dots: false,
                    ),
                  ),
                ),
              ),
              if (actors.connected && actors.selected != null)
                Positioned.fill(
                  child: CustomPaint(
                    painter: PulseRingPainter(
                      selected: actors.selected,
                      anim: _pulse,
                      screenSpace: true,
                      repaint: _pulse,
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
              // The brand panel.
              Positioned(
                top: 20,
                left: 24,
                child: MapBrandPanel(
                  versionLine: 'v$appVersion • BUILD $appBuildNumber',
                ),
              ),
              // The engine chips (the navigation) + Settings.
              Positioned(
                top: 20,
                right: 24,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    for (final m in Features.engineModes) ...[
                      MapEngineChip(
                        name: _engineLabel(l, m),
                        active: bar.connectedEngine == m,
                        highlight:
                            bar.connectedEngine == m ||
                            (bar.connectedEngine == null &&
                                mode == m &&
                                _tab != 3),
                        onTap: () => setState(() {
                          mode = m;
                          _tab = 0;
                        }),
                      ),
                      const SizedBox(height: 8),
                    ],
                    // The Settings chip sits slightly apart
                    // from the engine stack, as in the samples.
                    const SizedBox(height: 6),
                    MapSettingsChip(
                      label: l.navSettings,
                      active: _tab == 3,
                      onTap: () => setState(() => _tab = 3),
                    ),
                  ],
                ),
              ),
              // The bottom control bar.
              Positioned(
                bottom: 22,
                left: 0,
                right: 0,
                child: Center(
                  child: FractionallySizedBox(
                    widthFactor: 0.90,
                    child: MapBottomBar(
                      on: bar.on,
                      busy: bar.busy,
                      onToggle: bar.onToggle,
                      stateWord: bar.stateWord,
                      segments: bar.segments,
                      microLine: bar.microLine,
                    ),
                  ),
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
            (
              label: 'UP',
              value: running ? fmtRate(xray.upRate) : '—',
              flex: 3,
            ),
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
                    : countryName
                  ).toUpperCase(),
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
        await stopXray();
        await core.setOn(true);
      });
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
