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
import '../../urnetwork/ur_engine_controller.dart';
import '../../xray/xray_controller.dart';
import '../../xray/xray_models.dart';
import '../../net/exit_quality.dart';
import 'aether_pages.dart';
import 'dnstt_settings_page.dart';
import 'olcrtc_settings_page.dart';
import 'dpi_lab_page.dart';
import 'ember_format.dart';
import 'ember_theme.dart';
import 'lantern_pages.dart';
import 'map_widgets.dart';
import 'quick_presets.dart';
import 'openvpn_pages.dart';
import 'psiphon_pages.dart';
import 'urnetwork_engine_pages.dart';
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
    this.ur,
    required this.mode,
    required this.onModeChanged,
    required this.onOpenServers,
    required this.onOpenAccounts,
    required this.stopOtherEngine,
    this.onPowerTap,
  });

  final CoreController core;
  final XrayController xray;
  final PsiphonController psiphon;
  final LanternController lantern;
  final OpenVpnController openvpn;
  final AetherController warp;
  final AetherController masque;

  /// The URnetwork engine (build 2156, mode 8). Optional:
  /// tests construct EmberHome directly; mode 8 without a
  /// controller falls back to the Mozilla home rather than
  /// crashing.
  final UrEngineController? ur;
  final int mode;
  final ValueChanged<int> onModeChanged;
  final VoidCallback onOpenServers;
  final VoidCallback onOpenAccounts;

  /// Build 2145 (composition rebuild, binding decision 1):
  /// the shell's power closure — the identical callback the
  /// control bar's pill uses — offered to the homes whose
  /// hero composition carries its own tap zone (the V2Ray
  /// disconnected ring, the Psiphon status word). Optional:
  /// tests construct EmberHome directly, and a null callback
  /// leaves those zones inert.
  final VoidCallback? onPowerTap;

  /// Kept for the shell's wiring compatibility; the shell owns
  /// the toggles (and the arbitration) in the Map Control shell.
  final Future<void> Function() stopOtherEngine;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      // Build 2136 (visual review V-21): the home page used
      // to merge all seven engine controllers, so EVERY
      // engine's tick (the Xray stats poll above all)
      // rebuilt the visible page even when another engine
      // owned it. Each mode now listens only to its own
      // controller — the actors layer's pattern since
      // build 2092. Mode changes arrive from the shell,
      // which rebuilds this widget with the new mode.
      listenable: switch (mode) {
        0 => core,
        1 => xray,
        2 => psiphon,
        3 => lantern,
        4 => openvpn,
        5 => xray,
        6 => warp,
        7 => masque,
        8 => ur ?? core,
        _ => core,
      },
      builder: (context, _) => switch (mode) {
        0 => _MozillaHome(core: core, onOpenAccounts: onOpenAccounts),
        1 => _V2rayHome(
          xray: xray,
          onOpenServers: onOpenServers,
          onOpenAccounts: onOpenAccounts,
          stopOtherEngine: stopOtherEngine,
          onPowerTap: onPowerTap,
        ),
        2 => _PsiphonHome(psiphon: psiphon, onPowerTap: onPowerTap),
        3 => LanternHomePage(lantern: lantern),
        4 => OpenVpnHomePage(openvpn: openvpn, onOpenServers: onOpenServers),
        5 => WireGuardHomePage(xray: xray, onOpenServers: onOpenServers),
        6 => WarpHomePage(warp: warp),
        7 => MasqueHomePage(masque: masque),
        8 =>
          ur == null
              ? _MozillaHome(core: core, onOpenAccounts: onOpenAccounts)
              : UrHomePage(ur: ur!),
        _ => _MozillaHome(core: core, onOpenAccounts: onOpenAccounts),
      },
    );
  }
}

/// Build 2092 (item 14): the loading / failure card —
/// same glass as the sign-in card, its own words.
/// Build 2145 (UI-review fix A10): a widget class now, not a
/// Widget-returning method on _MozillaHome.
class _NoticeCard extends StatelessWidget {
  const _NoticeCard({
    required this.title,
    required this.body,
    this.spinner = false,
    this.action,
  });

