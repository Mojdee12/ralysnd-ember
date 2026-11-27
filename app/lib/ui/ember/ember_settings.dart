/// Settings, on mockup 4's layout: the flame-headed sections, the
/// connection-mode segmented card, toggle cards, and rows into the
/// deeper pages — with the engine's own section following the mode.
/// The About card (maker credit, license) lives on its own Info
/// page, reached from the «اینفو» row in the general section.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../aether/aether_controller.dart';
import '../../app_settings.dart';
import '../../core/android_core.dart';
import '../../core/core_controller.dart';
import '../../features.dart';
import '../../l10n/app_localizations.dart';
import '../../lantern/lantern_controller.dart';
import '../../openvpn/openvpn_controller.dart';
import '../../psiphon/psiphon_controller.dart';
import '../../warp/warp_controller.dart';
import '../../xray/config_builder.dart'
    show primaryResolver, dnsGroupMembers, resolverUnderTransport;
import '../../xray/xray_controller.dart';
import '../../xray/xray_models.dart';
import '../bypass_apps_page.dart';
import '../settings_page.dart';
import 'aether_pages.dart';
import 'app_lock.dart';
import 'automation_pages.dart';
import 'battery_report.dart';
import 'chain_builder_page.dart';
import 'daily_report_page.dart';
import 'ember_format.dart';
import 'ember_info.dart';
import 'ember_logs_page.dart';
import 'ember_sync.dart';
import 'leak_test_page.dart';
import 'map_settings.dart';
import 'map_widgets.dart';
import 'ember_theme.dart';
import 'lantern_pages.dart';
import 'openvpn_pages.dart';
import 'psiphon_pages.dart';
import 'warp_pages.dart';
import 'warp_settings_page.dart' hide WarpSettingsPage;
import 'wireguard_pages.dart';
import 'xray_logs_page.dart';
import 'xray_section.dart';

class EmberSettings extends StatelessWidget {
  final CoreController core;
  final XrayController xray;
  final PsiphonController psiphon;
  final LanternController lantern;
  final WarpController warp;
  final OpenVpnController openvpn;
  final AetherController aetherWarp;
  final AetherController aetherMasque;
  final AppSettings settings;

  /// The Windows desktop shell: the settings are the mockup's
  /// two-column card grid at full width, not the phone column.
  final bool desktop;

