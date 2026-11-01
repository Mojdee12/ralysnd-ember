/// The Ember shell: the four mockup tabs under the floating bottom
/// navigation, the engines behind one mode switch, and the
/// arbitration that keeps exactly one tunnel up.
///
/// On Windows (desktop: true) the same pages and arbitration sit in
/// the Fluent desktop shell instead: a left rail switches the engine
/// (the locked Windows mockups), over the dotted world map behind
/// frosted glass (PLAN.md §1).

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

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
import 'desktop_widgets.dart';
import 'ember_accounts.dart';
import 'ember_home.dart';
import 'ember_servers.dart';
import 'ember_settings.dart';
import 'ember_theme.dart';
import 'lantern_pages.dart';
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

class _EmberShellState extends State<EmberShell> {
  int _tab = 0;
  late final XrayController _xray = XrayController();
  late final PsiphonController _psiphon = PsiphonController();
  late final LanternController _lantern = LanternController();
  late final WarpController _warp = WarpController();
  bool _defaultsApplied = false;

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
            final encrypted = list.isNotEmpty &&
                list.every(
                  (s) => s.toString().startsWith('https://') ||
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
        onOpenServers: () => setState(() => _tab = 1),
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

  /// The Windows Fluent shell: the locked mockups' left rail (one
  /// entry per offered engine, then Servers and Settings) beside the
  /// same pages the phone shell shows, over the dotted world map
  /// blurred once behind the glass cards.
  Widget _buildDesktop(AppLocalizations l, List<Widget> pages) {
    String engineLabel(int m) => switch (m) {
          0 => l.modeMozilla,
          1 => l.modeV2ray,
          2 => l.modePsiphon,
          3 => l.modeLantern,
          _ => l.modeWarp,
        };
    return Scaffold(
      backgroundColor: const Color(0xFF11141C),
      body: Stack(
        children: [
          // The mockups' backdrop: a deep graphite-navy base with
          // the dotted world map BRIGHT across the whole window;
          // each glass card blurs it locally (no global blur — that
          // is what washed the map out in 2.0.1). The whole backdrop
          // sits in a RepaintBoundary: it is fully static, so its
          // layer is painted once and composited under everything,
          // never repainted by page rebuilds or value ticks.
          const Positioned.fill(child: ColoredBox(color: Color(0xFF11141C))),
          Positioned.fill(
            child: RepaintBoundary(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: CustomPaint(
                      painter: WorldMapPainter(
                        pins: const {},
                        selected: null,
                        connected: false,
                        pulse: 0,
                        homeLabel: '',
                        faint: true,
                        backdrop: true,
                      ),
                    ),
                  ),
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: RadialGradient(
                          center: const Alignment(0, -1.15),
                          radius: 1.15,
                          colors: [
                            // Kept very faint: this glow sits behind the
                            // first cards, whose backdrop blur would wash
                            // their glass warm if it were any stronger.
                            Ember.orange.withValues(alpha: 0.04),
                            Colors.transparent,
                          ],
                          stops: const [0, 0.55],
                        ),
                      ),
                    ),
                  ),
                  // The mockups' map calms toward the bottom edge, so
                  // the status bar stays readable over it.
                  const Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.transparent,
                            Colors.transparent,
                            Color(0x9911141C),
                          ],
                          stops: [0, 0.74, 1],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Row(
              children: [
                ListenableBuilder(
                  listenable: core,
                  builder: (context, _) {
                    final account = core.status?.activeAccount;
                    return _DesktopRail(
                      engines: [
                        for (final m in Features.engineModes)
                          (mode: m, label: engineLabel(m)),
                      ],
                      tab: _tab,
                      mode: mode,
                      onEngine: (m) => setState(() {
                        mode = m;
                        _tab = 0;
                      }),
                      onServers: () => setState(() => _tab = 1),
                      onAccounts: () => setState(() => _tab = 2),
                      onSettings: () => setState(() => _tab = 3),
                      serversLabel: l.navServers,
                      settingsLabel: l.navSettings,
                      accountEmail: account?.email ?? '',
                      accountName: account?.name ?? '',
                    );
                  },
                ),
                Expanded(
                  child: Column(
                    children: [
                      if (widget.banner != null) widget.banner!,
                      Expanded(
                        // The desktop pages use the full window
                        // width (mockup E) — no phone-width cap.
                        child: IndexedStack(index: _tab, children: pages),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
    );
  }
}

/// The Fluent rail's engine glyphs, echoing the mockups (globe,
/// linked nodes, umbrella).
IconData _engineIcon(int mode) => switch (mode) {
      0 => Icons.public_rounded,
      1 => Icons.hub_rounded,
      2 => Icons.umbrella_rounded,
      3 => Icons.highlight_rounded,
      _ => Icons.bolt_rounded,
    };

/// The desktop shell's left rail, as mockup E draws it (~250 px):
/// the big flame brand block at the top, one entry per offered
/// engine, a divider, Servers and Settings, and the account chip
/// (initials avatar + the signed-in email, or "No account") pinned
/// at the bottom — a tap on it opens the Accounts page.
class _DesktopRail extends StatelessWidget {
  const _DesktopRail({
    required this.engines,
    required this.tab,
    required this.mode,
    required this.onEngine,
    required this.onServers,
    required this.onAccounts,
    required this.onSettings,
    required this.serversLabel,
    required this.settingsLabel,
    required this.accountEmail,
    required this.accountName,
  });

  final List<({int mode, String label})> engines;
  final int tab;
  final int mode;
  final ValueChanged<int> onEngine;
  final VoidCallback onServers;
  final VoidCallback onAccounts;
  final VoidCallback onSettings;
  final String serversLabel;
  final String settingsLabel;
  final String accountEmail;
  final String accountName;

  @override
  Widget build(BuildContext context) {
    final who = accountEmail.isNotEmpty ? accountEmail : accountName;
    return Container(
      width: 250,
      decoration: BoxDecoration(
        color: Ember.surface.withValues(alpha: 0.78),
        border: const Border(right: BorderSide(color: Ember.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The brand block: the mockups' shield-and-flame mark
          // over the name, centered (no app-icon tile).
          const Padding(
            padding: EdgeInsets.fromLTRB(18, 24, 18, 20),
            child: Column(
              children: [
                EmberShieldMark(size: 66),
                SizedBox(height: 10),
                Text(
                  'Ralysnd Ember',
                  style: TextStyle(
                    fontSize: 16.5,
                    fontWeight: FontWeight.w700,
                    color: Ember.text,
                  ),
                ),
              ],
            ),
          ),
          for (final e in engines)
            _RailItem(
              icon: _engineIcon(e.mode),
              label: e.label,
              selected: tab == 0 && mode == e.mode,
              onTap: () => onEngine(e.mode),
            ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            child: Divider(color: Ember.line, height: 1),
          ),
          _RailItem(
            icon: Icons.layers_rounded,
            label: serversLabel,
            selected: tab == 1,
            onTap: onServers,
          ),
          _RailItem(
            icon: Icons.settings_rounded,
            label: settingsLabel,
            selected: tab == 3,
            onTap: onSettings,
          ),
          const Spacer(),
          // The account chip pinned at the foot.
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: onAccounts,
                borderRadius: BorderRadius.circular(14),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 9),
                  decoration: BoxDecoration(
                    color: tab == 2
                        ? Ember.orange.withValues(alpha: 0.16)
                        : Ember.card.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Ember.line),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 34,
                        height: 34,
                        decoration: const BoxDecoration(
                          color: Ember.cardSoft,
                          shape: BoxShape.circle,
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          _initials(who),
                          style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w800,
                            color: Ember.orange,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          who.isEmpty ? 'No account' : who,
                          style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: Ember.text,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The avatar's initials: the first letters of the first two
  /// words of the name/email, or "?" with no account.
  static String _initials(String who) {
    final parts =
        who.split(RegExp(r'[\s@._-]+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first[0].toUpperCase();
    return (parts[0][0] + parts[1][0]).toUpperCase();
  }
}

/// One rail entry: the mockups' translucent ember fill with an
/// orange edge bar when selected, plain dim text otherwise.
class _RailItem extends StatelessWidget {
  const _RailItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            decoration: BoxDecoration(
              color: selected
                  ? Ember.orange.withValues(alpha: 0.20)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
              border: Border(
                left: BorderSide(
                  color: selected ? Ember.orange : Colors.transparent,
                  width: 3,
                ),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 21,
                  color: selected ? Ember.orange : Ember.dim,
                ),
                const SizedBox(width: 13),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w700,
                      color: selected ? Ember.text : Ember.dim,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