  final String title;
  final String body;
  final bool spinner;
  final Widget? action;
@override
Widget build(BuildContext context) {
  return ListView(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
    children: [
      const SizedBox(height: 48),
      // Build 2145 (composition rebuild): the notice cards
      // are hairline panels now, not glass.
      _HairlinePanel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (spinner)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Ember.orange,
                    ),
                  )
                else
                  const Icon(
                    Icons.error_outline_rounded,
                    size: 16,
                    color: MapUi.dim,
                  ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    title,
                    style: Ember.heading,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(body, style: Ember.caption),
            if (action != null) ...[
              const SizedBox(height: 12),
              action!,
            ],
          ],
        ),
      ),
    ],
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
    // Build 2092 (UI audit item 14): loading and failure are
    // states of their own. A still-loading core (status not
    // yet in, account list not yet loaded) and a dead core
    // used to fall through to the sign-in card below — the
    // home told the user to sign in when the core simply had
    // not answered, or had died.
    if (status == null || core.accounts == null) {
      return const _NoticeCard(
        spinner: true,
        title: 'Starting Mozilla…',
        body: 'The Mozilla core is still loading.',
      );
    }
    if (core.unavailable != null) {
      return _NoticeCard(
        title: 'Mozilla is not answering',
        body:
            'The Mozilla core stopped responding. Retry, or '
            'pick another engine above.',
        action: MapActionPill(
          icon: Icons.refresh_rounded,
          label: 'Retry',
          primary: true,
          onTap: core.retry,
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      children: [
        const SizedBox(height: 48),
        _HairlinePanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.person_rounded, size: 16, color: MapUi.dim),
                  const SizedBox(width: 7),
                  // Build 2092 (item 60): the heading flexes —
                  // it had no Expanded/ellipsis.
                  Expanded(
                    child: Text(
                      'Mozilla needs an account',
                      style: Ember.heading,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Sign in with a Firefox account in Account to use '
                'Mozilla. If Mozilla is blocked in this region, '
                'tap Prepare now in Account to fetch its pass '
                'through another engine first — the tunnel itself '
                'then connects directly.',
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
    required this.stopOtherEngine,
    required this.onPowerTap,
  });

  final XrayController xray;
  final VoidCallback onOpenServers;
  final VoidCallback onOpenAccounts;
  final Future<void> Function() stopOtherEngine;
  final VoidCallback? onPowerTap;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final on = xray.state.running;
    final p = xray.selected;
    final sub = p == null ? null : xray.subscriptionOf(p);

    // Build 2074 (audit item 3): the top spacer is a capped
    // fraction of the viewport, not a fixed 150 dp — small or
    // landscape screens keep the card in the first viewport.
    // Build 2092 (audit item 39): the fraction reads the
    // page's OWN height (this ListView's LayoutBuilder), not
    // the full device height — see emberHomeTopGap.
    return LayoutBuilder(
      builder: (context, constraints) {
        final topGap = emberHomeTopGap(constraints.maxHeight);
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          children: [
            SizedBox(height: topGap),
        // Build 2145 (composition rebuild, pro5 samples):
        // the heroes ride above the config block, under the
        // map zone. Connecting is the proof-ladder
        // composition (binding decisions 3–4: real stage
        // state only, no percent figure, no cancel pill);
        // disconnected is the power-ring composition
        // (decisions 1–2). The connected hero is 2144's,
        // verified against pro3 and kept.
        if (xray.connecting) ...[
          _ConnectingLadder(xray: xray),
          const SizedBox(height: 16),
        ] else if (!on) ...[
          _DisconnectedHero(onPowerTap: onPowerTap),
          const SizedBox(height: 18),
        ],
        if (on && p != null) ...[
          // R1 (pro3): the connected hero sits in the page's
          // lower half like the sample — the map band above
          // it stays empty but for the arc. The shared top
          // gap is tuned for the ring states (pro5), so the
          // connected composition adds its own drop; the
          // config block and everything under it scroll, the
          // way pro5's detail state sanctions.
          const SizedBox(height: 170),
          _ConnectedHero(xray: xray, profile: p),
          const SizedBox(height: 12),
        ],
        // Build 2145 (composition rebuild, pro6-v2ray
        // sample): the luminous glass config card is
        // REPLACED by the sample's open composition — a
        // tracked orange label, the config name, and a mono
        // meta line (protocol · security · transport · port,
        // real Profile fields only). R1 (pro3 home): the
        // name drops to the display tier and the block's own
        // delay numeral is GONE — the connected hero above
        // carries the one numeral, as in the sample. The
        // whole block still taps through to the
        // Servers tab; the engine/plugin chips, the exit
        // and AWG lines, every notice row, the profile
        // totals and the lab-offer row that lived inside
        // the glass card ride under the composition,
        // unchanged. The DOWN/UP/SESSION tiles LEAVE this
        // block for the detail section's throughput panel.
        GestureDetector(
          behavior: HitTestBehavior.opaque,
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
                    Text(
                      'V2RAY · SELECTED CONFIG',
                      style: Ember.microLabelOrange,
                    ),
                    const SizedBox(height: 10),
                    // R1 (pro3 home): the block goes quiet —
                    // the delay numeral lives ONLY in the hero
                    // above it now (the block used to repeat it
                    // at hero scale, a second competing hero),
                    // and the name drops to the display tier so
                    // the hero word and numeral own the page.
                    // The failed-delay wording stays under the
                    // meta line, as before.
                    Text(
                      p.displayName,
                      style: const TextStyle(
                        fontSize: Ember.fontDisplay,
                        fontWeight: FontWeight.w300,
                        color: Ember.text,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _configMetaLine(p),
                      style: Ember.caption.copyWith(fontFamily: 'monospace'),
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (p.delayFailed) ...[
                      const SizedBox(height: 4),
                      Text(
                        '${l.pingLabel}: Failed',
                        style: Ember.caption,
                      ),
                    ],
                    const SizedBox(height: 12),
                    // Build 2145: the protocol / security /
                    // ping chips are gone — the meta line and
                    // the big numeral above carry that data
                    // now. The engine and plugin badges stay:
                    // they are live state, not decoration.
                    if (_hasEngineChips(xray, p)) ...[
                      Wrap(
                        spacing: 7,
                        runSpacing: 7,
                        children: [
                          // Build 2075: protocols the Xray core
                          // cannot serve but a sidecar engine can
                          // (TUIC, Snell, Naive, Tailscale,
                          // OpenConnect, Mieru) carry their engine
                          // badge; the red unsupported chip is only
                          // for protocols nothing serves.
                          if (xray.servedViaSidecar(p) &&
                              !p.protocol.servedByMieru)
                            const EmberChip(label: 'via sing-box')
                          else if (p.protocol.servedByMieru)
                            const EmberChip(label: 'via Mieru')
                          else if (!p.protocol.supportedByCore)
                            EmberChip(
                              label: l.unsupportedProtocol,
                              dot: Ember.red,
                            ),
                          // The Shadowsocks plugin is stored but
                          // never applied (build 2057, audit F-M11):
                          // the core has no plugin support, so the
                          // badge says so where the profile is
                          // shown — a plugin profile that connects
                          // runs without its plugin. Build 2126:
                          // a shadow-tls plugin with fronting on
                          // IS applied (by the sing-box engine —
                          // the chip above says so), so the badge
                          // must not run for a diverted profile.
                          if (p.hasUnsupportedPlugin &&
                              !xray.shadowTlsServed(p))
                            const EmberChip(
                              label: 'Plugin not applied',
                              dot: Ember.warn,
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
                    // Build 2106 (journey audit F-04): Provider
                    // DNS was on but no pin landed — the card
                    // says so instead of letting the session
                    // present itself as protected.
                    if (xray.providerDnsNotice.isNotEmpty) ...[
                      const SizedBox(height: 11),
                      Row(
                        children: [
                          const Icon(
                            Icons.dns_rounded,
                            size: 15,
                            color: Ember.orange,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              xray.providerDnsNotice,
                              style: Ember.caption,
                              overflow: TextOverflow.ellipsis,
                              maxLines: 2,
                            ),
                          ),
                        ],
                      ),
                    ],
                    // Build 2107: a connect just failed with the
                    // DPI Strategy Lab on — the Lab is offered
                    // here, never auto-run. Tapping opens the
                    // wizard with the failed config preselected.
                    if (xray.settings.dpiLabEnabled &&
                        xray.dpiLabOfferProfileId.isNotEmpty) ...[
                      const SizedBox(height: 11),
                      _labOfferRow(context, xray),
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
        // Build 2116 (B13-9, 2107-L6): with no selected
        // profile the in-card offer row above is unreachable
        // — exactly the state a pending offer can be in when
        // its profile has left the list. Surface the same
        // offer on its own card.
        if (p == null &&
            xray.settings.dpiLabEnabled &&
            xray.dpiLabOfferProfileId.isNotEmpty) ...[
          const SizedBox(height: 12),
          _HairlinePanel(child: _labOfferRow(context, xray)),
        ],
        // Build 2145 (composition rebuild, pro5 detail
        // sample): the connected detail section opens with
        // the tracked status strip — real exit place and
        // delay only, each part dropped when its data is
        // absent — then the throughput hairline panel the
        // config card's DOWN/UP tiles moved into.
        if (on && p != null) ...[
          const SizedBox(height: 18),
          Center(
            child: Text(
              [
                'CONNECTED',
                if (xray.exitInfo != null &&
                    xray.exitInfo!.displayName.isNotEmpty)
                  xray.exitInfo!.displayName.toUpperCase(),
                if (p.delayMs >= 0) '${latDigits(p.delayMs)} MS',
              ].join(' · '),
              style: Ember.microLabel.copyWith(color: Ember.text),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(height: 12),
          _ThroughputPanel(xray: xray),
        ],
        // Session summary (build 2075, feature items 13 +
        // 19): the running session at a glance — config,
        // node health, duration, traffic — plus the exit-IP
        // quality check.
        if (on && p != null) ...[
          const SizedBox(height: 12),
          _SessionSummaryCard(xray: xray, profile: p),
        ],
        if (sub != null && sub.totalBytes > 0) ...[
          const SizedBox(height: 12),
          // Build 2145 (composition rebuild, pro6-v2ray
          // sample): the subscription glass card and its
          // UsageRing are replaced by the sample's hairline
          // panel — the tracked name line with the orange
          // remaining figure at the right, a 2 px progress
          // line of the REMAINING fraction under it, and the
          // used / days-left / profile-count facts as micro
          // lines. The tap still opens Accounts.
          _HairlinePanel(
            onTap: onOpenAccounts,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    // Build 2074 (audit item 16): a long
                    // provider name ellipsises on one line
                    // instead of wrapping the panel apart.
                    Expanded(
                      child: Text(
                        'SUBSCRIPTION · ${sub.name.toUpperCase()}',
                        style: Ember.microLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      '${fmtGigabytes(sub.remainingBytes)} / '
                      '${fmtGigabytes(sub.totalBytes)} GB LEFT',
                      style: Ember.microLabelOrange,
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Stack(
                  children: [
                    Container(height: 2, color: MapUi.line),
                    FractionallySizedBox(
                      widthFactor: (sub.remainingBytes / sub.totalBytes)
                          .clamp(0.0, 1.0),
                      child: Container(height: 2, color: Ember.orange),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  l.subUsedOf(
                    fmtGigabytes(sub.usedBytes),
                    fmtGigabytes(sub.totalBytes),
                  ),
                  style: Ember.dimStyle,
                ),
                if (sub.remainingDays >= 0) ...[
                  const SizedBox(height: 5),
                  Text(
                    l.daysLeft(latDigits(sub.remainingDays)),
                    style: Ember.microLabel,
                  ),
                ],
                const SizedBox(height: 5),
                Text(
                  l.profilesCount(latDigits(xray.profilesOf(sub).length)),
                  style: Ember.microLabel,
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 12),
        // Build 2095 (feature 11): one-click presets.
        QuickPresetsCard(xray: xray, stopOtherEngine: stopOtherEngine),
        const SizedBox(height: 12),
        _UnderlayCard(xray: xray),
        const SizedBox(height: 12),
        _WarpCard(xray: xray),
        const SizedBox(height: 12),
        _ConnectionCheckCard(xray: xray),
          ],
        );
      },
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
    // Build 2098 (post-2097 audit M16): the live line names
    // the SESSION's underlay (captured at connect), not the
    // current setting — changing the chip mid-session used
    // to rewrite what the running session was described as
    // running over, and a 'none' setting fell through to
    // "Psiphon".
    final sessionUnderlay = xray.sessionUnderlay;
    // Build 2144 (reskin, pro5 detail sample): the UNDERLAY
    // panel's right-hand value — the session's underlay while
    // live, the chosen one otherwise, in the chips' own names.
    final valueName = switch (live ? sessionUnderlay : underlay) {
      'warp' => 'EmberWarp',
      'dnstt' => 'DNSTT',
      'olcrtc' => 'OLCRTC',
      'psiphon' => 'Psiphon',
      _ => 'None',
    };
    // Build 2145 (composition rebuild, pro5 detail sample):
    // the underlay card is a hairline panel now — same title
    // micro-label and current value, same chips as the
    // control, same DNSTT / OLCRTC affordances.
    return _HairlinePanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.layers_rounded, size: 16, color: MapUi.dim),
              const SizedBox(width: 7),
              Text('Underlay', style: Ember.microLabel),
              const Spacer(),
              Text(valueName, style: Ember.dimStyle),
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
              EmberChip(
                label: 'OLCRTC',
                selected: underlay == 'olcrtc',
                onTap: () => xray.setUnderlay('olcrtc'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            live
                ? 'This session is running over '
                      '${sessionUnderlay == 'warp'
                          ? 'EmberWarp'
                          : sessionUnderlay == 'dnstt'
                          ? 'DNSTT'
                          : sessionUnderlay == 'olcrtc'
                          ? 'OLCRTC'
                          : sessionUnderlay == 'psiphon'
                          ? 'Psiphon'
                          : 'an underlay tunnel'}.'
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
                : underlay == 'olcrtc'
                ? 'V2Ray sessions will connect through a WebRTC '
                      'video-call tunnel (OLCRTC) underneath — '
                      'it needs your olcrtc server in the same '
                      'call room at the other end.'
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
          if (underlay == 'olcrtc') ...[
            const SizedBox(height: 10),
            MapActionPill(
              icon: Icons.video_call_rounded,
              label: 'OLCRTC settings',
              onTap: () => openOlcrtcSettings(context, xray),
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
    // Build 2145: hairline panel (contents/callbacks intact).
    return _HairlinePanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.shield_rounded, size: 16, color: MapUi.dim),
              const SizedBox(width: 7),
              Text('EmberWarp', style: Ember.microLabel),
            ],
          ),
          // Build 2092 (item 40): the two pills ride their own
          // row under the heading — heading + Spacer + both
          // pills in one Row overflowed at 320 dp / large font.
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
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
    // Build 2145: hairline panel (contents/callbacks intact).
    return _HairlinePanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.fact_check_rounded, size: 16, color: MapUi.dim),
              const SizedBox(width: 7),
              Text('Connection check', style: Ember.microLabel),
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
  const _PsiphonHome({required this.psiphon, required this.onPowerTap});

  final PsiphonController psiphon;
  final VoidCallback? onPowerTap;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final state = psiphon.state;
    final on = state.connected;
    final exit = psiphon.exitInfo;
    // Build 2074 (audit item 3): same capped-fraction spacer
    // as the V2Ray home — min(150, 18% of the viewport).
    // Build 2092 (item 39): page-height derivation, as there.
    return LayoutBuilder(
      builder: (context, constraints) {
        final topGap = emberHomeTopGap(constraints.maxHeight);
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          children: [
            SizedBox(height: topGap),
        // Build 2145 (composition rebuild): the Psiphon hero
        // is open composition — the status word at hero
        // scale with the exit line open under it, no glass
        // hero card (the exit line's old glass strip is
        // folded in here). The hero is a tap zone for the
        // shell's power closure, like the V2Ray ring.
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onPowerTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                on
                    ? 'Connected'
                    : state.running
                    ? 'Connecting\u2026'
                    : 'Disconnected',
                style: Ember.hero,
              ),
              if (on && exit != null) ...[
                const SizedBox(height: 4),
                Text(
                  exit.line,
                  style: Ember.dimStyle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 14),
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
        if (state.running && !state.vpnMode) ...[
          const SizedBox(height: 12),
          // Build 2145: the local-proxy card is a hairline
          // panel now (contents intact).
          _HairlinePanel(
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
                // Build 2095 (third-pass audit 7-2): the
                // HTTP line is gone — the transplant core
                // serves SOCKS only and nothing listens on
                // the HTTP port (the About surface was
                // fixed the same way in batch 8).
              ],
            ),
          ),
        ],
          ],
        );
      },
    );
  }
}

/// a•••@domain, as the mockups show the account names.
String maskEmail(String email) {
  final at = email.indexOf('@');
  if (at <= 1) return email;
  return '${email[0]}•••${email.substring(at)}';
}

/// The connected hero (build 2144, pro3 sample): under the
/// map zone — the status word in the hero style, the exit
/// line in dim, then the last delay test as the huge light
/// numeral with PING tracked under it, and the session age
/// and the profile's traffic stacked at the right with
/// micro-labels. Every figure is data the card below already
/// shows (the profile's delay test, the session age, the
/// profile's persisted totals) — nothing is invented; the
/// numeral is the delay TEST result, exactly as the card's
/// ping chip labels it.
class _ConnectedHero extends StatelessWidget {
  const _ConnectedHero({required this.xray, required this.profile});

  final XrayController xray;
  final Profile profile;

  @override
  Widget build(BuildContext context) {
    final exit = xray.exitInfo;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Connected', style: Ember.hero),
        if (exit != null) ...[
          const SizedBox(height: 4),
          Text(
            exit.line,
            style: Ember.dimStyle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
        const SizedBox(height: 14),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Build 2145 (UI-review fix A9): the
                      // numeral renders at its true size (no
                      // FittedBox shrink against the text
                      // scale); the Flexible slot ellipsizes
                      // only at extreme scale/width pairs.
                      Flexible(
                        child: Text(
                          profile.delayMs >= 0
                              ? latDigits(profile.delayMs)
                              : '\u2014',
                          // Build 2147 (#22): the connected delay
                          // numeral wears the 2116 health colour
                          // (no reading → faint, via pingColor's
                          // ms < 0 arm), never plain white.
                          style: Ember.numeral.copyWith(
                            color: mapPingColor(profile.delayMs),
                          ),
                          maxLines: 1,
                          softWrap: false,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Padding(
                        padding: const EdgeInsets.only(top: 14),
                        child: Text('ms', style: Ember.dimStyle),
                      ),
                    ],
                  ),
                  Text('PING', style: Ember.microLabel),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _fmtSessionAge(xray.state.sinceMs),
                  style: const TextStyle(
                    fontSize: Ember.fontDisplay,
                    fontWeight: FontWeight.w300,
                    color: Ember.text,
                  ),
                ),
                Text('SESSION', style: Ember.microLabel),
                const SizedBox(height: 10),
                Text(
                  fmtBytes(profile.totalUpBytes + profile.totalDownBytes),
                  style: const TextStyle(
                    fontSize: Ember.fontDisplay,
                    fontWeight: FontWeight.w300,
                    color: Ember.text,
                  ),
                ),
                Text('TRAFFIC', style: Ember.microLabel),
              ],
            ),
          ],
        ),
      ],
    );
  }
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
  // Build 2092 (item 62): through latDigits like every other
  // displayed number (the 2074 routing was bypassed here).
  return latDigits(
    h > 0 ? '${two(h)}:${two(m)}:${two(r)}' : '${two(m)}:${two(r)}',
  );
}

/// The session summary card (build 2075, feature item 13):
/// while a V2Ray session is up — the active config, node
/// health (last real delay + whether the exit was verified),
/// session duration and the config's traffic totals. The
/// exit-IP quality check (item 19) rides on the same card:
/// one tap looks the exit up through the tunnel and shows
/// the hosting/proxy verdict with its source named; a
/// failed lookup says so, never an invented verdict.
/// One label/value line of the session summary card.
/// Build 2145 (UI-review fix A10): a widget class now, not a
/// Widget-returning method on the card's state.
class _SummaryLine extends StatelessWidget {
  const _SummaryLine({required this.label, required this.value, this.dot});

  final String label;
  final String value;
  final Color? dot;

  @override
  Widget build(BuildContext context) => Padding(
  padding: const EdgeInsets.only(bottom: 5),
  child: Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SizedBox(
        width: 58,
        child: Text(label, style: Ember.microLabel),
      ),
      if (dot != null) ...[
        Padding(
          padding: const EdgeInsets.only(top: 5),
          child: Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
          ),
        ),
        const SizedBox(width: 6),
      ],
      Expanded(
        child: Text(
          value,
          style: Ember.body,
          overflow: TextOverflow.ellipsis,
          maxLines: 2,
        ),
      ),
    ],
  ),
);
}

class _SessionSummaryCard extends StatefulWidget {
  final XrayController xray;
  final Profile profile;

  const _SessionSummaryCard({required this.xray, required this.profile});

  @override
  State<_SessionSummaryCard> createState() => _SessionSummaryCardState();
}

class _SessionSummaryCardState extends State<_SessionSummaryCard> {
  bool _checking = false;
  ExitQuality? _quality;
  bool _checkFailed = false;

  /// True when [_quality] came from the cache, not a fresh
  /// lookup — the card then shows its age (build 2082, V-7).
  bool _fromCache = false;

  /// On-demand check with the session cache (build 2082,
  /// verification V-7): a fresh verdict for the current exit
  /// IP is reused, not re-fetched; [force] (the "Check again"
  /// button) always goes to the lookup service.
  Future<void> _checkQuality({bool force = false}) async {
    final exitIp = widget.xray.exitInfo?.ip ?? '';
    if (!force && exitIp.isNotEmpty) {
      final cached = exitQualityCache.lookup(exitIp);
      if (cached != null) {
        setState(() {
          _quality = cached;
          _checkFailed = false;
          _fromCache = true;
        });
        return;
      }
    }
    setState(() {
      _checking = true;
      _checkFailed = false;
    });
    final q = await fetchExitQuality(
      httpProxyPort: widget.xray.settings.httpPort,
      // Build 2129 (leg 6): the known exit IP lets the
      // offline range tables still name the country when
      // the online quality lookup itself fails.
      ip: exitIp.isEmpty ? null : exitIp,
    );
    if (!mounted) return;
    if (q != null) exitQualityCache.store(q);
    setState(() {
      _checking = false;
      _quality = q;
      _checkFailed = q == null;
      _fromCache = false;
    });
  }

  /// " · checked 3 min ago" when the shown verdict came from
  /// the cache, else "" — the age is read live so it never
  /// goes stale on screen.
  String get _cachedAgeSuffix {
    if (!_fromCache) return '';
    final age = exitQualityCache.age(widget.xray.exitInfo?.ip ?? '');
    if (age == null) return '';
    return ' · ${qualityAgeLabel(age)}';
  }

  @override
  Widget build(BuildContext context) {
    final xray = widget.xray;
    final p = widget.profile;
    final health = p.delayMs >= 0
        ? 'Delay ${latDigits(p.delayMs)} ms'
        : p.delayFailed
        ? 'Last delay test failed'
        : 'Not delay-tested yet';
    final exit = xray.exitInfo?.line ?? 'Exit not verified yet';
    // Build 2145 (composition rebuild, pro5 detail sample):
    // the session summary is a hairline panel — same rows
    // (Config / Node / Exit with the route-proof dot /
    // Traffic) and the exit-quality check block intact.
    return _HairlinePanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.insights_rounded, size: 16, color: Ember.orange),
              const SizedBox(width: 8),
              Text('Session', style: Ember.microLabel),
              const Spacer(),
              // Build 2144 (reskin, pro5 detail sample): the
              // SESSION panel's big light value.
              Text(
                _fmtSessionAge(xray.state.sinceMs),
                style: const TextStyle(
                  fontSize: Ember.fontDisplay,
                  fontWeight: FontWeight.w300,
                  color: Ember.text,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _SummaryLine(label: 'Config', value: p.displayName),
          _SummaryLine(label: 'Node', value: health),
          // Build 2144: the ROUTE PROOF row — a green dot
          // rides the exit line when an exit was verified,
          // exactly the data the line already reports.
          _SummaryLine(
            label: 'Exit',
            value: exit,
            dot: xray.exitInfo != null ? Ember.green : null,
          ),
          _SummaryLine(label: 'Traffic', value: fmtProfileTotals(p)),
          const SizedBox(height: 12),
          if (_quality == null && !_checking && !_checkFailed)
            EmberButton(
              label: 'Check exit-IP quality',
              onTap: () => _checkQuality(),
            ),
          if (_checking)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 6),
              child: LinearProgressIndicator(color: Ember.orange),
            ),
          if (_checkFailed)
            Text(
              'Could not check the exit IP — the lookup service did not answer.',
              style: Ember.caption,
            ),
          if (_quality != null) ...[
            Wrap(
              spacing: 7,
              runSpacing: 7,
              children: [
                EmberChip(
                  // Build 2095 (audit 5-7): an unrated
                  // verdict shows no score.
                  label: _quality!.flagsKnown
                      ? '${_quality!.label} · ${latDigits(_quality!.score)}/100'
                      : _quality!.label,
                  dot: !_quality!.flagsKnown
                      ? Ember.faint
                      : _quality!.score >= 80
                      ? mapPingColor(80)
                      : _quality!.score >= 50
                      ? Ember.warn
                      : Ember.red,
                ),
                if (_quality!.hosting) const EmberChip(label: 'Datacenter IP'),
                if (_quality!.proxy) const EmberChip(label: 'Known proxy'),
                if (_quality!.mobile) const EmberChip(label: 'Mobile network'),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '${_quality!.ip} · ${_quality!.country} ${_quality!.city} · ${_quality!.isp} — per ipwho.is$_cachedAgeSuffix',
              style: Ember.caption,
            ),
            const SizedBox(height: 10),
            EmberButton(
              label: 'Check again',
              onTap: () => _checkQuality(force: true),
            ),
          ],
        ],
      ),
    );
  }

}

