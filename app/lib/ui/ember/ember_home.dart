/// Home, Map Control edition (2.2.0): the map itself is the
/// home — the shell paints the actors (home marker, exit pin,
/// arc) and owns the power (the bottom bar's capsule). What
/// remains here is each engine's floating glass content: the
/// account and its allowance in Mozilla mode, the selected
/// config in V2Ray mode, and the exit-region panel in
/// Psiphon mode.

import 'package:flutter/material.dart';

import '../../aether/aether_controller.dart';
import '../../core/core_controller.dart';
import '../../lantern/lantern_controller.dart';
import '../../l10n/app_localizations.dart';
import '../../openvpn/openvpn_controller.dart';
import '../../psiphon/psiphon_controller.dart';
import '../../psiphon/psiphon_platform.dart';
import '../../xray/xray_controller.dart';
import '../../xray/xray_models.dart';
import 'aether_pages.dart';
import 'dnstt_settings_page.dart';
import 'ember_format.dart';
import 'ember_theme.dart';
import 'lantern_pages.dart';
import 'map_widgets.dart';
import 'openvpn_pages.dart';
import 'profile_country.dart';
import 'psiphon_pages.dart';
import 'warp_settings_page.dart';
import 'wireguard_pages.dart';

class EmberHome extends StatelessWidget {
  const EmberHome({
    super.key,
    required this.core,
    required this.xray,
    required this.psiphon,
    required this.lantern,
    required this.openvpn,
    required this.warp,
    required this.masque,
    required this.mode,
    required this.onModeChanged,
    required this.onOpenServers,
    required this.onOpenAccounts,
    required this.stopOtherEngine,
  });

  final CoreController core;
  final XrayController xray;
  final PsiphonController psiphon;
  final LanternController lantern;
  final OpenVpnController openvpn;
  final AetherController warp;
  final AetherController masque;
  final int mode;
  final ValueChanged<int> onModeChanged;
  final VoidCallback onOpenServers;
  final VoidCallback onOpenAccounts;

  /// Kept for the shell's wiring compatibility; the shell owns
  /// the toggles (and the arbitration) in the Map Control shell.
  final Future<void> Function() stopOtherEngine;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        core,
        xray,
        psiphon,
        lantern,
        openvpn,
        warp,
        masque,
      ]),
      builder: (context, _) => switch (mode) {
        0 => _MozillaHome(core: core, onOpenAccounts: onOpenAccounts),
        1 => _V2rayHome(
          xray: xray,
          onOpenServers: onOpenServers,
          onOpenAccounts: onOpenAccounts,
        ),
        2 => _PsiphonHome(psiphon: psiphon),
        3 => LanternHomePage(lantern: lantern),
        4 => OpenVpnHomePage(openvpn: openvpn, onOpenServers: onOpenServers),
        5 => WireGuardHomePage(xray: xray, onOpenServers: onOpenServers),
        6 => WarpHomePage(warp: warp),
        7 => MasqueHomePage(masque: masque),
        _ => _MozillaHome(core: core, onOpenAccounts: onOpenAccounts),
      },
    );
  }
}

/// Mozilla home: the pure map, exactly like sample 1 — no
/// floating strip — once an account or a pass is ready. The
/// account and its remaining allowance live in the Accounts
/// view (the shell header's Account pill), whose cards show
/// the signed-in account, its usage bar and the remaining
/// figure.
/// Build 2074 (audit item 2): signed out / not loaded used to
/// be the same bare map, with no next step — that state now
/// renders an empty-state glass card with the sign-in /
/// Prepare guidance, shown only in that state.
class _MozillaHome extends StatelessWidget {
  const _MozillaHome({required this.core, required this.onOpenAccounts});

  final CoreController core;
  final VoidCallback onOpenAccounts;

