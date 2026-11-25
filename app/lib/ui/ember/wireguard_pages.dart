/// The standalone WireGuard section's pages, Map Control
/// edition (build 2032, sample s22): WireGuard profiles live
/// in the same store as every V2Ray config (the Xray core's
/// WireGuard outbound is the carrier), but this section is
/// WireGuard only — its own import (.conf files and
/// wireguard:// links), its own list, and the peer-fallback
/// connect ralysnd's WireGuard page has: a config with several
/// peers tries them in order until one actually carries
/// traffic.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/android_core.dart';
import '../../xray/link_parser.dart';
import '../../xray/profile_codec.dart';
import '../../xray/wg_conf.dart';
import '../../xray/wstunnel_args.dart';
import '../../xray/xray_controller.dart';
import '../../xray/xray_models.dart';
import '../../xray/xray_platform.dart';
import 'ember_dialogs.dart';
import 'ember_format.dart';
import 'ember_theme.dart';
import 'map_widgets.dart';
import 'profile_editor.dart';
import 'qr_pages.dart';
import 'wg_scan_page.dart';

List<Profile> wgProfilesOf(XrayController xray) =>
    xray.profiles.where((p) => p.protocol == Protocol.wireguard).toList();

/// Batch 4 (pro6 fidelity rollout): the flat hairline panel —
/// a solid card fill and a 1 px hairline edge, no blur, no
/// gradient wash, no luminous ring — that replaces MapGlass
/// on the recomposed WireGuard home (the same panel the
/// Psiphon/OpenVPN/Lantern surfaces carry in their own files).
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

/// Build 2097 (IMP-2): the parse + store add with no UI —
/// the file-import path uses it when the importing page is
/// gone by the time a pick returns. Build 2095's re-lock
/// disposed the page mid-pick (IMP-1 stops that), and a
/// page can also be popped by navigation mid-pick; a
/// completed pick must never be discarded for want of a
/// context — only the rename prompt and the messages need
/// one.
Future<WgConfResult> addWgConfText(
  XrayController xray,
  String text,
  String name,
) async {
  final result = parseWgConf(text, baseName: name, idFor: newProfileId);
  if (result.ok) {
    for (final p in result.profiles) {
      await xray.addProfile(p);
    }
  }
  return result;
}

/// Imports WireGuard config text (build 2050): the gate, the
/// name prompt, the parser, the store. Shared by the paste
/// path, the file picker, and the home page — one behaviour
/// everywhere. A parse failure names the parser's own reason;
/// nothing fails silently.
Future<void> importWgConfText(
  BuildContext context,
  XrayController xray,
  String text, {
  String suggestedName = 'WireGuard',
}) async {
  // The gate speaks the parser's language (build 2033):
  // section names are case-insensitive there, so a file
  // whose header reads [interface] must pass here too —
  // the pre-2033 case-sensitive check refused files the
  // parser itself would have accepted.
  // Build 2102: the shared gate (isWgConfText, wg_conf.dart).
  if (text.isEmpty || !isWgConfText(text)) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'That text is not a WireGuard config — no [Interface] section',
        ),
      ),
    );
    return;
  }
  final name = await _askWgName(context, suggestedName);
  if (name == null || !context.mounted) return;
  final result = await addWgConfText(xray, text, name);
  if (!result.ok) {
    // Build 2074 (audit item 6): a plain sentence — the
    // parser's raw reason stays out of the SnackBar (the
    // build-2070 pattern at _connect below).
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('That file is not a valid WireGuard config'),
      ),
    );
    return;
  }
  if (context.mounted) {
    // Build 2106 (journey audit F-05): the obfuscation claim
    // keys on the parameters the engine actually runs — a
    // config whose only Amnezia parameters are J1–J3 does
    // NOT earn the sentence (the engine discards them), and
    // any J1–J3 present are named as ignored, here at
    // import time as well as on the profile's row.
    final anySupported = result.profiles.any(
      (p) => p.hasSupportedAmneziaParams,
    );
    final anyJ = result.profiles.any((p) => p.hasUnsupportedJParams);
    // Build 2116 (audit WGX-1): a single-family import
    // says so at import — the uncovered family keeps the
    // user's real IP (the owner's Iranian-exit report).
    final familyNote = result.profiles
        .map(wgUncoveredFamilyNote)
        .whereType<String>()
        .firstOrNull;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Imported ${latDigits(result.profiles.length)} config'
          '${result.profiles.length == 1 ? '' : 's'}'
          '${anySupported ? ' — AmneziaWG parameters found: runs with AmneziaWG obfuscation (falls back to plain WireGuard if the obfuscated tunnel cannot reach the server)' : ''}'
          '${anyJ ? ' — note: J1–J3 parameters are not supported by this engine and are ignored' : ''}'
          '${familyNote != null ? ' — note: $familyNote' : ''}',
        ),
      ),
    );
  }
}