/// The DPI Strategy Lab offer row (build 2107): shown
/// inside the selected profile's card after a failed
/// connect, and — build 2116 (B13-9, 2107-L6) — also on
/// its own when no profile is selected, so an offer whose
/// profile has left the list is still reachable.
Widget _labOfferRow(BuildContext context, XrayController xray) {
  return GestureDetector(
  behavior: HitTestBehavior.opaque,
  onTap: () => Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => DpiLabPage(
        xray: xray,
        initialProfileId: xray.dpiLabOfferProfileId,
      ),
    ),
  ),
  child: Row(
    children: [
      const Icon(
        Icons.science_rounded,
        size: 15,
        color: Ember.orange,
      ),
      const SizedBox(width: 6),
      Expanded(
        child: Text(
          // The offer is set for ANY
          // terminal connect failure, not
          // only a proven block — the text
          // offers a test, it does not
          // assert a cause (build 2107,
          // verification iteration 1). It
          // names the config that failed,
          // which is not necessarily the
          // config this card shows.
          xray.dpiLabOfferProfile != null
              ? 'The connection to '
                    '${xray.dpiLabOfferProfile!.displayName} '
                    'failed. Run the DPI Strategy '
                    'Lab to test which strategy '
                    'carries traffic on this '
                    'network.'
              : 'A connection failed. Run the '
                    'DPI Strategy Lab to test '
                    'which strategy carries '
                    'traffic on this network.',
          style: Ember.caption,
          overflow: TextOverflow.ellipsis,
          maxLines: 2,
        ),
      ),
      const Icon(
        Icons.chevron_right_rounded,
        size: 15,
        color: Ember.orange,
      ),
    ],
  ),
);
}

