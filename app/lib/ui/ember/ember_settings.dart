/// Settings, on mockup 4's layout: the flame-headed sections, the
/// connection-mode segmented card, toggle cards, and rows into the
/// deeper pages — with the engine's own section following the mode.
/// The About card (maker credit, license) lives on its own Info
/// page, reached from the «اینفو» row in the general section.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' hide appBuildNumber;

import '../../aether/aether_controller.dart';
import '../../app_info.dart';
import '../../app_settings.dart';
import '../../core/android_core.dart';
import '../../core/core_controller.dart';
import '../../core/models.dart';
import '../../lantern/lantern_controller.dart';
import '../../l10n/app_localizations.dart';
import '../../openvpn/openvpn_controller.dart';
import 'automation_pages.dart';
import '../../platform.dart';
import '../../psiphon/psiphon_controller.dart';
import '../../xray/config_builder.dart'
    show primaryResolver, dnsGroupMembers, resolverUnderTransport;
import '../../xray/config_mixins.dart';
import '../../xray/dns_hosts.dart';
import '../../xray/hwid.dart';
import '../../xray/xray_controller.dart';
import '../../xray/xray_models.dart';
import '../../xray/xray_platform.dart';
import '../bypass_apps_page.dart';
import '../logs_page.dart';
import '../settings_page.dart';
import '../widgets.dart' show languageNames;
import 'battery_report.dart';
import 'ember_format.dart';
import 'ember_info.dart';
import 'app_lock.dart';
import 'ember_sync.dart';
import 'mozilla_bootstrap.dart';
import 'ember_updater.dart';
import 'ember_logs_page.dart';
import 'chain_builder_page.dart';
import 'pairing.dart';
import 'leak_test_page.dart';
import 'ember_theme.dart';
import 'lantern_pages.dart';
import 'map_widgets.dart';
import 'openvpn_pages.dart';
import 'psiphon_pages.dart';
import 'dpi_lab_page.dart';
import 'regionhop_page.dart';
import 'senpai_page.dart';
import 'smart_groups_page.dart';
import 'sni_spoof_page.dart';
import 'traffic_history_page.dart';
import 'warp_settings_page.dart';
import 'aether_pages.dart';
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
    this.bootstrap,
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

  /// Build 2095 (whole-app journey audit #62): the Mozilla
  /// bootstrap, for the Guardian-pass row under the Mozilla
  /// section. Null in tests.
  final MozillaBootstrap? bootstrap;

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
        // Build 2144 (reskin, pro6-settings sample): the
        // page title is the samples' huge light hero word.
        Align(
          alignment: Alignment.centerLeft,
          child: Text(l.navSettings, style: Ember.hero),
        ),
        const SizedBox(height: 16),
        if (v2ray)
          _XraySection(
            xray: xray,
            settings: settings,
            openvpn: openvpn,
            psiphon: psiphon,
            warp: warp,
            masque: masque,
          )
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
          _MozillaSection(core: core, bootstrap: bootstrap),
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
            // Build 2095 (feature 4): custom multi-hop
            // chains (underlay engine + exit config).
            MapSettingRow(
              label: 'Custom chains',
              subtitle: settings.chains.isEmpty
                  ? 'Build a two-hop route: an underlay engine under one of your configs'
                  : '${latDigits(settings.chains.length)} saved chain${settings.chains.length == 1 ? '' : 's'}',
              trailing: _navChevron,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) =>
                      ChainBuilderPage(xray: xray, settings: settings),
                ),
              ),
            ),
            // Build 2095 (feature 8): the leak test.
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
            // Build 2098 (Item B): the logs hub. The per-engine
            // log pages were only linked from inside each
            // engine's own section — and the WireGuard section
            // had no link at all, so the owner found no log in
            // Settings when a WireGuard crash sent him looking
            // for one. One entry, every engine, always here.
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
            // Tunnel MTU (build 2038, Iran-priority queue 2f;
            // moved here in build 2095, whole-app journey
            // audit #55 — it serves every engine, so it
            // lives in the cross-engine panel, not only in
            // the V2Ray section):
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
                    selected: xray.settings.tunnelMtu == n,
                    onTap: () async {
                      xray.settings.tunnelMtu = n;
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
          ],
        ),
            // Build 2095 (feature 7): the per-session
            // data budget. The shell warns at 80% and
            // disconnects at the cap.
            MapSettingRow(
              label: 'Session data budget',
              subtitle: settings.sessionBudgetMb <= 0
                  ? 'Off — sessions are not capped'
                  : 'Disconnects at ${latDigits(settings.sessionBudgetMb >= 1024 ? '${settings.sessionBudgetMb ~/ 1024} GB' : '${settings.sessionBudgetMb} MB')} per session (warns at 80%)',
              divider: false,
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
                        onTap: () =>
                            settings.update(sessionBudgetMb: mb),
                      ),
                    ),
                ],
              ),
            ),
        const SizedBox(height: 14),
        // Build 2075: Ember's own update feed (GitHub Releases).
        const _AppUpdatesPanel(),
        const SizedBox(height: 14),
        // Build 2096 (post-2095 audit L32): the settings
        // damage surface — build 2095 set the flag and
        // nothing ever read it, so a user whose settings
        // file was quarantined (lock and sync token gone
        // with it) was never told.
        // Build 2097 (post-2096 audit C-L10): the unreadable
        // state gets its OWN copy — the file is intact and
        // being protected, not damaged; build 2096 showed
        // the "did not survive" text for it because load()
        // set the damaged flag for both read problems.
        if (settings.storeUnreadable) ...[
          MapSettingsPanel(
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
          const SizedBox(height: 14),
        ] else if (settings.storeDamaged) ...[
          MapSettingsPanel(
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
          const SizedBox(height: 14),
        ],
        // Build 2097 (post-2096 audit C-L10): a failed save
        // is visible — saveError used to be write-only, set
        // by every failed save and read by nothing, so a
        // disk-full settings loss stayed invisible.
        if (settings.saveError != null && !settings.storeUnreadable) ...[
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
          const SizedBox(height: 14),
        ],
        // Build 2075 (feature items 11 + 20): the PIN app
        // lock and the encrypted GitHub sync.
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
                    warp: warp,
                    masque: masque,
                  ),
                ),
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
            // Build 2095 (whole-app journey audit #60): the
            // notification speed toggle, here in Ember's own
            // settings — it used to live only in the stock
            // settings page.
            MapSettingRow(
              label: 'Speed in notification',
              subtitle: 'Live up/down rates in the VPN notification',
              trailing: ValueListenableBuilder<bool>(
                valueListenable: AndroidCore.showSpeed,
                builder: (context, on, _) => MapToggle(
                  value: on,
                  onChanged: (v) => unawaited(
                    AndroidCore.setShowSpeed(v).catchError((Object e) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'The notification setting did not change',
                            ),
                          ),
                        );
                      }
                    }),
                  ),
                ),
              ),
            ),
            // Build 2095 (whole-app journey audit
            // #39/#43): notification actions are fixed per
            // engine — stated plainly here, since no setting
            // changes them.
            MapSettingRow(
              label: 'Notification actions',
              subtitle:
                  'Fixed per engine: V2Ray and WARP offer Pause '
                  'and Switch server; Psiphon, Lantern and '
                  'OpenVPN offer Disconnect.',
              trailing: const SizedBox.shrink(),
            ),
            // Build 2095 (whole-app journey audit #61): the
            // TUN UDP notice switch and the connection-column
            // picker, surfaced here — both used to live only
            // in the stock pages.
            MapSettingRow(
              label: 'UDP notice',
              subtitle:
                  'Warn when an app is picked that cannot use '
                  'the tunnel’s UDP',
              trailing: MapToggle(
                value: settings.udpNotice,
                onChanged: (v) => settings.update(udpNotice: v),
              ),
            ),
            MapSettingRow(
              label: 'Connection columns',
              subtitle:
                  '${latDigits(settings.hiddenConnectionColumns.length)} '
                  'hidden — tap to choose what the connections '
                  'view shows',
              trailing: _navChevron,
              onTap: () => _pickConnectionColumns(context, settings),
            ),
            MapSettingRow(
              label: l.languageRow,
              trailing: MapValueChip(
                // Build 2057 (audit §6 appearance low): the row
                // showed the raw language code ("en") — show the
                // language's own name instead.
                // Build 2095 (whole-app journey audit, §9
                // minor): every code maps through the shared
                // languageNames table, not just fa/en.
                text: languageNames[settings.language] ?? settings.language,
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
              // Build 2093: launcher shortcuts — long-press the
              // app icon to connect straight to a starred config.
              // The switch publishes or clears the shortcuts on
              // the spot; starring is the per-config opt-in.
              label: 'Launcher shortcuts',
              subtitle:
                  'Long-press the app icon to connect straight to a starred config',
              trailing: MapToggle(
                value: settings.launcherShortcutsEnabled,
                onChanged: (v) {
                  settings.update(launcherShortcutsEnabled: v);
                  unawaited(xray.syncLauncherShortcuts());
                },
              ),
            ),
            // Build 2105 (Mozilla feature 1): the sign-in
            // failure screen's browser offer. The browser route
            // itself is not gated — it is the dialog's primary
            // button since build 2033; only this new offer is.
            MapSettingRow(
              label: 'Browser sign-in fallback',
              subtitle:
                  'When a Mozilla sign-in is refused, offer '
                  'signing in with the browser on the failure '
                  'screen',
              trailing: MapToggle(
                value: settings.signinBrowserFallbackOffer,
                onChanged: (v) =>
                    settings.update(signinBrowserFallbackOffer: v),
              ),
            ),
            // Build 2105: the battery usage report. Recording
            // happens in the shell's session sampler; the page
            // states its own estimation limits.
            MapSettingRow(
              label: 'Battery usage report',
              subtitle:
                  'Attribute each session\'s battery drain to '
                  'the engine that was connected (an estimate)',
              trailing: MapToggle(
                value: settings.batteryReportEnabled,
                onChanged: (v) => settings.update(batteryReportEnabled: v),
              ),
            ),
            if (settings.batteryReportEnabled)
              MapSettingRow(
                label: 'Battery report',
                trailing: _navChevron,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const BatteryReportPage()),
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
            style: TextStyle(fontSize: Ember.fontMicro, color: MapUi.faint),
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
                    // Build 2106 (journey audit F-05): the
                    // label keys on the parameters the engine
                    // actually runs — a J1–J3-only profile is
                    // WireGuard here, not AmneziaWG.
                    : wgSelected.hasSupportedAmneziaParams
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
/// settings page; without a controller (tests) the row still
/// opens the settings page.
///
/// Build 2095 (whole-app journey audit #6): with a controller
/// the row opens THAT slot's own options page — it used to
/// open WarpSettingsPage (the EmberWarp profile) in both
/// modes, silently editing a different engine's slot.
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
            _emberPageRoute(
              '$name settings',
              c != null
                  ? AetherOptionsPage(controller: c, xray: xray)
                  : WarpSettingsPage(xray: xray),
            ),
          ),
        ),
        MapSettingRow(
          label: 'Endpoint',
          trailing: _plainValueTrailing(
            c == null || c.state.server.isEmpty ? '—' : c.state.server,
          ),
        ),
        // Build 2095 (V2Ray journey audit, batch 8): the kill
        // switch also lives in the WARP/MASQUE section — it
        // covers those tunnels, and its only home used to be
        // the V2Ray section. Same switch, same store.
        MapSettingRow(
          label: 'Kill switch',
          subtitle:
              'Block all traffic while the tunnel is down, '
              'including the auto-reconnect wait. Psiphon, '
              'Lantern and OpenVPN sessions are covered too '
              '(build 2125); Mozilla and AmneziaWG are not.',
          trailing: MapToggle(
            value: xray.settings.killSwitch,
            onChanged: (v) async {
              xray.settings.killSwitch = v;
              await xray.save();
              xray.notifySettingsChanged();
            },
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
        // Build 2092 (item 41): the per-app page brings its
        // OWN Scaffold and AppBar — wrapping it in
        // _emberPageRoute stacked a second title bar over
        // it (the 2074 chrome change overshot for this one
        // page; SettingsPage, the wrapper's other child,
        // has no bar of its own and keeps the wrapper).
        await Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => const BypassAppsPage()));
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
    fontSize: Ember.fontSmall,
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
                fontSize: Ember.fontBody,
                fontWeight: FontWeight.w500,
                color: MapUi.text,
              ),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 2),
              Text(
                subtitle!,
                // Build 2092 (item 38): the micro-type
                // floor — 11 sp at dim.
                style: const TextStyle(
                  fontSize: Ember.fontMicro,
                  color: MapUi.dim,
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

/// The routing-lists state row (build 2116, audit AB-06):
/// renders only while the core's geo lists are not both on
/// disk — the state that used to be invisible while every
/// destination rode the proxy waiting for lists that never
/// landed. Retry downloads now through the core's own
/// update call; the core's ladder retries on its own too.
class _RoutingListsRow extends StatefulWidget {
  const _RoutingListsRow({required this.core});

  final CoreController core;

  @override
  State<_RoutingListsRow> createState() => _RoutingListsRowState();
}

class _RoutingListsRowState extends State<_RoutingListsRow> {
  RoutingInfo? _info;
  bool _updating = false;

  @override
  void initState() {
    super.initState();
    unawaited(_read());
  }

  Future<void> _read() async {
    try {
      final info = await widget.core.call((api) => api.routing());
      if (mounted) setState(() => _info = info);
    } catch (_) {
      // Unknown state renders nothing — the row claims
      // only what the core reported.
    }
  }

  Future<void> _retry() async {
    setState(() => _updating = true);
    try {
      final info = await widget.core.call(
        (api) => api.updateRoutingLists(),
      );
      if (mounted) setState(() => _info = info);
    } catch (_) {
      // A failed retry re-reads the state; the row stays
      // with its message and the core's ladder continues.
      await _read();
    } finally {
      if (mounted) setState(() => _updating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final info = _info;
    if (info == null || info.lists.length >= 2) {
      return const SizedBox.shrink();
    }
    return MapSettingRow(
      label: 'Routing lists',
      subtitle:
          'Not downloaded yet — until they arrive, every '
          'destination rides the proxy. The app retries '
          'automatically.',
      trailing: _updating
          ? const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : TextButton(
              onPressed: () => unawaited(_retry()),
              child: const Text('Retry'),
            ),
    );
  }
}

class _MozillaSection extends StatefulWidget {
  const _MozillaSection({required this.core, this.bootstrap});
  final CoreController core;

  /// Build 2095 (audit #62): see EmberSettings.bootstrap.
  final MozillaBootstrap? bootstrap;

  @override
  State<_MozillaSection> createState() => _MozillaSectionState();
}

class _MozillaSectionState extends State<_MozillaSection> {
  bool? _routing;
  bool? _doh;
  String? _transport;

  /// Build 2105 (Mozilla features 2–4): the IP-version policy
  /// (dns.ip_version) and the connect-time fast failover
  /// (proxy.fast_failover). Same unknown-on-failure doctrine as
  /// the fields above.
  String? _ipVersion;
  bool? _fastFailover;
  bool _busy = false;

  /// Build 2095 (whole-app journey audit #13): a failed
  /// settings read is a state of its own — the section used
  /// to FABRICATE values on failure (routing off, DoH on),
  /// so the toggles showed a confident lie and the next edit
  /// wrote from it.
  bool _loadFailed = false;

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
      final proxy = settings['proxy'];
      if (mounted) {
        setState(() {
          _loadFailed = false;
          _routing = routing is Map ? routing['enabled'] == true : false;
          _doh =
              list.isNotEmpty &&
              list.every(
                (s) =>
                    s.toString().startsWith('https://') ||
                    s.toString().startsWith('tls://'),
              );
          // Build 2105: three transports now (h1 joined in
          // this build); an unknown stored value keeps the
          // old read's fallback (h3), exactly as before.
          _transport = proxy is Map && proxy['transport'] == 'h1'
              ? 'h1'
              : proxy is Map && proxy['transport'] == 'h2'
              ? 'h2'
              : 'h3';
          // An absent ip_version is a pre-2105 core's config:
          // the core treats it as 'auto', so the control does
          // too. An absent fast_failover is off (the core's
          // zero value), never a guess.
          final ipVersion = dns is Map ? dns['ip_version'] : null;
          _ipVersion = switch (ipVersion) {
            'ipv6_first' || 'ipv4_only' || 'ipv6_only' => ipVersion,
            _ => 'auto',
          };
          _fastFailover = proxy is Map && proxy['fast_failover'] == true;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          // Unknown stays unknown: nulls disable the toggles
          // and the retry row below offers the way back.
          _loadFailed = true;
          _routing = null;
          _doh = null;
          _transport = null;
          _ipVersion = null;
          _fastFailover = null;
        });
      }
    }
  }

  Future<void> _edit(void Function(Map<String, Object?>) edit) async {
    setState(() => _busy = true);
    try {
      await widget.core.editSettings(edit);
    } catch (e) {
      // Build 2095 (audit #13): a failed edit is SAID — it
      // used to vanish into "the core's next answer restores
      // the truth" while the toggle snapped back unexplained.
      if (mounted) {
        final text = e.toString();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'The core did not accept that change: '
              '${text.length > 140 ? '${text.substring(0, 140)}\u2026' : text}',
            ),
            duration: const Duration(seconds: 5),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
      unawaited(_load());
    }
  }

  Future<void> _setMode(String v) async {
    try {
      await AndroidCore.setMode(v);
    } catch (e) {
      if (mounted) {
        final text = e.toString();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'The connection mode did not change: '
              '${text.length > 140 ? '${text.substring(0, 140)}\u2026' : text}',
            ),
            duration: const Duration(seconds: 5),
          ),
        );
        setState(() {});
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final mode = AndroidCore.mode.value;
    return MapSettingsPanel(
      title: l.connectionSection,
      children: [
        // Build 2095 (whole-app journey audit #62): the
        // Guardian-pass (bootstrap) row under the Mozilla
        // section — it used to live only on the Account tab.
        if (widget.bootstrap != null)
          ListenableBuilder(
            listenable: widget.bootstrap!,
            builder: (context, _) {
              final b = widget.bootstrap!;
              return MapSettingRow(
                label: 'Guardian pass',
                subtitle: b.donor == 'off'
                    ? 'Off — set a donor in Account to fetch the pass'
                    : 'Fetched through another engine; tap Prepare '
                          'to refresh it',
                trailing: b.donor == 'off'
                    ? const SizedBox.shrink()
                    : EmberButton(
                        label: 'Prepare',
                        onTap: b.busy
                            ? null
                            : () async {
                                final verdict = await b.prepareIfNeeded();
                                if (context.mounted && !verdict.cancelled) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        verdict.proceed
                                            ? 'The Guardian pass is ready'
                                            : verdict.message ??
                                                  'The pass could not be '
                                                      'fetched',
                                      ),
                                    ),
                                  );
                                }
                              },
                      ),
              );
            },
          ),
        // The connection mode (mockup 4).
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l.connectionMode,
                style: const TextStyle(
                  fontSize: Ember.fontBody,
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
                onChanged: (v) => unawaited(_setMode(v)),
              ),
            ],
          ),
        ),
        const Divider(color: MapUi.line, height: 1, thickness: 1),
        MapSettingRow(
          label: l.smartRouting,
          subtitle: l.smartRoutingSub,
          // Build 2096 (post-2095 audit L18): an unknown
          // value renders DIMMED (the transport block's
          // treatment) — build 2095 disabled the toggles
          // but still rendered a confident value.
          trailing: Opacity(
            opacity: _routing == null ? 0.5 : 1,
            child: MapToggle(
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
        ),
        // Build 2116 (audit AB-06): the routing-lists
        // state — visible only while the lists are
        // missing, with a Retry that downloads now (the
        // core also retries on its own ladder).
        if (_routing == true) _RoutingListsRow(core: widget.core),
        MapSettingRow(
          label: l.doh,
          subtitle: l.dohSub,
          trailing: Opacity(
            opacity: _doh == null ? 0.5 : 1,
            child: MapToggle(
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
        ),
        if (_loadFailed)
          MapSettingRow(
            label: 'Core settings',
            subtitle: 'Could not be read from the core — tap to retry',
            trailing: _navChevron,
            onTap: () => unawaited(_load()),
          ),
        // Build 2095 (audit #13): the transport choice the
        // legacy settings page always had (proxy.transport
        // h2/h3) was missing from this section entirely.
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l.transport,
                style: const TextStyle(
                  fontSize: Ember.fontBody,
                  fontWeight: FontWeight.w500,
                  color: MapUi.text,
                ),
              ),
              const SizedBox(height: 9),
              // EmberSegmented has no disabled state: while
              // the value is unknown (read failed) or an edit
              // is in flight, the control is dimmed and
              // pointer-dead instead of tappable.
              Opacity(
                opacity: _busy || _transport == null ? 0.5 : 1,
                child: IgnorePointer(
                  ignoring: _busy || _transport == null,
                  child: EmberSegmented<String>(
                    value: _transport ?? 'h3',
                    options: [
                      // Build 2105 (Mozilla feature 2):
                      // HTTP/1.1 joins the choice. The labels
                      // are the bare protocol names for all
                      // three: the arb labels' (TCP)/(QUIC)
                      // qualifiers no longer fit a three-way
                      // segment on a phone-width panel (the
                      // widget tests' layout gate caught the
                      // overflow), and the names alone are
                      // unambiguous.
                      ('h1', 'HTTP/1.1', null),
                      ('h2', 'HTTP/2', null),
                      ('h3', 'HTTP/3', null),
                    ],
                    onChanged: (v) => _edit((config) {
                      final proxy = config['proxy'];
                      if (proxy is Map<String, Object?>) {
                        proxy['transport'] = v;
                      }
                    }),
                  ),
                ),
              ),
            ],
          ),
        ),
        // Build 2105 (Mozilla feature 2): the honest caveat,
        // shown only while HTTP/1.1 is the chosen transport —
        // whether Mozilla's edge accepts HTTP/1.1 CONNECT is
        // unproven, and the owner learns that here, not from a
        // silent failure.
        if (_transport == 'h1')
          Padding(
            padding: const EdgeInsets.only(bottom: 7),
            child: Text(
              'Experimental: Mozilla\'s servers may not accept '
              'HTTP/1.1. If the connection fails, switch back to '
              'HTTP/2.',
              style: TextStyle(fontSize: Ember.fontSmall, color: MapUi.dim),
            ),
          ),
        const Divider(color: MapUi.line, height: 1, thickness: 1),
        // Build 2105 (Mozilla feature 3): the IP-version
        // policy for reaching Mozilla's servers (dns.ip_version
        // in the core). 'Auto' is the core's long-standing
        // behaviour (IPv4 first, IPv6 when no IPv4 answer).
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'IP version for Mozilla servers',
                style: const TextStyle(
                  fontSize: Ember.fontBody,
                  fontWeight: FontWeight.w500,
                  color: MapUi.text,
                ),
              ),
              const SizedBox(height: 9),
              Opacity(
                opacity: _busy || _ipVersion == null ? 0.5 : 1,
                child: IgnorePointer(
                  ignoring: _busy || _ipVersion == null,
                  child: EmberSegmented<String>(
                    value: _ipVersion ?? 'auto',
                    options: [
                      // V4/V6 shorthand: the full 'IPv6
                      // first' wording overflows a four-way
                      // segment on phone widths (the widget
                      // tests' layout gate again); the
                      // section title above carries the full
                      // 'IP version' wording.
                      ('auto', 'Auto', null),
                      ('ipv6_first', 'V6 first', null),
                      ('ipv4_only', 'V4 only', null),
                      ('ipv6_only', 'V6 only', null),
                    ],
                    onChanged: (v) => _edit((config) {
                      final dns = config['dns'];
                      if (dns is Map<String, Object?>) {
                        dns['ip_version'] = v;
                      }
                    }),
                  ),
                ),
              ),
            ],
          ),
        ),
        const Divider(color: MapUi.line, height: 1, thickness: 1),
        // Build 2105 (Mozilla feature 4): connect-time fast
        // failover (proxy.fast_failover in the core). Off, a
        // failed server takes the core's standing three
        // strikes before the location moves on, as before.
        MapSettingRow(
          label: 'Fast failover',
          subtitle:
              'On a failed connect, try the next server in the '
              'same location right away',
          trailing: Opacity(
            opacity: _fastFailover == null ? 0.5 : 1,
            child: MapToggle(
              value: _fastFailover ?? false,
              onChanged: _busy || _fastFailover == null
                  ? null
                  : (v) => _edit((config) {
                      final proxy = config['proxy'];
                      if (proxy is Map<String, Object?>) {
                        proxy['fast_failover'] = v;
                      }
                    }),
            ),
          ),
        ),
        const Divider(color: MapUi.line, height: 1, thickness: 1),
        // Build 2087 (analysis A3): the Mozilla core's log page
        // was unreachable in this shell — every other engine
        // had a logs row in its section (Psiphon, Lantern,
        // OpenVPN, V2Ray), Mozilla's LogsPage was only linked
        // from the desktop shell. Same row, same pushed page.
        MapSettingRow(
          label: l.coreLogs,
          trailing: _navChevron,
          divider: false,
          onTap: () => Navigator.of(context)
              .push(_emberPageRoute(l.coreLogs, LogsPage(core: widget.core))),
        ),
      ],
    );
  }
}