  const EmberSettings({
    super.key,
    required this.core,
    required this.xray,
    required this.psiphon,
    required this.lantern,
    required this.warp,
    required this.openvpn,
    required this.aetherWarp,
    required this.aetherMasque,
    required this.settings,
    this.desktop = false,
  });

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final v2ray = settings.emberMode == 1;
    final psiphonMode = settings.emberMode == 2;
    final lanternMode = settings.emberMode == 3;
    final warpMode = settings.emberMode == 4;
    final wgMode = settings.emberMode == 5;
    final openvpnMode = settings.emberMode == 6;
    final aetherWarpMode = settings.emberMode == 7;
    final masqueMode = settings.emberMode == 8;
    final engineSection = v2ray
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Desktop only: the Windows backend's capture
              // choice. Android always captures through its
              // VpnService and never shows this; off = proxy
              // mode (local SOCKS/HTTP only).
              if (Features.desktopShell) ...[
                _ToggleCard(
                  title: 'System-wide capture (TUN)',
                  subtitle: 'Off = proxy mode: local SOCKS/HTTP only',
                  value: xray.settings.tunCapture,
                  onChanged: (v) async {
                    xray.settings.tunCapture = v;
                    await xray.save();
                  },
                ),
                const SizedBox(height: 10),
              ],
              XraySection(
                xray: xray,
                settings: settings,
                openvpn: openvpn,
                psiphon: psiphon,
                warp: aetherWarp,
                masque: aetherMasque,
              ),
            ],
          )
        : psiphonMode
        ? _PsiphonSection(psiphon: psiphon)
        : lanternMode
        ? _LanternSection(lantern: lantern)
        : warpMode
        ? _WarpSection(warp: warp)
        : wgMode
        ? _WireGuardSection(xray: xray)
        : openvpnMode
        ? _OpenVpnSection(openvpn: openvpn)
        : aetherWarpMode
        ? _AetherSection(controller: aetherWarp, xray: xray, name: 'EmberWarp')
        : masqueMode
        ? _AetherSection(controller: aetherMasque, xray: xray, name: 'MASQUE')
        : _MozillaSection(core: core);
    final generalCard = GlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        children: [
          // Per-app routing is an Android concept (its page is
          // served entirely by the Android channel); Windows has
          // no equivalent, so the row is not offered there.
          if (!Features.desktopShell) ...[
            _Row(
              icon: Icons.route_rounded,
              label: l.perAppProxy,
              onTap: () => Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const BypassAppsPage())),
            ),
            const Divider(color: Ember.line, height: 1),
          ],
          _Row(
            icon: Icons.tune_rounded,
            label: l.allSettings,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => Scaffold(
                  appBar: AppBar(),
                  body: SettingsPage(core: core, settings: settings),
                ),
              ),
            ),
          ),
          const Divider(color: Ember.line, height: 1),
          _Row(
            icon: Icons.language_rounded,
            label: l.languageRow,
            value: settings.language == 'fa' ? 'فارسی' : settings.language,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => Scaffold(
                  appBar: AppBar(),
                  body: SettingsPage(
                    core: core,
                    settings: settings,
                    opening: SettingsSection.general,
                  ),
                ),
              ),
            ),
          ),
          const Divider(color: Ember.line, height: 1),
          _Row(
            icon: Icons.info_outline_rounded,
            label: l.infoRow,
            onTap: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const EmberInfoPage())),
          ),
        ],
      ),
    );
    // The care-pack panels (W5): Android's settings tail —
    // the Iran panel under the V2Ray section, the
    // cross-engine Automation & diagnostics panel, the
    // settings-damage surfaces and Privacy & sync — composed
    // under whichever engine section is showing, in both
    // layouts.
    final fullSection = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        engineSection,
        if (v2ray) ...[
          const SizedBox(height: 14),
          IranFeatures2147Panel(xray: xray),
        ],
        const SizedBox(height: 14),
        _AutomationPanel(
          core: core,
          settings: settings,
          xray: xray,
          psiphon: psiphon,
          lantern: lantern,
          openvpn: openvpn,
          warp: aetherWarp,
          masque: aetherMasque,
        ),
        if (settings.storeUnreadable) ...[
          const SizedBox(height: 14),
          const MapSettingsPanel(
            title: 'Settings protected',
            children: [
              MapSettingRow(
                label: 'Your settings file could not be read',
                subtitle:
                    'The file is still there, so Ember is not '
                    'overwriting it — your settings are safe, '
                    'but changes will not be saved until the '
                    'app restarts and can read the file.',
                trailing: const SizedBox.shrink(),
                divider: false,
              ),
            ],
          ),
        ] else if (settings.storeDamaged) ...[
          const SizedBox(height: 14),
          const MapSettingsPanel(
            title: 'Settings recovered',
            children: [
              MapSettingRow(
                label: 'Your settings file was damaged',
                subtitle:
                    'Ember kept a copy of the damaged file and '
                    'started from defaults. Your app lock PIN '
                    'and GitHub sync sign-in did not survive — '
                    'set them up again here.',
                trailing: const SizedBox.shrink(),
                divider: false,
              ),
            ],
          ),
        ],
        if (settings.saveError != null && !settings.storeUnreadable) ...[
          const SizedBox(height: 14),
          MapSettingsPanel(
            title: 'Settings not saving',
            children: [
              MapSettingRow(
                label: 'Changes could not be saved to disk',
                subtitle:
                    'Settings are kept only until the app '
                    'closes. (${settings.saveError})',
                trailing: const SizedBox.shrink(),
                divider: false,
              ),
            ],
          ),
        ],
        const SizedBox(height: 14),
        MapSettingsPanel(
          title: 'Privacy & sync',
          children: [
            MapSettingRow(
              label: 'App lock',
              subtitle: settings.appLockEnabled
                  ? (settings.appLockBiometric
                        ? 'On — PIN or biometrics asked when the app opens'
                        : 'On — a PIN is asked when the app opens')
                  : 'Off — set a PIN to gate the app',
              trailing: _navChevron,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => AppLockSettingsPage(settings: settings),
                ),
              ),
            ),
            MapSettingRow(
              label: 'Sync via GitHub',
              subtitle: settings.syncGistId.isNotEmpty
                  ? 'Set up — encrypted backup in your own gist'
                  : 'Encrypted backup of your configs in your own GitHub',
              divider: false,
              trailing: _navChevron,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => SyncPage(
                    settings: settings,
                    xray: xray,
                    openvpn: openvpn,
                    psiphon: psiphon,
                    warp: aetherWarp,
                    masque: aetherMasque,
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
    if (desktop) {
      // The desktop settings page (2.1.0, map_settings.dart):
      // the Map Control sample's floating glass panels —
      // Connection, General, About, DNS, Routing, More — with
      // the engine section appended full-width underneath.
      return MapSettingsPage(
        core: core,
        settings: settings,
        engineSection: fullSection,
        xray: xray,
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
      children: [
        const Center(
          child: Icon(
            Icons.local_fire_department_rounded,
            color: Ember.orange,
            size: 34,
          ),
        ),
        const SizedBox(height: 6),
        Center(child: Text(l.navSettings, style: Ember.title)),
        Center(child: Text('Ralysnd Ember', style: Ember.caption)),
        const SizedBox(height: 20),
        fullSection,
        const SizedBox(height: 18),
        Text(l.generalSection, style: Ember.heading),
        const SizedBox(height: 10),
        generalCard,
      ],
    );
  }
}

/// The settings rows' forward chevron (Android's
/// _navChevron, build 2056: LTR points right).
const _navChevron = Icon(
  Icons.chevron_right_rounded,
  color: MapUi.faint,
  size: 20,
);

/// The cross-engine Automation & diagnostics panel
/// (Android build 2065/2095/2149, W5 port): the fallback
/// chain, auto-connect triggers, custom chains, the leak
/// test, the filtering probe, the logs hub, the daily
/// problem report (DEFAULT OFF), the tunnel MTU and the
/// session data budget.
class _AutomationPanel extends StatelessWidget {
  const _AutomationPanel({
    required this.core,
    required this.settings,
    required this.xray,
    required this.psiphon,
    required this.lantern,
    required this.openvpn,
    required this.warp,
    required this.masque,
  });
  final CoreController core;
  final AppSettings settings;
  final XrayController xray;
  final PsiphonController psiphon;
  final LanternController lantern;
  final OpenVpnController openvpn;
  final AetherController warp;
  final AetherController masque;

  @override
  Widget build(BuildContext context) {
    final reportCount = xray.problemJournal.countForDay(DateTime.now());
    return MapSettingsPanel(
      title: 'Automation & diagnostics',
      children: [
        MapSettingRow(
          label: 'Fallback chain',
          subtitle: settings.fallbackChainEnabled
              ? 'On — ${settings.fallbackChain.map(emberEngineLabel).join(' → ')}'
              : 'Off — a failed connect stays failed',
          trailing: _navChevron,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => FallbackChainPage(settings: settings),
            ),
          ),
        ),
        MapSettingRow(
          label: 'Auto-connect',
          subtitle: settings.emberAutoConnect
              ? 'On — boot, untrusted Wi-Fi, network change'
              : 'Off',
          trailing: _navChevron,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => AutoConnectPage(settings: settings),
            ),
          ),
        ),
        MapSettingRow(
          label: 'Custom chains',
          subtitle: settings.chains.isEmpty
              ? 'Build a two-hop route: an underlay engine under one of your configs'
              : '${latDigits(settings.chains.length)} saved chain${settings.chains.length == 1 ? '' : 's'}',
          trailing: _navChevron,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => ChainBuilderPage(xray: xray, settings: settings),
            ),
          ),
        ),
        MapSettingRow(
          label: 'Leak test',
          subtitle: 'What the outside world sees while you are connected',
          trailing: _navChevron,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => LeakTestPage(
                core: core,
                xray: xray,
                psiphon: psiphon,
                lantern: lantern,
                openvpn: openvpn,
                warp: warp,
                masque: masque,
              ),
            ),
          ),
        ),
        MapSettingRow(
          label: 'Filtering probe',
          subtitle: 'How this network treats UDP, DNS and TLS names',
          trailing: _navChevron,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const FilteringProbePage()),
          ),
        ),
        MapSettingRow(
          label: 'Logs',
          subtitle: 'Core, engine and crash logs for every engine',
          trailing: _navChevron,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => EmberLogsPage(
                core: core,
                xray: xray,
                psiphon: psiphon,
                lantern: lantern,
                openvpn: openvpn,
              ),
            ),
          ),
        ),
        MapSettingRow(
          label: 'Daily problem report',
          subtitle: xray.settings.dailyProblemReport
              ? 'On — problems are journaled for the daily digest'
              : 'Off — nothing is recorded',
          trailing: EmberToggle(
            value: xray.settings.dailyProblemReport,
            onChanged: (v) => unawaited(xray.setProblemReportEnabled(v)),
          ),
        ),
        if (xray.settings.dailyProblemReport)
          MapSettingRow(
            label: 'Today\u2019s problem report',
            subtitle: reportCount == 0
                ? 'No problems recorded today'
                : '${latDigits(reportCount)} problem${reportCount == 1 ? '' : 's'} recorded today',
            trailing: _navChevron,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => DailyReportPage(xray: xray)),
            ),
          ),
        MapSettingRow(
          label: 'Tunnel MTU',
          subtitle:
              'Interface MTU for every engine — smaller values help on networks that fragment packets. Applies at next connect.',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final n in const [1280, 1400, 1420, 1500])
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: EmberChip(
                    label: '$n',
                    compact: true,
                    selected: xray.settings.tunnelMtu == n,
                    onTap: () async {
                      xray.settings.tunnelMtu = n;
                      AndroidCore.tunnelMtu.value = n;
                      await xray.save();
                    },
                  ),
                ),
            ],
          ),
        ),
        MapSettingRow(
          label: 'Session data budget',
          subtitle: settings.sessionBudgetMb <= 0
              ? 'Off — sessions are not capped'
              : 'Disconnects at ${settings.sessionBudgetMb >= 1024 ? '${settings.sessionBudgetMb ~/ 1024} GB' : '${settings.sessionBudgetMb} MB'} per session (warns at 80%)',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (mb, label) in const [
                (0, 'Off'),
                (500, '500 MB'),
                (1024, '1 GB'),
                (2048, '2 GB'),
                (5120, '5 GB'),
              ])
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: EmberChip(
                    label: label,
                    compact: true,
                    selected: settings.sessionBudgetMb == mb,
                    onTap: () => settings.update(sessionBudgetMb: mb),
                  ),
                ),
            ],
          ),
        ),
        // Build 2105: the battery usage report. Recording
        // happens in the shell's session sampler; the page
        // states its own estimation limits.
        MapSettingRow(
          label: 'Battery usage report',
          subtitle:
              'Attribute each session\u2019s battery drain to '
              'the engine that was connected (an estimate)',
          divider: settings.batteryReportEnabled,
          trailing: EmberToggle(
            value: settings.batteryReportEnabled,
            onChanged: (v) => settings.update(batteryReportEnabled: v),
          ),
        ),
        if (settings.batteryReportEnabled)
          MapSettingRow(
            label: 'Battery report',
            trailing: _navChevron,
            divider: false,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const BatteryReportPage()),
            ),
          ),
      ],
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.icon, required this.label, this.value, this.onTap});
  final IconData icon;
  final String label;
  final String? value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 13),
      child: Row(
        children: [
          Icon(icon, size: 20, color: Ember.orange),
          const SizedBox(width: 11),
          Expanded(child: Text(label, style: Ember.body)),
          if (value != null) ...[
            Text(value!, style: Ember.dimStyle),
            const SizedBox(width: 6),
          ],
          const Icon(Icons.chevron_left_rounded, color: Ember.faint, size: 20),
        ],
      ),
    ),
  );
}