/// The .conf FILE import (build 2050, audit F-H14): the
/// WireGuard page was clipboard-only until now — a config that
/// lives as a file in Downloads or Telegram had no way in.
/// Rides the generalized native picker; a read failure (too
/// large, unreadable) is surfaced by name, never a silent
/// no-op. The file's own name seeds the config name.
Future<void> importWgConfFile(BuildContext context, XrayController xray) async {
  final Map<String, String>? picked;
  try {
    picked = await XrayPlatform.pickTextFile();
  } on PlatformException catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            // Build 2092 (item 19): the platform's raw
            // message stays out of the SnackBar.
            e.message == 'file-too-large'
                ? 'That file is too large to import (256 KB max)'
                : 'Could not read that file',
          ),
        ),
      );
    }
    return;
  }
  if (picked == null) return;
  var base = picked['name'] ?? 'WireGuard';
  if (base.toLowerCase().endsWith('.conf')) {
    base = base.substring(0, base.length - 5);
  }
  if (base.trim().isEmpty) base = 'WireGuard';
  final content = (picked['content'] ?? '').trim();
  if (!context.mounted) {
    // Build 2097 (IMP-2): the page is gone — the pick
    // outlived it (the pre-IMP-1 re-lock, or navigation).
    // The pick still counts: add under the file's own
    // name; only the rename prompt and the messages are
    // skipped. The [Interface] gate mirrors
    // importWgConfText's, so a non-config file adds nothing.
    if (content.isNotEmpty && isWgConfText(content)) {
      await addWgConfText(xray, content, base);
    }
    return;
  }
  await importWgConfText(context, xray, content, suggestedName: base);
}

Future<String?> _askWgName(BuildContext context, String initial) {
  final holder = _WgNameHolder(initial);
  return showEmberFormDialog<String>(
    context,
    title: 'Config name',
    content: _WgNameField(holder: holder),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      EmberButton(
        label: 'Import',
        onTap: () => Navigator.of(context).pop(holder.text.trim()),
      ),
    ],
  );
}

/// Carries the name field's text to the dialog's Import
/// action (build 2095, found by the audit-3 8-2 widget
/// test): the previous shape disposed the field's
/// controller in a finally block the moment the dialog
/// future completed, while the dialog's exit animation
/// still had the field mounted — "used after being
/// disposed" in debug builds. The field's State now owns
/// the controller and disposes it when the route is gone;
/// this holder is how the action reads the text.
class _WgNameHolder {
  _WgNameHolder(this.text);
  String text;
}

class _WgNameField extends StatefulWidget {
  const _WgNameField({required this.holder});
  final _WgNameHolder holder;

  @override
  State<_WgNameField> createState() => _WgNameFieldState();
}

class _WgNameFieldState extends State<_WgNameField> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.holder.text);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      autofocus: true,
      style: Ember.body,
      decoration: emberField(context, 'Name for the imported config'),
      onChanged: (v) => widget.holder.text = v,
    );
  }
}

/// Peer liveness for the live WireGuard session (build
/// 2075, feature item 18): "the core is running" is NOT
/// proof the peer answered. An AmneziaWG session proves it
/// with the UAPI handshake age; a plain WireGuard session
/// proves it with a verified exit or with traffic that has
/// actually flowed. Anything else is "no response yet" —
/// never a green Connected.
({bool proven, String line}) wgPeerLiveness(XrayController xray) {
  final s = xray.state;
  if (!s.running) return (proven: false, line: '');
  if (xray.awgSession) {
    return s.awgHandshakeAgeSec >= 0
        ? (
            proven: true,
            line: 'Handshake ${latDigits(s.awgHandshakeAgeSec)}s ago',
          )
        : (
            proven: false,
            line: 'No handshake yet — the peer has not answered.',
          );
  }
  if (xray.exitInfo != null) {
    return (proven: true, line: 'Exit verified through the tunnel');
  }
  if (s.downBytes > 0) {
    return (proven: true, line: 'Traffic is flowing');
  }
  return (
    proven: false,
    line:
        'Tunnel is up, but the peer has not answered yet — '
        'no traffic has flowed and the exit is unverified.',
  );
}

/// Build 2145 (composition rebuild, pro6-wireguard): one row
/// of the session's mono data table — a tracked label at the
/// left, the value in the sample's right-hand column, and a
/// hairline under every row but the last. The value is a
/// widget so the transfer row keeps its arrows as icons (the
/// glyph-arrow ban of build 2056 stands).
class _WgDataRow extends StatelessWidget {
  const _WgDataRow({
    required this.label,
    required this.value,
    this.last = false,
  });

  final String label;
  final Widget value;
  final bool last;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Expanded(flex: 4, child: Text(label, style: Ember.microLabel)),
              Expanded(flex: 6, child: value),
            ],
          ),
        ),
        if (!last) const Divider(color: MapUi.line, height: 1, thickness: 1),
      ],
    );
  }
}

/// A mono data value for the session table (the pro6
/// sample's monospace data column).
Widget _wgMono(String text, {Color? color}) => Text(
  text,
  style: Ember.body.copyWith(fontFamily: 'monospace', color: color),
  overflow: TextOverflow.ellipsis,
);

