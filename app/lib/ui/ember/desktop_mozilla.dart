/// The Mozilla DESKTOP home: the locked Fluent mockup E rendered as
/// a dashboard — a status card and a session card side by side, the
/// V2Ray configs strip under them, and the bottom status bar. Not
/// the phone page: no power ring, no centered column.
///
/// Facts only: the right card shows what the desktop core actually
/// reports (session duration, the account's quota, the exit the core
/// names). The desktop core exposes no per-session byte counters to
/// this UI, so none are shown — and there is no kill switch in this
/// app, so the footer never claims one.
///
/// The capture mode is NOT a card on this page (no mockup has
/// one): it lives on the desktop Settings page. What stays here is
/// honesty about it — the status footer's mode fact, and one slim
/// warning line when TUN is chosen but failed/missing/not running
/// (the core's tunNote, with its install action). The desktop
/// first-run default that picks TUN lives in the shell.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/core_controller.dart';
import '../../core/models.dart';
import '../../l10n/app_localizations.dart';
import '../../xray/xray_controller.dart';
import '../../xray/xray_models.dart';
import '../connection_mode.dart';
import 'desktop_widgets.dart';
import 'ember_format.dart';
import 'ember_theme.dart';
import 'profile_country.dart';
import 'qr_pages.dart';

class MozillaDesktopHome extends StatefulWidget {
  const MozillaDesktopHome({
    super.key,
    required this.core,
    required this.xray,
    required this.onOpenServers,
    required this.onOpenAccounts,
    required this.onOpenV2ray,
    required this.stopOtherEngine,
  });

  final CoreController core;
  final XrayController xray;
  final VoidCallback onOpenServers;
  final VoidCallback onOpenAccounts;
  final VoidCallback onOpenV2ray;
  final Future<void> Function() stopOtherEngine;

  @override
  State<MozillaDesktopHome> createState() => _MozillaDesktopHomeState();
}

class _MozillaDesktopHomeState extends State<MozillaDesktopHome> {
  bool _busy = false;

