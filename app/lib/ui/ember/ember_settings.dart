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
import '../../lantern/lantern_controller.dart';
import '../../l10n/app_localizations.dart';
import '../../openvpn/openvpn_controller.dart';
import 'automation_pages.dart';
import '../../platform.dart';
import '../../psiphon/psiphon_controller.dart';
import '../../xray/config_builder.dart'
    show
        primaryResolver,
        dnsGroupMembers,
        resolverUnderTransport,
        tcpFormOf,
        defaultRemoteDns;
import '../../xray/config_mixins.dart';
import '../../xray/dns_hosts.dart';
import '../../xray/xray_controller.dart';
import '../../xray/xray_models.dart';
import '../bypass_apps_page.dart';
import '../settings_page.dart';
import 'ember_format.dart';
import 'ember_info.dart';
import 'ember_theme.dart';
import 'lantern_pages.dart';
import 'map_widgets.dart';
import 'openvpn_pages.dart';
import 'psiphon_pages.dart';
import 'warp_settings_page.dart';
import 'wireguard_pages.dart';
import 'xray_logs_page.dart';

class EmberSettings extends StatelessWidget {
  const EmberSettings({
    super.key,
    required this.core,
    required this.xray,
    required this.psiphon,
    required this.lantern,
    required this.openvpn,
    required this.settings,
    this.warp,
    this.masque,
  });

  final CoreController core;
  final XrayController xray;
  final PsiphonController psiphon;
  final LanternController lantern;
  final OpenVpnController openvpn;
  final AppSettings settings;

  /// The Aether engines (build 2056, audit A-H5): without them
  /// the WARP/MASQUE modes could only fall through to Mozilla's
  /// section. Null in tests that do not cover those modes.
  final AetherController? warp;
  final AetherController? masque;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final v2ray = settings.emberMode == 1;
    final psiphonMode = settings.emberMode == 2;
    final lanternMode = settings.emberMode == 3;
    final openvpnMode = settings.emberMode == 4;
    final wgMode = settings.emberMode == 5;
    final warpMode = settings.emberMode == 6;
    final masqueMode = settings.emberMode == 7;
    return ListView(
      // Build 2074 (audit item 26): the bottom padding was
      // 8 dp — the last rows and the credit sat flush against
      // the shell's bottom bar. 32 dp clears it.
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        Center(
          child: Text(
            l.navSettings,
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: MapUi.text,
            ),
          ),
        ),
        const SizedBox(height: 16),
        if (v2ray)
          _XraySection(xray: xray)
        else if (psiphonMode)
          _PsiphonSection(psiphon: psiphon)
        else if (lanternMode)
          _LanternSection(lantern: lantern)
        else if (openvpnMode)
          _OpenVpnSection(openvpn: openvpn)
        else if (wgMode)
          _WireGuardSection(xray: xray)
        else if (warpMode)
          _WarpSection(xray: xray, name: 'WARP', controller: warp)
        else if (masqueMode)
          _WarpSection(xray: xray, name: 'MASQUE', controller: masque)
        else
          _MozillaSection(core: core),
        const SizedBox(height: 14),
        // Build 2065: the automation surface — the cross-engine
        // fallback chain (item 5), the auto-connect triggers
        // (item 14) and the read-only filtering probe (item 6).
        MapSettingsPanel(
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
              label: 'Filtering probe',
              subtitle: 'How this network treats UDP, DNS and TLS names',
              divider: false,
              trailing: _navChevron,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const FilteringProbePage()),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        MapSettingsPanel(
          title: l.generalSection,
          children: [
            _PerAppRow(label: l.perAppProxy),
            MapSettingRow(
              label: l.allSettings,
              trailing: _navChevron,
              onTap: () => Navigator.of(context).push(
                _emberPageRoute(
                  l.allSettings,
                  SettingsPage(core: core, settings: settings),
                ),
              ),
            ),
            MapSettingRow(
              label: l.languageRow,
              trailing: MapValueChip(
                // Build 2057 (audit §6 appearance low): the row
                // showed the raw language code ("en") — show the
                // language's own name instead.
                text: switch (settings.language) {
                  'fa' => 'فارسی',
                  'en' => 'English',
                  final code => code,
                },
              ),
              onTap: () => Navigator.of(context).push(
                _emberPageRoute(
                  l.languageRow,
                  SettingsPage(
                    core: core,
                    settings: settings,
                    opening: SettingsSection.general,
                  ),
                ),
              ),
            ),
            MapSettingRow(
              label: l.infoRow,
              trailing: _navChevron,
              divider: false,
              onTap: () => Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const EmberInfoPage())),
            ),
          ],
        ),
        const SizedBox(height: 18),
        const Center(
          child: Text(
            'Built by Rayan Vakili • Ralysnd',
            style: TextStyle(fontSize: 11.5, color: MapUi.faint),
          ),
        ),
        const SizedBox(height: 6),
      ],
    );
  }
}

/// The navigation affordance of the settings rows (the app's
/// standing forward chevron).
const _navChevron = Icon(
  // Build 2056 (audit Batch 9): the app is English LTR — the
  // forward chevron points right, not left.
  Icons.chevron_right_rounded,
  color: MapUi.faint,
  size: 20,
);

/// Build 2056 (audit A-H6): a pushed page in the Ember language —
/// a transparent bar with a real title over the map backdrop,
/// never the stock empty AppBar the "All settings" / "Language"
/// rows used to push.
Route<T> _emberPageRoute<T>(String title, Widget child) => MaterialPageRoute<T>(
  builder: (_) => Scaffold(
    backgroundColor: Ember.bg,
    appBar: AppBar(
      backgroundColor: Colors.transparent,
      elevation: 0,
      foregroundColor: Ember.text,
      title: Text(title, style: Ember.heading),
    ),
    body: EmberBackground(child: child),
  ),
);