/// The transfer row's value: the down/up totals with the
/// arrow icons the About view already uses.
Widget _wgTransferValue(int downBytes, int upBytes) => Directionality(
  textDirection: TextDirection.ltr,
  child: Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      const Icon(Icons.arrow_downward_rounded, size: 14, color: Ember.dim),
      const SizedBox(width: 3),
      Text(
        fmtBytes(downBytes),
        style: Ember.body.copyWith(fontFamily: 'monospace'),
      ),
      const SizedBox(width: 10),
      const Icon(Icons.arrow_upward_rounded, size: 14, color: Ember.dim),
      const SizedBox(width: 3),
      Text(
        fmtBytes(upBytes),
        style: Ember.body.copyWith(fontFamily: 'monospace'),
      ),
    ],
  ),
);

/// Build 2145: the pro6-wireguard mono table for one profile —
/// TRANSFER (the live session's bytes while it runs, else the
/// profile's stored totals), ALLOWED IPS, DNS, MTU and
/// PROTOCOL, every value from the profile/session data the
/// app already computes. A row with no data is omitted,
/// never filled. [panel] wraps the rows in the sample's
/// hairline panel; the About view renders the same rows bare
/// inside its own card.
class _WgSessionTable extends StatelessWidget {
  const _WgSessionTable({
    required this.xray,
    required this.profile,
    this.panel = true,
  });

  final XrayController xray;
  final Profile profile;
  final bool panel;

  @override
  Widget build(BuildContext context) {
    final p = profile;
    final live = xray.state.running && xray.selected?.id == p.id;
    final rows = <(String, Widget)>[];
    if (live) {
      rows.add((
        'TRANSFER',
        _wgTransferValue(xray.state.downBytes, xray.state.upBytes),
      ));
    } else if (profileHasTotals(p)) {
      rows.add((
        'TRANSFER',
        _wgTransferValue(p.totalDownBytes, p.totalUpBytes),
      ));
    }
    if (p.wgAllowedIPs.isNotEmpty) {
      rows.add(('ALLOWED IPS', _wgMono(p.wgAllowedIPs)));
    }
    if (p.wgDns.isNotEmpty) rows.add(('DNS', _wgMono(p.wgDns)));
    rows.add(('MTU', _wgMono(latDigits(p.mtu))));
    // A live session the AWG engine could not start runs
    // plain — the row names the session's real protocol, not
    // the profile's parameters (build 2050, audit C-1).
    final awg =
        p.hasSupportedAmneziaParams &&
        !(live && xray.awgFallbackNotice.isNotEmpty);
    rows.add((
      'PROTOCOL',
      _wgMono(
        awg ? 'AmneziaWG 2.0' : 'WireGuard',
        color: awg ? Ember.orange : null,
      ),
    ));
    final table = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < rows.length; i++)
          _WgDataRow(
            label: rows[i].$1,
            value: rows[i].$2,
            last: i == rows.length - 1,
          ),
      ],
    );
    if (!panel) return table;
    // Batch 4 (pro6 fidelity rollout): the flat hairline
    // panel — MapGlass's gradient wash leaves the home.
    return _HairlinePanel(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: table,
    );
  }
}

/// The effective per-app routing for the WireGuard
/// surface (build 2116, audit WGX-3): loads the same
/// AppRouting the per-app page edits and renders it as one
/// caption line. Renders nothing until the load lands and
/// nothing at all when it fails — the line is information,
/// never a blocker.
class _WgAppRoutingLine extends StatefulWidget {
  const _WgAppRoutingLine();

  @override
  State<_WgAppRoutingLine> createState() => _WgAppRoutingLineState();
}

class _WgAppRoutingLineState extends State<_WgAppRoutingLine> {
  String? _line;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final routing = await AndroidCore.appRouting();
      if (!mounted) return;
      setState(() {
        _line = routing.onlyChosen && routing.only.isNotEmpty
            ? 'Apps: only ${latDigits(routing.only.length)} selected '
                  'apps use this tunnel'
            : routing.bypass.isNotEmpty
            ? 'Apps: ${latDigits(routing.bypass.length)} apps bypass '
                  'this tunnel'
            : 'Apps: all apps use this tunnel';
      });
    } catch (_) {
      // The line is information only; a failed load leaves
      // the card as it was.
    }
  }

  @override
  Widget build(BuildContext context) {
    final line = _line;
    if (line == null) return const SizedBox.shrink();
    return Text(line, style: Ember.caption);
  }
}

/// The WireGuard home (mode 5): the status card (s22's
/// two-path card: the selected config, or the empty state with
/// the import actions), over the map.
class WireGuardHomePage extends StatelessWidget {
  const WireGuardHomePage({
    super.key,
    required this.xray,
    required this.onOpenServers,
  });

  final XrayController xray;
  final VoidCallback onOpenServers;

