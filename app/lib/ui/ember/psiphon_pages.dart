/// The Psiphon engine's pages: the exit-region list (also the
/// Servers tab's content in this mode), the settings page (mode,
/// region, upstream proxy, transports, logs), and the no-account
/// page shown on the Accounts tab — Psiphon needs no account.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../../psiphon/psiphon_controller.dart';
import '../../psiphon/psiphon_platform.dart';
import '../../psiphon/psiphon_strategy.dart';
import '../../xray/exit_info.dart';
import 'ember_dialogs.dart';
import 'ember_format.dart';
import 'ember_theme.dart';
import 'map_widgets.dart';

String regionName(String code) => englishCountryNames[code] ?? code;

/// Build 2145 (pro6 composition rebuild): the flat hairline
/// panel — a solid card fill and a 1 px hairline edge, no
/// blur, no luminous ring — that replaces MapGlass on the
/// recomposed Psiphon surfaces.
class _HairlinePanel extends StatelessWidget {
  const _HairlinePanel({required this.child, required this.padding});

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: MapUi.card,
        border: Border.all(color: MapUi.line),
        borderRadius: MapUi.panelBorder,
      ),
      padding: padding,
      child: child,
    );
  }
}

/// The Psiphon exit-region panel: the hero header and the
/// typographic region list open over the map (build 2145,
/// pro6 sample — the glass panel of 2144 leaves) — big light
/// country names as hairline rows, the selected one carrying
/// a check and, while Psiphon runs proxy-only (the
/// chain-underlay mode, the settings page's own wording),
/// the orange micro-label tag; the chain-underlay toggle row
/// sits at the list foot, bound to that same mode setting.
/// No per-region ping exists in the app, so no numeral is
/// shown — the sample's figures are not invented here.
/// Used inline on the home page (there [compact]) and as the
/// Servers-tab view; picking a region while the tunnel is up
/// takes effect on the next connect, exactly as before.
class PsiphonRegionsPanel extends StatelessWidget {
  const PsiphonRegionsPanel({
    super.key,
    required this.psiphon,
    this.compact = false,
  });

  final PsiphonController psiphon;
  final bool compact;

  void _pick(String code) {
    // setRegion restarts a running tunnel on the new exit
    // country (build 2033) — the pick is never a dead tap.
    unawaited(psiphon.setRegion(code));
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final selected = psiphon.settings.region;
    // Build 2144 (pro6 reskin): the chain-underlay state is
    // the app's own proxy-only mode (the settings page's
    // segmented control) — while it is on, the selected
    // region's row carries its wording as the orange tag.
    final chainUnderlay = !psiphon.settings.vpnMode;
    Widget row(String code, String label) {
      final on = selected == code;
      return InkWell(
        onTap: () => _pick(code),
        child: Container(
          constraints: const BoxConstraints(minHeight: 48),
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: MapUi.line, width: 1)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        // Batch 4 (pro6-psiphon): the sample's
                        // typographic row scale (was fontDisplay).
                        // Batch 5: the size is the theme's
                        // fontRegion token (value unchanged).
                        fontSize: Ember.fontRegion,
                        fontWeight: FontWeight.w300,
                        color: on ? Ember.text : MapUi.body,
                      ),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                    if (on && chainUnderlay) ...[
                      const SizedBox(height: 4),
                      Text(l.psiphonProxyOnly, style: Ember.microLabelOrange),
                    ],
                  ],
                ),
              ),
              if (on)
                const Icon(
                  Icons.check_rounded,
                  size: 18,
                  color: Ember.orange,
                ),
            ],
          ),
        ),
      );
    }

    final list = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        row('', l.psiphonRegionAuto),
        for (final code in psiphon.regionChoices) row(code, regionName(code)),
      ],
    );
    // Build 2145 (pro6 composition rebuild): the open
    // composition — hero header, hairline rows and the
    // chain-underlay toggle row at the list foot, directly
    // over the map; no panel under them.
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Batch 4 (pro6 fidelity rollout): the sample's
        // tracked engine label over the hero (the WireGuard
        // home's pattern).
        Text('ENGINE · PSIPHON', style: Ember.microLabelOrange),
        const SizedBox(height: 10),
        // Build 2144 (pro6 reskin): the header takes the
        // samples' hero tier.
        // Build 2150 (engine appearance audit E49-03): the
        // header's own ✕ is retired — in the Servers tab it
        // duplicated the shell header's BACK on the same
        // screen; the pushed and inline uses never carried
        // one. The shell BACK is the one way out.
        Text('Exit Region', style: Ember.hero),
        const SizedBox(height: 12),
        // Build 2074 (audit item 26): no nested scroll —
        // the rows lay out in full and the page scrolls
        // them.
        // Build 2150 (audit E49-05): the rows take a settled
        // ground of their own — on the raw full-strength
        // dot field the middle rows lost their contrast
        // (every other engine list sits on a banded or
        // frosted ground; pro6-psiphon's rows ground on
        // settled near-black). The scrim is the band
        // family's ramp deepened to the list's full height:
        // no border, no radius, no card — the ground
        // settles under the rows and the hairlines and
        // names keep their exact styling.
        Stack(
          children: [
            const Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: [0, 0.35, 1],
                    colors: [
                      Color(0x59050607),
                      Color(0xD9050607),
                      Color(0xE6050607),
                    ],
                  ),
                ),
              ),
            ),
            list,
          ],
        ),
        // Build 2145: the chain-underlay toggle row at the
        // list foot (the sample's foot row). Its value is
        // the same proxy-only mode state the selected row's
        // tag reads, and its callback is the settings page's
        // own update path (a settings copy with vpnMode
        // flipped, through updateSettings) — the segmented
        // control there and this toggle drive one setting.
        Container(
          constraints: const BoxConstraints(minHeight: 48),
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              Expanded(child: Text(l.psiphonProxyOnly, style: Ember.body)),
              EmberToggle(
                value: chainUnderlay,
                onChanged: (on) {
                  final next = PsiphonSettings.fromJson(
                    psiphon.settings.toJson(),
                  );
                  next.vpnMode = !on;
                  unawaited(psiphon.updateSettings(next));
                },
              ),
            ],
          ),
        ),
        // 2024 (Gemini audit v4, item 6): the static next-connect
        // helper line that used to sit under this card is gone —
        // it floated over the map dots and Sample 3 has no such
        // line. The takes-effect-on-next-connect behavior itself
        // is unchanged.
      ],
    );
  }
}