/// The WireGuard engine's section (build 2056, audit A-H5): modes
/// 5 used to fall through to Mozilla's section, showing
/// connection-mode / smart-routing / DoH controls for an engine
/// that has none of those. The section shows the selected
/// WireGuard config and its real run mode (AmneziaWG vs plain),
/// and opens the configurations panel.
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
        return MapSettingsPanel(
          title: l.connectionSection,
          children: [
            MapSettingRow(
              label: 'WireGuard',
              trailing: _valueTrailing(
                wgSelected?.displayName ?? 'No config selected',
              ),
              onTap: () => Navigator.of(context).push(
                _emberPageRoute('WireGuard', WireGuardServersView(xray: xray)),
              ),
            ),
            MapSettingRow(
              label: 'Engine',
              trailing: _plainValueTrailing(
                wgSelected == null
                    ? '—'
                    : wgSelected.hasAmneziaParams
                    ? 'AmneziaWG'
                    : 'WireGuard',
              ),
              divider: false,
            ),
          ],
        );
      },
    );
  }
}

/// The WARP / MASQUE engine's section (build 2056, audit A-H5):
/// modes 6–7 used to fall through to Mozilla's section. The
/// section shows the engine's live state and opens its real
/// settings page (WarpSettingsPage); without a controller (tests)
/// the row still opens the settings page.
class _WarpSection extends StatelessWidget {
  const _WarpSection({
    required this.xray,
    required this.name,
    required this.controller,
  });
  final XrayController xray;
  final String name;
  final AetherController? controller;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = controller;
    final stateWord = c == null
        ? 'Settings'
        : c.connected
        ? l.statusConnected
        : c.state.running || c.connecting
        ? l.stateConnecting
        : l.statusDisconnected;
    return MapSettingsPanel(
      title: l.connectionSection,
      children: [
        MapSettingRow(
          label: name,
          trailing: _valueTrailing(stateWord),
          onTap: () => Navigator.of(context).push(
            _emberPageRoute('$name settings', WarpSettingsPage(xray: xray)),
          ),
        ),
        MapSettingRow(
          label: 'Endpoint',
          trailing: _plainValueTrailing(
            c == null || c.state.server.isEmpty ? '—' : c.state.server,
          ),
          divider: false,
        ),
      ],
    );
  }
}

/// The per-app proxy row: it genuinely carries a current value
/// (the routing mode the BypassAppsPage edits), so — 2024,
/// Gemini audit v4 item 2 — it wears the orange value pill like
/// the language row; the pure-navigation rows around it keep
/// their chevrons. The value reloads when the page closes.
class _PerAppRow extends StatefulWidget {
  const _PerAppRow({required this.label});

  final String label;

  @override
  State<_PerAppRow> createState() => _PerAppRowState();
}

class _PerAppRowState extends State<_PerAppRow> {
  String? _value;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final routing = await AndroidCore.appRouting();
      if (mounted) {
        setState(() {
          _value = routing.onlyChosen
              ? 'Selected only'
              : routing.bypass.isEmpty
              ? 'All apps'
              : 'Custom';
        });
      }
    } catch (_) {
      // No answer (non-Android host): the row keeps its chevron.
    }
  }

  @override
  Widget build(BuildContext context) {
    return MapSettingRow(
      label: widget.label,
      trailing: _value == null ? _navChevron : MapValueChip(text: _value!),
      onTap: () async {
        // Build 2074 (audit item 11): the per-app page rides
        // the same _emberPageRoute chrome as its neighbours —
        // it was the one row pushed with a bare route.
        await Navigator.of(context)
            .push(_emberPageRoute(widget.label, const BypassAppsPage()));
        unawaited(_load());
      },
    );
  }
}

/// A settings row's trailing cluster for a value: the orange
/// value capsule carries the current value (round 3: the pill
/// replaces the trailing chevron on rows that have a value;
/// pure navigation rows keep the chevron).
Widget _valueTrailing(String value) => MapValueChip(text: value);

/// Build 2074 (audit item 7): a value on a row that does NOT
/// act — the WireGuard "Engine" and WARP "Endpoint" rows have
/// no onTap, so the tappable-looking capsule lied about them.
/// Non-actionable values render as plain dim text instead.
Widget _plainValueTrailing(String value) => Text(
  value,
  style: const TextStyle(
    fontSize: 12.5,
    fontWeight: FontWeight.w600,
    color: MapUi.dim,
  ),
  maxLines: 1,
  overflow: TextOverflow.ellipsis,
);

/// Build 2074 (audit item 16): a chip group as a full-width
/// row — label and subtitle on top, the chips in a Wrap below.
/// As a MapSettingRow trailing the same Wrap squeezed the
/// label to a sliver (mux / MTU / refresh groups).
class _ChipGroupRow extends StatelessWidget {
  const _ChipGroupRow({
    required this.label,
    this.subtitle,
    this.divider = true,
    required this.chips,
  });