  @override
  Widget build(BuildContext context) {
    final on = xray.state.running;
    final selected = xray.selected;
    final wgSelected =
        selected != null && selected.protocol == Protocol.wireguard
        ? selected
        : null;
    final count = wgProfilesOf(xray).length;
    // Build 2075 (item 18): the green dot and the word
    // Connected require a peer that has actually answered.
    final liveness = on && wgSelected != null ? wgPeerLiveness(xray) : null;
    // Build 2116 (AP-05): LayoutBuilder page height, as on
    // the V2Ray/Psiphon homes — not the device height.
    return LayoutBuilder(
      builder: (context, constraints) => ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        children: [
          // Build 2074 (audit item 3): the top spacer is a capped
          // fraction of the viewport height, not a fixed 150dp.
          SizedBox(
            // Build 2092 (item 39): the shared home top gap.
            height: emberHomeTopGap(constraints.maxHeight),
          ),
          // Build 2145 (composition rebuild, pro6-wireguard):
          // the status card's glass is retired — the session
          // reads as the sample's open composition (tracked
          // label, hero profile name, mono endpoint line,
          // handshake numeral) over the map, with the mono data
          // table as a hairline panel under it. The whole
          // composition keeps the old card's tap-through to the
          // configurations panel (the same onOpenServers).
          GestureDetector(
            onTap: onOpenServers,
            behavior: HitTestBehavior.opaque,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Build 2144 (reskin, pro6-wireguard sample): the
                // tracked engine label over the status word.
                Text('ENGINE · WIREGUARD', style: Ember.microLabelOrange),
                const SizedBox(height: 10),
                // Build 2145: the liveness dot and its word move
                // to a tracked status line — the hero slot below
                // now carries the profile name, as in the sample.
                Row(
                  children: [
                    Container(
                      width: 9,
                      height: 9,
                      decoration: BoxDecoration(
                        color: on && wgSelected != null
                            ? (liveness!.proven ? Ember.green : Ember.warn)
                            : Ember.faint,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        on && wgSelected != null
                            ? (liveness!.proven
                                  ? 'Connected'
                                  : 'No response yet')
                            : 'Not connected',
                        style: Ember.microLabel,
                      ),
                    ),
                    const Icon(Icons.chevron_right_rounded, color: MapUi.faint),
                  ],
                ),
                const SizedBox(height: 10),
                // Build 2145: the hero profile name at Ember.hero
                // (the sample's huge light name); with no
                // selection the hero carries the engine word, as
                // the status row did before.
                // Build 2147 (strict-audit F11): no
                // FittedBox shrink — the name ellipsises at
                // the column's width instead. (A Flexible
                // here broke layout: this column scrolls,
                // so its height is unbounded.)
                Text(
                  wgSelected != null ? wgSelected.displayName : 'WireGuard',
                  style: Ember.hero,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 6),
                if (wgSelected != null)
                  // Build 2145: the sample's mono ENDPOINT line —
                  // the profile's real endpoint, nothing else.
                  Text(
                    'ENDPOINT ${wgSelected.address}:${wgSelected.port}',
                    style: Ember.body.copyWith(
                      fontFamily: 'monospace',
                      color: MapUi.body,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  )
                else
                  Text(
                    count > 0
                        ? '${latDigits(count)} WireGuard config${count == 1 ? '' : 's'} — '
                              'pick one in the configurations panel.'
                        : 'No WireGuard configs yet — import a .conf file '
                              'or a wireguard:// link in the configurations '
                              'panel.',
                    style: Ember.body,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                // Build 2144 (pro6-wireguard): the last
                // handshake as the sample's enormous light
                // numeral — only the real UAPI handshake age
                // of a live AmneziaWG session, the one age
                // this page actually has.
                if (on &&
                    wgSelected != null &&
                    xray.awgSession &&
                    xray.state.awgHandshakeAgeSec >= 0) ...[
                  const SizedBox(height: 14),
                  Text('LAST HANDSHAKE', style: Ember.microLabel),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(
                        latDigits(xray.state.awgHandshakeAgeSec),
                        style: Ember.numeral,
                      ),
                      const SizedBox(width: 8),
                      Text('s ago', style: Ember.dimStyle),
                    ],
                  ),
                ],
                if (on && wgSelected != null && xray.exitInfo != null) ...[
                  const SizedBox(height: 6),
                  Text('Exit: ${xray.exitInfo!.line}', style: Ember.caption),
                ],
                // Build 2116 (audit WGX): the WG session's
                // exit was measured and came back unproven —
                // the card says so instead of staying silent.
                if (on &&
                    wgSelected != null &&
                    xray.exitInfo == null &&
                    xray.wgExitUnverified) ...[
                  const SizedBox(height: 6),
                  Text('Exit: unverified', style: Ember.caption),
                ],
                // Build 2116 (audit WGX-3): the effective
                // per-app routing, visible where the user
                // looks — an exclusion-caused bypass (the
                // browser bypass-listed, an Only set missing
                // it) is a WG-surface fact, not a Settings
                // secret.
                if (wgSelected != null) ...[
                  const SizedBox(height: 6),
                  const _WgAppRoutingLine(),
                ],
                // Build 2075 (item 18): an unproven peer says
                // so on the card, in words.
                if (liveness != null && !liveness.proven) ...[
                  const SizedBox(height: 6),
                  Text(
                    liveness.line,
                    style: Ember.caption.copyWith(color: Ember.warn),
                  ),
                ],
                // Build 2050 (audit C-1): an AmneziaWG profile
                // running as plain WireGuard says so here — the
                // session is not obfuscated, and the card must
                // not imply it is.
                if (on && xray.awgFallbackNotice.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    xray.awgFallbackNotice,
                    style: Ember.caption.copyWith(color: Ember.warn),
                  ),
                ],
                // Build 2145: the sample's mono data table as a
                // hairline panel under the hero block — the
                // selected profile's/session's real figures.
                if (wgSelected != null) ...[
                  const SizedBox(height: 14),
                  _WgSessionTable(xray: xray, profile: wgSelected),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
          // Build 2050 (audit F-H14): a labelled import on the
          // home page itself — before this, the only door was an
          // unlabelled whole-card tap into the configurations
          // panel, and the panel itself was clipboard-only.
          _HairlinePanel(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: Text('Bring your own config', style: Ember.heading),
                ),
                MapActionPill(
                  icon: Icons.folder_open_rounded,
                  label: 'Import .conf file',
                  onTap: () => importWgConfFile(context, xray),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          // Build 2098 (owner order): the WARP endpoint
          // scanner entry — probes sampled WARP endpoints
          // with real handshakes from the selected config.
          _HairlinePanel(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Find a faster endpoint', style: Ember.heading),
                      const SizedBox(height: 4),
                      Text(
                        wgSelected != null
                            ? 'Scan Cloudflare WARP endpoints with this '
                                  'config\u2019s own handshake.'
                            : 'Select a WireGuard config first, then scan '
                                  'for its fastest endpoint.',
                        style: Ember.caption,
                      ),
                    ],
                  ),
                ),
                MapActionPill(
                  icon: Icons.radar_rounded,
                  label: 'Scan endpoints',
                  onTap: wgSelected == null
                      ? null
                      : () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) =>
                                WgScanPage(xray: xray, profile: wgSelected),
                          ),
                        ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _HairlinePanel(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('How it runs', style: Ember.heading),
                const SizedBox(height: 6),
                Text(
                  'WireGuard rides the V2Ray engine\u2019s core as an '
                  'outbound — the same tunnel, stats and routing as '
                  'every other config. A config with several peers '
                  'tries them in order until one carries traffic '
                  '(peer fallback). A config with AmneziaWG '
                  'parameters runs on Ember\u2019s AmneziaWG engine '
                  'instead, with the obfuscation applied for real; '
                  'a peer the obfuscated tunnel cannot reach falls '
                  'back to plain WireGuard.',
                  style: Ember.caption,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _WgWstunnelCard(xray: xray),
        ],
      ),
    );
  }
}

