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
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../app_settings.dart';
import '../../core/android_core.dart';
import '../../core/core_controller.dart';
import '../../core/models.dart';
import '../../features.dart';
import '../../l10n/app_localizations.dart';
import '../../lantern/lantern_controller.dart';
import '../../psiphon/psiphon_controller.dart';
import '../../warp/warp_controller.dart';
import '../../xray/xray_controller.dart';
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
    if (Platform.isAndroid) {
      _psiphon.load();
      _lantern.load();
      _warp.load();
      AndroidCore.loadMode();
      _applyEmber2Defaults();
      // Keep the controllers' view of their services fresh on return.
      unawaited(_xray.refreshState());
    }
  }

  @override
  void dispose() {
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
      backgroundColor: Ember.bg,
      body: EmberBackground(
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
                ),
              ),
            ),
            Positioned.fill(
              child: BackdropFilter(
                filter: ui.ImageFilter.blur(sigmaX: 5, sigmaY: 5),
                child: ColoredBox(color: Ember.bg.withValues(alpha: 0.45)),
              ),
            ),
            Row(
              children: [
                _DesktopRail(
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
                  accountsLabel:
                      mode == 1 ? l.navSubscriptions : l.navAccounts,
                ),
                Expanded(
                  child: Column(
                    children: [
                      if (widget.banner != null) widget.banner!,
                      Expanded(
                        child: Align(
                          alignment: Alignment.topCenter,
                          child: ConstrainedBox(
                            constraints:
                                const BoxConstraints(maxWidth: 1120),
                            child:
                                IndexedStack(index: _tab, children: pages),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
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

/// The desktop shell's left rail: brand block, one entry per offered
/// engine (selecting one opens its home), Servers and Settings, and
/// the Accounts entry at the foot.
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
    required this.accountsLabel,
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
  final String accountsLabel;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 212,
      decoration: BoxDecoration(
        color: Ember.surface.withValues(alpha: 0.78),
        border: const Border(right: BorderSide(color: Ember.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 20, 18, 16),
            child: Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    gradient: Ember.gradient,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.local_fire_department_rounded,
                    color: Color(0xFF1A1206),
                    size: 22,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Ralysnd Ember',
                    style: Ember.heading.copyWith(fontSize: 15.5),
                    overflow: TextOverflow.ellipsis,
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
            padding: EdgeInsets.symmetric(horizontal: 18, vertical: 8),
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
          _RailItem(
            icon: Icons.people_rounded,
            label: accountsLabel,
            selected: tab == 2,
            onTap: onAccounts,
          ),
          const SizedBox(height: 14),
        ],
      ),
    );
  }
}

/// One rail entry: the mockups' ember-gradient pill when selected.
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
    final fg = selected ? const Color(0xFF1A1206) : Ember.dim;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              gradient: selected ? Ember.gradient : null,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: [
                Icon(icon, size: 20, color: fg),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: selected ? const Color(0xFF1A1206) : Ember.text,
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