  final String label;
  final String? subtitle;
  final bool divider;
  final List<Widget> chips;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: const TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w500,
                color: MapUi.text,
              ),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 2),
              Text(
                subtitle!,
                style: const TextStyle(
                  fontSize: 10,
                  color: MapUi.faint,
                  height: 1.3,
                ),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            const SizedBox(height: 9),
            Wrap(spacing: 6, runSpacing: 6, children: chips),
          ],
        ),
      ),
      if (divider) const Divider(color: MapUi.line, height: 1, thickness: 1),
    ],
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
      builder: (context, _) => MapSettingsPanel(
        title: l.connectionSection,
        children: [
          MapSettingRow(
            label: 'Psiphon',
            trailing: _valueTrailing(
              psiphon.settings.vpnMode ? l.psiphonVpnMode : l.psiphonProxyOnly,
            ),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => PsiphonSettingsPage(psiphon: psiphon),
              ),
            ),
          ),
          MapSettingRow(
            label: l.region,
            trailing: _valueTrailing(
              psiphon.settings.region.isEmpty
                  ? l.psiphonRegionAuto
                  : regionName(psiphon.settings.region),
            ),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => PsiphonSettingsPage(psiphon: psiphon),
              ),
            ),
          ),
          MapSettingRow(
            label: l.psiphonLogs,
            trailing: _navChevron,
            divider: false,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => PsiphonLogsPage(psiphon: psiphon),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The Lantern engine's section: a summary card into the
/// engine's page (server-list actions) and its log viewer.
class _LanternSection extends StatelessWidget {
  const _LanternSection({required this.lantern});
  final LanternController lantern;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: lantern,
      builder: (context, _) => MapSettingsPanel(
        title: l.connectionSection,
        children: [
          MapSettingRow(
            label: 'Lantern',
            trailing: _valueTrailing(
              lantern.state.connected
                  ? l.statusConnected
                  : lantern.state.running || lantern.state.coreRunning
                  ? l.stateConnecting
                  : l.statusDisconnected,
            ),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => LanternSettingsPage(lantern: lantern),
              ),
            ),
          ),
          MapSettingRow(
            label: 'Engine logs',
            trailing: _navChevron,
            divider: false,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => LanternLogsPage(lantern: lantern),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _OpenVpnSection extends StatelessWidget {
  const _OpenVpnSection({required this.openvpn});
  final OpenVpnController openvpn;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: openvpn,
      builder: (context, _) => MapSettingsPanel(
        title: l.connectionSection,
        children: [
          MapSettingRow(
            label: 'OpenVPN',
            trailing: _valueTrailing(
              openvpn.state.connected
                  ? l.statusConnected
                  : openvpn.state.running
                  ? l.stateConnecting
                  : l.statusDisconnected,
            ),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => OpenVpnSettingsPage(openvpn: openvpn),
              ),
            ),
          ),
          MapSettingRow(
            label: 'Engine logs',
            trailing: _navChevron,
            divider: false,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => OpenVpnLogsPage(openvpn: openvpn),
              ),
            ),
          ),
        ],
      ),
    );
  }
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
    return MapSettingsPanel(
      title: l.connectionSection,
      children: [
        // The connection mode (mockup 4).
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l.connectionMode,
                style: const TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w500,
                  color: MapUi.text,
                ),
              ),
              const SizedBox(height: 9),
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
        const Divider(color: MapUi.line, height: 1, thickness: 1),
        MapSettingRow(
          label: l.smartRouting,
          subtitle: l.smartRoutingSub,
          trailing: MapToggle(
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
        ),
        MapSettingRow(
          label: l.doh,
          subtitle: l.dohSub,
          divider: false,
          trailing: MapToggle(
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
          MapSettingsPanel(
            title: l.connectionSection,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 7),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l.routingPreset,
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w500,
                        color: MapUi.text,
                      ),
                    ),
                    const SizedBox(height: 9),
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
                    Text(
                      l.domainStrategy,
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w500,
                        color: MapUi.text,
                      ),
                    ),
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
              const Divider(color: MapUi.line, height: 1, thickness: 1),
              MapSettingRow(
                label: l.enableUdp,
                trailing: MapToggle(
                  value: s.enableUdp,
                  onChanged: (v) async {
                    s.enableUdp = v;
                    await xray.save();
                  },
                ),
              ),
              MapSettingRow(
                label: l.sniffing,
                trailing: MapToggle(
                  value: s.sniffing,
                  onChanged: (v) async {
                    s.sniffing = v;
                    await xray.save();
                  },
                ),
              ),
              MapSettingRow(
                label: l.fakeDns,
                trailing: MapToggle(
                  value: s.fakeDns,
                  onChanged: (v) async {
                    s.fakeDns = v;
                    await xray.save();
                  },
                ),
              ),
              MapSettingRow(
                label: l.ipv6Route,
                trailing: MapToggle(
                  value: s.ipv6Route,
                  onChanged: (v) async {
                    s.ipv6Route = v;
                    await xray.save();
                  },
                ),
              ),
              MapSettingRow(
                label: l.mux,
                subtitle: l.muxSub,
                trailing: MapToggle(
                  value: s.muxEnabled,
                  onChanged: (v) async {
                    s.muxEnabled = v;
                    await xray.save();
                  },
                ),
              ),
              // Mux concurrency (build 2060, grouped sweep): the
              // stream count lived in the model with no UI row —
              // now a chip row, shown with the mux toggle.
              if (s.muxEnabled) ...[
                _ChipGroupRow(
                  label: 'Mux concurrency',
                  subtitle: 'Concurrent streams per connection',
                  chips: [
                    for (final n in const [1, 2, 4, 8, 16])
                      EmberChip(
                        label: '$n',
                        compact: true,
                        selected: s.muxConcurrency == n,
                        onTap: () async {
                          s.muxConcurrency = n;
                          await xray.save();
                        },
                      ),
                  ],
                ),
              ],
              // Test All parallelism (build 2032): how many
              // throwaway cores the funnel's real stage runs at
              // once. Higher is faster and heavier.
              _ChipGroupRow(
                label: 'Test All parallelism',
                subtitle: 'Cores testing at once',
                chips: [
                  for (final n in const [2, 4, 6, 8])
                    EmberChip(
                      label: '$n',
                      compact: true,
                      selected: s.testAllConcurrency == n,
                      onTap: () async {
                        s.testAllConcurrency = n;
                        await xray.save();
                      },
                    ),
                ],
              ),
              MapSettingRow(
                label: l.fragment,
                subtitle: l.fragmentSub,
                trailing: MapToggle(
                  value: s.fragmentEnabled,
                  onChanged: (v) async {
                    s.fragmentEnabled = v;
                    await xray.save();
                  },
                ),
              ),
              // Fragment knobs (build 2060, grouped sweep): packets,
              // length and interval lived in the model with no UI
              // row — now chip rows, shown with the fragment toggle.
              if (s.fragmentEnabled) ...[
                _ChipGroupRow(
                  label: 'Fragment packets',
                  subtitle: 'Which packets to split',
                  chips: [
                    for (final p in const ['tlshello', '1-1', '1-3', '1-5'])
                      EmberChip(
                        label: p,
                        compact: true,
                        selected: s.fragmentPackets == p,
                        onTap: () async {
                          s.fragmentPackets = p;
                          await xray.save();
                        },
                      ),
                  ],
                ),
                _ChipGroupRow(
                  label: 'Fragment length',
                  subtitle: 'Split length in bytes',
                  chips: [
                    for (final n in const [50, 100, 200, 500])
                      EmberChip(
                        label: '$n',
                        compact: true,
                        selected: s.fragmentLength == n,
                        onTap: () async {
                          s.fragmentLength = n;
                          await xray.save();
                        },
                      ),
                  ],
                ),
                _ChipGroupRow(
                  label: 'Fragment interval',
                  subtitle: 'Delay between fragments (ms)',
                  chips: [
                    for (final n in const [10, 20, 50, 100])
                      EmberChip(
                        label: '$n',
                        compact: true,
                        selected: s.fragmentInterval == n,
                        onTap: () async {
                          s.fragmentInterval = n;
                          await xray.save();
                        },
                      ),
                  ],
                ),
              ],
              // Tunnel MTU (build 2038, Iran-priority queue 2f):
              // the MTU of the VPN interface, one value for every
              // engine's tunnel — the interface, the tun2socks
              // bridge and (Mozilla) the core's stack all use it.
              // 1500 is the default; smaller values help on
              // networks that fragment or drop full-size tunnel
              // packets. Applies at the next connect.
              _ChipGroupRow(
                label: 'Tunnel MTU',
                subtitle: 'Interface MTU for every engine — smaller values help on networks that fragment packets. Applies at next connect.',
                chips: [
                  for (final n in const [1280, 1400, 1420, 1500])
                    EmberChip(
                      label: '$n',
                      compact: true,
                      selected: s.tunnelMtu == n,
                      onTap: () async {
                        s.tunnelMtu = n;
                        // The Mozilla connect path reads this
                        // mirror (AndroidCore.tunnelMtu); the
                        // shell sets it at load, this keeps it
                        // in sync on every change.
                        AndroidCore.tunnelMtu.value = n;
                        await xray.save();
                      },
                    ),
                ],
              ),
              // Stage A (build 2026) + group semantics (build
              // 2035): fallback groups, ON by default — with it
              // off, the engine behaves exactly as in 2025.
              MapSettingRow(
                label: 'Fallback groups',
                subtitle: 'If a config dies or fails to connect, move to the next in its group automatically',
                divider: false,
                trailing: MapToggle(
                  value: s.adaptiveFailover,
                  onChanged: (v) async {
                    s.adaptiveFailover = v;
                    await xray.save();
                  },
                ),
              ),
              // Auto-reconnect (build 2042, feature-watch
              // 2026-11-12): a tunnel the carrier kills comes
              // back by itself after a short wait, a bounded
              // number of times; a manual disconnect never
              // reconnects. Not a kill-switch on its own: while
              // the app waits, the tunnel is down and traffic is
              // direct until the reconnect lands — unless the
              // kill switch below is on, which holds the dead
              // tunnel as a blackhole while it waits (2063).
              MapSettingRow(
                label: 'Auto-reconnect',
                subtitle: 'If the tunnel drops by itself, reconnect automatically. A manual disconnect never reconnects.',
                divider: false,
                trailing: MapToggle(
                  value: s.autoReconnect,
                  onChanged: (v) async {
                    s.autoReconnect = v;
                    await xray.save();
                    // The delay/attempts rows below appear or hide
                    // with this toggle, so the section must rebuild
                    // at once (save() alone does not notify).
                    xray.notifySettingsChanged();
                  },
                ),
              ),
              if (s.autoReconnect) ...[
                _ChipGroupRow(
                  label: 'Reconnect delay',
                  subtitle: 'Wait between the drop and the next try',
                  chips: [
                    for (final n in const [5, 10, 20, 30])
                      EmberChip(
                        label: '${n}s',
                        compact: true,
                        selected: s.reconnectDelaySeconds == n,
                        onTap: () async {
                          s.reconnectDelaySeconds = n;
                          await xray.save();
                          xray.notifySettingsChanged();
                        },
                      ),
                  ],
                ),
                _ChipGroupRow(
                  label: 'Reconnect attempts',
                  subtitle: 'Tries before giving up and waiting for you',
                  divider: false,
                  chips: [
                    for (final n in const [3, 5, 10])
                      EmberChip(
                        label: '$n',
                        compact: true,
                        selected: s.reconnectMaxAttempts == n,
                        onTap: () async {
                          s.reconnectMaxAttempts = n;
                          await xray.save();
                          xray.notifySettingsChanged();
                        },
                      ),
                  ],
                ),
              ],
              const Divider(color: MapUi.line, height: 1),
              // Kill switch (build 2063, feature queue #3):
              // while the V2Ray or WARP tunnel is down — a drop,
              // or a reconnect wait — all traffic is blocked
              // instead of going direct. Off by default; applies
              // at next connect. AmneziaWG sessions and the
              // Psiphon/Lantern engines are not covered yet, and
              // if Android itself kills the app, only Android's
              // Always-on VPN can block — this switch cannot.
              MapSettingRow(
                label: 'Kill switch',
                subtitle: 'Block all traffic while the tunnel is down, including the auto-reconnect wait.',
                trailing: MapToggle(
                  value: s.killSwitch,
                  onChanged: (v) async {
                    s.killSwitch = v;
                    await xray.save();
                    // The caption below appears or hides with
                    // this toggle, so the section must rebuild
                    // at once (save() alone does not notify).
                    xray.notifySettingsChanged();
                  },
                ),
              ),
              if (s.killSwitch)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    'While on, a dropped or failed V2Ray/WARP tunnel blocks all traffic until it reconnects or you disconnect. AmneziaWG, Psiphon and Lantern are not covered yet.',
                    style: Ember.caption,
                  ),
                ),
              const Divider(color: MapUi.line, height: 1),
              // TLS fingerprint rotation (build 2065, item 13):
              // each new connect of a profile whose fingerprint
              // field is empty takes the next browser fingerprint
              // from the rotation set. A profile with its own
              // fingerprint is never overridden.
              MapSettingRow(
                label: 'Rotate TLS fingerprint',
                subtitle: 'A different browser fingerprint (Chrome, Firefox, Safari, iOS) on each new connection, for configs that do not set their own',
                trailing: MapToggle(
                  value: s.rotateTlsFingerprint,
                  onChanged: (v) async {
                    s.rotateTlsFingerprint = v;
                    await xray.save();
                    xray.notifySettingsChanged();
                  },
                ),
              ),
              // Scheduled subscription health (build 2065, item
              // 12): an in-app schedule — while the app runs, the
              // real delay test re-runs at most once per interval,
              // never while a tunnel is up. Off by default
              // (battery). A background WorkManager job was NOT
              // used: androidx.work is not in the offline build
              // cache, and an unshipped dependency helps no one;
              // see BUILD-LOG 2065.
              MapSettingRow(
                label: 'Scheduled config health test',
                subtitle: 'Re-test every config with the real delay test on a schedule while the app runs',
                trailing: MapToggle(
                  value: s.subHealthEnabled,
                  onChanged: (v) async {
                    s.subHealthEnabled = v;
                    await xray.save();
                    xray.notifySettingsChanged();
                  },
                ),
              ),
              if (s.subHealthEnabled)
                _ChipGroupRow(
                  label: 'Health test interval',
                  subtitle: 'How often the scheduled test may run',
                  divider: false,
                  chips: [
                    for (final n in const [6, 12, 24])
                      EmberChip(
                        label: '${n}h',
                        compact: true,
                        selected: s.subHealthIntervalHours == n,
                        onTap: () async {
                          s.subHealthIntervalHours = n;
                          await xray.save();
                          xray.notifySettingsChanged();
                        },
                      ),
                  ],
                ),
              const Divider(color: MapUi.line, height: 1),
              // Config mixins (build 2043): the user's own JSON
              // object, merged into the tunnel config at the end
              // of every build — an advanced escape hatch for
              // core options the app has no toggle for (a log
              // level, an extra routing rule, a policy tweak).
              // Empty means no mixins: exactly the old config.
              _MixinsRow(
                mixinsText: s.configMixins,
                onChanged: (v) async {
                  s.configMixins = v;
                  await xray.save();
                },
              ),
            ],
          ),
          const SizedBox(height: 14),
          MapSettingsPanel(
            title: l.dnsSection,
            children: [
              _TextRow(
                label: l.remoteDns,
                initial: s.remoteDns,
                onSubmit: (v) async {
                  if (v.isNotEmpty) s.remoteDns = v;
                  await _save(context);
                },
              ),
              // Resolver presets (build 2030): the "+one"
              // schemes are the patched core's one-connection-
              // per-query DoH — a fresh connection per query
              // leaves no long-lived DoH session for a filter
              // to freeze.
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Wrap(
                  spacing: 7,
                  runSpacing: 7,
                  children: [
                    for (final (label, url) in const [
                      ('Google DoH', 'https://dns.google/dns-query'),
                      ('Google DoH +one', 'https+one://dns.google/dns-query'),
                      (
                        'Cloudflare DoH',
                        'https://cloudflare-dns.com/dns-query',
                      ),
                      (
                        'Cloudflare +one',
                        'https+one://cloudflare-dns.com/dns-query',
                      ),
                      ('Quad9 DoH', 'https://dns.quad9.net/dns-query'),
                    ])
                      EmberChip(
                        label: label,
                        selected: s.remoteDns == url,
                        onTap: () async {
                          s.remoteDns = url;
                          await xray.save();
                        },
                      ),
                  ],
                ),
              ),
              // Resolver transport (build 2032): DoH, or DoQ —
              // DNS-over-QUIC to the same provider — but the core
              // dispatches only quic+local (build 2053, audit
              // F-H4), which is local egress: the query leaves
              // the device directly, not through the tunnel. TCP
              // (build 2037, Iran-priority queue 2e) asks the same
              // provider over plain DNS on TCP port 53 at its
              // pinned IP — no hostname, no SNI, and UDP
              // poisoning cannot touch it. The chain line under
              // it is the config's real resolution order:
              // primary, then the group or the fallback when
              // enabled, each mapped through the same transport.
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 7,
                      runSpacing: 7,
                      children: [
                        EmberChip(
                          label: 'DoH',
                          selected: s.remoteDnsProto == 'doh',
                          onTap: () async {
                            s.remoteDnsProto = 'doh';
                            await xray.save();
                          },
                        ),
                        EmberChip(
                          label: 'DoQ (QUIC, direct)',
                          selected: s.remoteDnsProto == 'doq',
                          onTap: () async {
                            s.remoteDnsProto = 'doq';
                            await xray.save();
                          },
                        ),
                        EmberChip(
                          label: 'TCP (port 53)',
                          selected: s.remoteDnsProto == 'tcp',
                          onTap: () async {
                            s.remoteDnsProto = 'tcp';
                            await xray.save();
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 7),
                    Text(
                      'Resolution order: ${primaryResolver(s)}'
                      '${s.dnsGroup
                          ? ' → group: ${dnsGroupMembers.map((m) => resolverUnderTransport(m, s.remoteDnsProto)).join(' → ')}'
                          : s.dnsFallback
                          ? ' → ${resolverUnderTransport(s.fallbackDns.trim(), s.remoteDnsProto)}'
                          : ''}'
                      // Build 2056 (audit §6): the 2049 built-in
                      // fallback rides the default shape — the same
                      // condition as _dnsSection in config_builder
                      // — so the display names it instead of
                      // omitting it.
                      '${!s.dnsGroup && !s.dnsFallback && !s.adBlockDoh && s.remoteDns.trim() == defaultRemoteDns ? ' → ${tcpFormOf('https://dns.quad9.net/dns-query')} (built-in fallback)' : ''}'
                      // Build 2053 (audit F-H4): the core speaks
                      // ONLY quic+local for DoQ, and +local is
                      // local egress — the query leaves the device
                      // directly, not through the tunnel — so the
                      // "never the local one" line must not be
                      // claimed for DoQ. On a filtered network a
                      // direct DoQ query may fail; the TCP
                      // fallback behind the default resolver
                      // still applies.
                      '${s.remoteDnsProto == 'doq' ? ' • DoQ is local-egress: its queries leave the device directly, not through the tunnel' : ' • server names resolve through the provider DNS, never the local one'}',
                      style: Ember.caption,
                    ),
                  ],
                ),
              ),
              const Divider(color: MapUi.line, height: 1),
              _TextRow(
                label: l.localDns,
                initial: s.localDns,
                onSubmit: (v) async {
                  if (v.isNotEmpty) s.localDns = v;
                  await _save(context);
                },
              ),
              const Divider(color: MapUi.line, height: 1),
              // Ad-block preset (build 2030): the tunnel's
              // remote resolver becomes AdGuard's filtering
              // DoH — ads and trackers fail at resolution.
              MapSettingRow(
                label: 'Block ads & trackers',
                subtitle: 'Resolve through AdGuard’s filtering DNS',
                trailing: MapToggle(
                  value: s.adBlockDoh,
                  onChanged: (v) async {
                    s.adBlockDoh = v;
                    await xray.save();
                  },
                ),
              ),
              const Divider(color: MapUi.line, height: 1),
              // DNS group (build 2033): the primary plus the
              // well-known encrypted resolvers, worked in
              // order by the core — the resolver that answers
              // is the one that sticks, and every member is
              // encrypted, so a poisoned local answer never
              // enters. Supersedes the single fallback below
              // while on (the builder says so too).
              MapSettingRow(
                label: 'DNS group',
                subtitle: 'Google, Cloudflare and Quad9 asked in turn; the working one sticks',
                trailing: MapToggle(
                  value: s.dnsGroup,
                  onChanged: (v) async {
                    s.dnsGroup = v;
                    await xray.save();
                  },
                ),
              ),
              const Divider(color: MapUi.line, height: 1),
              // DNS fallback policy (build 2030): a second
              // resolver that answers only when the primary
              // fails to resolve — it never overrides the
              // ad-block filter's answers.
              MapSettingRow(
                label: 'DNS fallback',
                subtitle: 'Used only when the main resolver fails',
                trailing: MapToggle(
                  value: s.dnsFallback,
                  onChanged: (v) async {
                    s.dnsFallback = v;
                    await xray.save();
                  },
                ),
              ),
              if (s.dnsFallback) ...[
                const Divider(color: MapUi.line, height: 1),
                _TextRow(
                  label: 'Fallback DNS',
                  initial: s.fallbackDns,
                  onSubmit: (v) async {
                    if (v.isNotEmpty) s.fallbackDns = v;
                    await _save(context);
                  },
                ),
              ],
              const Divider(color: MapUi.line, height: 1),
              // Custom DNS hosts (build 2041): the user's own
              // name → IP map, answered by the tunnel's DNS
              // before any resolver is asked — pin a name to a
              // known-good IP when the local network's DNS lies
              // about it (a poisoned answer for a subscription
              // host, a provider's SNI name, or a local name
              // like wg.home).
              _HostsRow(
                hosts: s.customDnsHosts,
                onChanged: (v) async {
                  s.customDnsHosts = v;
                  await xray.save();
                },
              ),
              const Divider(color: MapUi.line, height: 1),
              _TextRow(
                label: l.socksPort,
                initial: '${s.socksPort}',
                numeric: true,
                onSubmit: (v) async {
                  final port = int.tryParse(v);
                  // Build 2057 (audit F-M2): the pair is validated
                  // together — a port that collides with another
                  // engine, with the HTTP port, or with the stats
                  // port (SOCKS + 5000) is refused here with the
                  // named reason instead of breaking every connect
                  // with a generic start failure.
                  final problem = port == null
                      ? 'Enter a port number.'
                      : validateXrayPorts(
                          socksPort: port,
                          httpPort: s.httpPort,
                        );
                  if (problem != null) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(problem),
                          duration: const Duration(seconds: 6),
                        ),
                      );
                    }
                    return;
                  }
                  s.socksPort = port!;
                  await _save(context);
                },
              ),
              const Divider(color: MapUi.line, height: 1),
              _TextRow(
                label: l.httpPort,
                initial: '${s.httpPort}',
                numeric: true,
                onSubmit: (v) async {
                  final port = int.tryParse(v);
                  final problem = port == null
                      ? 'Enter a port number.'
                      : validateXrayPorts(
                          socksPort: s.socksPort,
                          httpPort: port,
                        );
                  if (problem != null) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(problem),
                          duration: const Duration(seconds: 6),
                        ),
                      );
                    }
                    return;
                  }
                  s.httpPort = port!;
                  await _save(context);
                },
              ),
            ],
          ),
          const SizedBox(height: 14),
          // LAN sharing (build 2062, feature queue #2): share
          // the V2Ray tunnel as a SOCKS5/HTTP proxy on the local
          // network, with optional username/password auth. Off
          // by default; everything here applies at next connect.
          MapSettingsPanel(
            title: 'LAN sharing',
            children: [
              MapSettingRow(
                label: 'Share on local network',
                subtitle: 'Other devices on your Wi-Fi can use this tunnel as a proxy. Applies at next connect.',
                trailing: MapToggle(
                  value: s.lanShareEnabled,
                  onChanged: (v) async {
                    s.lanShareEnabled = v;
                    await xray.save();
                  },
                ),
              ),
              if (s.lanShareEnabled) ...[
                const Divider(color: MapUi.line, height: 1),
                _LanShareAddresses(
                  socksPort: s.socksPort,
                  httpPort: s.httpPort,
                ),
                const Divider(color: MapUi.line, height: 1),
                MapSettingRow(
                  label: 'Require username and password',
                  subtitle: 'Other devices must log in to use the tunnel',
                  trailing: MapToggle(
                    value: s.lanShareAuth,
                    onChanged: (v) async {
                      s.lanShareAuth = v;
                      await xray.save();
                    },
                  ),
                ),
                if (s.lanShareAuth) ...[
                  const Divider(color: MapUi.line, height: 1),
                  _TextRow(
                    label: 'Username',
                    initial: s.lanShareUser,
                    onSubmit: (v) async {
                      if (v.isEmpty) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Enter a username.'),
                              duration: Duration(seconds: 6),
                            ),
                          );
                        }
                        return;
                      }
                      s.lanShareUser = v;
                      await _save(context);
                    },
                  ),
                  const Divider(color: MapUi.line, height: 1),
                  _TextRow(
                    label: 'Password',
                    initial: s.lanSharePass,
                    obscure: true,
                    onSubmit: (v) async {
                      if (v.isEmpty) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Enter a password.'),
                              duration: Duration(seconds: 6),
                            ),
                          );
                        }
                        return;
                      }
                      s.lanSharePass = v;
                      await _save(context);
                    },
                  ),
                ],
                if (!s.lanShareAuth)
                  Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      'Anyone on your Wi-Fi can use the tunnel.',
                      style: Ember.caption,
                    ),
                  ),
                if (s.lanShareAuth && !s.lanShareAuthReady)
                  Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      'Enter a username and password — until then the shared proxy has no login.',
                      style: Ember.caption,
                    ),
                  ),
              ],
            ],
          ),
          const SizedBox(height: 14),
          MapSettingsPanel(
            title: l.customRules,
            children: [
              _ListRow(
                label: l.directDomains,
                values: s.customDirectDomains,
                onChanged: (v) async {
                  s.customDirectDomains = v;
                  await xray.save();
                },
              ),
              const Divider(color: MapUi.line, height: 1),
              _ListRow(
                label: l.directIps,
                values: s.customDirectIps,
                onChanged: (v) async {
                  s.customDirectIps = v;
                  await xray.save();
                },
              ),
              const Divider(color: MapUi.line, height: 1),
              _ListRow(
                label: l.blockDomains,
                values: s.customBlockDomains,
                onChanged: (v) async {
                  s.customBlockDomains = v;
                  await xray.save();
                },
              ),
              const Divider(color: MapUi.line, height: 1),
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
          const SizedBox(height: 14),
          MapSettingsPanel(
            title: l.subscriptionsTitle,
            children: [
              MapSettingRow(
                label: l.updateOnLaunch,
                trailing: MapToggle(
                  value: s.subUpdateOnLaunch,
                  onChanged: (v) async {
                    s.subUpdateOnLaunch = v;
                    await xray.save();
                  },
                ),
              ),
              // Subscription refresh period (build 2060, grouped
              // sweep): the hours value lived in the model with no
              // UI row — now a chip row in the Subscriptions panel.
              _ChipGroupRow(
                label: 'Subscription refresh',
                subtitle: 'Hours between automatic subscription updates',
                chips: [
                  for (final n in const [6, 12, 24, 48, 72])
                    EmberChip(
                      label: '${n}h',
                      compact: true,
                      selected: s.subAutoUpdateHours == n,
                      onTap: () async {
                        s.subAutoUpdateHours = n;
                        await xray.save();
                      },
                    ),
                ],
              ),
              MapSettingRow(
                label: l.backupData,
                trailing: _navChevron,
                onTap: () => _showBackup(context),
              ),
              MapSettingRow(
                label: l.restoreData,
                trailing: _navChevron,
                onTap: () => _showRestore(context),
              ),
              MapSettingRow(
                label: l.coreLogs,
                trailing: _navChevron,
                divider: false,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => XrayLogsPage(xray: xray)),
                ),
              ),
            ],
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
        // Build 2074 (audit item 25): scrollable content — the
        // unbounded backup JSON pushed the actions off-screen
        // on short/landscape screens.
        scrollable: true,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: Text(l.backupData, style: Ember.heading),
        content: SizedBox(
          width: double.maxFinite,
          child: SelectableText(
            backup,
            textDirection: TextDirection.ltr,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 10.5,
              color: Ember.dim,
            ),
          ),
        ),
        actions: [
          EmberButton(
            label: l.copyLink,
            onTap: () async {
              await Clipboard.setData(ClipboardData(text: backup));
              if (dialogContext.mounted) Navigator.of(dialogContext).pop();
            },
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(
              l.closeAction,
              style: const TextStyle(color: Ember.dim),
            ),
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
        // Build 2074 (audit item 25): scrollable content.
        scrollable: true,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: Text(l.restoreData, style: Ember.heading),
        content: TextField(
          controller: controller,
          minLines: 5,
          maxLines: 9,
          textDirection: TextDirection.ltr,
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 11,
            color: Ember.text,
          ),
          decoration: emberField(context, '{…}'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(
              l.closeAction,
              style: const TextStyle(color: Ember.dim),
            ),
          ),
          EmberButton(
            label: l.restoreData,
            onTap: () async {
              final ok = await xray.importBackup(controller.text);
              if (dialogContext.mounted) Navigator.of(dialogContext).pop();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(ok ? l.restoreOk : l.restoreFailed)),
                );
              }
            },
          ),
        ],
      ),
    );
  }
}

