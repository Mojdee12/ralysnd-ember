/// The V2Ray DESKTOP page: the approved clean-grid mockup — a big
/// header with Add / Import / Test All, one wide "Server Configs"
/// card, and rows with a protocol badge at the left, the config's
/// name and transport line in the middle, and a right column with
/// the used-traffic line over a FIXED-width ping pill, so the pills
/// form one straight column. The selected profile's row is lit
/// ember. Rows keep the phone list's full action menu.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../../xray/xray_controller.dart';
import '../../xray/xray_models.dart';
import 'desktop_widgets.dart';
import 'ember_format.dart';
import 'ember_theme.dart';
import 'profile_editor.dart';
import 'qr_pages.dart';

class V2rayDesktopPage extends StatefulWidget {
  const V2rayDesktopPage({super.key, required this.xray});

  final XrayController xray;

  @override
  State<V2rayDesktopPage> createState() => _V2rayDesktopPageState();
}

class _V2rayDesktopPageState extends State<V2rayDesktopPage> {
  String _query = '';
  bool _testingAll = false;

  XrayController get xray => widget.xray;

  Future<void> _testAll() async {
    setState(() => _testingAll = true);
    try {
      await xray.testAllDelays();
    } finally {
      if (mounted) setState(() => _testingAll = false);
    }
  }

  Future<void> _connectSelected() async {
    final l = AppLocalizations.of(context);
    try {
      if (xray.state.running) {
        await xray.disconnect();
      } else {
        await xray.connect();
      }
    } on StateError catch (e) {
      if (!mounted) return;
      final message = switch (e.message) {
        'no-profile' => l.noProfileSelected,
        'unsupported' => l.unsupportedProtocol,
        _ => l.startFailed,
      };
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: xray,
      builder: (context, _) {
        final q = _query.toLowerCase();
        final shown = xray.profiles.where((p) {
          if (q.isEmpty) return true;
          return p.name.toLowerCase().contains(q) ||
              p.address.toLowerCase().contains(q);
        }).toList();
        final active =
            xray.state.running ? xray.selected : null;
        return Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(26, 20, 26, 8),
                children: [
            DesktopHeader(
              title: 'V2Ray',
              titleSize: 46,
              subtitle:
                  'Manage V2Ray protocols • Real-time routing and performance',
              actions: [
                DesktopActionButton(
                  icon: Icons.add_rounded,
                  label: 'Add',
                  onTap: () => unawaited(openProfileEditor(context, xray)),
                ),
                DesktopActionButton(
                  icon: Icons.download_rounded,
                  label: 'Import',
                  onTap: () => unawaited(showPasteSheet(context, xray)),
                ),
                DesktopActionButton(
                  icon: Icons.list_rounded,
                  label: 'Test All',
                  primary: true,
                  busy: _testingAll,
                  onTap:
                      xray.profiles.isEmpty ? null : () => unawaited(_testAll()),
                ),
              ],
            ),
            const SizedBox(height: 18),
            GlassCard(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Server Configs',
                              style:
                                  Ember.heading.copyWith(fontSize: 19),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              '${latDigits(xray.profiles.length)} configs'
                              '${active != null ? ' • 1 active' : ''}',
                              style: Ember.caption,
                            ),
                          ],
                        ),
                      ),
                      if (xray.selected != null)
                        SizedBox(
                          width: 210,
                          child: DesktopTogglePill(
                            on: xray.state.running,
                            busy: xray.connecting,
                            onLabel: 'Connected',
                            offLabel: 'Connect',
                            onTap: () => unawaited(_connectSelected()),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    onChanged: (v) => setState(() => _query = v),
                    style: Ember.body,
                    decoration: emberField(
                      context,
                      l.searchConfig,
                      prefix: const Icon(Icons.search_rounded,
                          color: Ember.faint, size: 20),
                    ),
                  ),
                  const SizedBox(height: 10),
                  if (xray.profiles.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 22),
                      child: Center(
                        child: Text(l.noProfilesYet, style: Ember.dimStyle),
                      ),
                    )
                  else if (shown.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 22),
                      child: Center(
                        child: Text(l.noServersFound, style: Ember.dimStyle),
                      ),
                    )
                  else
                    for (var i = 0; i < shown.length; i++) ...[
                      if (i > 0)
                        const Divider(color: Ember.line, height: 1),
                      _ConfigRow(xray: xray, profile: shown[i]),
                    ],
                ],
              ),
            ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(26, 6, 26, 14),
              child: DesktopStatusBar(
              left: active != null
                  ? '${active.name} • ${active.protocol.label}'
                  : (xray.selected?.name ?? l.noProfileSelected),
              protectionOn: xray.state.running,
              ),
            ),
          ],
        );
      },
    );
  }
}

/// One config row of the clean grid: protocol badge, name +
/// transport line, then the fixed right column (used traffic over
/// the ping pill). Tap selects; the trailing menu carries the same
/// actions as the phone row (delay/speed test, edit, duplicate,
/// reset stats, QR, copy link, delete).
class _ConfigRow extends StatelessWidget {
  const _ConfigRow({required this.xray, required this.profile});