/// Build 2145 (composition rebuild): the hairline panel —
/// the detail samples' container language. A flat charcoal
/// fill and a single hairline rim; no glass gradient, no
/// blur, no luminous border. Contents and callbacks of the
/// cards it replaces are untouched; only the container
/// composition changed.
class _HairlinePanel extends StatelessWidget {
  const _HairlinePanel({required this.child, this.onTap});

  final Widget child;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final br = BorderRadius.circular(Ember.radiusPanel);
    return Container(
      decoration: BoxDecoration(
        color: MapUi.card,
        borderRadius: br,
        border: Border.all(color: MapUi.line),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: br,
        child: InkWell(
          onTap: onTap,
          borderRadius: br,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// The selected config's mono meta line (build 2145,
/// pro6-v2ray sample): protocol · security · transport ·
/// port — real Profile fields only, each segment dropped
/// when the field is empty.
String _configMetaLine(Profile p) {
  final parts = <String>[
    p.protocol.label.toUpperCase(),
    if (p.security.isNotEmpty) p.security.toUpperCase(),
    if (p.network.isNotEmpty) p.network.toUpperCase(),
    latDigits(p.port),
  ];
  return parts.join(' · ');
}

/// Whether the selected-config block has any engine /
/// plugin badge to show (build 2145) — the same conditions
/// the retired card's chip row carried.
bool _hasEngineChips(XrayController xray, Profile p) =>
    (xray.servedViaSidecar(p) && !p.protocol.servedByMieru) ||
    p.protocol.servedByMieru ||
    !p.protocol.supportedByCore ||
    (p.hasUnsupportedPlugin && !xray.shadowTlsServed(p));

/// The disconnected hero (build 2145, pro5 home-off
/// sample): a giant thin ring centred over the map band
/// with a PAINTED orange power glyph (binding decision 2 —
/// never the power icon font glyph, whose second instance
/// would collide with the control bar pill's icon in test
/// finders), the tracked CONNECT text under it, and the
/// 'Disconnected' hero word under the block. Ring + label
/// are one tap zone bound to the shell's power closure
/// (decision 1); with no closure the zone is inert. The
/// sample's 'Last exit · …' line is a standing gap — no
/// last-exit data exists in the disconnected state, so
/// nothing is shown for it.
class _DisconnectedHero extends StatelessWidget {
  const _DisconnectedHero({required this.onPowerTap});

  final VoidCallback? onPowerTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Center(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onPowerTap,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  // R1 (pro5-off): the sample's ring spans
                  // roughly two-thirds of the width — 264 dp
                  // at the owner's 411 dp surface.
                  // Build 2148 (FIX 7, class 2): at 264 the
                  // block outgrew the first viewport — the
                  // 'Disconnected' hero word was clipped at
                  // the list's bottom edge, half-painted.
                  // The ring steps to 224 and the gaps
                  // tighten so the whole composition (ring,
                  // CONNECT, hero word) fits above the fold;
                  // same composition, same proportions.
                  width: 224,
                  height: 224,
                  child: CustomPaint(painter: _PowerRingPainter()),
                ),
                const SizedBox(height: 12),
                Text(
                  'CONNECT',
                  style: const TextStyle(
                    fontSize: Ember.fontDisplay,
                    fontWeight: FontWeight.w300,
                    letterSpacing: 8,
                    color: Ember.text,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text('Disconnected', style: Ember.hero),
      ],
    );
  }
}

/// The power ring painter (build 2145): a hairline ring
/// and, centred in it, the power glyph drawn as strokes —
/// an arc open at the top and the stem through the gap.
class _PowerRingPainter extends CustomPainter {
  const _PowerRingPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = MapUi.lineStrong;
    canvas.drawCircle(center, size.width / 2 - 2, ringPaint);

    final glyphRadius = size.width * 0.125;
    final glyphPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round
      ..color = Ember.orange;
    // The arc: a full circle minus a ~70° gap at the top.
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: glyphRadius),
      -1.5708 + 0.61,
      6.2832 - 1.22,
      false,
      glyphPaint,
    );
    // The stem: from above the arc's gap down to the centre.
    canvas.drawLine(
      Offset(center.dx, center.dy - glyphRadius * 1.3),
      Offset(center.dx, center.dy - glyphRadius * 0.1),
      glyphPaint,
    );
  }