  @override
  Widget build(BuildContext context) {
    final status = core.status;
    final hasAccount =
        status?.activeAccount != null ||
        (core.accounts?.accounts.any((a) => a.enabled) ?? false);
    final pass = status?.pass;
    final hasPass = pass != null && pass.secondsUntilExpiry > 0;
    if (status != null && (hasAccount || hasPass)) {
      return const SizedBox.expand();
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      children: [
        const SizedBox(height: 48),
        MapGlass(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.person_rounded, size: 16, color: MapUi.dim),
                  const SizedBox(width: 7),
                  Text('Mozilla needs an account', style: Ember.heading),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Sign in with a Firefox account in Account to use '
                'Mozilla. If Mozilla is blocked in this region, '
                'use Prepare in Account to fetch its pass through '
                'another engine first — the tunnel itself then '
                'connects directly.',
                style: Ember.caption,
              ),
              const SizedBox(height: 12),
              MapActionPill(
                icon: Icons.person_rounded,
                label: 'Open Account',
                primary: true,
                onTap: onOpenAccounts,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The V2Ray home: the selected config's glass card (a tap opens
/// the configurations panel) and, when the config belongs to a
/// subscription with known usage, the subscription card.
class _V2rayHome extends StatelessWidget {
  const _V2rayHome({
    required this.xray,
    required this.onOpenServers,
    required this.onOpenAccounts,
  });

  final XrayController xray;
  final VoidCallback onOpenServers;
  final VoidCallback onOpenAccounts;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final on = xray.state.running;
    final p = xray.selected;
    final sub = p == null ? null : xray.subscriptionOf(p);
    final selectedCode = p == null ? null : profileCountryCode(p);

    // Build 2074 (audit item 3): the top spacer is a capped
    // fraction of the viewport, not a fixed 150 dp — small or
    // landscape screens keep the card in the first viewport.
    final topGap = MediaQuery.sizeOf(context).height * 0.18;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      children: [
        SizedBox(height: topGap > 150 ? 150 : topGap),
        MapGlass(
          // 2024 (Gemini audit v4, item 4): the shared luminous
          // glass rim (the Servers panel's treatment) when the
          // engine is live, replacing the flat custom border +
          // top rim line whose corner interplay read as a stray
          // orange sliver on the card's right edge.
          luminous: on,
          padding: const EdgeInsets.all(16),
          onTap: onOpenServers,
          child: p == null
              ? Row(
                  children: [
                    // Build 2027 (v7 audit arbitration): with
                    // the core RUNNING but no selected profile —
                    // reachable when a subscription refresh
                    // regenerates profile ids, or the running
                    // profile is deleted while the foreground
                    // service outlives the UI — "Choose a config
                    // first" contradicts the connected engine.
                    // Say what is actually true instead.
                    Icon(
                      on ? Icons.public_rounded : Icons.dns_outlined,
                      color: MapUi.dim,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        on
                            ? 'Connected — the running config is not '
                                  'in the list'
                            : l.noProfileSelected,
                        style: Ember.body,
                      ),
                    ),
                    const Icon(Icons.chevron_right_rounded, color: MapUi.faint),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 42,
                          height: 42,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.06),
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
                                // Build 2045: the name the user sees.
                                p.displayName,
                                style: Ember.heading,
                                overflow: TextOverflow.ellipsis,
                              ),
                              Text(
                                // Build 2074 (audit item 27):
                                // the port routes through
                                // latDigits like every number.
                                '${p.address}:${latDigits(p.port)}',
                                style: Ember.caption,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                        const Icon(
                          Icons.chevron_right_rounded,
                          color: MapUi.faint,
                        ),
                      ],
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
                              ? mapPingColor(p.delayMs)
                              : p.delayFailed
                              ? Ember.red
                              : null,
                        ),
                        if (!p.protocol.supportedByCore)
                          EmberChip(
                            label: l.unsupportedProtocol,
                            dot: Ember.red,
                          ),
                        // The Shadowsocks plugin is stored but
                        // never applied (build 2057, audit F-M11):
                        // the core has no plugin support, so the
                        // badge says so where the profile is
                        // shown — a plugin profile that connects
                        // runs without its plugin.
                        if (p.hasUnsupportedPlugin)
                          const EmberChip(
                            label: 'Plugin not applied',
                            dot: Ember.warn,
                          ),
                      ],
                    ),
                    // Sample A's live tiles (build 2050): the
                    // session's rates and age, on the card.
                    if (on) ...[
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          _HomeTile(
                            label: 'DOWN',
                            value: fmtRate(xray.downRate),
                          ),
                          const SizedBox(width: 8),
                          _HomeTile(label: 'UP', value: fmtRate(xray.upRate)),
                          const SizedBox(width: 8),
                          _HomeTile(
                            label: 'SESSION',
                            value: _fmtSessionAge(xray.state.sinceMs),
                          ),
                        ],
                      ),
                    ],
                    if (on && xray.exitInfo != null) ...[
                      const SizedBox(height: 11),
                      Row(
                        children: [
                          const Icon(
                            Icons.public_rounded,
                            size: 15,
                            color: MapUi.dim,
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
                    // AmneziaWG (build 2040): there is no exit
                    // lookup for a device with no SOCKS port, so
                    // the card shows the handshake instead — the
                    // proof the obfuscated tunnel is alive. A
                    // stale age on a quiet tunnel is normal for
                    // WireGuard, not a failure.
                    if (on && xray.awgSession) ...[
                      const SizedBox(height: 11),
                      Row(
                        children: [
                          const Icon(
                            Icons.shield_rounded,
                            size: 15,
                            color: MapUi.dim,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              xray.state.awgHandshakeAgeSec >= 0
                                  ? 'AmneziaWG · handshake ${latDigits(xray.state.awgHandshakeAgeSec)}s ago'
                                  : 'AmneziaWG · waiting for handshake…',
                              style: Ember.caption,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ],
                    if (on &&
                        (xray.state.coreProblem.isNotEmpty ||
                            xray.state.coreRestarts > 0)) ...[
                      const SizedBox(height: 11),
                      Row(
                        children: [
                          const Icon(
                            Icons.warning_amber_rounded,
                            size: 15,
                            color: Ember.orange,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              xray.state.coreProblem.isNotEmpty
                                  ? xray.state.coreProblem
                                  : 'Core restarted ${latDigits(xray.state.coreRestarts)}× this session',
                              style: Ember.caption,
                              overflow: TextOverflow.ellipsis,
                              maxLines: 2,
                            ),
                          ),
                        ],
                      ),
                    ],
                    if (xray.adaptiveNotice.isNotEmpty) ...[
                      const SizedBox(height: 11),
                      Row(
                        children: [
                          const Icon(
                            Icons.swap_horiz_rounded,
                            size: 15,
                            color: Ember.orange,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              xray.adaptiveNotice,
                              style: Ember.caption,
                              overflow: TextOverflow.ellipsis,
                              maxLines: 2,
                            ),
                          ),
                        ],
                      ),
                    ],
                    if (xray.switchNotice.isNotEmpty) ...[
                      const SizedBox(height: 11),
                      Row(
                        children: [
                          const Icon(
                            Icons.swap_horiz_rounded,
                            size: 15,
                            color: Ember.orange,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              xray.switchNotice,
                              style: Ember.caption,
                              overflow: TextOverflow.ellipsis,
                              maxLines: 2,
                            ),
                          ),
                        ],
                      ),
                    ],
                    if (xray.reconnectNotice.isNotEmpty) ...[
                      const SizedBox(height: 11),
                      Row(
                        children: [
                          const Icon(
                            Icons.autorenew_rounded,
                            size: 15,
                            color: Ember.orange,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              xray.reconnectNotice,
                              style: Ember.caption,
                              overflow: TextOverflow.ellipsis,
                              maxLines: 2,
                            ),
                          ),
                        ],
                      ),
                    ],
                    if (profileHasTotals(p)) ...[
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          const Icon(
                            Icons.data_usage_rounded,
                            size: 14,
                            color: MapUi.faint,
                          ),
                          const SizedBox(width: 6),
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
                  ],
                ),
        ),
        if (sub != null && sub.totalBytes > 0) ...[
          const SizedBox(height: 12),
          MapGlass(
            onTap: onOpenAccounts,
            padding: const EdgeInsets.all(16),
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
                      // Build 2074 (audit item 16): a long
                      // provider name ellipsises on one line
                      // instead of wrapping the card apart.
                      Text(
                        sub.name,
                        style: Ember.heading,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
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
        const SizedBox(height: 12),
        _UnderlayCard(xray: xray),
        const SizedBox(height: 12),
        _WarpCard(xray: xray),
        const SizedBox(height: 12),
        _ConnectionCheckCard(xray: xray),
      ],
    );
  }
}

/// The chain underlay toggle (build 2029A): GLOBAL, not
/// per-profile — with Psiphon chosen, every V2Ray session
/// starts the Psiphon core proxy-only first and dials through
/// it. DNSTT joined the row in build 2072 (its fields live on
/// the DNSTT settings page, opened from this card). Applies
/// to the next session; a running one keeps the shape it
/// started with.
class _UnderlayCard extends StatelessWidget {
  const _UnderlayCard({required this.xray});