/// The exit-region view (the Servers tab's content in Psiphon
/// mode, and pushed from the settings page).
class PsiphonRegionsView extends StatelessWidget {
  const PsiphonRegionsView({super.key, required this.psiphon});

  final PsiphonController psiphon;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: psiphon,
      builder: (context, _) {
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          children: [PsiphonRegionsPanel(psiphon: psiphon)],
        );
      },
    );
  }
}

/// The Accounts tab in Psiphon mode: there is no account — a status
/// card and the session's numbers instead.
class PsiphonAboutView extends StatelessWidget {
  const PsiphonAboutView({super.key, required this.psiphon});

  final PsiphonController psiphon;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: psiphon,
      builder: (context, _) {
        final state = psiphon.state;
        final exit = psiphon.exitInfo;
        return ListView(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
          children: [
            Center(child: Text(l.navAccounts, style: Ember.microLabel)),
            // Build 2144 (pro6 reskin): the engine name takes
            // the samples' hero tier.
            Center(child: Text('Psiphon', style: Ember.hero)),
            const SizedBox(height: 16),
            // Build 2145 (pro6 composition rebuild): the
            // about view's cards go flat — hairline panels,
            // contents unchanged.
            _HairlinePanel(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  const Icon(Icons.person_off_rounded, color: Ember.dim),
                  const SizedBox(width: 10),
                  Expanded(child: Text(l.psiphonNoAccount, style: Ember.body)),
                ],
              ),
            ),
            const SizedBox(height: 12),
            _HairlinePanel(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 9,
                        height: 9,
                        decoration: BoxDecoration(
                          color: state.connected
                              ? Ember.green
                              : state.running
                              ? Ember.amber
                              : Ember.faint,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        state.connected
                            ? l.statusConnected
                            : state.running
                            ? l.stateConnecting
                            : l.statusDisconnected,
                        style: Ember.heading,
                      ),
                    ],
                  ),
                  if (state.region.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      '${l.psiphonExitRegion}: ${regionName(state.region)}',
                      style: Ember.body,
                    ),
                  ],
                  if (exit != null) ...[
                    const SizedBox(height: 6),
                    Text(exit.line, style: Ember.body),
                  ],
                  if (state.upBytes > 0 || state.downBytes > 0) ...[
                    const SizedBox(height: 6),
                    Directionality(
                      textDirection: TextDirection.ltr,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.arrow_downward_rounded,
                            size: 14,
                            color: Ember.dim,
                          ),
                          const SizedBox(width: 3),
                          Text(fmtBytes(state.downBytes), style: Ember.body),
                          const SizedBox(width: 10),
                          const Icon(
                            Icons.arrow_upward_rounded,
                            size: 14,
                            color: Ember.dim,
                          ),
                          const SizedBox(width: 3),
                          Text(fmtBytes(state.upBytes), style: Ember.body),
                        ],
                      ),
                    ),
                  ],
                  if (!state.vpnMode && state.running) ...[
                    const SizedBox(height: 8),
                    Text(
                      // Build 2095 (whole-app journey audit
                      // #30): SOCKS only — the HTTP proxy half
                      // of this line named a port the bundled
                      // core does not serve.
                      'SOCKS 127.0.0.1:${latDigits(PsiphonPlatform.socksPort)}',
                      style: Ember.caption,
                    ),
                  ],
                  // Build 2125 (audit A25-04 / plan S-4):
                  // the kill-switch hold names itself — the
                  // session is down, but its TUN is held so
                  // traffic is blocked, never direct.
                  if (state.killSwitchHeld) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Kill switch holding: the session dropped, '
                      'and its tunnel is being held so traffic '
                      'stays blocked instead of going direct. '
                      'Reconnect or disconnect to clear it.',
                      style: Ember.caption,
                    ),
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// All of the Psiphon engine's settings on one page.
class PsiphonSettingsPage extends StatefulWidget {
  const PsiphonSettingsPage({super.key, required this.psiphon});

