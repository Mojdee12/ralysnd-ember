/// Home: the mockups' power ring, the mode switch, and the context
/// card of the active engine — the account and its 50 GB in Mozilla
/// mode, the selected config and its subscription in V2Ray mode.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/core_controller.dart';
import '../../core/models.dart';
import '../../features.dart';
import '../../l10n/app_localizations.dart';
import '../../lantern/lantern_controller.dart';
import '../../lantern/lantern_platform.dart';
import '../../psiphon/psiphon_controller.dart';
import '../../psiphon/psiphon_platform.dart';
import '../../warp/warp_controller.dart';
import '../../xray/exit_info.dart';
import '../../xray/xray_controller.dart';
import '../../xray/xray_models.dart';
import 'ember_format.dart';
import 'map_mozilla.dart';
import 'map_psiphon.dart';
import 'map_v2ray.dart';
import 'ember_theme.dart';
import 'profile_country.dart';
import 'warp_pages.dart' show warpModeLabel;
import 'world_map.dart';

class EmberHome extends StatelessWidget {
  const EmberHome({
    super.key,
    required this.core,
    required this.xray,
    required this.psiphon,
    required this.lantern,
    required this.warp,
    required this.mode,
    required this.onModeChanged,
    required this.onOpenServers,
    required this.onOpenAccounts,
    required this.stopOtherEngine,
    this.hideModeSwitch = false,
    this.desktop = false,
  });

  final CoreController core;
  final XrayController xray;
  final PsiphonController psiphon;
  final LanternController lantern;
  final WarpController warp;
  final int mode;
  final ValueChanged<int> onModeChanged;
  final VoidCallback onOpenServers;
  final VoidCallback onOpenAccounts;

  /// Stops the other engines before the Mozilla engine starts.
  final Future<void> Function() stopOtherEngine;

  /// The desktop shell switches engines in its rail instead: no
  /// switch (or tagline) at the top of the home page there.
  final bool hideModeSwitch;

  /// The Windows desktop shell: the home is the Map Control
  /// overlay of the active engine (map_mozilla.dart /
  /// map_v2ray.dart / map_psiphon.dart) floating over the shell's
  /// world map, not the phone page at all. Android never sets
  /// this.
  final bool desktop;

  @override
  Widget build(BuildContext context) {
    // The desktop overlays are their own pages; the phone layout
    // below is untouched for Android.
    if (desktop) {
      return switch (mode) {
        1 => MapV2rayPage(xray: xray),
        2 => MapPsiphonPage(psiphon: psiphon),
        _ => MapMozillaPage(
          core: core,
          onOpenServers: onOpenServers,
          onOpenAccounts: onOpenAccounts,
        ),
      };
    }
    final l = AppLocalizations.of(context);
    // The engines this platform offers (features.dart): on Windows
    // the switch holds Mozilla / V2Ray / Psiphon only.
    final modes = Features.engineModes;
    String labelOf(int m) => switch (m) {
      0 => l.modeMozilla,
      1 => l.modeV2ray,
      2 => l.modePsiphon,
      3 => l.modeLantern,
      _ => l.modeWarp,
    };
    return ListenableBuilder(
      listenable: Listenable.merge([core, xray, psiphon, lantern, warp]),
      builder: (context, _) => ListView(
        padding: const EdgeInsets.fromLTRB(18, 10, 18, 18),
        children: [
          const EmberAppBar(),
          const SizedBox(height: 14),
          if (!hideModeSwitch) ...[
            ModeSwitch(
              index: modes.indexOf(mode),
              onChanged: (i) => onModeChanged(modes[i]),
              labels: [for (final m in modes) labelOf(m)],
            ),
            const SizedBox(height: 8),
            Text(
              l.tagline,
              textAlign: TextAlign.center,
              style: Ember.caption.copyWith(fontSize: 12.5),
            ),
            const SizedBox(height: 10),
          ],
          if (mode == 0)
            _MozillaHome(
              core: core,
              onOpenServers: onOpenServers,
              onOpenAccounts: onOpenAccounts,
              stopOtherEngine: stopOtherEngine,
            )
          else if (mode == 1)
            _V2rayHome(
              xray: xray,
              onOpenServers: onOpenServers,
              onOpenAccounts: onOpenAccounts,
            )
          else if (mode == 2)
            _PsiphonHome(psiphon: psiphon, onOpenServers: onOpenServers)
          else if (mode == 3)
            _LanternHome(lantern: lantern, onOpenServers: onOpenServers)
          else
            _WarpHome(warp: warp, onOpenServers: onOpenServers),
        ],
      ),
    );
  }
}