/// WireGuard over WebSocket (build 2072): the engine-level
/// wstunnel option. While on, a WireGuard session carried by
/// the V2Ray engine sends its peer traffic through a
/// wstunnel client to the URL below — the session's config
/// points the peer at the local forwarder
/// (127.0.0.1:$wstunnelListenPort) and the wstunnel server
/// dials the real endpoint. The stored configs are never
/// rewritten. AmneziaWG-engine sessions are not wrapped.
class _WgWstunnelCard extends StatefulWidget {
  const _WgWstunnelCard({required this.xray});

  final XrayController xray;

  @override
  State<_WgWstunnelCard> createState() => _WgWstunnelCardState();
}

class _WgWstunnelCardState extends State<_WgWstunnelCard> {
  late final TextEditingController _url = TextEditingController(
    text: widget.xray.settings.wgWstunnelUrl,
  );

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final xray = widget.xray;
    final on = xray.settings.wgWstunnel;
    final urlOk = isWstunnelUrl(_url.text);
    return _HairlinePanel(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.language_rounded, size: 16, color: MapUi.dim),
              const SizedBox(width: 7),
              Expanded(
                child: Text('WireGuard over WebSocket', style: Ember.heading),
              ),
              EmberToggle(value: on, onChanged: (v) => xray.setWgWstunnel(v)),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Carries the peer\u2019s UDP inside a WebSocket '
            'tunnel (wstunnel) — for networks where the '
            'WireGuard endpoint is blocked but a ws/wss '
            'endpoint passes. A wstunnel server must run at '
            'the other end; it dials the real peer. Applies '
            'to WireGuard configs on the V2Ray engine; '
            'AmneziaWG-engine sessions are not wrapped.',
            style: Ember.caption,
          ),
          if (on) ...[
            const SizedBox(height: 11),
            TextField(
              controller: _url,
              style: Ember.body,
              textDirection: TextDirection.ltr,
              keyboardType: TextInputType.url,
              onChanged: (_) => setState(() {}),
              // Build 2095 (whole-app journey audit #46):
              // submit goes through the same validation as
              // the Save pill — it used to store a bad URL
              // silently.
              onSubmitted: (v) {
                final t = v.trim();
                if (t.isNotEmpty && !isWstunnelUrl(t)) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        'The URL must start with ws:// or wss:// '
                        '— nothing was saved.',
                      ),
                    ),
                  );
                  return;
                }
                xray.setWgWstunnelUrl(v);
              },
              decoration: emberField(context, 'wss://your-server.example:443')
                  .copyWith(
                    labelText: 'wstunnel server URL',
                    labelStyle: const TextStyle(
                      color: Ember.faint,
                      fontSize: Ember.fontBody,
                    ),
                    floatingLabelStyle: const TextStyle(color: Ember.orange),
                  ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _url.text.trim().isEmpty
                        ? 'Enter the wstunnel server URL.'
                        : urlOk
                        ? 'Sessions forward through this server.'
                        : 'The URL must start with ws:// or wss://.',
                    style: Ember.caption.copyWith(
                      color: _url.text.trim().isNotEmpty && !urlOk
                          ? Ember.orange
                          : null,
                    ),
                  ),
                ),
                MapActionPill(
                  icon: Icons.check_rounded,
                  label: 'Save URL',
                  // Build 2092 (item 60): an invalid URL is
                  // refused WITH feedback — it used to save
                  // silently and fail later at connect.
                  onTap: () {
                    final v = _url.text.trim();
                    if (v.isNotEmpty && !urlOk) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'The URL must start with ws:// or wss:// '
                            '— nothing was saved.',
                          ),
                        ),
                      );
                      return;
                    }
                    xray.setWgWstunnelUrl(_url.text);
                  },
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// The configurations panel in WireGuard mode: import actions
/// on top, then the WireGuard profiles with delay + exit data
/// and the fallback connect.
class WireGuardServersView extends StatelessWidget {
  const WireGuardServersView({super.key, required this.xray, this.onClose});