  Future<void> _toggle(bool on) async {
    setState(() => _busy = true);
    try {
      if (on) await widget.stopOtherEngine();
      await widget.core.setOn(on);
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

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([widget.core, widget.xray]),
      builder: (context, _) {
        final core = widget.core;
        final status = core.status;
        final phase = status?.state.phase ?? Phase.off;
        final on = phase == Phase.running;
        final busy = _busy || phase == Phase.starting;
        final proxy = status?.proxy;
        final exit = status?.exit;
        final account = status?.activeAccount;
        final usage = account?.usage;
        final countryCode =
            (exit?.countryCode.isNotEmpty ?? false) ? exit!.countryCode : (proxy?.countryCode ?? '');
        final countryName = (exit?.countryName.isNotEmpty ?? false)
            ? exit!.countryName
            : (proxy?.countryName ?? '');
        final city = (exit?.city.isNotEmpty ?? false)
            ? exit!.city
            : (proxy?.cityName ?? '');
        final exitIp = (exit?.ipv4.isNotEmpty ?? false) ? exit!.ipv4 : '';
        final mode = status == null ? 'clear' : connectionModeShown(status);
        final modeLabel = switch (mode) {
          'tun' => 'TUN',
          'set' => l.systemProxy,
          _ => l.modeProxyOnly,
        };
        // The footer facts: what is actually on, from the status.
        final dohOn = _dohOn(core);
        final footerFacts = [
          if (on) 'Encrypted',
          if (dohOn != null) (dohOn ? 'DoH ON' : 'DoH OFF'),
          '$modeLabel mode',
        ].join(' • ');

        return Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(26, 20, 26, 8),
                children: [
            DesktopHeader(
              title: 'Connection',
              subtitle: 'Secure & Fast VPN Engine',
            ),
            const SizedBox(height: 18),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // LEFT: the status card.
                Expanded(
                  flex: 11,
                  child: GlassCard(
                    glow: on,
                    padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            DesktopStateBadge(
                              label: on ? 'SECURE' : 'OFF',
                              color: on ? Ember.green : Ember.faint,
                            ),
                            const Spacer(),
                            const DesktopEnginePill(label: 'MOZILLA'),
                          ],
                        ),
                        const SizedBox(height: 14),
                        Text(
                          on
                              ? 'Connected to Mozilla VPN'
                              : 'Mozilla VPN',
                          style: const TextStyle(
                            fontSize: 21,
                            fontWeight: FontWeight.w800,
                            color: Ember.text,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            FlagRect(code: countryCode, width: 34),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                countryName.isEmpty
                                    ? l.recommendedServer
                                    : '${localizedCountryName(context, countryCode, countryName)}${city.isEmpty ? '' : ' • $city'}',
                                style: Ember.body,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          exitIp.isEmpty
                              ? 'Exit IP: —'
                              : 'Exit IP: $exitIp',
                          style: Ember.dimStyle,
                        ),
                        const SizedBox(height: 16),
                        DesktopTogglePill(
                          on: on,
                          busy: busy,
                          onLabel: 'Connected',
                          offLabel: 'Connect',
                          onTap: () => unawaited(_toggle(!on)),
                        ),
                        const SizedBox(height: 13),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(
                              Icons.shield_rounded,
                              size: 15,
                              color: Ember.orange,
                            ),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                footerFacts,
                                style: Ember.caption.copyWith(fontSize: 12.5),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                // RIGHT: "Session Traffic" — the mockup's card: two
                // HERO stats (the desktop core exposes no per-session
                // byte counters, so the heroes are the session time
                // and the account's quota left — real data only),
                // then the mockup's icon rows.
                Expanded(
                  flex: 10,
                  child: GlassCard(
                    padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
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
                            Text('Session Traffic', style: Ember.heading),
                          ],
                        ),
                        const SizedBox(height: 16),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: _SessionHero(startedAt: proxy?.startedAt),
                            ),
                            Expanded(
                              child: DesktopHeroStat(
                                icon: Icons.data_usage_rounded,
                                label: 'QUOTA LEFT',
                                value: usage == null
                                    ? '—'
                                    : usage.unlimited
                                        ? 'Unlimited'
                                        : '${fmtGigabytes(usage.remainingBytes)} GB',
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        const Divider(color: Ember.line, height: 1),
                        const SizedBox(height: 12),
                        _TrafficRow(
                          icon: Icons.pie_chart_rounded,
                          label: 'Quota used',
                          value: usage == null
                              ? '—'
                              : usage.unlimited
                                  ? 'Unlimited plan'
                                  : '${fmtGigabytes(usage.usedBytes)} of ${fmtGigabytes(usage.limitBytes)} GB',
                        ),
                        const SizedBox(height: 9),
                        _TrafficRow(
                          icon: Icons.public_rounded,
                          label: 'Exit',
                          value: exitIp.isEmpty
                              ? '—'
                              : '$exitIp${countryName.isEmpty ? '' : ' • ${localizedCountryName(context, countryCode, countryName)}'}',
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            // The slim TUN warning: only while TUN is chosen but
            // not running (tunNote is null in every healthy state,
            // proxy-only included — the footer names that mode).
            if (status != null && tunNote(l, status) != null) ...[
              const SizedBox(height: 12),
              _TunWarning(core: core),
            ],
            const SizedBox(height: 16),
            // The V2Ray configs strip of the mockup.
            _ConfigsStrip(
              xray: widget.xray,
              onOpenV2ray: widget.onOpenV2ray,
            ),
                ],
              ),
            ),
            // The status bar is pinned to the window's bottom edge,
            // as the mockups draw it (not flowing under the cards).
            Padding(
              padding: const EdgeInsets.fromLTRB(26, 6, 26, 14),
              child: DesktopStatusBar(
                left: countryName.isEmpty
                    ? l.recommendedServer
                    : '${localizedCountryName(context, countryCode, countryName)}${city.isEmpty ? '' : ' • $city'}',
                protectionOn: on && status?.computerUsesVpn == true,
              ),
            ),
          ],
        );
      },
    );
  }

  /// DoH state from the core's settings (https/tls DNS servers);
  /// null while unknown. Fetched once, when the core first answers.
  bool? _dohCache;
  bool _dohRequested = false;

  bool? _dohOn(CoreController core) {
    if (!_dohRequested && core.status != null) {
      _dohRequested = true;
      unawaited(() async {
        try {
          final settings = await core.settings();
          final dns = settings['dns'];
          final servers = dns is Map ? dns['servers'] : null;
          final list = servers is List ? servers : const [];
          final on = list.isNotEmpty &&
              list.every((s) =>
                  s.toString().startsWith('https://') ||
                  s.toString().startsWith('tls://'));
          if (mounted) setState(() => _dohCache = on);
        } catch (_) {
          // Unknown stays unknown; the footer omits the fact.
        }
      }());
    }
    return _dohCache;
  }
}

/// The SESSION hero of the traffic card: the live session clock,
/// ticking while the proxy runs, an em dash otherwise. Its own
/// widget so the ticking rebuilds nothing else.
class _SessionHero extends StatelessWidget {
  const _SessionHero({required this.startedAt});
  final DateTime? startedAt;