/// The Psiphon engine's section: a summary card into the engine's
/// own settings page (mode, region, upstream proxy, transports) and
/// its log viewer.
class _PsiphonSection extends StatelessWidget {
  const _PsiphonSection({required this.psiphon});
  final PsiphonController psiphon;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: psiphon,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionTitle(l.connectionSection),
          GlassCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Column(
              children: [
                _Row(
                  icon: Icons.tune_rounded,
                  label: 'Psiphon',
                  value: psiphon.settings.vpnMode
                      ? l.psiphonVpnMode
                      : l.psiphonProxyOnly,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => PsiphonSettingsPage(psiphon: psiphon),
                    ),
                  ),
                ),
                const Divider(color: Ember.line, height: 1),
                _Row(
                  icon: Icons.public_rounded,
                  label: l.region,
                  value: psiphon.settings.region.isEmpty
                      ? l.psiphonRegionAuto
                      : regionName(psiphon.settings.region),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => PsiphonSettingsPage(psiphon: psiphon),
                    ),
                  ),
                ),
                const Divider(color: Ember.line, height: 1),
                _Row(
                  icon: Icons.receipt_long_rounded,
                  label: l.psiphonLogs,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => PsiphonLogsPage(psiphon: psiphon),
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

/// The Lantern engine's section: a summary card into the engine's
/// own page and its log viewer. The free plan has no settings to
/// tune — the card says so instead of inventing some.
class _LanternSection extends StatelessWidget {
  const _LanternSection({required this.lantern});
  final LanternController lantern;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: lantern,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionTitle(l.connectionSection),
          GlassCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Column(
              children: [
                _Row(
                  icon: Icons.tune_rounded,
                  label: 'Lantern',
                  value: l.lanternAutoFree,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => LanternSettingsPage(lantern: lantern),
                    ),
                  ),
                ),
                const Divider(color: Ember.line, height: 1),
                _Row(
                  icon: Icons.receipt_long_rounded,
                  label: l.lanternLogs,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => LanternLogsPage(lantern: lantern),
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

/// The WARP+ engine's section: a summary card into the engine's own
/// settings page (connection mode, endpoint scan, cfon country,
/// endpoint override) and its log viewer.
class _WarpSection extends StatelessWidget {
  const _WarpSection({required this.warp});
  final WarpController warp;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: warp,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionTitle(l.connectionSection),
          GlassCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Column(
              children: [
                _Row(
                  icon: Icons.tune_rounded,
                  label: 'WARP+',
                  value: warpModeLabel(l, warp.settings.mode),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => WarpSettingsPage(warp: warp),
                    ),
                  ),
                ),
                const Divider(color: Ember.line, height: 1),
                _Row(
                  icon: Icons.receipt_long_rounded,
                  label: l.warpLogs,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => WarpLogsPage(warp: warp)),
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

/// The WireGuard engine's section (Android's _WireGuardSection,
/// build 2104 route): the selected config and the engine it
/// will actually run, into the WireGuard list.
class _WireGuardSection extends StatelessWidget {
  const _WireGuardSection({required this.xray});
  final XrayController xray;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: xray,
      builder: (context, _) {
        final selected = xray.selected;
        final wgSelected =
            selected != null && selected.protocol == Protocol.wireguard
            ? selected
            : null;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SectionTitle(l.connectionSection),
            GlassCard(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Column(
                children: [
                  _Row(
                    icon: Icons.vpn_key_rounded,
                    label: 'WireGuard',
                    value: wgSelected?.displayName ?? 'No config selected',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => WireGuardServersView(xray: xray),
                      ),
                    ),
                  ),
                  const Divider(color: Ember.line, height: 1),
                  _Row(
                    icon: Icons.memory_rounded,
                    label: 'Engine',
                    value: wgSelected == null
                        ? '—'
                        : wgSelected.hasSupportedAmneziaParams
                        ? 'AmneziaWG'
                        : 'WireGuard',
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// The OpenVPN engine's section (Android's _OpenVpnSection):
/// live state into the engine's settings, plus its logs.
class _OpenVpnSection extends StatelessWidget {
  const _OpenVpnSection({required this.openvpn});
  final OpenVpnController openvpn;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: openvpn,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionTitle(l.connectionSection),
          GlassCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Column(
              children: [
                _Row(
                  icon: Icons.vpn_lock_rounded,
                  label: 'OpenVPN',
                  value: openvpn.state.connected
                      ? l.statusConnected
                      : openvpn.state.running
                      ? l.stateConnecting
                      : l.statusDisconnected,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => OpenVpnSettingsPage(openvpn: openvpn),
                    ),
                  ),
                ),
                const Divider(color: Ember.line, height: 1),
                _Row(
                  icon: Icons.receipt_long_rounded,
                  label: 'Engine logs',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => OpenVpnLogsPage(openvpn: openvpn),
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

/// The EmberWarp / MASQUE section (Android's _WarpSection,
/// build 2056 audit A-H5 + 2095 audit #6): the slot's own
/// options page — never another engine's profile.
class _AetherSection extends StatelessWidget {
  const _AetherSection({
    required this.controller,
    required this.xray,
    required this.name,
  });
  final AetherController controller;
  final XrayController xray;
  final String name;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final c = controller;
        final stateWord = c.connected
            ? l.statusConnected
            : c.state.running || c.connecting
            ? l.stateConnecting
            : l.statusDisconnected;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SectionTitle(l.connectionSection),
            GlassCard(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Column(
                children: [
                  _Row(
                    icon: Icons.tune_rounded,
                    label: name,
                    value: stateWord,
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) =>
                            AetherOptionsPage(controller: c, xray: xray),
                      ),
                    ),
                  ),
                  const Divider(color: Ember.line, height: 1),
                  _Row(
                    icon: Icons.place_rounded,
                    label: 'Endpoint',
                    value: c.state.server.isEmpty ? '—' : c.state.server,
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ToggleCard extends StatelessWidget {
  const _ToggleCard({
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
  });
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: GlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Ember.body),
                if (subtitle != null) Text(subtitle!, style: Ember.caption),
              ],
            ),
          ),
          // Desktop gets the Map Control knob-less pill; the
          // phone keeps EmberToggle.
          if (Features.desktopShell)
            MapToggle(value: value, onChanged: onChanged)
          else
            EmberToggle(value: value, onChanged: onChanged),
        ],
      ),
    ),
  );
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Text(text, style: Ember.heading),
  );
}

// ---------------------------------------------------------------- Mozilla

class _MozillaSection extends StatefulWidget {
  const _MozillaSection({required this.core});
  final CoreController core;

  @override
  State<_MozillaSection> createState() => _MozillaSectionState();
}

class _MozillaSectionState extends State<_MozillaSection> {
  bool? _routing;
  bool? _doh;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    AndroidCore.mode.addListener(_onMode);
  }

  @override
  void dispose() {
    AndroidCore.mode.removeListener(_onMode);
    super.dispose();
  }

  void _onMode() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    try {
      final settings = await widget.core.settings();
      final routing = settings['routing'];
      final dns = settings['dns'];
      final servers = dns is Map ? dns['servers'] : null;
      final list = servers is List ? servers : const [];
      if (mounted) {
        setState(() {
          _routing = routing is Map ? routing['enabled'] == true : false;
          _doh =
              list.isNotEmpty &&
              list.every(
                (s) =>
                    s.toString().startsWith('https://') ||
                    s.toString().startsWith('tls://'),
              );
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _routing = false;
          _doh = true;
        });
      }
    }
  }

  Future<void> _edit(void Function(Map<String, Object?>) edit) async {
    setState(() => _busy = true);
    try {
      await widget.core.editSettings(edit);
    } catch (_) {
      // The core's next answer restores the truth.
    } finally {
      if (mounted) setState(() => _busy = false);
      unawaited(_load());
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final mode = AndroidCore.mode.value;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle(l.connectionSection),
        // The connection mode (mockup 4). Android chooses the
        // phone's VPN/proxy mode through its channel; on desktop the
        // mode is the core's own connection setting (the desktop
        // Settings page's Connection section), so this card is
        // Android-only. The routing and DoH toggles below speak to
        // the core directly and work on every platform.
        if (!Features.desktopShell) ...[
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l.connectionMode, style: Ember.body),
                const SizedBox(height: 11),
                EmberSegmented<String>(
                  value: mode,
                  options: [
                    ('vpn', l.modeVpn, Icons.shield_rounded),
                    ('proxy', l.modeProxy, Icons.hub_rounded),
                  ],
                  onChanged: (v) => unawaited(AndroidCore.setMode(v)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
        ],
        _ToggleCard(
          title: l.smartRouting,
          subtitle: l.smartRoutingSub,
          value: _routing ?? false,
          onChanged: _busy || _routing == null
              ? null
              : (v) => _edit((config) {
                  final routing = config['routing'];
                  if (routing is Map<String, Object?>) {
                    routing['enabled'] = v;
                  }
                }),
        ),
        _ToggleCard(
          title: l.doh,
          subtitle: l.dohSub,
          value: _doh ?? true,
          onChanged: _busy || _doh == null
              ? null
              : (v) => _edit((config) {
                  final dns = config['dns'];
                  if (dns is Map<String, Object?>) {
                    dns['servers'] = v
                        ? [
                            'https://1.1.1.1/dns-query',
                            'https://8.8.8.8/dns-query',
                            'https://9.9.9.9/dns-query',
                          ]
                        : ['1.1.1.1', '8.8.8.8'];
                  }
                }),
        ),
      ],
    );
  }
}

// ------------------------------------------------------------------ V2Ray


/// One editable text value row (label + current value, tap to edit).
class _TextRow extends StatelessWidget {
  const _TextRow({
    required this.label,
    required this.initial,
    required this.onSubmit,
    this.numeric = false,
  });
  final String label;
  final String initial;
  final Future<void> Function(String) onSubmit;
  final bool numeric;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: () async {
      final l = AppLocalizations.of(context);
      final controller = TextEditingController(text: initial);
      final value = await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          backgroundColor: Ember.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          title: Text(label, style: Ember.heading),
          content: TextField(
            controller: controller,
            autofocus: true,
            textDirection: TextDirection.ltr,
            keyboardType: numeric ? TextInputType.number : TextInputType.url,
            style: Ember.body,
            decoration: emberField(context, initial),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(
                l.closeAction,
                style: const TextStyle(color: Ember.dim),
              ),
            ),
            TextButton(
              onPressed: () =>
                  Navigator.of(dialogContext).pop(controller.text.trim()),
              child: Text(
                l.saveAction,
                style: const TextStyle(color: Ember.orange),
              ),
            ),
          ],
        ),
      );
      if (value != null) await onSubmit(value);
    },
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 13),
      child: Row(
        children: [
          Expanded(child: Text(label, style: Ember.body)),
          Text(
            initial.length > 26 ? '${initial.substring(0, 26)}…' : initial,
            style: Ember.dimStyle.copyWith(fontSize: 12),
            textDirection: TextDirection.ltr,
          ),
          const SizedBox(width: 6),
          const Icon(Icons.chevron_left_rounded, color: Ember.faint, size: 20),
        ],
      ),
    ),
  );
}