  final PsiphonController psiphon;

  @override
  State<PsiphonSettingsPage> createState() => _PsiphonSettingsPageState();
}

class _PsiphonSettingsPageState extends State<PsiphonSettingsPage> {
  late final TextEditingController _upstream = TextEditingController(
    text: widget.psiphon.settings.upstream,
  );

  /// Build 2095 (whole-app journey audit, §9 minor): the
  /// upstream field used to save only when the page was
  /// popped — it now also saves on submit and on focus loss.
  final FocusNode _upstreamFocus = FocusNode();

  PsiphonController get psiphon => widget.psiphon;

  @override
  void initState() {
    super.initState();
    _upstreamFocus.addListener(() {
      if (!_upstreamFocus.hasFocus) _saveUpstream();
    });
  }

  @override
  void dispose() {
    _saveUpstream();
    _upstreamFocus.dispose();
    _upstream.dispose();
    super.dispose();
  }

  void _saveUpstream() {
    final value = _upstream.text.trim();
    if (value == psiphon.settings.upstream) return;
    final next = PsiphonSettings.fromJson(psiphon.settings.toJson());
    next.upstream = value;
    unawaited(psiphon.updateSettings(next));
  }

  Future<void> _edit<T>(
    T value,
    void Function(PsiphonSettings, T) apply,
  ) async {
    final next = PsiphonSettings.fromJson(psiphon.settings.toJson());
    apply(next, value);
    await psiphon.updateSettings(next);
    if (mounted) setState(() {});
  }