  @override
  Widget build(BuildContext context) {
    if (startedAt == null) {
      return const DesktopHeroStat(
        icon: Icons.schedule_rounded,
        label: 'SESSION',
        value: '—',
      );
    }
    return StreamBuilder<void>(
      stream: Stream.periodic(const Duration(seconds: 1)),
      builder: (context, _) => DesktopHeroStat(
        icon: Icons.schedule_rounded,
        label: 'SESSION',
        value: fmtDuration(DateTime.now().difference(startedAt!)),
      ),
    );
  }
}

/// One row under the traffic card's divider, in the mockup's style:
/// a small icon, then "Label: value" on one line.
class _TrafficRow extends StatelessWidget {
  const _TrafficRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Icon(icon, size: 17, color: Ember.dim),
          const SizedBox(width: 9),
          Expanded(
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: '$label: ',
                      style: const TextStyle(color: Ember.dim),
                    ),
                    TextSpan(
                      text: value,
                      style: const TextStyle(
                        color: Ember.text,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                style: const TextStyle(fontSize: 14),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ],
      );
}

/// The slim TUN warning line under the status cards: amber text
/// with the install action inline, shown only while TUN is chosen
/// but failed/missing/not running (or a small note while it starts).
class _TunWarning extends StatelessWidget {
  const _TunWarning({required this.core});

  final CoreController core;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final status = core.status;
    final note = status == null ? null : tunNote(l, status);
    if (note == null) return const SizedBox.shrink();
    if (!note.problem) {
      return Text(
        note.text,
        textAlign: TextAlign.center,
        style: const TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
          color: Ember.warn,
        ),
      );
    }
    final busy = core.installingTun || core.removingTun;
    return Row(
      children: [
        const Icon(Icons.warning_amber_rounded, size: 16, color: Ember.warn),
        const SizedBox(width: 8),
        Expanded(
          child: Tooltip(
            message: note.detail,
            child: Text(
              note.text,
              style: const TextStyle(fontSize: 12.5, color: Ember.warn),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        if (note.install)
          TextButton(
            onPressed: busy ? null : () => installTunService(context, core),
            child: Text(note.again ? l.tunInstallAgain : l.tunInstall),
          ),
      ],
    );
  }
}

/// The mockup's wide "V2Ray Configs" strip: the first few profiles
/// as rows (flag, name, protocol line, ping pill), a header with
/// "+ Add Config", and an empty state that offers the import. A row
/// tap selects the profile and switches to the V2Ray engine.
class _ConfigsStrip extends StatelessWidget {
  const _ConfigsStrip({required this.xray, required this.onOpenV2ray});

  final XrayController xray;
  final VoidCallback onOpenV2ray;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final profiles = xray.profiles.take(3).toList();
    return GlassCard(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('V2Ray Configs', style: Ember.heading.copyWith(fontSize: 17)),
              const Spacer(),
              Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () => unawaited(showPasteSheet(context, xray)),
                  borderRadius: BorderRadius.circular(11),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 7),
                    decoration: BoxDecoration(
                      border: Border.all(
                          color: Ember.orange.withValues(alpha: 0.7)),
                      borderRadius: BorderRadius.circular(11),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.add_rounded, size: 16, color: Ember.orange),
                        SizedBox(width: 5),
                        Text(
                          'Add Config',
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w800,
                            color: Ember.orange,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (profiles.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(l.noProfilesYet, style: Ember.dimStyle),
            )
          else
            for (final p in profiles) ...[
              _StripRow(
                profile: p,
                unit: l.msUnit,
                testing: xray.isTesting(p.id),
                onTap: () {
                  xray.select(p);
                  onOpenV2ray();
                },
              ),
              const SizedBox(height: 8),
            ],
        ],
      ),
    );
  }
}

class _StripRow extends StatelessWidget {
  const _StripRow({
    required this.profile,
    required this.unit,
    required this.testing,
    required this.onTap,
  });

  final Profile profile;
  final String unit;
  final bool testing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final code = profileCountryCode(profile);
    final security = switch (profile.security) {
      'tls' => 'TLS',
      'reality' => 'Reality',
      _ => profile.network.toUpperCase(),
    };
    return Material(
      color: Colors.white.withValues(alpha: 0.09),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
          child: Row(
            children: [
              FlagRect(code: code ?? '', width: 40),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      profile.name,
                      style: Ember.heading.copyWith(fontSize: 14.5),
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      '${profile.protocol.label} • $security',
                      style: Ember.caption,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              DesktopPingPill(
                ms: profile.delayMs,
                failed: profile.delayFailed,
                testing: testing,
                unit: unit,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
