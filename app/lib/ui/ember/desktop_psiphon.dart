/// The Psiphon DESKTOP home: the approved Psiphon mockup — one
/// wide hero card (state badge, "Connected to Psiphon", flag +
/// region, egress IP, the wide toggle pill, an honest footer), then
/// two cards side by side: Connection Mode (the egress-region list,
/// selectable here) and Session (duration, data used from the
/// core's own byte counters, live rates). No power ring, no
/// centered phone column, and no invented facts (no kill switch —
/// there is none; the footer names the real mode).

import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../psiphon/psiphon_controller.dart';
import 'desktop_widgets.dart';
import 'ember_format.dart';
import 'ember_theme.dart';
import 'psiphon_pages.dart' show regionName;

class PsiphonDesktopHome extends StatefulWidget {
  const PsiphonDesktopHome({super.key, required this.psiphon});

  final PsiphonController psiphon;

  @override
  State<PsiphonDesktopHome> createState() => _PsiphonDesktopHomeState();
}

class _PsiphonDesktopHomeState extends State<PsiphonDesktopHome> {
  bool _busy = false;

  Future<void> _toggle() async {
    final psiphon = widget.psiphon;
    final l = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      if (psiphon.state.running) {
        await psiphon.disconnect();
      } else {
        await psiphon.connect();
      }
    } on StateError {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l.startFailed)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$e')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _pick(String code) {
    final next = PsiphonSettings.fromJson(widget.psiphon.settings.toJson());
    next.region = code;
    unawaited(widget.psiphon.updateSettings(next));
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: widget.psiphon,
      builder: (context, _) {
        final psiphon = widget.psiphon;
        final state = psiphon.state;
        final on = state.connected;
        final running = state.running;
        final busy = _busy || psiphon.connecting || (running && !on);
        final settings = psiphon.settings;
        final actual = state.region;
        final shownCode =
            on && actual.isNotEmpty ? actual : settings.region;
        final exit = psiphon.exitInfo;
        final egressIp = exit?.ip.isNotEmpty == true
            ? exit!.ip
            : (state.clientAddress.isNotEmpty ? state.clientAddress : '');
        final totalBytes = state.upBytes + state.downBytes;

        return ListView(
          padding: const EdgeInsets.fromLTRB(26, 20, 26, 14),
          children: [
            DesktopHeader(
              title: 'Psiphon',
              subtitle: 'Obfuscated Tunnel • Secure Proxy',
            ),
            const SizedBox(height: 18),
            // The hero card.
            GlassCard(
              glow: on,
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
              child: Column(
                children: [
                  Row(
                    children: [
                      DesktopStateBadge(
                        label: on
                            ? 'Connected'
                            : running
                                ? 'Connecting'
                                : 'OFF',
                        color: on
                            ? Ember.green
                            : running
                                ? Ember.warn
                                : Ember.faint,
                      ),
                      const Spacer(),
                      Text(
                        'PSIPHON',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.2,
                          color: Ember.orange.withValues(alpha: 0.85),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    on ? 'Connected to Psiphon' : 'Psiphon',
                    style: const TextStyle(
                      fontSize: 21,
                      fontWeight: FontWeight.w800,
                      color: Ember.text,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      FlagRect(code: shownCode, width: 34),
                      const SizedBox(width: 10),
                      Text(
                        shownCode.isEmpty
                            ? l.psiphonRegionAuto
                            : regionName(shownCode),
                        style: Ember.body,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    egressIp.isEmpty
                        ? 'Egress IP: —'
                        : 'Egress IP: $egressIp',
                    style: Ember.dimStyle,
                  ),
                  const SizedBox(height: 16),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 430),
                    child: DesktopTogglePill(
                      on: on,
                      busy: busy,
                      onLabel: 'Connected • Disconnect',
                      offLabel: 'Connect',
                      onTap: () => unawaited(_toggle()),
                    ),
                  ),
                  const SizedBox(height: 13),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.shield_rounded,
                          size: 15, color: Ember.orange),
                      const SizedBox(width: 6),
                      Text(
                        settings.vpnMode
                            ? 'Obfuscated • VPN mode (TUN)'
                            : 'Obfuscated • Proxy only',
                        style: Ember.caption.copyWith(fontSize: 12.5),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Connection Mode: the region list.
                Expanded(
                  flex: 11,
                  child: GlassCard(
                    padding: const EdgeInsets.fromLTRB(18, 15, 18, 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Connection Mode', style: Ember.heading),
                        const SizedBox(height: 10),
                        _RegionTile(
                          code: '',
                          title: 'Automatic (Recommended)',
                          subtitle: 'Best latency & reliability — auto-selected',
                          selected: settings.region.isEmpty,
                          onTap: () => _pick(''),
                        ),
                        for (final code
                            in psiphon.regionChoices.take(6))
                          _RegionTile(
                            code: code,
                            title: regionName(code),
                            subtitle: on && actual == code
                                ? 'Connected now'
                                : 'Egress region',
                            selected: settings.region == code,
                            onTap: () => _pick(code),
                          ),
                        const SizedBox(height: 6),
                        Text(
                          l.psiphonNextConnectHint,
                          style: Ember.caption,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                // Session: duration, data, rates — the core's own
                // counters, nothing invented.
                Expanded(
                  flex: 10,
                  child: GlassCard(
                    padding: const EdgeInsets.fromLTRB(18, 15, 18, 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.insights_rounded,
                                size: 19, color: Ember.orange),
                            const SizedBox(width: 8),
                            Text('Session', style: Ember.heading),
                          ],
                        ),
                        const SizedBox(height: 6),
                        _DurationRow(sinceMs: running ? state.sinceMs : 0),
                        DesktopKvRow(
                          icon: Icons.data_usage_rounded,
                          label: 'Data used',
                          value: running ? fmtBytes(totalBytes) : '—',
                        ),
                        DesktopKvRow(
                          icon: Icons.arrow_downward_rounded,
                          label: 'Download',
                          value: running ? fmtBytes(state.downBytes) : '—',
                        ),
                        DesktopKvRow(
                          icon: Icons.arrow_upward_rounded,
                          label: 'Upload',
                          value: running ? fmtBytes(state.upBytes) : '—',
                          divider: false,
                        ),
                        if (running) ...[
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              const Icon(Icons.speed_rounded,
                                  size: 15, color: Ember.faint),
                              const SizedBox(width: 7),
                              Directionality(
                                textDirection: TextDirection.ltr,
                                child: Text(
                                  '↓ ${fmtRate(psiphon.downRate)} · ↑ ${fmtRate(psiphon.upRate)}',
                                  style: Ember.caption,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            DesktopStatusBar(
              left: shownCode.isEmpty
                  ? l.psiphonRegionAuto
                  : regionName(shownCode),
              protectionOn: on && settings.vpnMode,
            ),
          ],
        );
      },
    );
  }
}

/// The session-duration row (ticks while running).
class _DurationRow extends StatelessWidget {
  const _DurationRow({required this.sinceMs});
  final int sinceMs;

  @override
  Widget build(BuildContext context) {
    if (sinceMs <= 0) {
      return const DesktopKvRow(
        icon: Icons.schedule_rounded,
        label: 'Duration',
        value: '—',
      );
    }
    return StreamBuilder<void>(
      stream: Stream.periodic(const Duration(seconds: 1)),
      builder: (context, _) => DesktopKvRow(
        icon: Icons.schedule_rounded,
        label: 'Duration',
        value: fmtDuration(
          DateTime.now().difference(
            DateTime.fromMillisecondsSinceEpoch(sinceMs),
          ),
        ),
      ),
    );
  }
}

/// One selectable region row of the Connection Mode card: a radio
/// ring (ember when selected), a small flag, name and subtitle.
class _RegionTile extends StatelessWidget {
  const _RegionTile({
    required this.code,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  final String code;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Material(
          color: Ember.cardSoft.withValues(alpha: selected ? 0.9 : 0.5),
          borderRadius: BorderRadius.circular(13),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(13),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(13),
                border: Border.all(
                  color: selected
                      ? Ember.orange.withValues(alpha: 0.55)
                      : Ember.line,
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 19,
                    height: 19,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: selected ? Ember.orange : Ember.faint,
                        width: 2,
                      ),
                    ),
                    child: selected
                        ? Center(
                            child: Container(
                              width: 9,
                              height: 9,
                              decoration: const BoxDecoration(
                                color: Ember.orange,
                                shape: BoxShape.circle,
                              ),
                            ),
                          )
                        : null,
                  ),
                  const SizedBox(width: 11),
                  if (code.isNotEmpty) ...[
                    FlagRect(code: code, width: 30),
                    const SizedBox(width: 10),
                  ],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: Ember.body.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          subtitle,
                          style: Ember.caption,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
}
