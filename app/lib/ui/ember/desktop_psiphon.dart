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

  /// The page's structural signature: everything the layout
  /// depends on EXCEPT the session byte counters and rates. The
  /// controller polls while connected and the old root
  /// ListenableBuilder rebuilt (and re-blurred) every glass card
  /// on every poll; now the counters live in the session-card
  /// island and this page rebuilds when the signature changes.
  String _sig = '';

  @override
  void initState() {
    super.initState();
    widget.psiphon.addListener(_onTick);
  }

  @override
  void dispose() {
    widget.psiphon.removeListener(_onTick);
    super.dispose();
  }

  String _signature() {
    final psiphon = widget.psiphon;
    final state = psiphon.state;
    return [
      state.running,
      state.connected,
      state.region,
      state.clientAddress,
      state.regions.length,
      psiphon.connecting,
      psiphon.settings.region,
      psiphon.settings.vpnMode,
      psiphon.exitInfo?.ip,
      psiphon.lastError,
    ].join('|');
  }

  void _onTick() {
    if (!mounted) return;
    final next = _signature();
    if (next != _sig) {
      _sig = next;
      setState(() {});
    }
  }

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
    {
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

        return Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(26, 20, 26, 8),
                children: [
            // THE HERO CARD (sample 3): the huge two-line title
            // and the flag + exit-region line at the left, the
            // big orange toggle pill at the right.
            GlassCard(
              glow: on,
              padding: const EdgeInsets.fromLTRB(28, 24, 28, 22),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          on
                              ? 'Connected via\nPsiphon'
                              : running
                                  ? 'Connecting…\nPsiphon'
                                  : 'Not connected\nPsiphon',
                          style: const TextStyle(
                            fontSize: 31,
                            fontWeight: FontWeight.w800,
                            color: Desk.ink,
                            height: 1.12,
                          ),
                        ),
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            FlagRect(code: shownCode, width: 32),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                shownCode.isEmpty
                                    ? l.psiphonRegionAuto
                                    : 'exit region ${regionName(shownCode)}',
                                style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                  color: Desk.inkSoft,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 7),
                        Text(
                          egressIp.isEmpty
                              ? 'Egress IP: —  •  ${settings.vpnMode ? 'VPN mode (TUN)' : 'Proxy only'}'
                              : 'Egress IP: $egressIp  •  ${settings.vpnMode ? 'VPN mode (TUN)' : 'Proxy only'}',
                          style: Desk.caption.copyWith(fontSize: 12.5),
                        ),
                        if ((psiphon.lastError ?? '').isNotEmpty) ...[
                          const SizedBox(height: 7),
                          Text(
                            psiphon.lastError ?? '',
                            style: Desk.caption.copyWith(
                              fontSize: 12.5,
                              color: Desk.red,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 20),
                  DesktopHeroToggle(
                    on: on,
                    busy: busy,
                    onTap: () => unawaited(_toggle()),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            // The region chips (sample 3): glass chips, the
            // chosen one peach-tinted with a check.
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                EmberChip(
                  label: l.psiphonRegionAuto,
                  selected: settings.region.isEmpty,
                  onTap: () => _pick(''),
                ),
                for (final code in psiphon.regionChoices)
                  EmberChip(
                    label: regionName(code),
                    selected: settings.region == code,
                    onTap: () => _pick(code),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Text(l.psiphonNextConnectHint, style: Desk.caption),
            const SizedBox(height: 16),
            // The session card: a live island (the counters move
            // with the controller's polls).
            ListenableBuilder(
              listenable: widget.psiphon,
              builder: (context, _) =>
                  _PsiphonSessionCard(psiphon: widget.psiphon),
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
    }
  }
}

/// The Psiphon page's Session card, reading the controller itself:
/// the page's live island (see the state class doc), rebuilt by the
/// controller's polls without rebuilding the page.
class _PsiphonSessionCard extends StatelessWidget {
  const _PsiphonSessionCard({required this.psiphon});

  final PsiphonController psiphon;

  @override
  Widget build(BuildContext context) {
    final state = psiphon.state;
    final on = state.connected;
    final running = state.running;
    final totalBytes = state.upBytes + state.downBytes;
    final (upValue, upUnit) = rateParts(running ? psiphon.upRate : 0);
    final (downValue, downUnit) = rateParts(running ? psiphon.downRate : 0);
    return GlassCard(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DesktopHeroRow(
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
              _DurationHero(sinceMs: running ? state.sinceMs : 0),
            ],
          ),
          const SizedBox(height: 16),
          const Divider(color: Desk.line, height: 1),
          const SizedBox(height: 12),
          Row(
            children: [
              Icon(
                on
                    ? Icons.check_circle_rounded
                    : Icons.radio_button_unchecked_rounded,
                size: 17,
                color: on ? Desk.green : Desk.faint,
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
                  color: on ? Desk.green : Desk.dim,
                ),
              ),
              const Spacer(),
              Directionality(
                textDirection: TextDirection.ltr,
                child: Text(
                  running
                      ? 'Data used: ${fmtBytes(totalBytes)}'
                      : 'Data used: —',
                  style: Desk.caption.copyWith(
                    fontSize: 12.5,
                    color: Desk.dim,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 11),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.50),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Desk.line),
            ),
            child: Row(
              children: [
                const Icon(Icons.shield_rounded,
                    size: 15, color: Desk.dim),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    on
                        ? 'Psiphon core v2.0.42 • Tunnel OK'
                        : 'Psiphon core v2.0.42 • SOCKS 11808',
                    style: Desk.caption.copyWith(
                      color: Desk.dim,
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
    );
  }
}

/// The TIME hero of the session card (ticks while running).
class _DurationHero extends StatelessWidget {
  const _DurationHero({required this.sinceMs});
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