  final XrayController xray;
  final VoidCallback? onClose;

  Future<void> _importConf(BuildContext context) async {
    // Build 2106 (verification iteration 1, L7): the same
    // guard _importLink got for F-06 — this sibling read
    // the clipboard unguarded, so a HyperOS clipboard
    // denial was the same silent no-op here.
    final String text;
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      text = data?.text?.trim() ?? '';
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not read the clipboard')),
        );
      }
      return;
    }
    if (!context.mounted) return;
    if (text.isEmpty || !isWgConfText(text)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Copy a .conf file\u2019s text first, then tap import'),
        ),
      );
      return;
    }
    await importWgConfText(context, xray, text);
  }

  Future<void> _importLink(BuildContext context) async {
    // Build 2106 (journey audit F-06 == residual 2101-L1):
    // both awaits are guarded — builds ≤2105 let a
    // clipboard PlatformException (HyperOS denies clipboard
    // reads behind a permission prompt) escape as an
    // unhandled async error, and the tap produced no
    // feedback at all: a silent no-op on an import surface.
    final String text;
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      text = data?.text?.trim() ?? '';
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not read the clipboard')),
        );
      }
      return;
    }
    if (!context.mounted) return;
    if (!text.contains('wireguard://') && !text.contains('wg://')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Copy a wireguard:// link first, then tap import'),
        ),
      );
      return;
    }
    try {
      final r = await xray.importLinksAsync(text);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              // Build 2074 (audit items 6+27): the count routes
              // through latDigits(), and a failed import is a
              // plain sentence — the parser's raw first error
              // stays out of the SnackBar.
              r.added > 0
                  ? 'Imported ${latDigits(r.added)} config${r.added == 1 ? '' : 's'}'
                  : 'Nothing importable in the clipboard',
            ),
          ),
        );
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Nothing importable in the clipboard')),
        );
      }
    }
  }

  Future<void> _connect(BuildContext context, Profile p) async {
    try {
      if (xray.state.running && xray.selected?.id == p.id) {
        await xray.disconnect();
        return;
      }
      await xray.connectWireGuardWithFallback(p);
    } on StateError catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              // Build 2074 (audit item 6): only the known code
              // gets its sentence; any other StateError message
              // is raw internals and stays out of the SnackBar.
              e.message == 'wg-all-peers-failed'
                  ? 'No peer of this config carried traffic — '
                        'the endpoints may be filtered or down'
                  : 'The tunnel did not start — check the core logs',
            ),
          ),
        );
      }
    } catch (e) {
      // Build 2070 (review §3.4): a plain line, not the raw
      // exception — the detail stays in the controller's
      // diagnostics journal and the log page.
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('The tunnel did not start — check the core logs'),
          ),
        );
      }
    }
  }

  // Build 2095 (owner-reported appearance fix): the same
  // container-level frosted backing as the V2Ray list —
  // these profile rows (MapGlass blur: false) rendered on
  // the bare dotted map.
  @override
  Widget build(BuildContext context) {
    return MapListFrost(
      child: ListenableBuilder(
        listenable: xray,
        builder: (context, _) {
          final profiles = wgProfilesOf(xray);
          // Group peers of one imported config together.
          final groups = <String, List<Profile>>{};
          for (final p in profiles) {
            groups.putIfAbsent(wgGroupKey(p), () => []).add(p);
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            children: [
              // Build 2149 (audit A48-04): the header zone is
              // PAGE composition now, not a floating card —
              // with no configs the rimmed luminous panel
              // occupied the top third over ≈55% void, and
              // its ✕ duplicated the shell header's BACK
              // (the 2148 navigation model: BACK is the one
              // leave affordance on a non-Home tab). The
              // title, the import actions and the empty copy
              // sit open on the ground, as the pro6-wireguard
              // composition lays them out; the profile rows
              // below keep their own cards. [onClose] stays
              // in the view's contract (the shell passes it)
              // but no longer renders a second control.
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'WireGuard configurations',
                    style: Ember.heading,
                  ),
                  const SizedBox(height: 10),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        MapActionPill(
                          icon: Icons.folder_open_rounded,
                          label: 'Import file',
                          onTap: () => importWgConfFile(context, xray),
                        ),
                        MapActionPill(
                          icon: Icons.content_paste_rounded,
                          label: 'Paste .conf',
                          onTap: () => _importConf(context),
                        ),
                        MapActionPill(
                          icon: Icons.link_rounded,
                          label: 'Paste link',
                          onTap: () => _importLink(context),
                        ),
                        // Build 2095 (whole-app journey audit
                        // #47): scan a WireGuard QR from this
                        // view too — the scanner used to live
                        // only on the V2Ray tab.
                        MapActionPill(
                          icon: Icons.qr_code_scanner_rounded,
                          label: 'Scan QR',
                          onTap: () => scanAndImport(context, xray),
                        ),
                        // Build 2095 (whole-app journey audit
                        // #48): add a config by hand — the
                        // editor refuses to save it without
                        // the private key, peer key and
                        // endpoint.
                        MapActionPill(
                          icon: Icons.edit_rounded,
                          label: 'Add manually',
                          onTap: () => openProfileEditor(
                            context,
                            xray,
                            draft: Profile(
                              id: newProfileId(),
                              name: 'WireGuard',
                              protocol: Protocol.wireguard,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (profiles.isEmpty) ...[
                      const SizedBox(height: 10),
                      Text(
                        'Nothing here yet. Import a .conf file from '
                        'storage, or paste its text; several peers '
                        'in one file become a fallback group.',
                        style: Ember.caption,
                      ),
                    ],
                ],
              ),
              for (final entry in groups.entries) ...[
                if (entry.value.length > 1) ...[
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          entry.value.first.name
                              .split(' · ')
                              .first
                              .toUpperCase(),
                          style: const TextStyle(
                            fontSize: Ember.fontMicro,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1.6,
                            color: MapUi.dim,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        '${latDigits(entry.value.length)} peers · fallback on',
                        style: Ember.caption,
                      ),
                    ],
                  ),
                ],
                for (final p in entry.value) ...[
                  const SizedBox(height: 10),
                  _WgProfileRow(
                    xray: xray,
                    profile: p,
                    onConnect: () => _connect(context, p),
                  ),
                ],
              ],
            ],
          );
        },
      ),
    );
  }
}