/// One editable list row (comma/newline-separated values).
class _ListRow extends StatelessWidget {
  const _ListRow({
    required this.label,
    required this.values,
    required this.onChanged,
  });
  final String label;
  final List<String> values;
  final Future<void> Function(List<String>) onChanged;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: () async {
      final l = AppLocalizations.of(context);
      final controller = TextEditingController(text: values.join('\n'));
      final text = await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          backgroundColor: Ember.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          title: Text(label, style: Ember.heading),
          content: TextField(
            controller: controller,
            autofocus: true,
            minLines: 4,
            maxLines: 8,
            textDirection: TextDirection.ltr,
            style: Ember.body,
            decoration: emberField(context, 'example.com'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(
                l.closeAction,
                style: const TextStyle(color: Ember.dim),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(controller.text),
              child: Text(
                l.saveAction,
                style: const TextStyle(color: Ember.orange),
              ),
            ),
          ],
        ),
      );
      if (text != null) {
        await onChanged(
          text
              .split(RegExp(r'[\n,]'))
              .map((e) => e.trim())
              .where((e) => e.isNotEmpty)
              .toList(),
        );
      }
    },
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 13),
      child: Row(
        children: [
          Expanded(child: Text(label, style: Ember.body)),
          Text('${values.length}', style: Ember.dimStyle),
          const SizedBox(width: 6),
          const Icon(Icons.chevron_left_rounded, color: Ember.faint, size: 20),
        ],
      ),
    ),
  );
}