  String _edgesSummary(PsiphonSettings settings) {
    final ranked = rankCdnEdges(settings.cdnEdges);
    final best = ranked.where((e) => e.lastOk && e.lastMs != null).toList();
    // Build 2074 (audit item 27): displayed numbers route
    // through latDigits().
    if (best.isNotEmpty) return '${latDigits(best.first.lastMs!)} ms';
    return '${latDigits(settings.cdnEdges.length)} edges';
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final settings = psiphon.settings;
    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Ember.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Ember.text,
        title: Text('Psiphon', style: Ember.heading),
      ),
      // Build 2150 (engine appearance audit E49-05): every
      // pushed Psiphon page takes the banded ground the
      // other engine pages already use — the plain ground
      // left these pages on the raw full-strength dot
      // field. This page and the five below alike.
      body: EmberBackground(
        banded: true,
        child: ListView(
          padding: EdgeInsets.fromLTRB(18, MediaQuery.of(context).padding.top + kToolbarHeight + 8, 18, 18),
          children: [
            Text(l.psiphonConnectionMode, style: Ember.heading),
            const SizedBox(height: 10),
            EmberSegmented<bool>(
              value: settings.vpnMode,
              onChanged: (v) => _edit(v, (s, v) => s.vpnMode = v),
              options: [
                (true, l.psiphonVpnMode, Icons.vpn_lock_rounded),
                (false, l.psiphonProxyOnly, Icons.swap_horiz_rounded),
              ],
            ),
            const SizedBox(height: 18),
            MapGlass(
        blur: false,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Column(
                children: [
                  _SettingsRow(
                    icon: Icons.public_rounded,
                    label: l.region,
                    value: settings.region.isEmpty
                        ? l.psiphonRegionAuto
                        : regionName(settings.region),
                    onTap: () async {
                      await Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => Scaffold(
                            extendBodyBehindAppBar: true,
                            backgroundColor: Ember.bg,
                            appBar: AppBar(
                              backgroundColor: Colors.transparent,
                              elevation: 0,
                              foregroundColor: Ember.text,
                              title: Text(l.region, style: Ember.heading),
                            ),
                            body: EmberBackground(
                              banded: true,
                              // Build 2138 (visual review V-26):
                              // the body extends behind the
                              // transparent bar; the regions view
                              // is shared with the shell, so the
                              // bar inset wraps it here instead
                              // of padding inside the view.
                              child: Padding(
                                padding: EdgeInsets.only(
                                  top:
                                      MediaQuery.of(context).padding.top +
                                      kToolbarHeight,
                                ),
                                child: PsiphonRegionsView(psiphon: psiphon),
                              ),
                            ),
                          ),
                        ),
                      );
                      if (mounted) setState(() {});
                    },
                  ),
                  const Divider(color: Ember.line, height: 1),
                  _SettingsRow(
                    icon: Icons.tune_rounded,
                    label: l.psiphonTransports,
                    value: settings.protocols.isEmpty
                        ? l.psiphonTransportsAuto
                        : latDigits(settings.protocols.length),
                    onTap: () async {
                      await Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) =>
                              PsiphonTransportsPage(psiphon: psiphon),
                        ),
                      );
                      if (mounted) setState(() {});
                    },
                  ),
                  const Divider(color: Ember.line, height: 1),
                  _SettingsRow(
                    icon: Icons.receipt_long_rounded,
                    label: l.psiphonLogs,
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => PsiphonLogsPage(psiphon: psiphon),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            // Build 2065: the strategy pack — method ladder, CDN
            // edges, and the fork-core toggles.
            Text('Connection strategy', style: Ember.heading),
            const SizedBox(height: 10),
            MapGlass(
        blur: false,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Column(
                children: [
                  _SettingsRow(
                    icon: Icons.route_rounded,
                    label: 'Connection method',
                    value: psiphonMethodName(settings.method),
                    onTap: () async {
                      await Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => PsiphonMethodPage(psiphon: psiphon),
                        ),
                      );
                      if (mounted) setState(() {});
                    },
                  ),
                  const Divider(color: Ember.line, height: 1),
                  // Bridge mode (build 2075, feature item 10):
                  // the fronted-rung policy for the Auto ladder.
                  _SettingsRow(
                    icon: Icons.shield_rounded,
                    label: 'Bridge mode',
                    value: switch (settings.bridgeMode) {
                      'on' => 'Bridges only',
                      'off' => 'No bridges',
                      _ => 'Auto',
                    },
                    onTap: () async {
                      const modes = ['auto', 'on', 'off'];
                      const labels = {
                        'auto': 'Auto — fronted and plain rungs alternate',
                        'on': 'Bridges only — no plain direct rung',
                        'off': 'No bridges — direct and relayed only',
                      };
                      // Build 2092 (item 50): the shared
                      // Ember form dialog replaces the stock
                      // SimpleDialog; options are 48 dp rows.
                      final picked = await showEmberFormDialog<String>(
                        context,
                        title: 'Bridge mode',
                        content: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (final m in modes)
                              InkWell(
                                onTap: () => Navigator.of(context).pop(m),
                                child: Container(
                                  constraints: const BoxConstraints(
                                    minHeight: 48,
                                  ),
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    labels[m]!,
                                    style: Ember.body.copyWith(
                                      color: settings.bridgeMode == m
                                          ? Ember.orange
                                          : Ember.text,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                        actions: const [],
                      );
                      if (picked != null && picked != settings.bridgeMode) {
                        final next = PsiphonSettings.fromJson(
                          settings.toJson(),
                        );
                        next.bridgeMode = picked;
                        await psiphon.updateSettings(next);
                        if (mounted) setState(() {});
                      }
                    },
                  ),
                  const Divider(color: Ember.line, height: 1),
                  _SettingsRow(
                    icon: Icons.cloud_rounded,
                    label: 'CDN edges',
                    value: _edgesSummary(settings),
                    onTap: () async {
                      await Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => PsiphonEdgesPage(psiphon: psiphon),
                        ),
                      );
                      if (mounted) setState(() {});
                    },
                  ),
                  const Divider(color: Ember.line, height: 1),
                  _SwitchRow(
                    icon: Icons.dns_rounded,
                    label: 'CDN fronting',
                    hint: 'Scanned + tested edges carry the fronted rung',
                    value: settings.cdnFronting,
                    onChanged: (v) => _edit(v, (s, v) => s.cdnFronting = v),
                  ),
                  const Divider(color: Ember.line, height: 1),
                  _SwitchRow(
                    icon: Icons.timer_off_rounded,
                    label: 'Disable timeouts',
                    hint: 'Slower attempts, fewer early give-ups',
                    value: settings.disableTimeouts,
                    onChanged: (v) => _edit(v, (s, v) => s.disableTimeouts = v),
                  ),
                  const Divider(color: Ember.line, height: 1),
                  // Build 2129 (Leg 2): the Shiro bootstrap
                  // (DEFAULT OFF) — the public Shirokhorshid
                  // partner set as one unit: identity,
                  // 2,434-entry list, fronting overrides.
                  _SwitchRow(
                    icon: Icons.public_rounded,
                    label: 'Shiro bootstrap',
                    hint:
                        'Public Shirokhorshid server set instead of the built-in one',
                    value: settings.shiroBootstrap,
                    onChanged: (v) => _edit(v, (s, v) => s.shiroBootstrap = v),
                  ),
                  const Divider(color: Ember.line, height: 1),
                  // Build 2129 (Leg 2): strong mode
                  // (DEFAULT OFF) — AggressiveEstablishment,
                  // in either bootstrap.
                  _SwitchRow(
                    icon: Icons.bolt_rounded,
                    label: 'Strong mode',
                    hint: 'Aggressive tunnel establishment attempts',
                    value: settings.strongMode,
                    onChanged: (v) => _edit(v, (s, v) => s.strongMode = v),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            Text(l.psiphonUpstreamProxy, style: Ember.heading),
            const SizedBox(height: 6),
            Text(l.psiphonUpstreamHint, style: Ember.caption),
            const SizedBox(height: 10),
            TextField(
              controller: _upstream,
              focusNode: _upstreamFocus,
              style: Ember.body,
              keyboardType: TextInputType.url,
              autocorrect: false,
              enableSuggestions: false,
              // Build 2116 (AP-16): the shared field — this
              // was a hand-rolled clone at radius 14 with
              // the graphite fill.
              decoration: emberField(context, 'http://host:port'),
              onSubmitted: (_) => _saveUpstream(),
            ),
            const SizedBox(height: 12),
            Text(l.psiphonNextConnectHint, style: Ember.caption),
          ],
        ),
      ),
    );
  }
}