// ------------------------------------------------------------------ V2Ray

class _XraySection extends StatelessWidget {
  const _XraySection({
    required this.xray,
    this.settings,
    this.openvpn,
    this.psiphon,
    this.warp,
    this.masque,
  });
  final XrayController xray;

  /// Build 2095 (V2Ray journey audit #15): the app settings,
  /// so the backup can carry them. Optional — without it the
  /// backup is configs-only, as before.
  final AppSettings? settings;

  /// Build 2116 (AB-05): the other engines' controllers,
  /// so this section's backup/restore and pairing flows
  /// carry their sections too. Optional, like [settings].
  final OpenVpnController? openvpn;
  final PsiphonController? psiphon;
  final AetherController? warp;
  final AetherController? masque;

  XraySettings get s => xray.settings;

  /// Build 2101 (settings-dns-2099-diagnosis.md, S1/S2): the
  /// section's ONE save path. XrayController.save() persists
  /// without notifying — deliberately, for its bulk internal
  /// writers — so a settings callback that only saved left the
  /// page showing the OLD value until navigation (the value
  /// WAS on disk; the toggle, chip or DNS row simply never
  /// rebuilt). Every callback in this section now saves
  /// through here, and the notify lands the new value on
  /// screen at once.
  Future<void> _saveSection() async {
    await xray.save();
    xray.notifySettingsChanged();
  }