/// LAN sharing addresses (build 2062, feature queue #2): the
/// SOCKS5 and HTTP proxy URLs other devices on the local
/// network use, from this device's LAN address. Long-press (or
/// the copy button) copies a URL; with no Wi-Fi address there
/// is nothing to share yet.
class _LanShareAddresses extends StatefulWidget {
  const _LanShareAddresses({required this.socksPort, required this.httpPort});

  final int socksPort;
  final int httpPort;

  @override
  State<_LanShareAddresses> createState() => _LanShareAddressesState();
}

class _LanShareAddressesState extends State<_LanShareAddresses> {
  String? _address;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    lanAddress().then((a) {
      if (mounted) {
        setState(() {
          _address = a;
          _done = true;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_done) {
      return Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Text('Finding the local address…', style: Ember.caption),
      );
    }
    final address = _address;
    if (address == null) {
      return Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Text(
          'Connect to Wi-Fi to see the address.',
          style: Ember.caption,
        ),
      );
    }
    return Column(
      children: [
        _LanAddressRow(
          label: 'SOCKS5',
          url: 'socks5://$address:${widget.socksPort}',
        ),
        _LanAddressRow(
          label: 'HTTP',
          url: 'http://$address:${widget.httpPort}',
        ),
      ],
    );
  }
}

class _LanAddressRow extends StatelessWidget {
  const _LanAddressRow({required this.label, required this.url});