/// A settings row with a real switch (build 2065).
class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.icon,
    required this.label,
    required this.hint,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final String label;
  final String hint;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Row(
      children: [
        Icon(icon, size: 20, color: Ember.orange),
        const SizedBox(width: 11),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: Ember.body),
              Text(hint, style: Ember.caption),
            ],
          ),
        ),
        // Build 2074 (audit item 5): the shared MapToggle
        // pill the sibling engines use, not a stock
        // Material Switch.
        MapToggle(value: value, onChanged: onChanged),
      ],
    ),
  );
}

class _SettingsRow extends StatelessWidget {
  const _SettingsRow({
    required this.icon,
    required this.label,
    this.value,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final String? value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    child: Padding(
      // Build 2092 (item 50): 14 dp vertical padding puts
      // the row at the 48 dp floor (was ~46).
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Row(
        children: [
          Icon(icon, size: 20, color: Ember.orange),
          const SizedBox(width: 11),
          Expanded(child: Text(label, style: Ember.body)),
          if (value != null) ...[
            // Build 2074 (audit item 16): the value is bounded
            // — a long region/method name ellipsizes instead
            // of overflowing the row.
            Flexible(
              child: Text(
                value!,
                style: Ember.dimStyle,
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
                textAlign: TextAlign.end,
              ),
            ),
            const SizedBox(width: 6),
          ],
          // Build 2056 (audit Batch 9): English LTR — right.
          const Icon(Icons.chevron_right_rounded, color: Ember.faint, size: 20),
        ],
      ),
    ),
  );
}

/// The transport multi-select: nothing ticked = the core's automatic
/// choice (its default); ticking any box limits the core to those.
class PsiphonTransportsPage extends StatefulWidget {
  const PsiphonTransportsPage({super.key, required this.psiphon});

  final PsiphonController psiphon;

