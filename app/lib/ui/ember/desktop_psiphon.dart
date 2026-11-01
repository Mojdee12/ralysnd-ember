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

        return Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(26, 20, 26, 8),
                children: [
            DesktopHeader(
              title: 'Psiphon',
              subtitle: 'Obfuscated Tunnel • Secure Proxy',
            ),
            const SizedBox(height: 24),
            // The hero card: its content is CENTERED, as the
            // mockup draws it — the state badge centered at the
            // top, the PSIPHON pill at the card's top right.
            GlassCard(
              glow: on,
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
              child: Column(
                children: [
                  Stack(
                    alignment: Alignment.center,
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
                      const Align(
                        alignment: Alignment.centerRight,
                        child: DesktopEnginePill(label: 'PSIPHON'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Text(
                    on ? 'Connected to Psiphon' : 'Psiphon',
                    style: const TextStyle(
                      fontSize: 23,
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
                      labelIcon: on ? Icons.graphic_eq_rounded : null,
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
                // Session: the mockup's stacked HERO numbers —
                // Duration, then Data Used (the core's own byte
                // counters) — a status row, and the engine strip.
                Expanded(
                  flex: 10,
                  child: GlassCard(
                    padding: const EdgeInsets.fromLTRB(18, 15, 18, 14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(6),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.10),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: const Icon(
                                Icons.insights_rounded,
                                size: 17,
                                color: Ember.text,
                              ),
                            ),
                            const SizedBox(width: 9),
                            Text('Session', style: Ember.heading),
                          ],
                        ),
                        const SizedBox(height: 14),
                        _DurationHero(sinceMs: running ? state.sinceMs : 0),
                        const SizedBox(height: 12),
                        const Divider(color: Ember.line, height: 1),
                        const SizedBox(height: 12),
                        DesktopHeroStat(
                          icon: Icons.arrow_upward_rounded,
                          label: 'DATA USED',
                          value: running ? fmtBytes(totalBytes) : '—',
                        ),
                        if (running) ...[
                          const SizedBox(height: 6),
                          Directionality(
                            textDirection: TextDirection.ltr,
                            child: Text(
                              '↓ ${fmtBytes(state.downBytes)} · ↑ ${fmtBytes(state.upBytes)}'
                              '   ·   ↓ ${fmtRate(psiphon.downRate)} · ↑ ${fmtRate(psiphon.upRate)}',
                              style: Ember.caption,
                            ),
                          ),
                        ],
                        const SizedBox(height: 12),
                        const Divider(color: Ember.line, height: 1),
                        const SizedBox(height: 11),
                        Row(
                          children: [
                            Icon(
                              on
                                  ? Icons.check_circle_rounded
                                  : Icons.radio_button_unchecked_rounded,
                              size: 17,
                              color: on ? Ember.green : Ember.faint,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              on
                                  ? 'Stable • Tunnel up'
                                  : running
                                      ? 'Connecting…'
                                      : 'Not connected',
                              style: TextStyle(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w700,
                                color: on ? Ember.green : Ember.dim,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 11),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 11, vertical: 8),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.07),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                                color: Colors.white.withValues(alpha: 0.10)),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.shield_rounded,
                                  size: 15, color: Ember.dim),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  on
                                      ? 'Psiphon core v2.0.42 • Tunnel OK'
                                      : 'Psiphon core v2.0.42 • SOCKS 11808',
                                  style: Ember.caption.copyWith(
                                    color: Ember.dim,
                                    fontSize: 12,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(26, 6, 26, 14),
              child: DesktopStatusBar(
              left: shownCode.isEmpty
                  ? l.psiphonRegionAuto
                  : regionName(shownCode),
              protectionOn: on && settings.vpnMode,
              ),
            ),
          ],
        );
      },
    );
  }
}

/// The DURATION hero of the session card (ticks while running).
class _DurationHero extends StatelessWidget {
  const _DurationHero({required this.sinceMs});
  final int sinceMs;

  @override
  Widget build(BuildContext context) {
    if (sinceMs <= 0) {
      return const DesktopHeroStat(
        icon: Icons.schedule_rounded,
        label: 'DURATION',
        value: '—',
      );
    }
    return StreamBuilder<void>(
      stream: Stream.periodic(const Duration(seconds: 1)),
      builder: (context, _) => DesktopHeroStat(
        icon: Icons.schedule_rounded,
        label: 'DURATION',
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
          // The selected row stays NEUTRAL glass like the mockup's:
          // selection reads from the orange radio and border, never
          // from a warm fill (an orange fill here reintroduced the
          // sepia cast the glass pass removed).
          color: selected
              ? Colors.white.withValues(alpha: 0.11)
              : Colors.white.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(13),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(13),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(13),
                border: Border.all(
                  color: selected
                      ? Ember.orange.withValues(alpha: 0.55)
                      : Colors.white.withValues(alpha: 0.10),
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