class _MozillaHome extends StatefulWidget {
  const _MozillaHome({
    required this.core,
    required this.onOpenServers,
    required this.onOpenAccounts,
    required this.stopOtherEngine,
  });

  final CoreController core;
  final VoidCallback onOpenServers;
  final VoidCallback onOpenAccounts;
  final Future<void> Function() stopOtherEngine;

  @override
  State<_MozillaHome> createState() => _MozillaHomeState();
}

class _MozillaHomeState extends State<_MozillaHome> {
  bool _busy = false;

  Future<void> _toggle(bool on) async {
    setState(() => _busy = true);
    try {
      if (on) await widget.stopOtherEngine();
      await widget.core.setOn(on);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final core = widget.core;
    final status = core.status;
    final phase = status?.state.phase ?? Phase.off;
    final on = phase == Phase.running;
    final busy = _busy || phase == Phase.starting;
    final account = status?.activeAccount;
    final usage = account?.usage;
    final startedAt = status?.proxy?.startedAt;
    final traffic = status?.traffic;

    return Column(
      children: [
        PowerRing(on: on, busy: busy, onTap: () => _toggle(!on)),
        const SizedBox(height: 14),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (on) ...[
              Container(
                width: 9,
                height: 9,
                decoration: const BoxDecoration(
                  color: Ember.green,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
            ],
            Text(
              on ? l.statusConnected : l.statusDisconnected,
              style: TextStyle(
                fontSize: 21,
                fontWeight: FontWeight.w800,
                color: on ? Ember.orange : Ember.text,
              ),
            ),
          ],
        ),
        const SizedBox(height: 5),
        if (on && startedAt != null)
          _SessionLine(startedAt: startedAt, caption: l.secureConnection)
        else
          Text(l.secureConnection, style: Ember.dimStyle),
        if (on && traffic != null) ...[
          const SizedBox(height: 8),
          _RatesRow(upRate: traffic.upRate, downRate: traffic.downRate),
        ],
        const SizedBox(height: 20),
        // The active account and its allowance (mockup 1).
        GlassCard(
          onTap: widget.onOpenAccounts,
          child: account == null
              ? Row(
                  children: [
                    const Icon(Icons.person_outline_rounded, color: Ember.dim),
                    const SizedBox(width: 10),
                    Expanded(child: Text(l.noAccountYet, style: Ember.body)),
                    const Icon(Icons.chevron_left_rounded, color: Ember.faint),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 40,
                          height: 40,
                          decoration: const BoxDecoration(
                            gradient: Ember.gradient,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.person_rounded,
                            color: Color(0xFF1A1206),
                            size: 22,
                          ),
                        ),
                        const SizedBox(width: 11),
                        Expanded(
                          child: Text(
                            maskEmail(
                              account.email.isEmpty
                                  ? account.name
                                  : account.email,
                            ),
                            style: Ember.heading,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.all(7),
                          decoration: const BoxDecoration(
                            color: Ember.cardSoft,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.swap_horiz_rounded,
                            color: Ember.dim,
                            size: 18,
                          ),
                        ),
                      ],
                    ),
                    if (usage != null) ...[
                      const SizedBox(height: 14),
                      Text(
                        l.remainingOf(
                          fmtGigabytes(usage.remainingBytes),
                          fmtGigabytes(usage.limitBytes),
                        ),
                        style: Ember.body,
                      ),
                      const SizedBox(height: 9),
                      UsageBar(
                        fraction: usage.limitBytes > 0
                            ? (usage.usedBytes / usage.limitBytes).clamp(
                                0.0,
                                1.0,
                              )
                            : 0,
                      ),
                      const SizedBox(height: 7),
                      Align(
                        alignment: AlignmentDirectional.centerEnd,
                        child: Text(
                          l.usedPercent(
                            latDigits(
                              usage.limitBytes > 0
                                  ? (usage.usedBytes * 100 ~/ usage.limitBytes)
                                  : 0,
                            ),
                          ),
                          style: Ember.caption,
                        ),
                      ),
                    ],
                  ],
                ),
        ),
        const SizedBox(height: 12),
        // The chosen server row (mockup 1).
        _MozillaServerRow(core: core, onTap: widget.onOpenServers),
      ],
    );
  }
}