  @override
  bool shouldRepaint(_PowerRingPainter oldDelegate) => false;
}

/// The connecting composition (build 2145, pro5
/// home-connecting sample; binding decisions 3–4): an
/// indeterminate thin ring at hero scale over the tracked
/// CONNECTING label, then the three proof stages as
/// hairline rows. Every stage reads real controller state
/// only — Tunnel up = the core is running, Exit answering
/// = an exit lookup landed, Proving traffic = the session
/// was verified. Done wears the orange check-circle, the
/// first unfinished stage spins, the rest wait hollow. No
/// percent figure (no progress value exists) and no cancel
/// pill (no live cancel path exists) — both standing gaps.
class _ConnectingLadder extends StatelessWidget {
  const _ConnectingLadder({required this.xray});

  final XrayController xray;

  @override
  Widget build(BuildContext context) {
    final stages = <(String, bool)>[
      ('Tunnel up', xray.state.running),
      ('Exit answering', xray.exitInfo != null),
      ('Proving traffic', xray.state.verified),
    ];
    final active = stages.indexWhere((s) => !s.$2);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 110,
                height: 110,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Ember.orange,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'CONNECTING',
                style: Ember.microLabelOrange.copyWith(
                  fontSize: Ember.fontTitle,
                  letterSpacing: 6,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        for (var i = 0; i < stages.length; i++) ...[
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    stages[i].$1,
                    style: stages[i].$2 || i == active
                        ? Ember.body
                        : Ember.dimStyle,
                  ),
                ),
                if (stages[i].$2)
                  const Icon(
                    Icons.check_circle_outline_rounded,
                    size: 22,
                    color: Ember.orange,
                  )
                else if (i == active)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Ember.orange,
                    ),
                  )
                else
                  Container(
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: MapUi.lineStrong),
                    ),
                  ),
              ],
            ),
          ),
          if (i < stages.length - 1)
            Container(height: 1, color: MapUi.line),
        ],
      ],
    );
  }
}