  final String label;
  final String url;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 7),
    child: Row(
      children: [
        SizedBox(width: 64, child: Text(label, style: Ember.body)),
        Expanded(child: SelectableText(url, style: Ember.body)),
        IconButton(
          icon: const Icon(Icons.copy_rounded, color: MapUi.faint, size: 18),
          tooltip: 'Copy',
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: url));
            if (context.mounted) {
              ScaffoldMessenger.of(context)
                  .showSnackBar(const SnackBar(content: Text('Copied.')));
            }
          },
        ),
      ],
    ),
  );
}

/// One editable text value row (label + current value, tap to edit).
class _TextRow extends StatelessWidget {
  const _TextRow({
    required this.label,
    required this.initial,
    required this.onSubmit,
    this.numeric = false,
    // Build 2062 (LAN sharing): the password row hides its
    // value — obscured in the dialog AND masked in the row
    // chip, so the password is never on screen in plain text.
    this.obscure = false,
  });
  final String label;
  final String initial;
  final Future<void> Function(String) onSubmit;
  final bool numeric;
  final bool obscure;

  @override
  Widget build(BuildContext context) => InkWell(
    borderRadius: BorderRadius.circular(14),
    onTap: () async {
      final l = AppLocalizations.of(context);
      final controller = TextEditingController(text: initial);
      final value = await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          // Build 2074 (audit item 25): scrollable content.
          scrollable: true,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          title: Text(label, style: Ember.heading),
          content: TextField(
            controller: controller,
            autofocus: true,
            obscureText: obscure,
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
            EmberButton(
              label: l.saveAction,
              onTap: () =>
                  Navigator.of(dialogContext).pop(controller.text.trim()),
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
          Flexible(
            child: MapValueChip(
              // Build 2074 (audit item 26): a fixed-length mask
              // — '•' * length disclosed the exact password
              // length on the settings screen.
              text: obscure
                  ? (initial.isEmpty ? '' : '••••••••')
                  : initial.length > 40
                  ? '${initial.substring(0, 40)}…'
                  : initial,
            ),
          ),
          const SizedBox(width: 6),
          const Icon(Icons.chevron_right_rounded, color: MapUi.faint, size: 18),
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
    borderRadius: BorderRadius.circular(14),
    onTap: () async {
      final l = AppLocalizations.of(context);
      final controller = TextEditingController(text: values.join('\n'));
      final text = await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          // Build 2074 (audit item 25): scrollable content.
          scrollable: true,
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
            EmberButton(
              label: l.saveAction,
              onTap: () => Navigator.of(dialogContext).pop(controller.text),
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
          MapValueChip(text: latDigits(values.length)),
        ],
      ),
    ),
  );
}

/// Custom DNS hosts (build 2041): the user's own name → IP map.
/// Same row-and-dialog language as [_ListRow] — a count chip on
/// the row, an Ember-surface dialog with one `name = IP` per
/// line. A line that fails validation is never saved silently:
/// the dialog stays open and names the offending lines, so a
/// typo cannot vanish into a half-written map.
class _HostsRow extends StatelessWidget {
  const _HostsRow({required this.hosts, required this.onChanged});
  final Map<String, String> hosts;
  final Future<void> Function(Map<String, String>) onChanged;

  @override
  Widget build(BuildContext context) => InkWell(
    borderRadius: BorderRadius.circular(14),
    onTap: () async {
      final l = AppLocalizations.of(context);
      final controller = TextEditingController(text: dnsHostsText(hosts));
      final saved = await showDialog<Map<String, String>>(
        context: context,
        builder: (dialogContext) {
          // Lives outside the StatefulBuilder's builder so a
          // rebuild after setDialogState keeps the error text.
          String? error;
          return StatefulBuilder(
            builder: (dialogContext, setDialogState) => AlertDialog(
              // Build 2074 (audit item 25): scrollable content.
              scrollable: true,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
              title: Text('Custom DNS hosts', style: Ember.heading),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'One per line: name = IP. Answered by the tunnel’s '
                    'DNS before any resolver is asked.',
                    style: Ember.caption,
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: controller,
                    autofocus: true,
                    minLines: 4,
                    maxLines: 8,
                    textDirection: TextDirection.ltr,
                    style: Ember.body,
                    decoration: emberField(context, 'example.com = 1.2.3.4'),
                  ),
                  if (error != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      error!,
                      style: Ember.caption.copyWith(color: Ember.red),
                    ),
                  ],
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: Text(
                    l.closeAction,
                    style: const TextStyle(color: Ember.dim),
                  ),
                ),
                EmberButton(
                  label: l.saveAction,
                  onTap: () {
                    final parsed = parseDnsHostsText(controller.text);
                    if (parsed.invalidLines.isNotEmpty) {
                      setDialogState(() {
                        error =
                            'Check these lines: ${parsed.invalidLines.take(3).join(', ')}';
                      });
                      return;
                    }
                    Navigator.of(dialogContext).pop(parsed.entries);
                  },
                ),
              ],
            ),
          );
        },
      );
      if (saved != null) await onChanged(saved);
    },
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 13),
      child: Row(
        children: [
          Expanded(child: Text('Custom DNS hosts', style: Ember.body)),
          MapValueChip(text: latDigits(hosts.length)),
        ],
      ),
    ),
  );
}

