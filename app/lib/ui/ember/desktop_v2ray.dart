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

  /// The page's structural signature: everything the layout
  /// depends on EXCEPT the per-profile traffic totals. The
  /// controller polls the core's counters every couple of seconds
  /// while connected and the old root ListenableBuilder rebuilt
  /// (and re-blurred) the whole page on every poll; now the totals
  /// live in per-row islands and this page rebuilds only when the
  /// signature changes.
  String _sig = '';

  @override
  void initState() {
    super.initState();
    xray.addListener(_onTick);
  }

  @override
  void dispose() {
    xray.removeListener(_onTick);
    super.dispose();
  }

  String _signature() => [
        xray.profiles.length,
        xray.selectedProfileId,
        xray.state.running,
        xray.state.name,
        xray.connecting,
        xray.lastError,
        for (final p in xray.profiles)
          '${p.id}:${p.name}:${p.delayMs}:${p.delayFailed}:${xray.isTesting(p.id)}',
      ].join('|');

  void _onTick() {
    if (!mounted) return;
    final next = _signature();
    if (next != _sig) {
      _sig = next;
      setState(() {});
    }
  }

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
    {
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
            // THE HEADER CARD (sample 2): the page title and the
            // big toggle at the left, Add / Import / Test All at
            // the right, all on one glass card.
            GlassCard(
              glow: xray.state.running,
              padding: const EdgeInsets.fromLTRB(24, 18, 24, 18),
              child: Row(
                children: [
                  const Text(
                    'V2Ray',
                    style: TextStyle(
                      fontSize: 34,
                      fontWeight: FontWeight.w800,
                      color: Desk.ink,
                      height: 1.1,
                    ),
                  ),
                  if (xray.selected != null) ...[
                    const SizedBox(width: 22),
                    DesktopHeroToggle(
                      on: xray.state.running,
                      busy: xray.connecting,
                      onTap: () => unawaited(_connectSelected()),
                    ),
                  ],
                  const Spacer(),
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
                    icon: Icons.speed_rounded,
                    label: 'Test All',
                    primary: true,
                    busy: _testingAll,
                    onTap: xray.profiles.isEmpty
                        ? null
                        : () => unawaited(_testAll()),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
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
                              style: Desk.heading.copyWith(fontSize: 19),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              '${latDigits(xray.profiles.length)} configs'
                              '${active != null ? ' • 1 active' : ''}',
                              style: Desk.caption,
                            ),
                          ],
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
                        const Divider(color: Desk.line, height: 1),
                      _ConfigRow(xray: xray, profile: shown[i]),
                    ],
                ],
              ),
            ),
            const SizedBox(height: 16),
            // The session card (sample 2): the three hero columns
            // over the live rates and the session clock. A live
            // island of its own.
            ListenableBuilder(
              listenable: xray,
              builder: (context, _) => _V2raySessionCard(xray: xray),
            ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(26, 6, 26, 14),
              child: DesktopStatusBar(
              left: active != null
                  ? '${active.name} • ${active.protocol.label}'
                      '${xray.state.running && xray.state.note.isNotEmpty ? ' • ${xray.state.note}' : ''}'
                  : (xray.selected?.name ?? l.noProfileSelected),
              protectionOn: xray.state.running,
              ),
            ),
          ],
        );
    }
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
        '${profile.address}:${latDigits(profile.port)} • $transport • $security';
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => xray.select(profile),
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            gradient: selected ? Desk.peachGradient : null,
            color: selected ? null : Colors.white.withValues(alpha: 0.45),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected
                  ? Ember.orange.withValues(alpha: 0.55)
                  : Desk.line,
            ),
          ),
          child: Row(
            children: [
              // The protocol pill: a small orange capsule, as the
              // samples draw it.
              Container(
                constraints: const BoxConstraints(minWidth: 64),
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  gradient: Ember.gradient,
                  borderRadius: BorderRadius.circular(999),
                ),
                alignment: Alignment.center,
                child: Text(
                  profile.protocol.label,
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      profile.name,
                      style: Desk.heading.copyWith(fontSize: 15.5),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      style: Desk.caption.copyWith(fontSize: 12.5),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 14),
              // The fixed right column: traffic line, then the
              // color-coded ping text — the same right edge in
              // every row.
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Directionality(
                    textDirection: TextDirection.ltr,
                    // A live island: the totals move with the
                    // controller's counter polls; the row (and the
                    // page's glass card) must not rebuild with them.
                    child: ListenableBuilder(
                      listenable: xray,
                      builder: (context, _) => Text(
                        profileHasTotals(profile)
                            ? 'Used traffic: ${fmtBytes(profile.totalDownBytes + profile.totalUpBytes)}'
                            : 'Used traffic: —',
                        style: Desk.caption.copyWith(color: Desk.dim),
                      ),
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
                    color: Desk.faint, size: 20),
                color: Colors.white,
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
                        style: const TextStyle(color: Desk.red)),
                  ),
                ],
              ),
              if (running)
                const Icon(Icons.check_circle_rounded,
                    size: 20, color: Desk.green),
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

/// The V2Ray page's session card (sample 2): UPLOAD / DOWNLOAD /
/// TIME hero columns over the controller's live rates and the
/// session clock; dashes while disconnected.
class _V2raySessionCard extends StatelessWidget {
  const _V2raySessionCard({required this.xray});

  final XrayController xray;

  @override
  Widget build(BuildContext context) {
    final state = xray.state;
    final running = state.running;
    final (upValue, upUnit) = rateParts(running ? xray.upRate : 0);
    final (downValue, downUnit) = rateParts(running ? xray.downRate : 0);
    return GlassCard(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 18),
      child: DesktopHeroRow(
        stats: [
          DesktopHeroStat(
            icon: Icons.arrow_upward_rounded,
            label: 'UPLOAD',
            value: running ? upValue : '—',
            unit: running ? upUnit : '',
          ),
          DesktopHeroStat(
            icon: Icons.arrow_downward_rounded,
            label: 'DOWNLOAD',
            value: running ? downValue : '—',
            unit: running ? downUnit : '',
          ),
          _XrayTimeHero(sinceMs: running ? state.sinceMs : 0),
        ],
      ),
    );
  }
}

/// The TIME hero of the V2Ray session card (ticks while running).
class _XrayTimeHero extends StatelessWidget {
  const _XrayTimeHero({required this.sinceMs});
  final int sinceMs;

  @override
  Widget build(BuildContext context) {
    if (sinceMs <= 0) {
      return const DesktopHeroStat(
        icon: Icons.schedule_rounded,
        label: 'TIME',
        value: '—',
      );
    }
    return StreamBuilder<void>(
      stream: Stream.periodic(const Duration(seconds: 1)),
      builder: (context, _) => DesktopHeroStat(
        icon: Icons.schedule_rounded,
        label: 'TIME',
        value: fmtDuration(
          DateTime.now().difference(
            DateTime.fromMillisecondsSinceEpoch(sinceMs),
          ),
        ),
      ),
    );
  }
}