class _MozillaServerRow extends StatelessWidget {
  const _MozillaServerRow({required this.core, required this.onTap});
  final CoreController core;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final proxy = core.status?.proxy;
    final name = proxy?.countryName ?? '';
    final code = proxy?.countryCode ?? '';
    final city = proxy?.cityName ?? '';
    return GlassCard(
      onTap: onTap,
      child: Row(
        children: [
          FlagCircle(code: code),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name.isEmpty
                      ? l.recommendedServer
                      : '${localizedCountryName(context, code, name)}${city.isEmpty ? '' : ' • $city'}',
                  style: Ember.heading,
                ),
                Text(l.recommendedServerSub, style: Ember.caption),
              ],
            ),
          ),
          const Icon(Icons.chevron_left_rounded, color: Ember.faint),
        ],
      ),
    );
  }
}

/// The V2Ray home, on the approved v2ray-screen1 layout.
class _V2rayHome extends StatefulWidget {
  const _V2rayHome({
    required this.xray,
    required this.onOpenServers,
    required this.onOpenAccounts,
  });

  final XrayController xray;
  final VoidCallback onOpenServers;
  final VoidCallback onOpenAccounts;

  @override
  State<_V2rayHome> createState() => _V2rayHomeState();
}

class _V2rayHomeState extends State<_V2rayHome> {
  Future<void> _toggle() async {
    final xray = widget.xray;
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
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final xray = widget.xray;
    final on = xray.state.running;
    final p = xray.selected;
    final sub = p == null ? null : xray.subscriptionOf(p);

    // Pins: one per country derivable from the profiles' remarks,
    // plus the exit country the tunnel itself reported while
    // connected. Nothing else is ever drawn — no country is invented
    // for a remark that carries none.
    final pinCodes = <String>{};
    for (final profile in xray.profiles) {
      final code = profileCountryCode(profile);
      if (code != null) pinCodes.add(code);
    }
    final selectedCode = p == null ? null : profileCountryCode(p);
    final exitCode = on ? xray.exitInfo?.countryCode : null;
    if (exitCode != null && exitCode.isNotEmpty) pinCodes.add(exitCode);
    final activeCode =
        selectedCode ??
        (exitCode != null && exitCode.isNotEmpty ? exitCode : null);

    return Column(
      children: [
        WorldMapPanel(
          pins: pinCodes,
          selected: activeCode,
          connected: on,
          homeLabel:
              '${l.mapHome} • ${localizedCountryName(context, 'IR', 'Iran')}',
        ),
        const SizedBox(height: 12),
        // The control card (layout E): the selected config, its exit
        // line, ping, per-config totals and session rates, then the
        // wide connect button — the same toggle the power ring drove,
        // unchanged underneath.
        GlassCard(
          glow: on,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (p == null)
                InkWell(
                  onTap: widget.onOpenServers,
                  child: Row(
                    children: [
                      const Icon(Icons.dns_outlined, color: Ember.dim),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(l.noProfileSelected, style: Ember.body),
                      ),
                      const Icon(
                        Icons.chevron_left_rounded,
                        color: Ember.faint,
                      ),
                    ],
                  ),
                )
              else ...[
                InkWell(
                  onTap: widget.onOpenServers,
                  child: Row(
                    children: [
                      Container(
                        width: 42,
                        height: 42,
                        decoration: const BoxDecoration(
                          color: Ember.cardSoft,
                          shape: BoxShape.circle,
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          selectedCode == null
                              ? '🌐'
                              : countryFlagEmoji(selectedCode),
                          style: const TextStyle(fontSize: 21),
                        ),
                      ),
                      const SizedBox(width: 11),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              p.name,
                              style: Ember.heading,
                              overflow: TextOverflow.ellipsis,
                            ),
                            Text(
                              '${p.address}:${p.port}',
                              style: Ember.caption,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      const Icon(
                        Icons.chevron_left_rounded,
                        color: Ember.faint,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 7,
                  runSpacing: 7,
                  children: [
                    EmberChip(label: p.protocol.label),
                    if (p.security.isNotEmpty)
                      EmberChip(label: p.security.toUpperCase()),
                    EmberChip(
                      label: p.delayMs >= 0
                          ? '${l.pingLabel}: ${latDigits(p.delayMs)}ms'
                          : p.delayFailed
                          ? '${l.pingLabel}: Failed'
                          : l.pingLabel,
                      dot: p.delayMs >= 0
                          ? pingColor(p.delayMs)
                          : p.delayFailed
                          ? Ember.red
                          : null,
                    ),
                    if (!p.protocol.supportedByCore)
                      EmberChip(label: l.unsupportedProtocol, dot: Ember.red),
                  ],
                ),
                // The exit line: shown only while connected and only
                // when the through-tunnel lookup answered.
                if (on && xray.exitInfo != null) ...[
                  const SizedBox(height: 11),
                  Row(
                    children: [
                      const Icon(
                        Icons.public_rounded,
                        size: 15,
                        color: Ember.dim,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          xray.exitInfo!.line,
                          style: Ember.caption,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ],
                // This config's cumulative counted traffic.
                if (profileHasTotals(p)) ...[
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      const Icon(
                        Icons.data_usage_rounded,
                        size: 14,
                        color: Ember.faint,
                      ),
                      const SizedBox(width: 6),
                      // Fully-English LTR totals line; pin direction.
                      Directionality(
                        textDirection: TextDirection.ltr,
                        child: Text(
                          fmtProfileTotals(p),
                          style: Ember.caption,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 13),
                Row(
                  children: [
                    Container(
                      width: 9,
                      height: 9,
                      decoration: BoxDecoration(
                        color: on ? Ember.green : Ember.faint,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      on ? l.statusConnected : l.statusDisconnected,
                      style: TextStyle(
                        fontSize: 15.5,
                        fontWeight: FontWeight.w800,
                        color: on ? Ember.orange : Ember.dim,
                      ),
                    ),
                    // Status, a fixed gap, then the session line —
                    // never a Spacer: it could collapse to zero and
                    // glue the timer onto the status word (2006).
                    if (on && xray.state.sinceMs > 0) ...[
                      const SizedBox(width: 10),
                      Expanded(
                        child: _SessionLine(
                          startedAt: DateTime.fromMillisecondsSinceEpoch(
                            xray.state.sinceMs,
                          ),
                          caption: l.secureConnection,
                        ),
                      ),
                    ],
                  ],
                ),
                if (on) ...[
                  const SizedBox(height: 9),
                  _RatesRow(upRate: xray.upRate, downRate: xray.downRate),
                ],
              ],
              const SizedBox(height: 14),
              _WideConnectButton(
                on: on,
                busy: xray.connecting,
                connectLabel: l.connectAction,
                disconnectLabel: l.disconnectAction,
                workingLabel: l.working,
                onTap: () => unawaited(_toggle()),
              ),
            ],
          ),
        ),
        // The subscription usage card (v2ray mockup 1).
        if (sub != null && sub.totalBytes > 0) ...[
          const SizedBox(height: 12),
          GlassCard(
            onTap: widget.onOpenAccounts,
            child: Row(
              children: [
                UsageRing(
                  fraction: sub.usedFraction,
                  centerText: '${latDigits((sub.usedFraction * 100).round())}%',
                  size: 84,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(sub.name, style: Ember.heading),
                      const SizedBox(height: 5),
                      Text(
                        l.subUsedOf(
                          fmtGigabytes(sub.usedBytes),
                          fmtGigabytes(sub.totalBytes),
                        ),
                        style: Ember.dimStyle,
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 7,
                        children: [
                          if (sub.remainingDays >= 0)
                            EmberChip(
                              label: l.daysLeft(latDigits(sub.remainingDays)),
                              dot: Ember.green,
                            ),
                          EmberChip(
                            label: l.profilesCount(
                              latDigits(xray.profilesOf(sub).length),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// The wide glowing connect button of the map layout: gradient while
/// disconnected, an outlined ember state while connected, a spinner
/// while the tunnel is coming up.
class _WideConnectButton extends StatelessWidget {
  const _WideConnectButton({
    required this.on,
    required this.busy,
    required this.connectLabel,
    required this.disconnectLabel,
    required this.workingLabel,
    required this.onTap,
  });

  final bool on;
  final bool busy;
  final String connectLabel;
  final String disconnectLabel;
  final String workingLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final dark = !on && !busy;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: busy ? null : onTap,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          height: 54,
          decoration: BoxDecoration(
            gradient: dark ? Ember.gradient : null,
            color: dark ? null : Ember.cardSoft,
            borderRadius: BorderRadius.circular(18),
            border: on && !busy
                ? Border.all(color: Ember.orange.withValues(alpha: 0.55))
                : null,
            boxShadow: dark
                ? [
                    BoxShadow(
                      color: Ember.orange.withValues(alpha: 0.35),
                      blurRadius: 18,
                      spreadRadius: 1,
                    ),
                  ]
                : const [],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (busy)
                const SizedBox(
                  width: 19,
                  height: 19,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.2,
                    color: Ember.orange,
                  ),
                )
              else
                Icon(
                  Icons.power_settings_new_rounded,
                  size: 21,
                  color: dark ? const Color(0xFF1A1206) : Ember.orange,
                ),
              const SizedBox(width: 9),
              Text(
                busy ? workingLabel : (on ? disconnectLabel : connectLabel),
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: dark
                      ? const Color(0xFF1A1206)
                      : (on ? Ember.orange : Ember.dim),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Session duration + a caption, ticking every second while shown.
class _SessionLine extends StatelessWidget {
  const _SessionLine({required this.startedAt, required this.caption});
  final DateTime startedAt;
  final String caption;

  @override
  Widget build(BuildContext context) => StreamBuilder<void>(
    stream: Stream.periodic(const Duration(seconds: 1)),
    builder: (context, _) {
      final d = DateTime.now().difference(startedAt);
      // Duration, separator and caption are SEPARATE widgets with
      // real gaps — never one mixed-direction string, whose bidi
      // reordering glued the timer onto the status word (2006).
      // The duration is pinned LTR so it reads 00:34 in both
      // layout directions.
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Directionality(
            textDirection: TextDirection.ltr,
            child: Text(fmtDuration(d), style: Ember.dimStyle),
          ),
          const SizedBox(width: 6),
          Text('•', style: Ember.dimStyle.copyWith(color: Ember.faint)),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              caption,
              style: Ember.dimStyle,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      );
    },
  );
}

class _RatesRow extends StatelessWidget {
  const _RatesRow({required this.upRate, required this.downRate});
  final int upRate;
  final int downRate;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      const Icon(Icons.arrow_upward_rounded, size: 14, color: Ember.orange),
      const SizedBox(width: 3),
      Text(fmtRate(upRate), style: Ember.caption.copyWith(color: Ember.dim)),
      const SizedBox(width: 16),
      const Icon(Icons.arrow_downward_rounded, size: 14, color: Ember.amber),
      const SizedBox(width: 3),
      Text(fmtRate(downRate), style: Ember.caption.copyWith(color: Ember.dim)),
    ],
  );
}

/// The Psiphon home: the same power ring and status grammar as the
/// Mozilla home, driven by the core's own state — connecting until
/// the core reports its tunnel, then the session line, live rates,
/// the session's byte totals, and the exit line looked up through
/// the tunnel itself.
class _PsiphonHome extends StatefulWidget {
  const _PsiphonHome({required this.psiphon, required this.onOpenServers});

  final PsiphonController psiphon;
  final VoidCallback onOpenServers;

  @override
  State<_PsiphonHome> createState() => _PsiphonHomeState();
}

class _PsiphonHomeState extends State<_PsiphonHome> {
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
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(l.startFailed)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final psiphon = widget.psiphon;
    final state = psiphon.state;
    final on = state.connected;
    final running = state.running;
    final busy = _busy || psiphon.connecting || (running && !on);
    final settings = psiphon.settings;
    // The region line: where the tunnel actually landed once the
    // core says so, else the region picked in settings.
    final actual = state.region;
    final shownCode = on && actual.isNotEmpty ? actual : settings.region;
    final exit = psiphon.exitInfo;

    return Column(
      children: [
        PowerRing(on: on, busy: busy, onTap: () => unawaited(_toggle())),
        const SizedBox(height: 14),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (on) ...[
              Container(
                width: 9,
                height: 9,
                decoration: const BoxDecoration(
                  color: Ember.green,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
            ],
            Text(
              on
                  ? l.statusConnected
                  : running
                  ? l.stateConnecting
                  : l.statusDisconnected,
              style: TextStyle(
                fontSize: 21,
                fontWeight: FontWeight.w800,
                color: on ? Ember.orange : Ember.text,
              ),
            ),
          ],
        ),
        const SizedBox(height: 5),
        if (running && state.sinceMs > 0)
          _SessionLine(
            startedAt: DateTime.fromMillisecondsSinceEpoch(state.sinceMs),
            caption: l.secureConnection,
          )
        else
          Text(l.secureConnection, style: Ember.dimStyle),
        if (running) ...[
          const SizedBox(height: 8),
          _RatesRow(upRate: psiphon.upRate, downRate: psiphon.downRate),
          if (state.upBytes > 0 || state.downBytes > 0) ...[
            const SizedBox(height: 7),
            // Fully-English LTR totals line, like the V2Ray one.
            Directionality(
              textDirection: TextDirection.ltr,
              child: Text(
                '↓ ${fmtBytes(state.downBytes)} · ↑ ${fmtBytes(state.upBytes)}',
                style: Ember.caption,
              ),
            ),
          ],
        ],
        const SizedBox(height: 20),
        // The exit-region card: a tap opens the region list (the
        // Servers tab in this mode).
        GlassCard(
          onTap: widget.onOpenServers,
          child: Row(
            children: [
              FlagCircle(code: shownCode),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      shownCode.isEmpty
                          ? l.psiphonRegionAuto
                          : (englishCountryNames[shownCode] ?? shownCode),
                      style: Ember.heading,
                    ),
                    Text(
                      on && actual.isNotEmpty ? l.psiphonExitRegion : l.region,
                      style: Ember.caption,
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_left_rounded, color: Ember.faint),
            ],
          ),
        ),
        if (on && exit != null) ...[
          const SizedBox(height: 12),
          GlassCard(
            child: Row(
              children: [
                const Icon(Icons.public_rounded, size: 16, color: Ember.dim),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    exit.line,
                    style: Ember.body,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ],
        if (running && !state.vpnMode) ...[
          const SizedBox(height: 12),
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l.psiphonLocalProxies, style: Ember.heading),
                const SizedBox(height: 8),
                Text(
                  'SOCKS  127.0.0.1:${PsiphonPlatform.socksPort}',
                  style: Ember.body,
                ),
                const SizedBox(height: 4),
                Text(
                  'HTTP  127.0.0.1:${PsiphonPlatform.httpPort}',
                  style: Ember.body,
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// The Lantern home: the same power ring and status grammar as the
/// Psiphon home, driven by the core's own state — connecting until
/// the core reports its tunnel, then the session line, the server
/// the free plan landed on, and the exit line looked up through the
/// tunnel itself. The core exposes no session byte counters to the
/// mobile bindings, so — unlike Psiphon — no rates or totals are
/// shown; inventing them would be worse than omitting them.
class _LanternHome extends StatefulWidget {
  const _LanternHome({required this.lantern, required this.onOpenServers});

  final LanternController lantern;
  final VoidCallback onOpenServers;

  @override
  State<_LanternHome> createState() => _LanternHomeState();
}

class _LanternHomeState extends State<_LanternHome> {
  bool _busy = false;

  Future<void> _toggle() async {
    final lantern = widget.lantern;
    final l = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      if (lantern.state.running) {
        await lantern.disconnect();
      } else {
        await lantern.connect();
      }
    } on StateError {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(l.startFailed)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final lantern = widget.lantern;
    final state = lantern.state;
    final on = state.connected;
    final running = state.running;
    final busy = _busy || lantern.connecting || (running && !on);
    final exit = lantern.exitInfo;
    // The flag: the exit lookup's country once connected, else the
    // selected server's country code when the core reports one.
    final flagCode = on && exit != null && exit.countryCode.isNotEmpty
        ? exit.countryCode
        : state.serverCountryCode;

    return Column(
      children: [
        PowerRing(on: on, busy: busy, onTap: () => unawaited(_toggle())),
        const SizedBox(height: 14),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (on) ...[
              Container(
                width: 9,
                height: 9,
                decoration: const BoxDecoration(
                  color: Ember.green,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
            ],
            Text(
              on
                  ? l.statusConnected
                  : running
                  ? l.stateConnecting
                  : l.statusDisconnected,
              style: TextStyle(
                fontSize: 21,
                fontWeight: FontWeight.w800,
                color: on ? Ember.orange : Ember.text,
              ),
            ),
          ],
        ),
        const SizedBox(height: 5),
        if (running && state.sinceMs > 0)
          _SessionLine(
            startedAt: DateTime.fromMillisecondsSinceEpoch(state.sinceMs),
            caption: l.secureConnection,
          )
        else
          Text(l.secureConnection, style: Ember.dimStyle),
        const SizedBox(height: 20),
        // The server card: a tap opens the server view (the Servers
        // tab in this mode). The free plan auto-selects; once the
        // core has landed somewhere it says where.
        GlassCard(
          onTap: widget.onOpenServers,
          child: Row(
            children: [
              FlagCircle(code: flagCode),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      on && state.serverLine.isNotEmpty
                          ? state.serverLine
                          : l.lanternAutoFree,
                      style: Ember.heading,
                    ),
                    Text(
                      on && state.serverLine.isNotEmpty
                          ? l.lanternServer
                          : l.region,
                      style: Ember.caption,
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_left_rounded, color: Ember.faint),
            ],
          ),
        ),
        if (on && exit != null) ...[
          const SizedBox(height: 12),
          GlassCard(
            child: Row(
              children: [
                const Icon(Icons.public_rounded, size: 16, color: Ember.dim),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    exit.line,
                    style: Ember.body,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ],
        if (running) ...[
          const SizedBox(height: 12),
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l.lanternLocalProxy, style: Ember.heading),
                const SizedBox(height: 8),
                Text(
                  'SOCKS / HTTP  127.0.0.1:${LanternPlatform.socksPort}',
                  style: Ember.body,
                ),
                if (state.capAllotted != null && state.capUsed != null) ...[
                  const SizedBox(height: 6),
                  Directionality(
                    textDirection: TextDirection.ltr,
                    child: Text(
                      '${l.lanternDataCap}: ${fmtBytes(state.capUsed!)} / '
                      '${fmtBytes(state.capAllotted!)}',
                      style: Ember.body,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
        // The failed-start card, mirroring the WARP home: a failed
        // attempt stays visible (with the service's own reason when
        // it reported one) instead of vanishing behind a snackbar.
        if (state.failed && !on && !running) ...[
          const SizedBox(height: 12),
          GlassCard(
            child: Row(
              children: [
                const Icon(
                  Icons.error_outline_rounded,
                  size: 16,
                  color: Ember.red,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    state.failure.isNotEmpty
                        ? '${l.startFailed} — ${state.failure}'
                        : '${l.startFailed} — ${l.lanternLogs}',
                    style: Ember.body,
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// The WARP+ home: the same power ring and status grammar as the
/// Psiphon home. The core is warp-plus as a subprocess: it registers
/// its anonymous identity, optionally scans endpoints, and only
/// serves its proxy after its own connectivity test passes — so the
/// ring lights when the service says connected. Session traffic
/// comes from the service's per-UID counters, like the Xray home's.
class _WarpHome extends StatefulWidget {
  const _WarpHome({required this.warp, required this.onOpenServers});

  final WarpController warp;
  final VoidCallback onOpenServers;

  @override
  State<_WarpHome> createState() => _WarpHomeState();
}

class _WarpHomeState extends State<_WarpHome> {
  bool _busy = false;

  Future<void> _toggle() async {
    final warp = widget.warp;
    final l = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      if (warp.state.active) {
        await warp.disconnect();
      } else {
        await warp.connect();
      }
    } on StateError {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(l.startFailed)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final warp = widget.warp;
    final state = warp.state;
    final on = state.connected;
    final active = state.active;
    final busy = _busy || warp.connecting || (active && !on);
    final settings = warp.settings;
    final exit = warp.exitInfo;

    return Column(
      children: [
        PowerRing(on: on, busy: busy, onTap: () => unawaited(_toggle())),
        const SizedBox(height: 14),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (on) ...[
              Container(
                width: 9,
                height: 9,
                decoration: const BoxDecoration(
                  color: Ember.green,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
            ],
            Text(
              on
                  ? l.statusConnected
                  : active
                  ? l.stateConnecting
                  : l.statusDisconnected,
              style: TextStyle(
                fontSize: 21,
                fontWeight: FontWeight.w800,
                color: on ? Ember.orange : Ember.text,
              ),
            ),
          ],
        ),
        const SizedBox(height: 5),
        if (state.running && state.sinceMs > 0)
          _SessionLine(
            startedAt: DateTime.fromMillisecondsSinceEpoch(state.sinceMs),
            caption: l.secureConnection,
          )
        else
          Text(l.secureConnection, style: Ember.dimStyle),
        if (state.running) ...[
          const SizedBox(height: 8),
          _RatesRow(upRate: warp.upRate, downRate: warp.downRate),
          if (state.upBytes > 0 || state.downBytes > 0) ...[
            const SizedBox(height: 7),
            // Fully-English LTR totals line, like the V2Ray one.
            Directionality(
              textDirection: TextDirection.ltr,
              child: Text(
                '↓ ${fmtBytes(state.downBytes)} · ↑ ${fmtBytes(state.upBytes)}',
                style: Ember.caption,
              ),
            ),
          ],
        ],
        const SizedBox(height: 20),
        // The mode card: the active connection setup; a tap opens
        // the setup summary (the Servers tab in this mode).
        GlassCard(
          onTap: widget.onOpenServers,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: const BoxDecoration(
                      color: Ember.cardSoft,
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: const Text('🌀', style: TextStyle(fontSize: 19)),
                  ),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          active && state.mode.isNotEmpty
                              ? state.mode
                              : warpModeLabel(l, settings.mode),
                          style: Ember.heading,
                        ),
                        Text(
                          settings.endpoint.trim().isEmpty
                              ? '${l.warpEndpoint}: ${l.warpEndpointAuto}'
                              : '${l.warpEndpoint}: ${settings.endpoint.trim()}',
                          style: Ember.caption,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_left_rounded, color: Ember.faint),
                ],
              ),
              const SizedBox(height: 11),
              Wrap(
                spacing: 7,
                runSpacing: 7,
                children: [
                  const EmberChip(label: 'WireGuard'),
                  if (settings.mode == WarpMode.gool)
                    EmberChip(label: l.warpModeGool, dot: Ember.green),
                  if (settings.mode == WarpMode.cfon)
                    EmberChip(
                      label: '${l.warpModeCfon} · ${settings.country}',
                      dot: Ember.green,
                    ),
                  if (settings.scan)
                    EmberChip(label: l.warpScan, dot: Ember.green),
                ],
              ),
            ],
          ),
        ),
        if (on && exit != null) ...[
          const SizedBox(height: 12),
          GlassCard(
            child: Row(
              children: [
                const Icon(Icons.public_rounded, size: 16, color: Ember.dim),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    exit.line,
                    style: Ember.body,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ],
        if (state.failed && !active) ...[
          const SizedBox(height: 12),
          GlassCard(
            child: Row(
              children: [
                const Icon(
                  Icons.error_outline_rounded,
                  size: 16,
                  color: Ember.red,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${l.startFailed} — ${l.warpLogs}',
                    style: Ember.body,
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// a•••@domain, as the mockups show the account names.
String maskEmail(String email) {
  final at = email.indexOf('@');
  if (at <= 1) return email;
  return '${email[0]}•••${email.substring(at)}';
}
