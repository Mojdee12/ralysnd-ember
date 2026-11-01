/// Settings, on mockup 4's layout: the flame-headed sections, the
/// connection-mode segmented card, toggle cards, and rows into the
/// deeper pages — with the engine's own section following the mode.
/// The About card (maker credit, license) lives on its own Info
/// page, reached from the «اینفو» row in the general section.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
import '../../xray/xray_models.dart';
import '../bypass_apps_page.dart';
import '../settings_page.dart';
import 'desktop_settings.dart';
import 'desktop_widgets.dart';
import 'ember_info.dart';
import 'ember_theme.dart';
import 'lantern_pages.dart';
import 'psiphon_pages.dart';
import 'warp_pages.dart';
import 'xray_logs_page.dart';

class EmberSettings extends StatelessWidget {
  final CoreController core;
  final XrayController xray;
  final PsiphonController psiphon;
  final LanternController lantern;
  final WarpController warp;
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
    final engineSection = v2ray
        ? _XraySection(xray: xray)
        : psiphonMode
            ? _PsiphonSection(psiphon: psiphon)
            : lanternMode
                ? _LanternSection(lantern: lantern)
                : warpMode
                    ? _WarpSection(warp: warp)
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
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const BypassAppsPage()),
                  ),
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
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const EmberInfoPage()),
                ),
              ),
            ],
          ),
        );
    if (desktop) {
      // The desktop settings page (2.0.3, desktop_settings.dart):
      // the Settings mockup's two-column glass cards — General,
      // DNS, Connection (the capture-mode switcher), Routing,
      // About, More — with the engine section appended full-width
      // and the status bar at the bottom.
      return DesktopSettingsPage(
        core: core,
        settings: settings,
        engineSection: engineSection,
        protectionOn: core.status?.state.phase == Phase.running ||
            xray.state.running ||
            psiphon.state.connected,
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
        engineSection,
        const SizedBox(height: 18),
        Text(l.generalSection, style: Ember.heading),
        const SizedBox(height: 10),
        generalCard,
      ],
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.icon,
    required this.label,
    this.value,
    this.onTap,
  });
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
                    MaterialPageRoute(
                      builder: (_) => WarpLogsPage(warp: warp),
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
                    if (subtitle != null)
                      Text(subtitle!, style: Ember.caption),
                  ],
                ),
              ),
              // Desktop gets the mockups' wide pill switch (pale
              // knob left when ON); the phone keeps EmberToggle.
              if (Features.desktopShell)
                DesktopSwitch(value: value, onChanged: onChanged)
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
          _doh = list.isNotEmpty &&
              list.every(
                (s) => s.toString().startsWith('https://') ||
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

class _XraySection extends StatelessWidget {
  const _XraySection({required this.xray});
  final XrayController xray;

  XraySettings get s => xray.settings;

  Future<void> _save(BuildContext context) async {
    await xray.save();
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context).savedNote)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: xray,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionTitle(l.connectionSection),
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l.routingPreset, style: Ember.body),
                const SizedBox(height: 11),
                Wrap(
                  spacing: 7,
                  runSpacing: 7,
                  children: [
                    for (final preset in RoutingPreset.values)
                      EmberChip(
                        label: switch (preset) {
                          RoutingPreset.global => l.presetGlobal,
                          RoutingPreset.bypassLan => l.presetBypassLan,
                          RoutingPreset.bypassIran => l.presetBypassIran,
                          RoutingPreset.directAll => l.presetDirectAll,
                        },
                        selected: s.routingPreset == preset,
                        onTap: () async {
                          s.routingPreset = preset;
                          await xray.save();
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 13),
                Text(l.domainStrategy, style: Ember.body),
                const SizedBox(height: 9),
                EmberSegmented<String>(
                  value: s.domainStrategy,
                  options: [
                    ('IPIfNonMatch', 'IPIfNonMatch', null),
                    ('AsIs', 'AsIs', null),
                    ('IPOnDemand', 'IPOnDemand', null),
                  ],
                  onChanged: (v) async {
                    s.domainStrategy = v;
                    await xray.save();
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          // Desktop only: the Windows backend's mode choice. Android
          // always captures through its VpnService and never shows
          // this; off = proxy mode (local SOCKS/HTTP only).
          if (Features.desktopShell) ...[
            _ToggleCard(
              title: 'System-wide capture (TUN)',
              subtitle: 'Off = proxy mode: local SOCKS/HTTP only',
              value: s.tunCapture,
              onChanged: (v) async {
                s.tunCapture = v;
                await xray.save();
              },
            ),
          ],
          _ToggleCard(
            title: l.enableUdp,
            value: s.enableUdp,
            onChanged: (v) async {
              s.enableUdp = v;
              await xray.save();
            },
          ),
          _ToggleCard(
            title: l.sniffing,
            value: s.sniffing,
            onChanged: (v) async {
              s.sniffing = v;
              await xray.save();
            },
          ),
          _ToggleCard(
            title: l.fakeDns,
            value: s.fakeDns,
            onChanged: (v) async {
              s.fakeDns = v;
              await xray.save();
            },
          ),
          _ToggleCard(
            title: l.ipv6Route,
            value: s.ipv6Route,
            onChanged: (v) async {
              s.ipv6Route = v;
              await xray.save();
            },
          ),
          _ToggleCard(
            title: l.mux,
            subtitle: l.muxSub,
            value: s.muxEnabled,
            onChanged: (v) async {
              s.muxEnabled = v;
              await xray.save();
            },
          ),
          _ToggleCard(
            title: l.fragment,
            subtitle: l.fragmentSub,
            value: s.fragmentEnabled,
            onChanged: (v) async {
              s.fragmentEnabled = v;
              await xray.save();
            },
          ),
          _ToggleCard(
            title: l.allowInsecure,
            value: s.allowInsecure,
            onChanged: (v) async {
              s.allowInsecure = v;
              await xray.save();
            },
          ),
          const SizedBox(height: 8),
          _SectionTitle(l.dnsSection),
          GlassCard(
            child: Column(
              children: [
                _TextRow(
                  label: l.remoteDns,
                  initial: s.remoteDns,
                  onSubmit: (v) async {
                    if (v.isNotEmpty) s.remoteDns = v;
                    await _save(context);
                  },
                ),
                const Divider(color: Ember.line, height: 1),
                _TextRow(
                  label: l.localDns,
                  initial: s.localDns,
                  onSubmit: (v) async {
                    if (v.isNotEmpty) s.localDns = v;
                    await _save(context);
                  },
                ),
                const Divider(color: Ember.line, height: 1),
                _TextRow(
                  label: l.socksPort,
                  initial: '${s.socksPort}',
                  numeric: true,
                  onSubmit: (v) async {
                    final port = int.tryParse(v);
                    if (port != null && port > 0 && port < 65536) {
                      s.socksPort = port;
                    }
                    await _save(context);
                  },
                ),
                const Divider(color: Ember.line, height: 1),
                _TextRow(
                  label: l.httpPort,
                  initial: '${s.httpPort}',
                  numeric: true,
                  onSubmit: (v) async {
                    final port = int.tryParse(v);
                    if (port != null && port > 0 && port < 65536) {
                      s.httpPort = port;
                    }
                    await _save(context);
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          _SectionTitle(l.customRules),
          GlassCard(
            child: Column(
              children: [
                _ListRow(
                  label: l.directDomains,
                  values: s.customDirectDomains,
                  onChanged: (v) async {
                    s.customDirectDomains = v;
                    await xray.save();
                  },
                ),
                const Divider(color: Ember.line, height: 1),
                _ListRow(
                  label: l.directIps,
                  values: s.customDirectIps,
                  onChanged: (v) async {
                    s.customDirectIps = v;
                    await xray.save();
                  },
                ),
                const Divider(color: Ember.line, height: 1),
                _ListRow(
                  label: l.blockDomains,
                  values: s.customBlockDomains,
                  onChanged: (v) async {
                    s.customBlockDomains = v;
                    await xray.save();
                  },
                ),
                const Divider(color: Ember.line, height: 1),
                _ListRow(
                  label: l.proxyDomains,
                  values: s.customProxyDomains,
                  onChanged: (v) async {
                    s.customProxyDomains = v;
                    await xray.save();
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          _SectionTitle(l.subscriptionsTitle),
          _ToggleCard(
            title: l.updateOnLaunch,
            value: s.subUpdateOnLaunch,
            onChanged: (v) async {
              s.subUpdateOnLaunch = v;
              await xray.save();
            },
          ),
          GlassCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Column(
              children: [
                _Row(
                  icon: Icons.backup_rounded,
                  label: l.backupData,
                  onTap: () => _showBackup(context),
                ),
                const Divider(color: Ember.line, height: 1),
                _Row(
                  icon: Icons.restore_rounded,
                  label: l.restoreData,
                  onTap: () => _showRestore(context),
                ),
                const Divider(color: Ember.line, height: 1),
                _Row(
                  icon: Icons.terminal_rounded,
                  label: l.coreLogs,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => XrayLogsPage(xray: xray)),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showBackup(BuildContext context) async {
    final l = AppLocalizations.of(context);
    final backup = await xray.exportBackup();
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: Ember.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: Text(l.backupData, style: Ember.heading),
        content: SizedBox(
          width: double.maxFinite,
          child: SelectableText(
            backup,
            textDirection: TextDirection.ltr,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 10.5, color: Ember.dim),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: backup));
              if (dialogContext.mounted) Navigator.of(dialogContext).pop();
            },
            child: Text(l.copyLink, style: const TextStyle(color: Ember.orange)),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l.closeAction, style: const TextStyle(color: Ember.dim)),
          ),
        ],
      ),
    );
  }

  Future<void> _showRestore(BuildContext context) async {
    final l = AppLocalizations.of(context);
    final controller = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: Ember.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: Text(l.restoreData, style: Ember.heading),
        content: TextField(
          controller: controller,
          minLines: 5,
          maxLines: 9,
          textDirection: TextDirection.ltr,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: Ember.text),
          decoration: emberField(context, '{…}'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l.closeAction, style: const TextStyle(color: Ember.dim)),
          ),
          TextButton(
            onPressed: () async {
              final ok = await xray.importBackup(controller.text);
              if (dialogContext.mounted) Navigator.of(dialogContext).pop();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text(ok ? l.restoreOk : l.restoreFailed),
                ));
              }
            },
            child: Text(l.restoreData, style: const TextStyle(color: Ember.orange)),
          ),
        ],
      ),
    );
  }
}

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
                  child: Text(l.closeAction, style: const TextStyle(color: Ember.dim)),
                ),
                TextButton(
                  onPressed: () =>
                      Navigator.of(dialogContext).pop(controller.text.trim()),
                  child: Text(l.saveAction, style: const TextStyle(color: Ember.orange)),
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
                  child: Text(l.closeAction, style: const TextStyle(color: Ember.dim)),
                ),
                TextButton(
                  onPressed: () =>
                      Navigator.of(dialogContext).pop(controller.text),
                  child: Text(l.saveAction, style: const TextStyle(color: Ember.orange)),
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
