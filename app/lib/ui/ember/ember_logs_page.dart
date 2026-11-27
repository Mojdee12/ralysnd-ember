/// Logs hub (build 2098, Item B): one Settings entry that
/// reaches every engine's log view.
///
/// Before this build the log pages existed but were linked
/// only from inside each engine's own Settings section —
/// the WireGuard section had no link at all, so an owner
/// hitting a WireGuard crash found "no log in Settings"
/// (his words) exactly when he needed one. This page is a
/// plain index over the EXISTING log views; it adds no new
/// log storage. WARP/MASQUE have no log view of their own
/// (the Aether controller keeps no readable log), so they
/// get no row — a row that opens nothing is worse than no
/// row.
import 'package:flutter/material.dart';

import '../../core/core_controller.dart';
import '../../lantern/lantern_controller.dart';
import '../../openvpn/openvpn_controller.dart';
import '../../psiphon/psiphon_controller.dart';
import '../../xray/xray_controller.dart';
import '../logs_page.dart';
import 'ember_theme.dart';
import 'lantern_pages.dart';
import 'map_widgets.dart';
import 'openvpn_pages.dart';
import 'psiphon_pages.dart';
import 'xray_logs_page.dart';

class EmberLogsPage extends StatelessWidget {
  const EmberLogsPage({
    super.key,
    required this.core,
    required this.xray,
    required this.psiphon,
    required this.lantern,
    required this.openvpn,
  });

  final CoreController core;
  final XrayController xray;
  final PsiphonController psiphon;
  final LanternController lantern;
  final OpenVpnController openvpn;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Ember.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Ember.text,
        title: Text('Logs', style: Ember.heading),
      ),
      body: EmberBackground(
        child: ListView(
          padding: EdgeInsets.fromLTRB(16, MediaQuery.of(context).padding.top + kToolbarHeight + 6, 16, 24),
          children: [
            MapSettingsPanel(
              title: 'Engine logs',
              children: [
                MapSettingRow(
                  label: 'V2Ray & WireGuard',
                  subtitle:
                      'Core log, tunnel log and the native crash record',
                  trailing: const Icon(
                    Icons.chevron_right_rounded,
                    color: Ember.dim,
                    size: 20,
                  ),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => XrayLogsPage(xray: xray),
                    ),
                  ),
                ),
                MapSettingRow(
                  label: 'OpenVPN',
                  subtitle: 'Session log and connection trail',
                  trailing: const Icon(
                    Icons.chevron_right_rounded,
                    color: Ember.dim,
                    size: 20,
                  ),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => OpenVpnLogsPage(openvpn: openvpn),
                    ),
                  ),
                ),
                MapSettingRow(
                  label: 'Lantern',
                  subtitle: 'Engine log',
                  trailing: const Icon(
                    Icons.chevron_right_rounded,
                    color: Ember.dim,
                    size: 20,
                  ),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => LanternLogsPage(lantern: lantern),
                    ),
                  ),
                ),
                MapSettingRow(
                  label: 'Psiphon',
                  subtitle: 'Engine log',
                  trailing: const Icon(
                    Icons.chevron_right_rounded,
                    color: Ember.dim,
                    size: 20,
                  ),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => PsiphonLogsPage(psiphon: psiphon),
                    ),
                  ),
                ),
                MapSettingRow(
                  label: 'Mozilla',
                  subtitle: 'Core log',
                  divider: false,
                  trailing: const Icon(
                    Icons.chevron_right_rounded,
                    color: Ember.dim,
                    size: 20,
                  ),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) =>
                          LogsPage(core: core, emberChrome: true),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                'If the app or an engine misbehaves, the V2Ray & '
                'WireGuard log is the first place to look — it '
                'ends with the native crash record whenever one '
                'was written.',
                style: Ember.caption,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