  @override
  State<PsiphonTransportsPage> createState() => _PsiphonTransportsPageState();
}

class _PsiphonTransportsPageState extends State<PsiphonTransportsPage> {
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final selected = widget.psiphon.settings.protocols;
    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Ember.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Ember.text,
        title: Text(l.psiphonTransports, style: Ember.heading),
      ),
      body: EmberBackground(
        banded: true,
        child: ListView(
          padding: EdgeInsets.fromLTRB(18, MediaQuery.of(context).padding.top + kToolbarHeight + 8, 18, 18),
          children: [
            Text(
              selected.isEmpty
                  ? l.psiphonTransportsAuto
                  : '${latDigits(selected.length)} / '
                        '${latDigits(psiphonTransports.length)}',
              style: Ember.caption,
            ),
            const SizedBox(height: 10),
            MapGlass(
        blur: false,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Column(
                children: [
                  for (var i = 0; i < psiphonTransports.length; i++) ...[
                    if (i > 0) const Divider(color: Ember.line, height: 1),
                    InkWell(
                      onTap: () async {
                        final t = psiphonTransports[i];
                        final next = PsiphonSettings.fromJson(
                          widget.psiphon.settings.toJson(),
                        );
                        if (!next.protocols.remove(t.value)) {
                          next.protocols.add(t.value);
                        }
                        await widget.psiphon.updateSettings(next);
                        if (mounted) setState(() {});
                      },
                      child: Padding(
                        // Build 2092 (item 50): the transport
                        // rows reach the 48 dp floor (was ~43).
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                psiphonTransports[i].label,
                                style: Ember.body,
                              ),
                            ),
                            Icon(
                              selected.contains(psiphonTransports[i].value)
                                  ? Icons.check_box_rounded
                                  : Icons.check_box_outline_blank_rounded,
                              color:
                                  selected.contains(psiphonTransports[i].value)
                                  ? Ember.orange
                                  : Ember.faint,
                              size: 21,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 10),
            Text(l.psiphonNextConnectHint, style: Ember.caption),
          ],
        ),
      ),
    );
  }
}

/// The Psiphon log viewer: psiphon.log (the core's diagnostic
/// notices and, since build 2066, the badvpn bridge's lines too)
/// and tunlink.log (the pre-2066 bridge's file, kept readable so
/// an upgraded phone's old evidence stays visible), newest
/// content last.
class PsiphonLogsPage extends StatefulWidget {
  const PsiphonLogsPage({super.key, required this.psiphon});

  final PsiphonController psiphon;

  @override
  State<PsiphonLogsPage> createState() => _PsiphonLogsPageState();
}

class _PsiphonLogsPageState extends State<PsiphonLogsPage> {
  late Future<String> _logs = widget.psiphon.readLogs();

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Ember.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Ember.text,
        title: Text(l.psiphonLogs, style: Ember.heading),
        actions: [
          IconButton(
            onPressed: () => setState(() => _logs = widget.psiphon.readLogs()),
            icon: const Icon(Icons.refresh_rounded, color: Ember.dim),
          ),
          // Build 2092 (item 51): Clear carries a tooltip
          // and confirms first, like the other log pages.
          IconButton(
            tooltip: 'Clear logs',
            onPressed: () async {
              final confirmed = await showEmberConfirm(
                context,
                title: 'Clear logs?',
                message: 'Delete the saved Psiphon logs?',
                confirmLabel: 'Clear',
              );
              if (!confirmed) return;
              await widget.psiphon.clearLogs();
              setState(() => _logs = widget.psiphon.readLogs());
            },
            icon: const Icon(Icons.delete_outline_rounded, color: Ember.dim),
          ),
        ],
      ),
      body: EmberBackground(
        banded: true,
        child: FutureBuilder<String>(
          future: _logs,
          builder: (context, snap) {
            // Build 2074 (audit item 8): a loading or failed
            // read is not an empty log — spinner while waiting,
            // an error line on failure, "no logs" only when the
            // read truly came back empty.
            if (snap.connectionState == ConnectionState.waiting) {
              return const Center(
                child: CircularProgressIndicator(color: Ember.orange),
              );
            }
            if (snap.hasError) {
              return ListView(
                padding: EdgeInsets.fromLTRB(18, MediaQuery.of(context).padding.top + kToolbarHeight + 8, 18, 18),
                children: [
                  MapGlass(
        blur: false,
                    padding: const EdgeInsets.all(13),
                    child: Text(
                      'The logs could not be loaded.',
                      style: Ember.body,
                    ),
                  ),
                ],
              );
            }
            final text = snap.data ?? '';
            return ListView(
              padding: EdgeInsets.fromLTRB(18, MediaQuery.of(context).padding.top + kToolbarHeight + 8, 18, 18),
              children: [
                if (snap.hasData)
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: TextButton.icon(
                      // Build 2092 (item 51): 48 dp floor.
                      style: TextButton.styleFrom(
                        minimumSize: const Size(0, 48),
                      ),
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: text));
                        if (context.mounted) {
                          ScaffoldMessenger.of(
                            context,
                          ).showSnackBar(SnackBar(content: Text(l.logsCopied)));
                        }
                      },
                      icon: const Icon(
                        Icons.copy_rounded,
                        size: 16,
                        color: Ember.dim,
                      ),
                      label: Text(l.copyAll, style: Ember.caption),
                    ),
                  ),
                MapGlass(
        blur: false,
                  padding: const EdgeInsets.all(13),
                  child: SelectableText(
                    text.isEmpty ? l.noLogs : text,
                    style: Ember.caption.copyWith(fontFamily: 'monospace'),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// The connection-method picker (build 2065): Auto runs the
/// ladder (fronted → clean-IP → direct → conduit, winner first);
/// a picked method runs alone. The pairing field for a personal
/// Conduit station lives here too — it is a method prerequisite,
/// so it sits with the method it unlocks.
class PsiphonMethodPage extends StatefulWidget {
  const PsiphonMethodPage({super.key, required this.psiphon});

  final PsiphonController psiphon;

  @override
  State<PsiphonMethodPage> createState() => _PsiphonMethodPageState();
}

class _PsiphonMethodPageState extends State<PsiphonMethodPage> {
  late final TextEditingController _pairing = TextEditingController();
  String? _pairingError;

  PsiphonController get psiphon => widget.psiphon;

  static const _hints = <String, String>{
    '': 'Tries each method in order; the winner on this network goes first next time',
    'A': 'Meek through CDN front domains, with scanned + tested edges',
    'E': 'Fronted meek aimed at the tested clean edge IPs',
    'D': 'Every protocol, direct — no fronting, no in-proxy',
    'C': 'Tunnel through other users\' Conduit stations (WebRTC)',
    'P': 'Only through your paired personal Conduit station',
    'X': 'Chain through the upstream proxy set below',
  };

  Future<void> _pick(String method) async {
    final next = PsiphonSettings.fromJson(psiphon.settings.toJson());
    next.method = method;
    await psiphon.updateSettings(next);
    if (mounted) setState(() {});
  }

  Future<void> _savePairing() async {
    final parsed = parseConduitPairing(_pairing.text);
    if (parsed == null) {
      setState(
        () => _pairingError = 'This is not a Conduit pairing link — it starts with psiphon://pair/',
      );
      return;
    }
    final next = PsiphonSettings.fromJson(psiphon.settings.toJson());
    next.compartmentId = parsed.id;
    next.compartmentName = parsed.name;
    await psiphon.updateSettings(next);
    _pairing.clear();
    if (mounted) setState(() => _pairingError = null);
  }

  Future<void> _clearPairing() async {
    final next = PsiphonSettings.fromJson(psiphon.settings.toJson());
    next.compartmentId = '';
    next.compartmentName = '';
    if (next.method == 'P') next.method = '';
    await psiphon.updateSettings(next);
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _pairing.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = psiphon.settings;
    final winner = settings.winnerFor(settings.networkKey);
    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Ember.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Ember.text,
        title: Text('Connection method', style: Ember.heading),
      ),
      body: EmberBackground(
        banded: true,
        child: ListView(
          padding: EdgeInsets.fromLTRB(18, MediaQuery.of(context).padding.top + kToolbarHeight + 8, 18, 18),
          children: [
            if (winner.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(
                  'Last winner on this network: ${psiphonMethodName(winner)}',
                  style: Ember.caption,
                ),
              ),
            MapGlass(
        blur: false,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Column(
                children: [
                  for (var i = 0; i < psiphonMethods.length; i++) ...[
                    if (i > 0) const Divider(color: Ember.line, height: 1),
                    InkWell(
                      onTap: () => _pick(psiphonMethods.keys.elementAt(i)),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 11),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    psiphonMethods.values.elementAt(i),
                                    style: Ember.body,
                                  ),
                                  Text(
                                    _hints[psiphonMethods.keys.elementAt(i)] ??
                                        '',
                                    style: Ember.caption,
                                  ),
                                ],
                              ),
                            ),
                            Icon(
                              settings.method ==
                                      psiphonMethods.keys.elementAt(i)
                                  ? Icons.check_circle_rounded
                                  : Icons.circle_outlined,
                              color:
                                  settings.method ==
                                      psiphonMethods.keys.elementAt(i)
                                  ? Ember.orange
                                  : Ember.faint,
                              size: 21,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 18),
            Text('Personal Conduit pairing', style: Ember.heading),
            const SizedBox(height: 6),
            Text(
              settings.compartmentId.isEmpty
                  ? 'Paste a friend\'s psiphon://pair/ link to use their private Conduit station.'
                  : 'Paired: ${settings.compartmentName.isEmpty ? 'a station' : settings.compartmentName}',
              style: Ember.caption,
            ),
            const SizedBox(height: 10),
            if (settings.compartmentId.isEmpty) ...[
              TextField(
                controller: _pairing,
                style: Ember.body,
                autocorrect: false,
                enableSuggestions: false,
                // Build 2116 (AP-16): the shared field (the
                // clone's error wiring rides copyWith).
                decoration: emberField(
                  context,
                  'psiphon://pair/…',
                ).copyWith(errorText: _pairingError),
                onSubmitted: (_) => _savePairing(),
              ),
              const SizedBox(height: 10),
              EmberButton(
                label: 'Save pairing',
                icon: Icons.link_rounded,
                onTap: _savePairing,
              ),
            ] else
              EmberButton(
                label: 'Remove pairing',
                icon: Icons.link_off_rounded,
                onTap: _clearPairing,
              ),
          ],
        ),
      ),
    );
  }
}

/// The ping-tested CDN edge list (build 2065): built-in Akamai /
/// Fastly candidates plus the owner's own IP+SNI entries. "Test
/// all" runs a real TCP+TLS handshake per entry (apps cannot send
/// ICMP; the number shown is handshake latency). The fastest
/// reachable BUILT-IN edges feed the core automatically; pinning
/// one built-in edge and turning auto-use off feeds exactly that
/// one. Build 2095 (whole-app journey audit #18/#19): custom
/// edges are a latency WATCHLIST — the core feed selects by
/// provider (akamai/fastly), so a custom edge can be tested but
/// never fed or pinned; the page says so instead of promising
/// a capability it does not have.
class PsiphonEdgesPage extends StatefulWidget {
  const PsiphonEdgesPage({super.key, required this.psiphon});

  final PsiphonController psiphon;

  @override
  State<PsiphonEdgesPage> createState() => _PsiphonEdgesPageState();
}

class _PsiphonEdgesPageState extends State<PsiphonEdgesPage> {
  PsiphonController get psiphon => widget.psiphon;

  Future<void> _edit(void Function(PsiphonSettings) apply) async {
    final next = PsiphonSettings.fromJson(psiphon.settings.toJson());
    apply(next);
    await psiphon.updateSettings(next);
    if (mounted) setState(() {});
  }

  Future<void> _addCustom() async {
    final address = TextEditingController();
    final sni = TextEditingController();
    // Build 2092 (items 50/61): the shared scrollable Ember
    // form dialog and fields; the two controllers are
    // disposed once their text is read.
    final ok = await showEmberFormDialog<bool>(
      context,
      title: 'Add CDN edge',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: address,
            style: Ember.body,
            autocorrect: false,
            enableSuggestions: false,
            decoration: emberField(context, 'IP or hostname'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: sni,
            style: Ember.body,
            autocorrect: false,
            enableSuggestions: false,
            decoration: emberField(context, 'SNI hostname'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        EmberButton(label: 'Add', onTap: () => Navigator.of(context).pop(true)),
      ],
    );
    final a = address.text.trim();
    final s = sni.text.trim();
    address.dispose();
    sni.dispose();
    if (ok != true) return;
    if (a.isEmpty) return;
    await _edit((settings) {
      settings.cdnEdges.add(
        CdnEdge(address: a, sni: s.isEmpty ? a : s, provider: 'custom'),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: psiphon,
      builder: (context, _) {
        final settings = psiphon.settings;
        final ranked = rankCdnEdges(settings.cdnEdges);
        return Scaffold(
          extendBodyBehindAppBar: true,
          backgroundColor: Ember.bg,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            elevation: 0,
            foregroundColor: Ember.text,
            title: Text('CDN edges', style: Ember.heading),
          ),
          body: EmberBackground(
        banded: true,
            child: ListView(
              padding: EdgeInsets.fromLTRB(18, MediaQuery.of(context).padding.top + kToolbarHeight + 8, 18, 18),
              children: [
                Text(
                  'Each entry is tested with a real TCP + TLS handshake; the number is that handshake\'s latency. '
                  'Only built-in Akamai/Fastly edges feed the core — custom edges are a test-only watchlist.',
                  style: Ember.caption,
                ),
                const SizedBox(height: 10),
                EmberButton(
                  label: psiphon.edgeTesting ? 'Testing…' : 'Test all',
                  icon: Icons.speed_rounded,
                  onTap: psiphon.edgeTesting
                      ? null
                      : () => unawaited(psiphon.testAllEdges()),
                ),
                const SizedBox(height: 12),
                _SwitchRow(
                  icon: Icons.auto_awesome_rounded,
                  label: 'Use fastest automatically',
                  hint: 'Feed the fastest reachable edges to the core',
                  value: settings.edgeAutoUse,
                  onChanged: (v) => _edit((s) => s.edgeAutoUse = v),
                ),
                const SizedBox(height: 6),
                MapGlass(
        blur: false,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  child: Column(
                    children: [
                      // Build 2074 (audit item 17): an empty list
                      // says so — no bare empty glass.
                      if (ranked.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Text(
                            'No edges yet — the built-in list loads '
                            'with the engine, or add a custom edge below.',
                            style: Ember.caption,
                          ),
                        ),
                      for (var i = 0; i < ranked.length; i++) ...[
                        if (i > 0) const Divider(color: Ember.line, height: 1),
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 9),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      ranked[i].address,
                                      style: Ember.body,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    Text(
                                      ranked[i].provider == 'custom'
                                          ? 'custom · test only · SNI ${ranked[i].sni}'
                                          : '${ranked[i].provider} · SNI ${ranked[i].sni}',
                                      style: Ember.caption,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ),
                              ),
                              Text(
                                ranked[i].lastTestAtMs == 0
                                    ? 'Not tested'
                                    : ranked[i].lastOk
                                    ? '${latDigits('${ranked[i].lastMs}')} ms'
                                    : 'Failed',
                                style: ranked[i].lastOk
                                    ? Ember.body
                                    : Ember.caption,
                              ),
                              IconButton(
                                tooltip: ranked[i].provider == 'custom'
                                    ? 'Custom edges are test-only'
                                    : settings.pinnedEdgeId == ranked[i].id
                                    ? 'Pinned'
                                    : 'Pin this edge',
                                icon: Icon(
                                  settings.pinnedEdgeId == ranked[i].id
                                      ? Icons.push_pin_rounded
                                      : Icons.push_pin_outlined,
                                  size: 18,
                                  color: settings.pinnedEdgeId == ranked[i].id
                                      ? Ember.orange
                                      : Ember.faint,
                                ),
                                onPressed: ranked[i].provider == 'custom'
                                    ? null
                                    : () => _edit((s) {
                                        s.pinnedEdgeId =
                                            s.pinnedEdgeId == ranked[i].id
                                            ? ''
                                            : ranked[i].id;
                                      }),
                              ),
                              if (!ranked[i].builtin)
                                IconButton(
                                  tooltip: 'Remove',
                                  icon: const Icon(
                                    Icons.delete_outline_rounded,
                                    size: 18,
                                    color: Ember.faint,
                                  ),
                                  // Build 2092 (item 50):
                                  // deleting a custom edge
                                  // confirms first.
                                  onPressed: () async {
                                    final confirmed = await showEmberConfirm(
                                      context,
                                      title: 'Remove edge?',
                                      message:
                                          'Remove the custom edge '
                                          '${ranked[i].address}?',
                                      confirmLabel: 'Remove',
                                    );
                                    if (!confirmed) return;
                                    await _edit((s) {
                                      s.cdnEdges.removeWhere(
                                        (e) => e.id == ranked[i].id,
                                      );
                                      if (s.pinnedEdgeId == ranked[i].id) {
                                        s.pinnedEdgeId = '';
                                      }
                                    });
                                  },
                                ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                EmberButton(
                  label: 'Add custom edge',
                  icon: Icons.add_rounded,
                  onTap: _addCustom,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