  Future<void> _save(BuildContext context) async {
    await _saveSection();
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
                        fontSize: Ember.fontBody,
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
                              RoutingPreset.bypassChina => 'Bypass China',
                              RoutingPreset.directAll => l.presetDirectAll,
                            },
                            selected: s.routingPreset == preset,
                            onTap: () async {
                              s.routingPreset = preset;
                              await _saveSection();
                            },
                          ),
                      ],
                    ),
                    const SizedBox(height: 13),
                    Text(
                      l.domainStrategy,
                      style: const TextStyle(
                        fontSize: Ember.fontBody,
                        fontWeight: FontWeight.w500,
                        color: MapUi.text,
                      ),
                    ),
                    const SizedBox(height: 9),
                    EmberSegmented<String>(
                      // Batch 5 (fidelity rollout, pro7-routing
                      // sample): the routing mode segmented is
                      // the sample's FLAT form — tracked text,
                      // the chosen one orange over a 2 px bar,
                      // no tray. Same options, values and save.
                      flat: true,
                      value: s.domainStrategy,
                      // Build 2145 (UI-review fix A11): the
                      // LABELS are plain words a first-time user
                      // can parse; the VALUES stay the exact
                      // config strings the core expects. (The
                      // verb forms — "Resolve if no match" —
                      // overflow the equal-width segment cells
                      // at phone widths; the section's own
                      // title carries the verb's context.)
                      options: [
                        ('IPIfNonMatch', 'If no match', null),
                        ('AsIs', 'As is', null),
                        ('IPOnDemand', 'On demand', null),
                      ],
                      onChanged: (v) async {
                        s.domainStrategy = v;
                        await _saveSection();
                      },
                    ),
                  ],
                ),
              ),
              const Divider(color: MapUi.line, height: 1, thickness: 1),
              MapSettingRow(
                label: l.enableUdp,
                // Build 2118: last row of the Connection panel
                // after the split below — no divider under it.
                divider: false,
                trailing: MapToggle(
                  value: s.enableUdp,
                  onChanged: (v) async {
                    s.enableUdp = v;
                    await _saveSection();
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          // Build 2118 (appearance fix round): the Connection
          // panel carried ~19 rows and read as one monolithic
          // card next to the samples' compact grouped cards.
          // It splits into three panels — grouping only: every
          // row keeps its place in the order, its control and
          // its callback. The two new titles are hardcoded
          // strings, like this section's own hardcoded row
          // labels ('Sniff HTTP', 'Fallback groups') — no new
          // l10n keys.
          MapSettingsPanel(
            title: 'Sniffing',
            children: [
              MapSettingRow(
                label: l.sniffing,
                trailing: MapToggle(
                  value: s.sniffing,
                  onChanged: (v) async {
                    s.sniffing = v;
                    await _saveSection();
                  },
                ),
              ),
              // Build 2095 (V2Ray journey audit #22): the
              // per-protocol sniffing set — the builder
              // hardcoded http+tls+quic into destOverride.
              MapSettingRow(
                label: 'Sniff HTTP',
                subtitle: 'Destination override for HTTP traffic',
                trailing: MapToggle(
                  value: s.sniffHttp,
                  onChanged: !s.sniffing
                      ? null
                      : (v) async {
                          s.sniffHttp = v;
                          await _saveSection();
                        },
                ),
              ),
              MapSettingRow(
                label: 'Sniff TLS',
                subtitle: 'Destination override for TLS (SNI)',
                trailing: MapToggle(
                  value: s.sniffTls,
                  onChanged: !s.sniffing
                      ? null
                      : (v) async {
                          s.sniffTls = v;
                          await _saveSection();
                        },
                ),
              ),
              MapSettingRow(
                label: 'Sniff QUIC',
                subtitle: 'Destination override for QUIC traffic',
                trailing: MapToggle(
                  value: s.sniffQuic,
                  onChanged: !s.sniffing
                      ? null
                      : (v) async {
                          s.sniffQuic = v;
                          await _saveSection();
                        },
                ),
              ),
              // Build 2108 (Block QUIC toggle, feature-watch
              // 2026-11-18): a routing rule, not a sniffing
              // knob — it is NOT gated on [s.sniffing], and it
              // applies at the next connect. Covers the
              // V2Ray/Xray path only; the Settings copy says so
              // in the model doc, and the row subtitle keeps the
              // mechanism honest (UDP/443 → TCP fallback).
              MapSettingRow(
                // Build 2116 (B13-10, 2108-L2): the rule drops
                // ALL UDP/443, not only QUIC — the label and
                // subtitle say so instead of implying a
                // QUIC-only filter. Behaviour unchanged.
                label: 'Block QUIC (all UDP/443)',
                subtitle:
                    'Drops every UDP packet to port 443, QUIC '
                    'or not, so apps fall back to TCP. V2Ray '
                    'sessions only — it does not cover '
                    'DNS-over-QUIC, which resolves on the local '
                    'endpoint (build 2125, audit A25-35).',
                // Build 2118: last row of the Sniffing panel
                // after the split — no divider under it.
                divider: false,
                trailing: MapToggle(
                  value: s.blockQuic,
                  onChanged: (v) async {
                    s.blockQuic = v;
                    await _saveSection();
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          // Build 2118: the third panel of the split (see the
          // Sniffing panel above) — everything the Connection
          // panel carried after the sniffing set.
          MapSettingsPanel(
            title: 'Advanced',
            children: [
              // Build 2126 (feature pick 3): the ShadowTLS
              // fronting switch. Off (the default), a
              // Shadowsocks profile whose link carries a
              // shadow-tls plugin connects on the Xray core
              // WITHOUT the plugin, exactly as in 2125; on,
              // the sing-box engine serves it with the TLS
              // front applied. Applies at the next connect.
              // Build 2127 (H2): the Sudoku engine switch.
              // Off (the default), a Sudoku profile refuses
              // at connect in plain words and nothing else
              // changes; on, the Sudoku engine (Hiddify's
              // sing-box fork, its own binary) serves it.
              MapSettingRow(
                label: 'Sudoku (Hiddify engine)',
                subtitle:
                    'Serves Sudoku profiles through the '
                    'bundled Sudoku engine. Sudoku exists '
                    'only in Hiddify\'s sing-box fork, so it '
                    'rides its own engine binary. Off: a '
                    'Sudoku profile will not connect.',
                trailing: MapToggle(
                  value: s.sudokuEnabled,
                  onChanged: (v) async {
                    s.sudokuEnabled = v;
                    await _saveSection();
                  },
                ),
              ),
              // Build 2139 (leg 1): the RegionHop switch.
              // Off (the default), the app never contacts
              // the regionhop panel and no RegionHop entry
              // exists; on, the entry below opens the page.
              // The toggle itself makes no network calls.
              MapSettingRow(
                label: 'RegionHop (server Psiphon exits)',
                subtitle:
                    'Your own server\u2019s Psiphon exits, '
                    'managed from its panel and reached '
                    'through authenticated relays on the '
                    'same box. Off: the app never contacts '
                    'the panel.',
                trailing: MapToggle(
                  value: s.regionHopEnabled,
                  onChanged: (v) async {
                    s.regionHopEnabled = v;
                    await _saveSection();
                  },
                ),
              ),
              if (s.regionHopEnabled)
                MapSettingRow(
                  label: 'RegionHop',
                  subtitle: s.regionHopPanelUrl.isEmpty
                      ? 'Set up the panel connection'
                      : 'Panel locations, exits and connect',
                  trailing: _navChevron,
                  onTap: () => openRegionHop(context, xray),
                ),
              MapSettingRow(
                label: 'ShadowTLS fronting (Shadowsocks)',
                subtitle:
                    'Serves Shadowsocks configs whose link '
                    'carries a shadow-tls plugin through the '
                    'sing-box engine, with the TLS front '
                    'applied (TCP only — ShadowTLS cannot '
                    'relay UDP). Off: those configs connect '
                    'without the plugin, as before.',
                trailing: MapToggle(
                  value: s.shadowTlsFronting,
                  onChanged: (v) async {
                    s.shadowTlsFronting = v;
                    await _saveSection();
                  },
                ),
              ),
              // Build 2126 (D1).
              MapSettingRow(
                label: 'Gecko packet sizes (Hysteria2)',
                subtitle:
                    'Applies the packet-size band a gecko '
                    'config carries in its link (gecko '
                    'min/max packet size) through the '
                    'sing-box engine. Off: gecko configs '
                    'connect without the size band, as '
                    'before.',
                trailing: MapToggle(
                  value: s.geckoPacketSizes,
                  onChanged: (v) async {
                    s.geckoPacketSizes = v;
                    await _saveSection();
                  },
                ),
              ),
              // Build 2126 (D6).
              MapSettingRow(
                label: 'Noise decoy (Hysteria2)',
                subtitle:
                    'Sends random decoy packets on the '
                    'Hysteria2 socket just before the real '
                    'handshake, so a filter\'s first read '
                    'is noise. Off: no decoy packets, as '
                    'before.',
                trailing: MapToggle(
                  value: s.hy2NoiseDecoy,
                  onChanged: (v) async {
                    s.hy2NoiseDecoy = v;
                    await _saveSection();
                  },
                ),
              ),
              // Build 2126 (D8).
              MapSettingRow(
                label: 'TLS fragmentation (sing-box engine)',
                subtitle:
                    'Splits the TLS hello across fragments '
                    'on handshakes the sing-box engine '
                    'terminates (TUIC, AnyTLS, Snell, Naive '
                    'and diverted configs). Off: those '
                    'hellos travel whole, as before.',
                trailing: MapToggle(
                  value: s.sidecarTlsFragment,
                  onChanged: (v) async {
                    s.sidecarTlsFragment = v;
                    await _saveSection();
                  },
                ),
              ),
              // Build 2127 (H3): per-route SNI spoofing.
              MapSettingRow(
                label: 'SNI spoofing (sing-box engine)',
                subtitle:
                    'For the domains in your rules, the '
                    'sing-box engine shows a filter a fake '
                    'TLS hello with a decoy name before the '
                    'real handshake. Off: no fake hellos, '
                    'as before.',
                trailing: MapToggle(
                  value: s.sniSpoofEnabled,
                  onChanged: (v) async {
                    s.sniSpoofEnabled = v;
                    await _saveSection();
                  },
                ),
              ),
              if (s.sniSpoofEnabled)
                MapSettingRow(
                  label: 'SNI spoofing rules',
                  subtitle:
                      '${s.sniSpoofRules.length} rule'
                      '${s.sniSpoofRules.length == 1 ? '' : 's'}',
                  trailing: _navChevron,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => SniSpoofPage(xray: xray),
                    ),
                  ),
                ),
              // Batch 5 (fidelity rollout, pro7-dns sample):
              // the FakeDNS row moves to the DNS panel — the
              // sample's OPTIONS block groups it with the
              // providers; the row, its toggle and its save
              // path are unchanged (a grouping move, the
              // build-2118 panel-split precedent).
              MapSettingRow(
                label: l.ipv6Route,
                trailing: MapToggle(
                  value: s.ipv6Route,
                  onChanged: (v) async {
                    s.ipv6Route = v;
                    await _saveSection();
                  },
                ),
              ),
              MapSettingRow(
                label: l.mux,
                // Build 2095 (V2Ray journey audit #27, second
                // half): the row names the protocols mux
                // applies to — it used to read as global.
                subtitle:
                    '${l.muxSub} Applies to VLESS, VMess, Trojan '
                    'and Shadowsocks configs.',
                trailing: MapToggle(
                  value: s.muxEnabled,
                  onChanged: (v) async {
                    s.muxEnabled = v;
                    await _saveSection();
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
                          await _saveSection();
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
                        await _saveSection();
                      },
                    ),
                ],
              ),
              // Delay test timeout (build 2109, feature-watch
              // 2026-11-12, FlClash 0.9.2): how long one test
              // request waits for an answer — the single test,
              // Test All, the DPI Lab probes and the sandbox
              // test. 8s is the value every build ≤2108 used,
              // so a store that never set it behaves exactly as
              // before; shorter fails slow configs faster,
              // longer gives them more time to answer.
              _ChipGroupRow(
                label: 'Delay test timeout',
                subtitle: 'How long each test request waits for an answer',
                chips: [
                  for (final n in const [3, 5, 8, 10, 15, 20])
                    EmberChip(
                      label: '${n}s',
                      compact: true,
                      selected: s.delayTestTimeoutSec == n,
                      onTap: () async {
                        s.delayTestTimeoutSec = n;
                        await _saveSection();
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
                    await _saveSection();
                  },
                ),
              ),
              // Build 2126 (D2): shown with the fragment
              // toggle it modifies.
              if (s.fragmentEnabled)
                MapSettingRow(
                  label: 'Fragment via FinalMask',
                  subtitle:
                      'Applies the fragment split inside the '
                      'connection (FinalMask) instead of '
                      'through a chained dialer — the newer '
                      'core mechanism. Off: the chained '
                      'dialer, as before.',
                  trailing: MapToggle(
                    value: s.fragmentViaFinalmask,
                    onChanged: (v) async {
                      s.fragmentViaFinalmask = v;
                      await _saveSection();
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
                          await _saveSection();
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
                          await _saveSection();
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
                          await _saveSection();
                        },
                      ),
                  ],
                ),
              ],
              // Build 2136 (item 8): randomized fragment
              // geometry — the fragment chain's fixed cuts
              // become ranges around the values above.
              MapSettingRow(
                label: 'Randomized fragment geometry',
                subtitle:
                    'The fragment length and interval above '
                    'become ranges (half to double); the core '
                    'picks a fresh cut per connection. Off: '
                    'the fixed values are used, as before.',
                trailing: MapToggle(
                  value: s.fragmentRandomGeometry,
                  onChanged: (v) async {
                    s.fragmentRandomGeometry = v;
                    await _saveSection();
                  },
                ),
              ),
              // Stage A (build 2026) + group semantics (build
              // 2035): fallback groups, ON by default — with it
              // off, the engine behaves exactly as in 2025.
              // Build 2087: the subtitle says what the switch
              // still governs — a manual connect no longer
              // walks (it tries exactly the picked config), so
              // the group move is for sessions that die.
              MapSettingRow(
                label: 'Fallback groups',
                subtitle: 'If a connected config dies, move to the next in its group automatically — a manual connect always tries exactly the config you picked',
                divider: false,
                trailing: MapToggle(
                  value: s.adaptiveFailover,
                  onChanged: (v) async {
                    s.adaptiveFailover = v;
                    await _saveSection();
                  },
                ),
              ),
              // Build 2136 (item 14): auto-fastest group.
              MapSettingRow(
                label: 'Auto-fastest group',
                subtitle:
                    'A connect starts from the fastest tested '
                    'member of the config\'s group instead of '
                    'the tapped one; failover still walks the '
                    'group if it fails. Off: the tapped config '
                    'starts, as before.',
                trailing: MapToggle(
                  value: s.autoFastestGroup,
                  onChanged: (v) async {
                    s.autoFastestGroup = v;
                    await _saveSection();
                  },
                ),
              ),
              // Build 2136 (item 1): stop on sleep.
              MapSettingRow(
                label: 'Stop VPN when the screen turns off',
                subtitle:
                    'Disconnects the running engine when the '
                    'device sleeps, instead of holding the '
                    'tunnel overnight. Acts while the app '
                    'process is alive. Off: sleep behaviour '
                    'is unchanged.',
                trailing: MapToggle(
                  value: s.stopVpnOnSleep,
                  onChanged: (v) async {
                    s.stopVpnOnSleep = v;
                    await _saveSection();
                  },
                ),
              ),
              // Build 2095 (feature 2): the stall
              // watchdog's user control. The watchdog
              // detects a frozen tunnel (traffic up,
              // nothing back, probes failing) and escalates
              // — shapes first, then the group failover.
              MapSettingRow(
                label: 'Stall watchdog',
                subtitle: 'If the tunnel freezes, switch shapes and then configs automatically',
                trailing: MapToggle(
                  value: s.stallWatchdog,
                  onChanged: (v) async {
                    s.stallWatchdog = v;
                    await _saveSection();
                  },
                ),
              ),
              // Smart dial racing (build 2075, feature item 5):
              // when the picked config fails, the next group
              // members' endpoints are probed in parallel and
              // the first that answers is tried first, instead
              // of one slow timeout after another.
              MapSettingRow(
                label: 'Smart dial racing',
                subtitle: 'Race the fallback group\'s endpoints in parallel and dial the first that answers',
                divider: false,
                trailing: MapToggle(
                  value: s.smartDialRacing,
                  onChanged: (v) async {
                    s.smartDialRacing = v;
                    await _saveSection();
                    xray.notifySettingsChanged();
                  },
                ),
              ),
              // Country exclusion (build 2075, feature item
              // 16): automatic picks — the fallback walk and
              // keep-fastest pruning — skip configs whose
              // observed exit country is listed. A manual tap
              // still connects any config.
              _ListRow(
                label: 'Excluded exit countries',
                values: s.excludedCountries,
                onChanged: (v) async {
                  s.excludedCountries = v
                      .map((e) => e.trim().toUpperCase())
                      .where((e) => e.length == 2)
                      .toList();
                  await _saveSection();
                  xray.notifySettingsChanged();
                },
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(
                  'ISO country codes (e.g. IR, CN, RU). Automatic selection skips configs that exit there; tapping one yourself still connects it.',
                  style: Ember.caption,
                ),
              ),
              // Routing by network type (build 2075, feature
              // item 26): the active routing preset follows
              // the transport; a running tunnel keeps the
              // preset it started with.
              MapSettingRow(
                label: 'Routing by network type',
                subtitle: 'Use a different routing preset on Wi-Fi and on mobile data',
                divider: false,
                trailing: MapToggle(
                  value: s.routingByNetwork,
                  onChanged: (v) async {
                    s.routingByNetwork = v;
                    await _saveSection();
                    xray.notifySettingsChanged();
                  },
                ),
              ),
              if (s.routingByNetwork) ...[
                _ChipGroupRow(
                  label: 'On Wi-Fi',
                  subtitle: 'Routing preset for Wi-Fi networks',
                  chips: [
                    for (final preset in RoutingPreset.values)
                      EmberChip(
                        label: switch (preset) {
                          RoutingPreset.global => 'Global',
                          RoutingPreset.bypassLan => 'Bypass LAN',
                          RoutingPreset.bypassIran => 'Bypass Iran',
                          RoutingPreset.bypassChina => 'Bypass China',
                          RoutingPreset.directAll => 'Direct all',
                        },
                        compact: true,
                        selected: s.routingPresetWifi == preset,
                        onTap: () async {
                          s.routingPresetWifi = preset;
                          await _saveSection();
                          xray.notifySettingsChanged();
                        },
                      ),
                  ],
                ),
                _ChipGroupRow(
                  label: 'On mobile data',
                  subtitle: 'Routing preset for mobile networks',
                  divider: false,
                  chips: [
                    for (final preset in RoutingPreset.values)
                      EmberChip(
                        label: switch (preset) {
                          RoutingPreset.global => 'Global',
                          RoutingPreset.bypassLan => 'Bypass LAN',
                          RoutingPreset.bypassIran => 'Bypass Iran',
                          RoutingPreset.bypassChina => 'Bypass China',
                          RoutingPreset.directAll => 'Direct all',
                        },
                        compact: true,
                        selected: s.routingPresetMobile == preset,
                        onTap: () async {
                          s.routingPresetMobile = preset;
                          await _saveSection();
                          xray.notifySettingsChanged();
                        },
                      ),
                  ],
                ),
              ],
              // Multi-peer WireGuard (build 2075, feature item
              // 27): a .conf with several peers connects with
              // all of them in the outbound, not just the one
              // peer this profile carries.
              MapSettingRow(
                label: 'Use all peers of a WireGuard config',
                subtitle: 'When a .conf file has several peers, connect with every peer in it',
                divider: false,
                trailing: MapToggle(
                  value: s.wgUseAllPeers,
                  onChanged: (v) async {
                    s.wgUseAllPeers = v;
                    await _saveSection();
                    xray.notifySettingsChanged();
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
                    await _saveSection();
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
                          await _saveSection();
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
                          await _saveSection();
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
              // at next connect. Build 2125 (audit A25-04)
              // extended the hold to the Psiphon, Lantern and
              // OpenVPN engines; build 2127 (H4) covers the
              // last two: Mozilla (the service keeps a dup of
              // the TUN fd, so the interface survives the
              // core as a blackhole) and AmneziaWG (the
              // library's own lockdown). If Android itself
              // kills the app, only Android's Always-on VPN
              // can block — this switch cannot.
              MapSettingRow(
                label: 'Kill switch',
                subtitle: 'Block all traffic while the tunnel is down, including the auto-reconnect wait.',
                trailing: MapToggle(
                  value: s.killSwitch,
                  onChanged: (v) async {
                    s.killSwitch = v;
                    await _saveSection();
                    // Build 2127 (H4): the Mozilla engine
                    // reads the same switch through its
                    // AndroidCore mirror.
                    AndroidCore.killSwitch.value = v;
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
                    'While on, a dropped or failed tunnel blocks all traffic until it reconnects or you disconnect. This covers every engine: V2Ray/WARP, Psiphon, Lantern, OpenVPN, Mozilla and AmneziaWG.',
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
                    await _saveSection();
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
                    await _saveSection();
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
                          await _saveSection();
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
                  await _saveSection();
                },
              ),
            ],
          ),
          const SizedBox(height: 14),
          MapSettingsPanel(
            title: l.dnsSection,
            children: [
              // Build 2101 (settings-dns-2099-diagnosis.md,
              // S2): the panel never said WHEN a DNS change
              // takes effect — the config is built fresh at
              // connect, so a mid-session edit silently waited
              // for the next connect and read as "doesn't
              // apply". The LAN-sharing panel's wording, here
              // too.
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  'Applies at next connect.',
                  style: Ember.caption,
                ),
              ),
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
              // Batch 5 (fidelity rollout, pro7-dns sample):
              // the presets are provider ROWS now, not chips —
              // name, the URL verbatim as the caption, and a
              // flat SELECTED pill on the row whose URL the
              // field currently holds; the tap and the save
              // are the chip's own. The sample's 'Default'
              // row has no separate counterpart: the app's
              // model is the one URL field above, whose
              // shipped default is the Cloudflare DoH value
              // (build 2111) — that row carries SELECTED
              // whenever the value is untouched.
              for (final (label, url) in const [
                ('Google DoH', 'https://dns.google/dns-query'),
                ('Google DoH +one', 'https+one://dns.google/dns-query'),
                ('Cloudflare DoH', 'https://cloudflare-dns.com/dns-query'),
                (
                  'Cloudflare +one',
                  'https+one://cloudflare-dns.com/dns-query',
                ),
                ('Quad9 DoH', 'https://dns.quad9.net/dns-query'),
              ])
                _DnsProviderRow(
                  label: label,
                  url: url,
                  selected: s.remoteDns == url,
                  onTap: () async {
                    s.remoteDns = url;
                    await _saveSection();
                  },
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
                            await _saveSection();
                          },
                        ),
                        EmberChip(
                          label: 'DoQ (QUIC, direct)',
                          selected: s.remoteDnsProto == 'doq',
                          onTap: () async {
                            s.remoteDnsProto = 'doq';
                            await _saveSection();
                          },
                        ),
                        EmberChip(
                          label: 'TCP (port 53)',
                          selected: s.remoteDnsProto == 'tcp',
                          onTap: () async {
                            s.remoteDnsProto = 'tcp';
                            await _saveSection();
                          },
                        ),
                        // DNSCrypt (build 2075, feature item 7):
                        // the local dnscrypt-proxy sidecar is
                        // the resolver — encrypted DNSCrypt /
                        // DoH to a pinned public set, run by
                        // the app while the tunnel is up.
                        EmberChip(
                          label: 'DNSCrypt',
                          selected: s.remoteDnsProto == 'dnscrypt',
                          onTap: () async {
                            s.remoteDnsProto = 'dnscrypt';
                            await _saveSection();
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
                      // Build 2056 named the 2049 built-in
                      // fallback here when it rode the default
                      // shape; build 2101 removes that fallback
                      // (owner order 2026-11-18 — v2rayNG's
                      // shape carries none), so the line names
                      // only what the config really holds.
                      // Build 2053 (audit F-H4): the core speaks
                      // ONLY quic+local for DoQ, and +local is
                      // local egress — the query leaves the device
                      // directly, not through the tunnel — so the
                      // "never the local one" line must not be
                      // claimed for DoQ.
                      '${s.remoteDnsProto == 'doq'
                          ? ' • DoQ is local-egress: its queries leave the device directly, not through the tunnel'
                          : s.remoteDnsProto == 'dnscrypt'
                          ? ' • DNSCrypt runs through the app\'s local dnscrypt-proxy (127.0.0.1:20530); its signed resolver list downloads on first use'
                          : ' • server names resolve through the provider DNS, never the local one'}',
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
              // Build 2116 (B9-3, re-verified): this field
              // is NOT the V2Ray core's DNS — the generated
              // config derives that from the remote DNS
              // above. It is the tunnel-interface DNS for
              // WireGuard, Lantern and Psiphon, and the row
              // says so instead of implying otherwise.
              Padding(
                padding: const EdgeInsets.only(top: 6, bottom: 2),
                child: Text(
                  'Applies to WireGuard, Lantern and Psiphon '
                  'tunnels. The V2Ray core uses the remote DNS '
                  'above.',
                  style: Ember.caption,
                ),
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
                    await _saveSection();
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
                    await _saveSection();
                  },
                ),
              ),
              const Divider(color: MapUi.line, height: 1),
              // DNS cache off (build 2075, feature item 23 —
              // the part of the DNS control pack the core
              // honestly supports: its DNS section has a real
              // disableCache field. Optimistic caching and
              // per-resolver timeouts have no field in the
              // core's DNS schema and are not offered.)
              MapSettingRow(
                label: 'Disable DNS cache',
                subtitle: 'The core re-resolves every name instead of serving its cache',
                trailing: MapToggle(
                  value: s.dnsCacheDisabled,
                  onChanged: (v) async {
                    s.dnsCacheDisabled = v;
                    await _saveSection();
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
                    await _saveSection();
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
              // Batch 5 (fidelity rollout, pro7-dns sample):
              // FakeDNS lives here now — the sample's DNS
              // OPTIONS block (its row moved from the Advanced
              // panel; same toggle, same save path).
              MapSettingRow(
                label: l.fakeDns,
                trailing: MapToggle(
                  value: s.fakeDns,
                  onChanged: (v) async {
                    s.fakeDns = v;
                    await _saveSection();
                  },
                ),
              ),
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
                  await _saveSection();
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
                    await _saveSection();
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
                      await _saveSection();
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
          // Local proxy (build 2075, feature items 17 + 24):
          // a dedicated browser port, and an optional login on
          // the loopback proxy inbounds.
          MapSettingsPanel(
            title: 'Local proxy',
            children: [
              MapSettingRow(
                label: 'Dedicated browser port',
                subtitle:
                    'A fixed HTTP proxy on 127.0.0.1:${s.browserPort} while connected. Point your browser at it yourself — nothing is configured for you.',
                trailing: MapToggle(
                  value: s.browserPortEnabled,
                  onChanged: (v) async {
                    s.browserPortEnabled = v;
                    await _saveSection();
                  },
                ),
              ),
              if (s.browserPortEnabled) ...[
                const Divider(color: MapUi.line, height: 1),
                _TextRow(
                  label: 'Browser port',
                  initial: '${s.browserPort}',
                  numeric: true,
                  onSubmit: (v) async {
                    final port = int.tryParse(v);
                    if (port == null || port < 1024 || port > 65535) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'Enter a port between 1024 and 65535.',
                            ),
                            duration: Duration(seconds: 6),
                          ),
                        );
                      }
                      return;
                    }
                    s.browserPort = port;
                    await _save(context);
                  },
                ),
              ],
              const Divider(color: MapUi.line, height: 1),
              MapSettingRow(
                label: 'Require a login on this device',
                subtitle: 'The local SOCKS and HTTP proxies ask for a username and password. The LAN sharing login above stays separate.',
                trailing: MapToggle(
                  value: s.localProxyAuth,
                  onChanged: (v) async {
                    s.localProxyAuth = v;
                    await _saveSection();
                  },
                ),
              ),
              if (s.localProxyAuth) ...[
                const Divider(color: MapUi.line, height: 1),
                _TextRow(
                  label: 'Username',
                  initial: s.localProxyUser,
                  onSubmit: (v) async {
                    s.localProxyUser = v;
                    await _save(context);
                  },
                ),
                const Divider(color: MapUi.line, height: 1),
                _TextRow(
                  label: 'Password',
                  initial: s.localProxyPass,
                  obscure: true,
                  onSubmit: (v) async {
                    s.localProxyPass = v;
                    await _save(context);
                  },
                ),
                if (!s.localProxyAuthReady)
                  Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      'Enter a username and password — until then the local proxies have no login.',
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
                  await _saveSection();
                },
              ),
              const Divider(color: MapUi.line, height: 1),
              _ListRow(
                label: l.directIps,
                values: s.customDirectIps,
                onChanged: (v) async {
                  s.customDirectIps = v;
                  await _saveSection();
                },
              ),
              const Divider(color: MapUi.line, height: 1),
              _ListRow(
                label: l.blockDomains,
                values: s.customBlockDomains,
                onChanged: (v) async {
                  s.customBlockDomains = v;
                  await _saveSection();
                },
              ),
              const Divider(color: MapUi.line, height: 1),
              _ListRow(
                label: l.proxyDomains,
                values: s.customProxyDomains,
                onChanged: (v) async {
                  s.customProxyDomains = v;
                  await _saveSection();
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
                    await _saveSection();
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
                        await _saveSection();
                      },
                    ),
                ],
              ),
              // Build 2134 (leg 2): the automatic per-device
              // HWID switch — default OFF; while off, fetches
              // send exactly build 2133's headers.
              MapSettingRow(
                label: 'Device HWID header',
                subtitle:
                    'Send this device\'s stable ID (x-hwid) '
                    'when fetching subscriptions — some panels '
                    'require it',
                trailing: MapToggle(
                  value: s.subHwidEnabled,
                  onChanged: (v) async {
                    s.subHwidEnabled = v;
                    if (v && s.deviceHwid.isEmpty) {
                      s.deviceHwid = generateDeviceHwid();
                    }
                    await _saveSection();
                  },
                ),
              ),
              if (s.subHwidEnabled) ...[
                MapSettingRow(
                  label: 'Device ID',
                  subtitle: s.deviceHwid.isEmpty
                      ? 'Created on the next fetch'
                      : s.deviceHwid,
                  trailing: const Icon(
                    Icons.copy_rounded,
                    size: 18,
                    color: MapUi.dim,
                  ),
                  onTap: s.deviceHwid.isEmpty
                      ? null
                      : () async {
                          await Clipboard.setData(
                            ClipboardData(text: s.deviceHwid),
                          );
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Device ID copied'),
                              ),
                            );
                          }
                        },
                ),
                MapSettingRow(
                  label: 'Regenerate device ID',
                  subtitle: 'Panels will see a new device',
                  trailing: const Icon(
                    Icons.refresh_rounded,
                    size: 18,
                    color: MapUi.dim,
                  ),
                  onTap: () async {
                    s.deviceHwid = generateDeviceHwid();
                    await _saveSection();
                  },
                ),
              ],
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
          const SizedBox(height: 14),
          // Build 2105: the build's three V2Ray features, each
          // behind its own default-OFF switch (the standing
          // rule). Off, none of them records, groups, or
          // resolves anything, and the config list and the
          // connect path are exactly the pre-2105 ones.
          MapSettingsPanel(
            title: 'Traffic & groups',
            children: [
              MapSettingRow(
                label: 'Traffic history',
                subtitle:
                    'Record each config\'s traffic by the hour, '
                    'for the chart below',
                trailing: MapToggle(
                  value: s.trafficHistoryEnabled,
                  onChanged: (v) async {
                    s.trafficHistoryEnabled = v;
                    await _saveSection();
                  },
                ),
              ),
              if (s.trafficHistoryEnabled)
                MapSettingRow(
                  label: 'Traffic chart',
                  subtitle: 'What each config moved, by the hour',
                  trailing: _navChevron,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => TrafficHistoryPage(xray: xray),
                    ),
                  ),
                ),
              MapSettingRow(
                label: 'Smart groups',
                subtitle:
                    'Gather configs into groups by your own rules '
                    '(protocol, name, latency, …)',
                trailing: MapToggle(
                  value: s.smartGroupsEnabled,
                  onChanged: (v) async {
                    s.smartGroupsEnabled = v;
                    await _saveSection();
                  },
                ),
              ),
              if (s.smartGroupsEnabled)
                MapSettingRow(
                  label: 'Smart group rules',
                  subtitle:
                      '${s.smartGroupRules.length} rule'
                      '${s.smartGroupRules.length == 1 ? '' : 's'}',
                  trailing: _navChevron,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => SmartGroupsPage(xray: xray),
                    ),
                  ),
                ),
              MapSettingRow(
                label: 'Provider DNS for servers',
                subtitle:
                    'Resolve a subscription\'s server names '
                    'through the DNS set on that subscription '
                    '(in its editor), not the network\'s resolver',
                trailing: MapToggle(
                  value: s.providerDnsEnabled,
                  onChanged: (v) async {
                    s.providerDnsEnabled = v;
                    await _saveSection();
                  },
                ),
                divider: false,
              ),
            ],
          ),
          const SizedBox(height: 14),
          // Build 2107: the DPI Strategy Lab, behind its own
          // default-OFF switch (the standing rule). Off, no
          // connect path consults the Lab's per-network memory
          // and no failed connect offers it.
          MapSettingsPanel(
            title: 'DPI Strategy Lab',
            children: [
              MapSettingRow(
                label: 'DPI Strategy Lab',
                subtitle:
                    'Test which evasion strategy carries '
                    'traffic on this network, remember the '
                    'winner per network, and dial it first '
                    'there',
                trailing: MapToggle(
                  value: s.dpiLabEnabled,
                  onChanged: (v) async {
                    s.dpiLabEnabled = v;
                    await _saveSection();
                  },
                ),
                divider: s.dpiLabEnabled,
              ),
              if (s.dpiLabEnabled)
                MapSettingRow(
                  label: 'Open the Strategy Lab',
                  subtitle: 'Run discovery, see remembered networks',
                  trailing: _navChevron,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => DpiLabPage(xray: xray),
                    ),
                  ),
                  divider: true,
                ),
              // Build 2129 (Leg 3): the Senpai scanner,
              // inside the Lab section behind its own
              // default-OFF switch (on top of the Lab's).
              if (s.dpiLabEnabled)
                MapSettingRow(
                  label: 'Senpai scanner',
                  subtitle:
                      'Discover working endpoints with the '
                      'SenPaiScanner engine; import the top '
                      'results as profiles',
                  trailing: MapToggle(
                    value: s.senpaiEnabled,
                    onChanged: (v) async {
                      s.senpaiEnabled = v;
                      await _saveSection();
                    },
                  ),
                  divider: s.senpaiEnabled,
                ),
              if (s.dpiLabEnabled && s.senpaiEnabled)
                MapSettingRow(
                  label: 'Open the Senpai scanner',
                  subtitle: 'Scan, resume, import top results',
                  trailing: _navChevron,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => SenpaiPage(xray: xray),
                    ),
                  ),
                  divider: false,
                ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _showBackup(BuildContext context) async {
    final l = AppLocalizations.of(context);
    // Build 2092 (item 29): the dialog opens at once and
    // shows its progress — the export used to run invisibly
    // before anything appeared.
    // Build 2095 (V2Ray journey audit #15): the app
    // settings ride the backup (secrets stripped by the
    // controller) — a restore used to carry configs only.
    final future = xray.exportBackup(
      appSettingsJson: settings?.toJson(),
      // Build 2116 (AB-05): the other engines' sections
      // ride the settings-page backup too.
      engineSections: buildEngineSections(
        openvpn: openvpn,
        psiphon: psiphon,
        warp: warp,
        masque: masque,
      ),
    );
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        // Build 2074 (audit item 25): scrollable content — the
        // unbounded backup JSON pushed the actions off-screen
        // on short/landscape screens.
        scrollable: true,
        // Batch 5 (fidelity rollout): the dialog surface
        // takes the app's own panel colour instead of the
        // stock Material grey, so the surface reads as part
        // of the app (the pro7-backup composition sits on
        // the same near-black ground).
        backgroundColor: MapUi.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: Text(l.backupData, style: Ember.heading),
        content: SizedBox(
          width: double.maxFinite,
          child: FutureBuilder<String?>(
            future: future,
            builder: (context, snap) {
              // Build 2098 (post-2097 audit M11): the export
              // refuses (completes with null) while the store
              // is protected — say so instead of spinning
              // forever on the progress indicator.
              if (snap.connectionState == ConnectionState.done &&
                  !snap.hasData) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Text(
                    xray.storeError ?? 'The backup could not be created.',
                    style: const TextStyle(color: Ember.dim, fontSize: Ember.fontBody),
                  ),
                );
              }
              if (!snap.hasData) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Center(
                    child: CircularProgressIndicator(color: Ember.orange),
                  ),
                );
              }
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Batch 5 (fidelity rollout, pro7-backup
                  // sample): the dialog opens in the sample's
                  // composition — the file as a monospace line
                  // (its real generated size), the contents as
                  // hairline count rows from the live store,
                  // then the export as the slim hairline pill.
                  // GAPs recorded, not filled: the app keeps
                  // no last-local-backup stamp (the sample's
                  // LAST BACKUP hero date) and the local
                  // backup has no encrypt option (encryption
                  // is the GitHub sync seal's, with its
                  // password) — neither is invented here.
                  Text(
                    'ember-backup.json · '
                    '${latDigits('${(utf8.encode(snap.data!).length / 1024).round()}')} KB',
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: Ember.fontSmall,
                      color: MapUi.dim,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Profiles inside',
                          style: TextStyle(
                            fontSize: Ember.fontBody,
                            color: MapUi.text,
                          ),
                        ),
                      ),
                      Text(
                        latDigits('${xray.profiles.length}'),
                        style: const TextStyle(
                          fontSize: Ember.fontBody,
                          fontWeight: FontWeight.w600,
                          color: MapUi.text,
                        ),
                      ),
                    ],
                  ),
                  const Divider(color: MapUi.line, height: 18, thickness: 1),
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Subscriptions inside',
                          style: TextStyle(
                            fontSize: Ember.fontBody,
                            color: MapUi.text,
                          ),
                        ),
                      ),
                      Text(
                        latDigits('${xray.subscriptions.length}'),
                        style: const TextStyle(
                          fontSize: Ember.fontBody,
                          fontWeight: FontWeight.w600,
                          color: MapUi.text,
                        ),
                      ),
                    ],
                  ),
                  const Divider(color: MapUi.line, height: 18, thickness: 1),
                  const SizedBox(height: 4),
                  // The export itself (build 2095, journey
                  // audit #19/#20: the backup leaves as a FILE
                  // or through the share sheet) — as the
                  // sample's slim pill; the handler is the
                  // retired action's own, unchanged.
                  Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: () async {
                        final saved = await XrayPlatform.saveTextFile(
                          'ember-backup.json',
                          snap.data!,
                        );
                        // Build 2098 (verification V-5): null
                        // means another save dialog is already
                        // open — it will report for itself, so
                        // this tap closes nothing and says
                        // nothing.
                        if (saved == null) return;
                        if (dialogContext.mounted) {
                          Navigator.of(dialogContext).pop();
                        }
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                saved
                                    ? 'Backup saved to a file'
                                    : 'Save cancelled',
                              ),
                            ),
                          );
                        }
                      },
                      borderRadius: BorderRadius.circular(999),
                      child: Container(
                        height: 46,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: MapUi.card,
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(color: MapUi.lineStrong),
                        ),
                        child: const Text(
                          'Save to file',
                          style: TextStyle(
                            fontSize: Ember.fontBody,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1.6,
                            color: MapUi.text,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  SelectableText(
                    snap.data!,
                    textDirection: TextDirection.ltr,
                    // Build 2092 (item 38): the data text meets
                    // the 11 sp floor (was 10.5).
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: Ember.fontSmall,
                      color: Ember.dim,
                    ),
                  ),
                  const SizedBox(height: 12),
                  // Build 2119 (audit F-12): the Sync page's
                  // honest never-travels note rides the
                  // backup dialog too — up to 2118 this
                  // surface showed the data with no word
                  // about what is NOT in it.
                  const Text(
                    'What never travels in this backup: OpenVPN '
                    'usernames and passwords (they stay in this '
                    'device\'s own vault), your Mozilla account, '
                    'pass and core settings, Aether identity and '
                    'scan results, the Lantern server list, '
                    'the selected '
                    'OpenVPN profile, traffic history, the '
                    'battery log and the GitHub token.',
                    style: TextStyle(color: Ember.dim, fontSize: Ember.fontSmall),
                  ),
                ],
              );
            },
          ),
        ),
        actions: [
          // Build 2095 (V2Ray journey audit #19/#20): the
          // backup leaves as a FILE or through the share
          // sheet, not only as clipboard text.
          // Batch 5: 'Save to file' moved into the content
          // as the slim export pill (same handler); the
          // actions keep Share / Copy / Transfer / Close.
          FutureBuilder<String?>(
            future: future,
            builder: (context, snap) => TextButton(
              onPressed: !snap.hasData
                  ? null
                  : () async {
                      await XrayPlatform.shareText(
                        snap.data!,
                        title: 'Ember backup',
                      );
                      if (dialogContext.mounted) {
                        Navigator.of(dialogContext).pop();
                      }
                    },
              child: const Text('Share'),
            ),
          ),
          FutureBuilder<String?>(
            future: future,
            // Batch 5: the copy action wears the dialog's
            // tracked text-action form, not the gradient
            // EmberButton; label and handler unchanged.
            builder: (context, snap) => TextButton(
              onPressed: !snap.hasData
                  ? null
                  : () async {
                      // Build 2095 (audit 5-4): a whole
                      // backup is a secret — self-clearing.
                      await copySensitive(snap.data!);
                      if (dialogContext.mounted) {
                        Navigator.of(dialogContext).pop();
                      }
                    },
              child: Text(
                l.copyLink,
                style: const TextStyle(
                  color: Ember.orange,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2,
                ),
              ),
            ),
          ),
          // Build 2095 (feature 15): device pairing —
          // the same backup, sealed into scannable codes.
          if (settings != null)
            TextButton(
              onPressed: () {
                Navigator.of(dialogContext).pop();
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => PairingExportPage(
                      xray: xray,
                      settings: settings!,
                      openvpn: openvpn,
                      psiphon: psiphon,
                      warp: warp,
                      masque: masque,
                    ),
                  ),
                );
              },
              child: const Text('Transfer to another device'),
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
    // Build 2092 (items 29/61): the Restore action disables
    // while the import runs (a second tap used to start a
    // double import), and the field's controller is
    // disposed when the dialog closes.
    var busy = false;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          // Build 2074 (audit item 25): scrollable content.
          scrollable: true,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          title: Text(l.restoreData, style: Ember.heading),
          content: TextField(
            controller: controller,
            minLines: 5,
            maxLines: 9,
            textDirection: TextDirection.ltr,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: Ember.fontMicro,
              color: Ember.text,
            ),
            decoration: emberField(context, '{…}'),
          ),
          actions: [
            // Build 2095 (feature 15): receive a pairing
            // transfer by scanning its codes.
            if (settings != null)
              TextButton(
                onPressed: busy
                    ? null
                    : () {
                        Navigator.of(dialogContext).pop();
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => PairingImportPage(
                              xray: xray,
                              settings: settings!,
                              openvpn: openvpn,
                              psiphon: psiphon,
                              warp: warp,
                              masque: masque,
                            ),
                          ),
                        );
                      },
                child: const Text('Receive from another device'),
              ),
            TextButton(
              onPressed: busy ? null : () => Navigator.of(dialogContext).pop(),
              child: Text(
                l.closeAction,
                style: const TextStyle(color: Ember.dim),
              ),
            ),
            EmberButton(
              label: busy ? 'Restoring…' : l.restoreData,
              onTap: busy
                  ? null
                  : () async {
                      setDialogState(() => busy = true);
                      final result = await xray.importBackup(controller.text);
                      if (dialogContext.mounted) {
                        Navigator.of(dialogContext).pop();
                      }
                      // Build 2095 (audit #15): the backup's
                      // app settings land on the live object
                      // (the sync token and lock PIN never
                      // ride a backup, so both survive).
                      // Build 2098 (L11): the settings half
                      // can now refuse (unreadable store) —
                      // that is a failed restore, reported
                      // as one, not an uncaught error.
                      var settingsFailed = false;
                      if (result?.appSettingsJson != null &&
                          settings != null) {
                        try {
                          await settings!.applyRestoredSettings(
                            result!.appSettingsJson!,
                          );
                        } catch (_) {
                          settingsFailed = true;
                        }
                      }
                      // Build 2116 (AB-05): the backup's
                      // engine sections land on their
                      // controllers too. Build 2125
                      // (A25-07): sections that could not
                      // be applied are named in the result.
                      var engineFailures = const <String>[];
                      if (result?.engineSections != null) {
                        engineFailures = await applyEngineSections(
                          result!.engineSections!,
                          openvpn: openvpn,
                          psiphon: psiphon,
                          warp: warp,
                          masque: masque,
                        );
                      }
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            // Build 2095 (V2Ray journey audit
                            // #10): a restore that skipped
                            // damaged entries SAYS so — it used
                            // to report plain success while
                            // configs vanished.
                            content: Text(
                              result == null || settingsFailed
                                  ? l.restoreFailed
                                  : result.skipped > 0
                                  ? '${l.restoreOk} ${result.skipped} damaged '
                                        '${result.skipped == 1 ? 'entry was' : 'entries were'} '
                                        'skipped.'
                                        // Build 2095 (audit 4a-3):
                                        // transform notes ride along.
                                        '${result.notes.isEmpty ? '' : ' ${result.notes.join(' ')}'}'
                                        // Build 2125 (A25-07):
                                        // unapplied engine
                                        // sections are named.
                                        '${engineFailures.isEmpty ? '' : ' These sections could not be applied: ${engineFailures.join(', ')}.'}'
                                  : result.notes.isNotEmpty
                                  ? '${l.restoreOk} ${result.notes.join(' ')}'
                                        '${engineFailures.isEmpty ? '' : ' These sections could not be applied: ${engineFailures.join(', ')}.'}'
                                  : engineFailures.isNotEmpty
                                  ? '${l.restoreOk} These sections could not be applied: ${engineFailures.join(', ')}.'
                                  : l.restoreOk,
                            ),
                          ),
                        );
                      }
                    },
            ),
          ],
        ),
      ),
    );
    controller.dispose();
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
    // Build 2092 (item 60): a throwing lookup used to leave
    // "Finding the local address…" up forever — the error
    // lands in the same done state as a null address.
    lanAddress()
        .then((a) {
          if (mounted) {
            setState(() {
              _address = a;
              _done = true;
            });
          }
        })
        .catchError((_) {
          if (mounted) setState(() => _done = true);
          return null;
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
          url: 'socks5://$address:${latDigits(widget.socksPort)}',
        ),
        _LanAddressRow(
          label: 'HTTP',
          url: 'http://$address:${latDigits(widget.httpPort)}',
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
/// Batch 5 (fidelity rollout, pro7-dns sample): one DNS
/// provider row — the preset's name, its URL verbatim as a
/// monospace caption, and the flat SELECTED pill when the
/// remote-DNS field currently holds this URL. A hairline
/// under every row; the whole row is the tap target (the
/// retired preset chip's own callback).
class _DnsProviderRow extends StatelessWidget {
  const _DnsProviderRow({
    required this.label,
    required this.url,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String url;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              label,
                              style: const TextStyle(
                                fontSize: Ember.fontTitle,
                                fontWeight: FontWeight.w500,
                                color: MapUi.text,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (selected) ...[
                            const SizedBox(width: 9),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: Ember.orange,
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: const Text(
                                'SELECTED',
                                style: TextStyle(
                                  fontSize: Ember.fontMicro,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 0.8,
                                  color: Color(0xFF1A1206),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        url,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: Ember.fontSmall,
                          color: MapUi.dim,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const Divider(color: MapUi.line, height: 1, thickness: 1),
      ],
    );
  }
}

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
      // Build 2092 (item 61): the dialog's controller is
      // disposed once the dialog has closed.
      controller.dispose();
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
      // Build 2092 (item 61): dispose the dialog's
      // controller once the dialog has closed.
      controller.dispose();
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
      // Build 2092 (item 61): dispose the dialog's
      // controller once the dialog has closed.
      controller.dispose();
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
        // Build 2092 (item 61): dispose the dialog's
        // controller once the dialog has closed.
        controller.dispose();
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

/// Build 2095 (whole-app journey audit #61): choose which
/// connections-view columns show. Writes the same
/// AppSettings.hiddenConnectionColumns the connections view
/// itself edits.
Future<void> _pickConnectionColumns(
  BuildContext context,
  AppSettings settings,
) async {
  const columns = [
    ('time', 'Time'),
    ('destination', 'Destination'),
    ('route', 'Route'),
    ('inbound', 'Inbound'),
    ('protocol', 'Protocol'),
    ('traffic', 'Traffic'),
    ('duration', 'Duration'),
  ];
  final hidden = {...settings.hiddenConnectionColumns};
  final saved = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      title: Text('Connection columns', style: Ember.heading),
      content: StatefulBuilder(
        builder: (context, setLocal) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (key, label) in columns)
              CheckboxListTile(
                value: !hidden.contains(key),
                onChanged: (v) => setLocal(() {
                  if (v ?? true) {
                    hidden.remove(key);
                  } else {
                    hidden.add(key);
                  }
                }),
                title: Text(label, style: Ember.body),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
                dense: true,
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Cancel', style: TextStyle(color: Ember.dim)),
        ),
        EmberButton(
          label: 'Save',
          onTap: () => Navigator.of(dialogContext).pop(true),
        ),
      ],
    ),
  );
  if (saved ?? false) {
    settings.update(hiddenConnectionColumns: hidden);
  }
}

/// Build 2075: the "App updates" panel — Ember's own GitHub
/// Releases feed, checked by EmberUpdater (started in
/// runAndroid). Shows the current build, the feed state, and —
/// when a newer build exists — its notes and the
/// download/install actions. Hidden entirely where no updater
/// runs (desktop, tests).
class _AppUpdatesPanel extends StatefulWidget {
  const _AppUpdatesPanel();

  @override
  State<_AppUpdatesPanel> createState() => _AppUpdatesPanelState();
}

class _AppUpdatesPanelState extends State<_AppUpdatesPanel> {
  /// Build 2092 (item 58): the release notes expand past
  /// their 8-line cap on tap.
  bool _notesExpanded = false;

  /// Build 2092 (item 29): the Install tap is guarded — a
  /// second tap used to launch a duplicate intent.
  bool _installing = false;

  @override
  Widget build(BuildContext context) {
    final updater = EmberUpdater.instance;
    if (updater == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: updater,
      builder: (context, _) {
        final u = updater;
        final stateLine = switch (u.state) {
          EmberUpdateState.idle => 'Not checked yet',
          EmberUpdateState.checking => 'Checking GitHub…',
          EmberUpdateState.upToDate => 'You are on the latest build',
          EmberUpdateState.available =>
            'Build ${latDigits('${u.release!.build}')} is available',
          EmberUpdateState.downloading =>
            'Downloading… ${latDigits('${(u.progress * 100).round()}')}%',
          // Build 2119 (audit F-11): a download the feed
          // gave no checksum for is offered as what it
          // is — unverified — not with the same words as
          // a verified one.
          EmberUpdateState.downloaded =>
            u.downloadedVerified
                ? 'Downloaded — ready to install · checksum verified'
                : 'Downloaded — ready to install · UNVERIFIED '
                      '(the feed published no checksum)',
          EmberUpdateState.error => u.errorText,
          // Build 2125 (audit A25-52 / P-56): an
          // unresolvable own-build reads as what it is —
          // the comparison could not be made — never as
          // "You are on the latest build".
          EmberUpdateState.unknownBuild => u.errorText,
          // Build 2127 (audit A26-21): a release tagged
          // with a plain version number (no build number)
          // is named, with the reason it is not offered as
          // an update — it can still be downloaded and
          // installed by hand from the block below.
          EmberUpdateState.uncomparable =>
            'Release ${u.release!.tag} is published, but its '
                'version tag has no build number to compare '
                'with yours',
        };
        return MapSettingsPanel(
          title: 'App updates',
          children: [
            // Build 2144 (reskin, pro6-settings sample): the
            // identity line — flame mark, then the same label
            // and version line the row always carried.
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  const EmberShieldMark(size: 30),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Current version',
                          style: const TextStyle(
                            fontSize: Ember.fontBody,
                            fontWeight: FontWeight.w500,
                            color: MapUi.text,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Ralysnd Ember $appVersion • build ${latDigits(appBuildNumber)}',
                          style: const TextStyle(
                            fontSize: Ember.fontMicro,
                            color: MapUi.dim,
                            height: 1.3,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const Divider(color: MapUi.line, height: 1, thickness: 1),
            // Build 2095 (feature 13 — update
            // channels): Stable reads the latest
            // release; Beta the newest including
            // pre-releases.
            MapSettingRow(
              label: 'Update channel',
              subtitle: u.settings.updateChannel == 'beta'
                  ? 'Beta — newest release, including pre-releases'
                  : 'Stable — the latest finished release',
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  EmberChip(
                    label: 'Stable',
                    compact: true,
                    selected: u.settings.updateChannel != 'beta',
                    onTap: () {
                      u.settings.update(updateChannel: 'stable');
                      // Build 2096 (audit L11): the other
                      // channel's release leaves the offer.
                      u.noteChannelChanged();
                    },
                  ),
                  const SizedBox(width: 6),
                  EmberChip(
                    label: 'Beta',
                    compact: true,
                    selected: u.settings.updateChannel == 'beta',
                    onTap: () {
                      u.settings.update(updateChannel: 'beta');
                      u.noteChannelChanged();
                    },
                  ),
                ],
              ),
            ),
            MapSettingRow(
              label: 'Check for updates',
              subtitle: stateLine,
              divider:
                  u.state == EmberUpdateState.available ||
                  u.state == EmberUpdateState.uncomparable ||
                  u.state == EmberUpdateState.downloading ||
                  u.state == EmberUpdateState.downloaded,
              // Build 2144 (reskin): the sample's orange CHECK
              // text action, not a filled button — same tap,
              // same busy gate.
              trailing: TextButton(
                onPressed: u.busy ? null : () => u.check(manual: true),
                child: Text('Check', style: Ember.microLabelOrange),
              ),
            ),
            if ((u.state == EmberUpdateState.available ||
                    u.state == EmberUpdateState.uncomparable) &&
                u.release != null) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(0, 10, 0, 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(u.release!.name, style: Ember.body),
                    if (u.release!.notes.trim().isNotEmpty) ...[
                      const SizedBox(height: 6),
                      // Build 2092 (item 58): the notes are
                      // expandable past the 8-line cap.
                      InkWell(
                        onTap: () =>
                            setState(() => _notesExpanded = !_notesExpanded),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              u.release!.notes.trim(),
                              style: Ember.caption,
                              maxLines: _notesExpanded ? null : 8,
                              overflow: _notesExpanded
                                  ? TextOverflow.visible
                                  : TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              _notesExpanded ? 'Show less' : 'Show more',
                              style: Ember.caption.copyWith(
                                color: Ember.orange,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 10),
                    EmberButton(
                      // Build 2125 (audit A25-09): a kept
                      // partial download names the button
                      // for what it does — resume.
                      // Build 2126 (audit A26-27): the
                      // kept part counts from DISK too
                      // (u.resumableBytes, resolved by
                      // check()) — up to 2125 only the
                      // in-memory progress of THIS process
                      // named it, so a part left by an
                      // earlier process or an errored
                      // attempt read plain "Download" while
                      // the tap still resumed.
                      label: (u.progress > 0 && u.progress < 1) ||
                              u.resumableBytes > 0
                          ? 'Resume download'
                          : 'Download (' +
                                fmtBytes(u.release!.apkSize) +
                                ')',
                      icon: Icons.download_rounded,
                      onTap: () => u.download(),
                    ),
                  ],
                ),
              ),
            ],
            if (u.state == EmberUpdateState.downloading) ...[
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: LinearProgressIndicator(
                  value: u.progress > 0 ? u.progress : null,
                  color: Ember.orange,
                  // Build 2092 (item 58): the palette token,
                  // not a one-off literal.
                  backgroundColor: MapUi.lineStrong,
                ),
              ),
              // Build 2125 (audit A25-09): a download can
              // be cancelled — the fetched part is kept and
              // the next Download resumes it.
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: EmberButton(
                  label: 'Cancel download',
                  onTap: () => u.cancelDownload(),
                ),
              ),
            ],
            if (u.state == EmberUpdateState.downloaded)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: EmberButton(
                  // Build 2125 (audit A25-48 / P-52): the
                  // UNVERIFIED marking rides the Install
                  // button itself, not only the state line
                  // above it — the button is the thing being
                  // tapped, and a feed that published no
                  // checksum must not borrow a verified
                  // download's plain label.
                  label: _installing
                      ? 'Opening…'
                      : u.downloadedVerified
                      ? 'Install'
                      : 'Install — UNVERIFIED',
                  icon: Icons.system_update_rounded,
                  // Build 2092 (item 29): guarded — repeated
                  // taps no longer stack installer intents.
                  onTap: _installing
                      ? null
                      : () async {
                          setState(() => _installing = true);
                          try {
                            if (await AndroidCore.canInstallPackages()) {
                              await u.install();
                            } else {
                              await AndroidCore.openInstallSettings();
                            }
                          } finally {
                            if (mounted) {
                              setState(() => _installing = false);
                            }
                          }
                        },
                ),
              ),
          ],
        );
      },
    );
  }
}