  final XrayController xray;

  @override
  Widget build(BuildContext context) {
    final underlay = xray.settings.underlay;
    final live = xray.state.running && xray.state.chainUnderlay;
    return MapGlass(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.layers_rounded, size: 16, color: MapUi.dim),
              const SizedBox(width: 7),
              Text('Underlay', style: Ember.heading),
            ],
          ),
          const SizedBox(height: 10),
          // Build 2072: four underlays no longer fit the
          // header row — the chips wrap instead.
          Wrap(
            spacing: 7,
            runSpacing: 7,
            children: [
              EmberChip(
                label: 'None',
                selected: underlay == 'none',
                onTap: () => xray.setUnderlay('none'),
              ),
              EmberChip(
                label: 'Psiphon',
                selected: underlay == 'psiphon',
                onTap: () => xray.setUnderlay('psiphon'),
              ),
              EmberChip(
                label: 'EmberWarp',
                selected: underlay == 'warp',
                onTap: () => xray.setUnderlay('warp'),
              ),
              EmberChip(
                label: 'DNSTT',
                selected: underlay == 'dnstt',
                onTap: () => xray.setUnderlay('dnstt'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            live
                ? 'This session is running over '
                      '${underlay == 'warp'
                          ? 'EmberWarp'
                          : underlay == 'dnstt'
                          ? 'DNSTT'
                          : 'Psiphon'}.'
                : underlay == 'psiphon'
                ? 'V2Ray sessions will connect through a Psiphon '
                      'tunnel underneath.'
                : underlay == 'warp'
                ? 'V2Ray sessions will connect through the '
                      'EmberWarp core underneath.'
                : underlay == 'dnstt'
                ? 'V2Ray sessions will connect through a DNS '
                      'tunnel (DNSTT) underneath — it needs your '
                      'dnstt-server running at the other end.'
                : 'V2Ray sessions connect directly.',
            style: Ember.caption,
          ),
          if (underlay == 'dnstt') ...[
            const SizedBox(height: 10),
            MapActionPill(
              icon: Icons.dns_rounded,
              label: 'DNSTT settings',
              onTap: () => openDnsttSettings(context, xray),
            ),
          ],
          if (xray.chainNotice.isNotEmpty) ...[
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.warning_amber_rounded,
                  size: 15,
                  color: Ember.orange,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    xray.chainNotice,
                    style: Ember.caption,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// The EmberWarp card (build 2030; renamed from 'WARP
/// MASQUE' in build 2071, review §1.5 — the shell's Aether
/// engine is the app's 'WARP', this core is EmberWarp): the
/// EmberWarp core as a standalone tunnel — connect here and
/// the device runs over Cloudflare WARP with no Xray in the
/// path. The same core, profile and identity serve the
/// EmberWarp underlay above.
/// When Cloudflare refuses the saved identity, the Renew
/// action appears here (the ONLY renewal path — normal
/// connects never re-register silently).
class _WarpCard extends StatelessWidget {
  const _WarpCard({required this.xray});

  final XrayController xray;

  @override
  Widget build(BuildContext context) {
    final ws = xray.warpState;
    final live = xray.warpSession;
    final status = live
        ? 'Connected — this session runs over WARP.'
        : ws.renewNeeded
        ? 'Cloudflare refused the saved WARP identity.'
        : !ws.identityPresent
        ? 'No WARP identity yet — the first connect registers '
              'one (free and anonymous).'
        : 'WARP through Cloudflare’s MASQUE / WireGuard '
              'gateways.';
    return MapGlass(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.shield_rounded, size: 16, color: MapUi.dim),
              const SizedBox(width: 7),
              Text('EmberWarp', style: Ember.heading),
              const Spacer(),
              MapActionPill(
                icon: Icons.settings_rounded,
                label: 'Settings',
                onTap: () => openWarpSettings(context, xray),
              ),
              const SizedBox(width: 7),
              MapActionPill(
                icon: Icons.bolt_rounded,
                label: live
                    ? 'Disconnect'
                    : xray.connecting
                    ? 'Working…'
                    : 'Connect',
                primary: live,
                onTap: xray.connecting
                    ? null
                    : () async {
                        try {
                          if (live) {
                            await xray.disconnect();
                          } else {
                            await xray.connectWarp();
                          }
                        } catch (_) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  xray.lastError ??
                                      'The EmberWarp session could not start.',
                                ),
                              ),
                            );
                          }
                        }
                      },
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(status, style: Ember.caption),
          if (xray.reconnectNotice.isNotEmpty) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                const Icon(
                  Icons.autorenew_rounded,
                  size: 15,
                  color: Ember.orange,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    xray.reconnectNotice,
                    style: Ember.caption,
                    overflow: TextOverflow.ellipsis,
                    maxLines: 2,
                  ),
                ),
              ],
            ),
          ],
          if (ws.renewNeeded && !live) ...[
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.warning_amber_rounded,
                  size: 15,
                  color: Ember.orange,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'The saved identity is dead. Renewing '
                    'registers a fresh one — nothing else '
                    'changes.',
                    style: Ember.caption,
                  ),
                ),
                MapActionPill(
                  icon: Icons.refresh_rounded,
                  label: 'Renew WARP Key',
                  onTap: () => xray.renewWarpIdentity(),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// The guided connection check (build 2029A): staged,
/// plain-language — against the live tunnel when one is up,
/// against the selected profile when not.
class _ConnectionCheckCard extends StatelessWidget {
  const _ConnectionCheckCard({required this.xray});

  final XrayController xray;

  @override
  Widget build(BuildContext context) {
    final stages = xray.lastCheck;
    return MapGlass(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.fact_check_rounded, size: 16, color: MapUi.dim),
              const SizedBox(width: 7),
              Text('Connection check', style: Ember.heading),
              const Spacer(),
              MapActionPill(
                icon: Icons.play_arrow_rounded,
                label: xray.checking ? 'Checking…' : 'Run check',
                onTap: xray.checking ? null : () => xray.runConnectionCheck(),
              ),
            ],
          ),
          if (stages.isEmpty && !xray.checking) ...[
            const SizedBox(height: 8),
            Text(
              xray.state.running
                  ? 'Walks the live tunnel stage by stage and '
                        'says what it finds, in plain language.'
                  : 'Checks the selected server stage by stage '
                        'and says what it finds, in plain language.',
              style: Ember.caption,
            ),
          ],
          for (final stage in stages) ...[
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  stage.ok ? Icons.check_circle_rounded : Icons.cancel_rounded,
                  size: 15,
                  color: stage.ok ? Ember.green : Ember.red,
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(stage.title, style: Ember.body),
                      Text(stage.detail, style: Ember.caption),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// The Psiphon home: the exit-region panel floats over the map
/// (sample 3), with the exit line and the local-proxy card under
/// it when the state calls for them.
class _PsiphonHome extends StatelessWidget {
  const _PsiphonHome({required this.psiphon});

  final PsiphonController psiphon;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final state = psiphon.state;
    final on = state.connected;
    final exit = psiphon.exitInfo;
    // Build 2074 (audit item 3): same capped-fraction spacer
    // as the V2Ray home — min(150, 18% of the viewport).
    final topGap = MediaQuery.sizeOf(context).height * 0.18;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      children: [
        SizedBox(height: topGap > 150 ? 150 : topGap),
        // Sample 3's geometry: the region panel hugs the lower
        // LEFT so the arc and both pins keep the upper canvas.
        // 2027 (v7 audit): 0.68 -> 0.70 — the extra width is
        // what the long region names ("United Kingdom", the
        // selected pill's check mark) needed to stop clipping.
        // Build 2074 (audit item 26): 0.70 still clipped long
        // region names in a ~252 dp panel — widened to 0.90,
        // still inside the screen bounds.
        Align(
          alignment: Alignment.centerLeft,
          child: FractionallySizedBox(
            widthFactor: 0.90,
            child: PsiphonRegionsPanel(psiphon: psiphon, compact: true),
          ),
        ),
        if (on && exit != null) ...[
          const SizedBox(height: 12),
          MapGlass(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
            child: Row(
              children: [
                const Icon(Icons.public_rounded, size: 16, color: MapUi.dim),
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
        if (state.running && !state.vpnMode) ...[
          const SizedBox(height: 12),
          MapGlass(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l.psiphonLocalProxies, style: Ember.heading),
                const SizedBox(height: 8),
                // Build 2074 (audit item 27): both local-proxy
                // ports route through latDigits.
                Text(
                  'SOCKS  127.0.0.1:${latDigits(PsiphonPlatform.socksPort)}',
                  style: Ember.body,
                ),
                const SizedBox(height: 4),
                Text(
                  'HTTP  127.0.0.1:${latDigits(PsiphonPlatform.httpPort)}',
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

/// a•••@domain, as the mockups show the account names.
String maskEmail(String email) {
  final at = email.indexOf('@');
  if (at <= 1) return email;
  return '${email[0]}•••${email.substring(at)}';
}

/// One of the home connection card's live tiles (build 2050).
class _HomeTile extends StatelessWidget {
  const _HomeTile({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: MapUi.insetFill,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Ember.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              // Build 2074 (audit item 23): the tile labels
              // (DOWN / UP / SESSION) floor at 11 sp — 9 sp was
              // unreadable in daylight.
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
              color: MapUi.faint,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: MapUi.text,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    ),
  );
}

/// "04:12" / "01:04:12" for a session that started at
/// [sinceMs] (build 2050); — before the first sample.
String _fmtSessionAge(int sinceMs) {
  if (sinceMs <= 0) return '\u2014';
  var sec = (DateTime.now().millisecondsSinceEpoch - sinceMs) ~/ 1000;
  if (sec < 0) sec = 0;
  String two(int v) => v.toString().padLeft(2, '0');
  final h = sec ~/ 3600;
  final m = (sec % 3600) ~/ 60;
  final r = sec % 60;
  return h > 0 ? '${two(h)}:${two(m)}:${two(r)}' : '${two(m)}:${two(r)}';
}