/// Config mixins (build 2043): the user's own JSON object, merged
/// into the tunnel config at the end of every build. Same
/// row-and-dialog language as [_HostsRow] — a chip on the row, an
/// Ember-surface dialog with a multiline JSON field. Text that is
/// not a JSON object is never saved silently: the dialog stays
/// open and names the error, so a typo cannot vanish into a
/// half-written config. Clearing the field removes the mixins
/// entirely (the old config, byte for byte).
class _MixinsRow extends StatelessWidget {
  const _MixinsRow({required this.mixinsText, required this.onChanged});
  final String mixinsText;
  final Future<void> Function(String) onChanged;

  @override
  Widget build(BuildContext context) {
    final keyCount = parseConfigMixins(mixinsText).mixins?.length ?? 0;
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () async {
        final l = AppLocalizations.of(context);
        final controller = TextEditingController(text: mixinsText);
        final saved = await showDialog<String>(
          context: context,
          builder: (dialogContext) {
            // Lives outside the StatefulBuilder's builder so a
            // rebuild after setDialogState keeps the error text.
            String? error;
            return StatefulBuilder(
              builder: (dialogContext, setDialogState) => AlertDialog(
                // Build 2074 (audit item 25): scrollable content.
                scrollable: true,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24),
                ),
                title: Text('Config mixins', style: Ember.heading),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Your own JSON, merged into the tunnel config '
                      'last. Maps merge, lists are added, other '
                      'values replace. Applies at next connect.',
                      style: Ember.caption,
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: controller,
                      autofocus: true,
                      minLines: 6,
                      maxLines: 10,
                      textDirection: TextDirection.ltr,
                      style: Ember.body,
                      decoration: emberField(
                        context,
                        '{"log": {"loglevel": "info"}}',
                      ),
                    ),
                    if (error != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        error!,
                        style: Ember.caption.copyWith(color: Ember.red),
                      ),
                    ],
                  ],
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
                    onPressed: () => Navigator.of(dialogContext).pop(''),
                    child: const Text(
                      'Clear',
                      style: TextStyle(color: Ember.dim),
                    ),
                  ),
                  EmberButton(
                    label: l.saveAction,
                    onTap: () {
                      final parsed = parseConfigMixins(controller.text);
                      if (parsed.error != null) {
                        setDialogState(() {
                          error = parsed.error;
                        });
                        return;
                      }
                      Navigator.of(dialogContext).pop(controller.text);
                    },
                  ),
                ],
              ),
            );
          },
        );
        if (saved != null) await onChanged(saved);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 13),
        child: Row(
          children: [
            Expanded(child: Text('Config mixins', style: Ember.body)),
            MapValueChip(
              text: keyCount == 0 ? 'Off' : '${latDigits(keyCount)} keys',
            ),
          ],
        ),
      ),
    );
  }
}