/// The throughput panel (build 2145, pro5 detail sample):
/// the session's current DOWN / UP rates at hero scale
/// with tracked micro-labels, over the rate chart. This is
/// where the config card's DOWN/UP tiles moved to; the
/// values are the controller's live rates via fmtRate,
/// exactly as the tiles showed them.
class _ThroughputPanel extends StatelessWidget {
  const _ThroughputPanel({required this.xray});

  final XrayController xray;

  @override
  Widget build(BuildContext context) {
    return _HairlinePanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: _RateColumn(label: 'DOWN', value: fmtRate(xray.downRate))),
              const SizedBox(width: 12),
              Expanded(child: _RateColumn(label: 'UP', value: fmtRate(xray.upRate))),
            ],
          ),
          const SizedBox(height: 12),
          _RateChart(xray: xray),
        ],
      ),
    );
  }

}

/// One rate column of the throughput panel: the figure at
/// hero scale with its unit small beside it — the group-head
/// figure's two-size pattern (build 2145, UI-review fixes A9
/// + A10: a widget class, and no FittedBox shrinking the
/// string against the user's text scale; the string is
/// fmtRate's, split at its last space into figure + unit).
class _RateColumn extends StatelessWidget {
  const _RateColumn({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final split = value.lastIndexOf(' ');
    final figure = split > 0 ? value.substring(0, split) : value;
    final unit = split > 0 ? value.substring(split + 1) : '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Flexible(
              child: Text(
                figure,
                style: Ember.hero,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (unit.isNotEmpty) ...[
              const SizedBox(width: 6),
              Text(unit, style: Ember.dimStyle),
            ],
          ],
        ),
        const SizedBox(height: 2),
        Text(label, style: Ember.microLabelOrange),
      ],
    );
  }
}

