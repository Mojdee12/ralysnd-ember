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
/// The connection mode is part of this page on desktop (Part B):
/// the core's factory default is proxy-only ("clear"), which
/// connects and pings while no system traffic flows — the first
/// on-PC failure. The mode row shows the current mode and changes
/// it through chooseConnectionMode, and the core's TunNote (with its
/// install/retry button) appears when TUN is chosen but not running.

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

        return ListView(
          padding: const EdgeInsets.fromLTRB(26, 20, 26, 14),
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
                            Text(
                              'MOZILLA',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 1.2,
                                color: Ember.orange.withValues(alpha: 0.85),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        Text(
                          on
                              ? 'Connected to Mozilla VPN'
                              : 'Mozilla VPN',
                          style: const TextStyle(
                            fontSize: 19,
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
                          children: [
                            const Icon(
                              Icons.shield_rounded,
                              size: 15,
                              color: Ember.orange,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
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
                // RIGHT: the session card — quota, duration, exit.
                Expanded(
                  flex: 10,
                  child: GlassCard(
                    padding: const EdgeInsets.fromLTRB(20, 18, 20, 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(
                              Icons.insights_rounded,
                              size: 19,
                              color: Ember.orange,
                            ),
                            const SizedBox(width: 8),
                            Text('Session', style: Ember.heading),
                          ],
                        ),
                        const SizedBox(height: 6),
                        _SessionDurationRow(startedAt: proxy?.startedAt),
                        if (usage != null && !usage.unlimited) ...[
                          DesktopKvRow(
                            icon: Icons.data_usage_rounded,
                            label: 'Quota used',
                            value:
                                '${fmtGigabytes(usage.usedBytes)} / ${fmtGigabytes(usage.limitBytes)} GB',
                          ),
                          DesktopKvRow(
                            icon: Icons.battery_saver_rounded,
                            label: 'Quota left',
                            value: '${fmtGigabytes(usage.remainingBytes)} GB',
                          ),
                        ] else if (usage != null)
                          const DesktopKvRow(
                            icon: Icons.data_usage_rounded,
                            label: 'Quota',
                            value: 'Unlimited',
                          )
                        else
                          DesktopKvRow(
                            icon: Icons.person_outline_rounded,
                            label: 'Account',
                            value: account == null ? '—' : 'Signed in',
                          ),
                        DesktopKvRow(
                          icon: Icons.public_rounded,
                          label: 'Exit IP',
                          value: exitIp.isEmpty ? '—' : exitIp,
                        ),
                        DesktopKvRow(
                          icon: Icons.flag_rounded,
                          label: 'Exit country',
                          value: countryName.isEmpty
                              ? '—'
                              : localizedCountryName(
                                  context, countryCode, countryName),
                          divider: false,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            // The connection mode row + the TUN problem note (Part B:
            // never sit silently in proxy-only mode).
            const SizedBox(height: 14),
            GlassCard(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.tune_rounded,
                          size: 18, color: Ember.orange),
                      const SizedBox(width: 9),
                      Text(l.connectionMode, style: Ember.body),
                      const Spacer(),
                      _ModeChip(
                        label: l.modeProxyOnly,
                        selected: mode == 'clear',
                        onTap: () => unawaited(
                            chooseConnectionMode(context, core, 'clear')),
                      ),
                      const SizedBox(width: 7),
                      _ModeChip(
                        label: l.systemProxy,
                        selected: mode == 'set',
                        onTap: () => unawaited(
                            chooseConnectionMode(context, core, 'set')),
                      ),
                      const SizedBox(width: 7),
                      _ModeChip(
                        label: 'TUN',
                        selected: mode == 'tun',
                        onTap: () => unawaited(
                            chooseConnectionMode(context, core, 'tun')),
                      ),
                    ],
                  ),
                  if (mode == 'clear' && status != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Proxy only: apps that use the local proxy are '
                      'covered; the rest of the system connects '
                      'directly. Pick TUN for every app.',
                      style: Ember.caption,
                    ),
                  ],
                  if (status != null)
                    TunNote(
                      core: core,
                      box: (text, tooltip) => Tooltip(
                        message: tooltip,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 9),
                          decoration: BoxDecoration(
                            color: Ember.warn.withValues(alpha: 0.13),
                            border: Border.all(
                                color: Ember.warn.withValues(alpha: 0.5)),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.warning_amber_rounded,
                                  size: 17, color: Ember.warn),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(text, style: Ember.body),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            // The V2Ray configs strip of the mockup.
            _ConfigsStrip(
              xray: widget.xray,
              onOpenV2ray: widget.onOpenV2ray,
            ),
            const SizedBox(height: 14),
            DesktopStatusBar(
              left: countryName.isEmpty
                  ? l.recommendedServer
                  : '${localizedCountryName(context, countryCode, countryName)}${city.isEmpty ? '' : ' • $city'}',
              protectionOn: on && status?.computerUsesVpn == true,
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

/// The session-duration row: ticks while the proxy runs, an em dash
/// otherwise. Its own widget so the ticking rebuilds nothing else.
class _SessionDurationRow extends StatelessWidget {
  const _SessionDurationRow({required this.startedAt});
  final DateTime? startedAt;

  @override
  Widget build(BuildContext context) {
    if (startedAt == null) {
      return const DesktopKvRow(
        icon: Icons.schedule_rounded,
        label: 'Session',
        value: '—',
      );
    }
    return StreamBuilder<void>(
      stream: Stream.periodic(const Duration(seconds: 1)),
      builder: (context, _) => DesktopKvRow(
        icon: Icons.schedule_rounded,
        label: 'Session',
        value: fmtDuration(DateTime.now().difference(startedAt!)),
      ),
    );
  }
}

/// One connection-mode chip (Proxy only / System proxy / TUN).
class _ModeChip extends StatelessWidget {
  const _ModeChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(999),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
            decoration: BoxDecoration(
              gradient: selected ? Ember.gradient : null,
              color: selected ? null : Ember.cardSoft,
              borderRadius: BorderRadius.circular(999),
              border: selected ? null : Border.all(color: Ember.line),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w800,
                color: selected ? const Color(0xFF1A1206) : Ember.dim,
              ),
            ),
          ),
        ),
      );
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
      color: Ember.cardSoft.withValues(alpha: 0.65),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
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