class _WgProfileRow extends StatelessWidget {
  const _WgProfileRow({
    required this.xray,
    required this.profile,
    required this.onConnect,
  });

  final XrayController xray;
  final Profile profile;
  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context) {
    final p = profile;
    final live = xray.state.running && xray.selected?.id == p.id;
    return MapGlass(
      // Build 2074 (audit item 13): repeated list rows render
      // without a live BackdropFilter — the static-fill pattern
      // OpenVPN's list already used.
      blur: false,
      padding: const EdgeInsets.all(14),
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
                      // Build 2045: the name the user sees.
                      p.displayName,
                      style: Ember.heading,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      '${p.address}:${p.port}',
                      // Build 2144: endpoints read as monospace
                      // data lines, as in the pro6 sample.
                      style: Ember.caption.copyWith(fontFamily: 'monospace'),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              EmberChip(
                label: live
                    ? 'Disconnect'
                    : xray.connecting
                    ? 'Working…'
                    : 'Connect',
                selected: live,
                onTap: xray.connecting ? null : onConnect,
              ),
            ],
          ),
          const SizedBox(height: 9),
          Wrap(
            spacing: 7,
            runSpacing: 7,
            children: [
              EmberChip(
                label: p.delayMs >= 0
                    ? 'Ping ${latDigits(p.delayMs)}ms'
                    : p.delayFailed
                    ? 'Ping failed'
                    : 'Ping —',
                dot: p.delayMs >= 0
                    ? mapPingColor(p.delayMs)
                    : p.delayFailed
                    ? Ember.red
                    : null,
                onTap: () => xray.testDelay(p),
              ),
              if (p.exitIp.isNotEmpty)
                EmberChip(
                  label:
                      'Exit ${p.exitIp}'
                      '${p.exitCountryCode.isNotEmpty ? ' • ${p.exitCountryCode}' : ''}',
                ),
              if (p.hasSupportedAmneziaParams)
                EmberChip(
                  // Build 2050 (audit C-1): the chip tells the
                  // truth for the LIVE row — a session the AWG
                  // engine could not start runs plain, and the
                  // row says so instead of claiming obfuscation.
                  // Build 2106 (journey audit F-05): the chip
                  // keys on the parameters the engine actually
                  // runs — a J1–J3-only profile gets no
                  // AmneziaWG claim at all (see the J chip
                  // below).
                  label: live && xray.awgFallbackNotice.isNotEmpty
                      ? 'AmneziaWG failed — running plain WireGuard'
                      : 'AmneziaWG — runs obfuscated',
                ),
              if (p.hasUnsupportedJParams)
                EmberChip(
                  // Build 2106 (journey audit F-05): J1–J3
                  // are stored and exported, but the WG
                  // Tunnel engine discards them — the row
                  // says so instead of letting an AmneziaWG
                  // label imply they are applied.
                  label: 'J1–J3 not supported by this engine — ignored',
                ),
              // Build 2116 (audit WGX-1): a single-family
              // profile leaves the other family's traffic
              // on the real network — the row says which.
              if (wgUncoveredChipLabel(p) != null)
                EmberChip(label: wgUncoveredChipLabel(p)!),
              if (profileHasTotals(p)) EmberChip(label: fmtProfileTotals(p)),
              // Build 2095 (whole-app journey audit #49):
              // edit this config in the profile editor.
              MapActionPill(
                icon: Icons.edit_rounded,
                label: 'Edit',
                onTap: () => openProfileEditor(context, xray, existing: p),
              ),
              // Build 2095 (whole-app journey audit #50):
              // share the config as its wireguard:// link.
              MapActionPill(
                icon: Icons.copy_rounded,
                label: 'Copy link',
                onTap: () async {
                  // Build 2098 (post-2097 audit L23): the
                  // link carries the config's PRIVATE key —
                  // it goes through the self-clearing copy
                  // every other secret in the app uses, not
                  // a plain clipboard write that leaves the
                  // key readable by any app, indefinitely.
                  await copySensitive(profileToLink(p));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Link copied')),
                    );
                  }
                },
              ),
              // Build 2095 (whole-app journey audit #33):
              // export the config as a .conf file other
              // WireGuard clients can import.
              MapActionPill(
                icon: Icons.file_download_rounded,
                label: 'Export .conf',
                onTap: () async {
                  final saved = await XrayPlatform.saveTextFile(
                    '${p.displayName.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_')}.conf',
                    wgConfFromProfile(p),
                  );
                  // Build 2098 (verification V-5): null
                  // means another save is already open and
                  // will report for itself — say nothing.
                  if (saved == null) return;
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          saved ? 'Config file saved' : 'Save cancelled',
                        ),
                      ),
                    );
                  }
                },
              ),
              MapActionPill(
                icon: Icons.delete_outline_rounded,
                label: 'Delete',
                onTap: () async {
                  final confirm = await showDialog<bool>(
                    context: context,
                    builder: (dialogContext) => AlertDialog(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(24),
                      ),
                      title: Text(
                        'Delete ${p.displayName}?',
                        style: Ember.heading,
                      ),
                      content: Text(
                        // Build 2098 (post-2097 audit L17):
                        // the disconnect-first disclosure,
                        // matching the multi-delete wording.
                        'This removes the config and its stored '
                        'traffic totals. If it is connected, it '
                        'is disconnected first.',
                        style: Ember.body,
                      ),
                      actions: [
                        TextButton(
                          onPressed: () =>
                              Navigator.of(dialogContext).pop(false),
                          child: const Text(
                            'Cancel',
                            style: TextStyle(color: Ember.dim),
                          ),
                        ),
                        EmberButton(
                          label: 'Delete',
                          onTap: () => Navigator.of(dialogContext).pop(true),
                        ),
                      ],
                    ),
                  );
                  if (confirm != true || !context.mounted) return;
                  if (live) await xray.disconnect();
                  await xray.deleteProfile(p);
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The Accounts tab in WireGuard mode: no account — the
/// configs are the user's own files; session numbers instead.
class WireGuardAboutView extends StatelessWidget {
  const WireGuardAboutView({super.key, required this.xray});

  final XrayController xray;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: xray,
      builder: (context, _) {
        final count = wgProfilesOf(xray).length;
        final on = xray.state.running;
        final selected = xray.selected;
        return ListView(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
          children: [
            // Build 2145: the tracked engine label over the
            // title, matching the home composition.
            Center(
              child: Text('ENGINE · WIREGUARD', style: Ember.microLabelOrange),
            ),
            const SizedBox(height: 8),
            // Build 2144: the page title in the samples'
            // large light hero type.
            Center(child: Text('WireGuard', style: Ember.hero)),
            Center(
              child: Text('Your own configs, no account', style: Ember.caption),
            ),
            const SizedBox(height: 16),
            MapGlass(
              blur: false,
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    on && selected != null
                        // Build 2045: the name the user sees.
                        // Build 2075 (item 18): "Connected"
                        // only when the peer has answered —
                        // a WireGuard selection whose peer is
                        // silent reads "Tunnel up" instead.
                        ? (selected.protocol == Protocol.wireguard &&
                                  !wgPeerLiveness(xray).proven
                              ? 'Tunnel up: ${selected.displayName}'
                              : 'Connected: ${selected.displayName}')
                        : 'Not connected',
                    style: Ember.heading,
                    // Build 2059 (audit §6 appearance low): the name
                    // can be long — ellipsis, never overflow.
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${latDigits(count)} WireGuard config${count == 1 ? '' : 's'} '
                    'in the store',
                    style: Ember.body,
                  ),
                  // Build 2145: the session's figures read as
                  // the same hairline mono table the home
                  // composition carries (bare here — this card
                  // is the panel). It subsumes the old standalone
                  // transfer row: TRANSFER shows the live bytes
                  // under the same on-and-selected condition.
                  if (selected != null &&
                      selected.protocol == Protocol.wireguard) ...[
                    const SizedBox(height: 4),
                    _WgSessionTable(
                      xray: xray,
                      profile: selected,
                      panel: false,
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