/// The rate chart (build 2145, pro5 detail sample; binding
/// decision 5): samples the controller's downRate on every
/// controller notification into a ~30-point ring buffer
/// and paints the sample's single orange polyline.
/// Presentational only — it reads an existing getter and
/// drives nothing.
class _RateChart extends StatefulWidget {
  const _RateChart({required this.xray});

  final XrayController xray;

  @override
  State<_RateChart> createState() => _RateChartState();
}

class _RateChartState extends State<_RateChart> {
  final List<int> _samples = [];

  @override
  void initState() {
    super.initState();
    _samples.add(widget.xray.downRate);
    widget.xray.addListener(_onTick);
  }

  @override
  void dispose() {
    widget.xray.removeListener(_onTick);
    super.dispose();
  }

  void _onTick() {
    if (!mounted) return;
    setState(() {
      _samples.add(widget.xray.downRate);
      if (_samples.length > 30) _samples.removeAt(0);
    });
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 56,
      width: double.infinity,
      child: CustomPaint(
        painter: _RateChartPainter(List<int>.of(_samples)),
      ),
    );
  }
}

class _RateChartPainter extends CustomPainter {
  const _RateChartPainter(this.samples);

  final List<int> samples;

  @override
  void paint(Canvas canvas, Size size) {
    final baseline = Paint()
      ..strokeWidth = 1
      ..color = MapUi.line;
    canvas.drawLine(
      Offset(0, size.height - 1),
      Offset(size.width, size.height - 1),
      baseline,
    );
    if (samples.length < 2) return;
    var max = 0;
    for (final s in samples) {
      if (s > max) max = s;
    }
    if (max <= 0) max = 1;
    final stepX = size.width / (samples.length - 1);
    const padTop = 4.0;
    final usable = size.height - padTop - 2;
    final path = Path();
    final dotPaint = Paint()..color = Ember.orange;
    for (var i = 0; i < samples.length; i++) {
      final x = stepX * i;
      final y = padTop + usable * (1 - samples[i] / max);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
      canvas.drawCircle(Offset(x, y), 1.5, dotPaint);
    }
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = Ember.orange;
    canvas.drawPath(path, line);
  }

  @override
  bool shouldRepaint(_RateChartPainter oldDelegate) => true;
}