  final XrayController xray;
  final Profile profile;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final selected = xray.selectedProfileId == profile.id;
    final running = xray.state.running && selected;
    final transport = switch (profile.network) {
      'ws' => 'WS',
      'grpc' => 'gRPC',
      'httpupgrade' => 'HTTPUpgrade',
      'xhttp' => 'XHTTP',
      'h2' || 'http' => 'HTTP',
      'kcp' => 'KCP',
      'quic' => 'QUIC',
      _ => 'TCP',
    };
    final security = switch (profile.security) {
      'tls' => 'TLS',
      'reality' => 'Reality',
      _ => 'None',
    };
    final subtitle =
        '$transport • Port ${latDigits(profile.port)} • $security';
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => xray.select(profile),
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          decoration: BoxDecoration(
            gradient: selected
                ? LinearGradient(
                    colors: [
                      Ember.orange.withValues(alpha: 0.32),
                      Ember.orange.withValues(alpha: 0.10),
                    ],
                  )
                : null,
            borderRadius: BorderRadius.circular(14),
            border: selected
                ? Border.all(color: Ember.orange.withValues(alpha: 0.55))
                : null,
          ),
          child: Row(
            children: [
              // The protocol badge: orange on the selected row.
              Container(
                width: 118,
                padding: const EdgeInsets.symmetric(vertical: 9),
                decoration: BoxDecoration(
                  gradient: selected ? Ember.gradient : null,
                  color: selected
                      ? null
                      : Colors.white.withValues(alpha: 0.07),
                  borderRadius: BorderRadius.circular(11),
                  border: selected
                      ? null
                      : Border.all(
                          color: Colors.white.withValues(alpha: 0.12)),
                ),
                alignment: Alignment.center,
                child: Text(
                  profile.protocol.label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: selected ? Colors.white : Ember.dim,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      profile.name,
                      style: Ember.heading.copyWith(fontSize: 15.5),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      style: Ember.caption,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 14),
              // The fixed right column: traffic line, then the pill —
              // the pill's right edge is the same x in every row.
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Directionality(
                    textDirection: TextDirection.ltr,
                    child: Text(
                      profileHasTotals(profile)
                          ? 'Used traffic: ${fmtBytes(profile.totalDownBytes + profile.totalUpBytes)}'
                          : 'Used traffic: —',
                      style: Ember.caption.copyWith(color: Ember.dim),
                    ),
                  ),
                  const SizedBox(height: 6),
                  DesktopPingPill(
                    ms: profile.delayMs,
                    failed: profile.delayFailed,
                    testing: xray.isTesting(profile.id),
                    unit: l.msUnit,
                  ),
                ],
              ),
              const SizedBox(width: 6),
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert_rounded,
                    color: Ember.faint, size: 20),
                color: Ember.card,
                onSelected: (v) => unawaited(_act(context, v)),
                itemBuilder: (_) => [
                  PopupMenuItem(value: 'delay', child: Text(l.delayTest)),
                  PopupMenuItem(value: 'speed', child: Text(l.speedTest)),
                  PopupMenuItem(value: 'edit', child: Text(l.editProfile)),
                  PopupMenuItem(
                      value: 'duplicate', child: Text(l.duplicate)),
                  PopupMenuItem(
                      value: 'resetStats', child: Text(l.resetStats)),
                  PopupMenuItem(value: 'qr', child: Text(l.shareQr)),
                  PopupMenuItem(value: 'copy', child: Text(l.copyLink)),
                  PopupMenuItem(
                    value: 'delete',
                    child: Text(l.deleteProfile,
                        style: const TextStyle(color: Ember.red)),
                  ),
                ],
              ),
              if (running)
                const Icon(Icons.check_circle_rounded,
                    size: 20, color: Ember.green),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _act(BuildContext context, String action) async {
    final l = AppLocalizations.of(context);
    switch (action) {
      case 'delay':
        final ms = await xray.testDelay(profile);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(ms >= 0
                ? '${l.delayTest}: ${latDigits(ms)} ${l.msUnit}'
                : l.testFailed),
          ));
        }
      case 'speed':
        final bps = await xray.testSpeed(profile);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content:
                Text(bps >= 0 ? '${l.speedTest}: ${fmtRate(bps)}' : l.testFailed),
          ));
        }
      case 'edit':
        await openProfileEditor(context, xray, existing: profile);
      case 'duplicate':
        await xray.duplicateProfile(profile);
      case 'resetStats':
        await xray.resetProfileStats(profile);
      case 'qr':
        await showProfileQr(context, profile);
      case 'copy':
        await Clipboard.setData(ClipboardData(text: profileLinkOf(profile)));
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l.linkCopied)),
          );
        }
      case 'delete':
        await xray.deleteProfile(profile);
    }
  }
}
