/// The Aether engines' pages, Map Control edition (build
/// 2032): WARP (sample s23 — the radar) and MASQUE (sample
/// s24 — the broken shells), rebuilt in Ember's theme over the
/// ralysnd engines taken as they are. Every number on these
/// pages rides from the engine's real state (its stage
/// vocabulary, its selected endpoint, a Cloudflare trace
/// through the tunnel) — nothing is decorative data.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../aether/aether_controller.dart';
import '../../aether/aether_platform.dart';
import '../../xray/xray_controller.dart';
import 'cf_scanner_page.dart';
import 'ember_dialogs.dart';
import 'ember_format.dart';
import 'ember_theme.dart';
import 'map_widgets.dart';
import 'warp_settings_page.dart';

const _scanModes = ['turbo', 'balanced', 'thorough', 'stealth', 'ironclad'];
const _ipModes = ['v4', 'v6', 'both'];

/// Batch 4 (pro6 fidelity rollout): the flat hairline panel —
/// a solid card fill and a 1 px hairline edge, no blur, no
/// gradient wash, no luminous ring — that replaces MapGlass
/// on the recomposed Aether home surfaces (the same panel
/// the Psiphon/OpenVPN/Lantern surfaces carry in their own
/// files).
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

/// Batch 4 (pro6-warp): the status card's hero word — what
/// the tunnel IS, from the state that proves it. A trace
/// that answered carries the tier (plus → WARP+, on/off →
/// WARP); with no trace the hero is the slot's own name
/// (WARP / MASQUE, the controller's displayName). The
/// connection STATE is not the hero's job any more — it
/// reads as the tracked status line under the hero, in the
/// engine's own words, verbatim (the honesty contract is
/// untouched: the same words, the same conditions).
String _aetherHeroWord(AetherController c) {
  final warp = c.exitTrace?['warp'] ?? '';
  if (warp == 'plus') return 'WARP+';
  if (warp.isNotEmpty) return 'WARP';
  return c.displayName;
}

String _scanLabel(String m) => switch (m) {
  'turbo' => 'Turbo',
  'balanced' => 'Balanced',
  'thorough' => 'Thorough',
  'stealth' => 'Stealth',
  'ironclad' => 'Ironclad',
  _ => m,
};

/// Build 2145 (composition rebuild, pro6-warp): the PROTOCOL
/// row's value for the trace panel — the slot's real carrier,
/// from the options the engine actually runs. The WARP slot
/// is WireGuard by construction (its home page says so); a
/// MASQUE-family carrier appends its fixed transport, and
/// under Auto the ladder decides per rung, so no transport
/// is claimed.
String _aetherProtocolLabel(AetherController c) {
  if (c.isWarp) return 'WireGuard';
  final o = c.options;
  final base = switch (o.protocol) {
    'wg' => 'WireGuard',
    'gool' => 'WARP in WARP',
    'mim' => 'MASQUE in MASQUE',
    _ => 'MASQUE',
  };
  final carrier =
      o.protocol == 'masque' || o.protocol == 'gool' || o.protocol == 'mim';
  if (!carrier) return base;
  return switch (o.transport) {
    'h3' => '$base · HTTP/3',
    'h2' => '$base · HTTP/2',
    _ => base,
  };
}

/// Build 2145: one hairline row of the exit-trace panel — a
/// tracked label at the left, the mono value in the sample's
/// right-hand column, a hairline under all but the last row.
class _AetherTraceRow extends StatelessWidget {
  const _AetherTraceRow({
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

/// A mono trace value for the panel's data column.
Widget _aetherMono(String text, {Color? color}) => Text(
  text,
  style: Ember.body.copyWith(fontFamily: 'monospace', color: color),
  overflow: TextOverflow.ellipsis,
);

/// The shared status card: stage dot + the engine's own stage
/// label, the selected endpoint, the identity state, and —
/// loudly — the last failure with the engine log tail.
class _AetherStatusCard extends StatelessWidget {
  const _AetherStatusCard({required this.controller, required this.title});

  final AetherController controller;
  final String title;

  @override
  Widget build(BuildContext context) {
    final state = controller.state;
    final on = controller.connected;
    final error = controller.lastError == null
        ? null
        : aetherErrorText(controller.lastError!);
    // Build 2145 (composition rebuild, pro6-warp): hero-first —
    // the card's glass is retired; the mode reads as the
    // sample's open composition: the tracked CLOUDFLARE label
    // (the sample's 'CLOUDFLARE · MASQUE' where the mode is
    // MASQUE; the slot's/protocol's existing names govern the
    // other modes), then the status word at hero scale with
    // its stage dot, then the endpoint/identity lines as
    // before. Same state, same stage vocabulary, same lines.
    // Batch 4 (pro6 fidelity rollout): the cluster takes the
    // sample's centred composition — the tracked label, the
    // hero word (what the tunnel IS: _aetherHeroWord), and
    // the state as a tracked status line (stage dot + the
    // verbatim state word, the WireGuard home's pattern).
    // The data lines below keep the left-aligned flow.
    final tracked = controller.isWarp
        ? 'CLOUDFLARE · WARP'
        : switch (controller.options.protocol) {
            'masque' => 'CLOUDFLARE · MASQUE',
            'wg' => 'CLOUDFLARE · WIREGUARD',
            'gool' => 'CLOUDFLARE · WARP IN WARP',
            'mim' => 'CLOUDFLARE · MASQUE IN MASQUE',
            _ => 'CLOUDFLARE · ${title.toUpperCase()}',
          };
    final stateWord = on
        ? 'Connected'
        : state.running || controller.connecting
        ? (state.stageLabel.isNotEmpty ? state.stageLabel : 'Connecting…')
        : 'Not connected';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Center(child: Text(tracked, style: Ember.microLabelOrange)),
        const SizedBox(height: 10),
        // Build 2147 (strict-audit F11): no FittedBox —
        // the hero word ellipsises at extreme scales
        // instead of shrinking off-token. (No Flexible:
        // this column's height is unbounded.)
        SizedBox(
          width: double.infinity,
          child: Text(
            _aetherHeroWord(controller),
            style: Ember.hero,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 9,
              height: 9,
              decoration: BoxDecoration(
                color: on
                    ? Ember.green
                    : state.running || controller.connecting
                    ? Ember.amber
                    : Ember.faint,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
            Flexible(child: Text(stateWord, style: Ember.microLabel)),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          state.server.isNotEmpty
              ? 'Endpoint ${state.server}'
                    '${state.rtt.isNotEmpty ? ' • ${state.rtt}' : ''}'
              : state.identity
              ? 'Identity ready — the engine scans and picks an '
                    'endpoint when it connects.'
              : 'No identity yet — the first connect registers '
                    'one (free and anonymous).',
          // Build 2144: a real endpoint reads as the
          // sample's monospace data line; the identity
          // sentences keep the body style.
          style: state.server.isNotEmpty
              ? Ember.body.copyWith(fontFamily: 'monospace', color: MapUi.body)
              : Ember.body,
        ),
        if (state.profile.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text('Obfuscation: ${state.profile}', style: Ember.caption),
        ],
        if (state.probeTopReason.isNotEmpty && !on) ...[
          const SizedBox(height: 4),
          Text(
            'Most probes failed with: ${state.probeTopReason}',
            style: Ember.caption,
          ),
        ],
        // Build 2125 (audit A25-28): the Dart re-probe's
        // stale verdict — the core still claims the
        // session, but repeated trace probes through it
        // stopped answering. The session is NOT torn
        // down on a probe's say-so (build 2115's lesson);
        // the page says what the probes see.
        if (controller.dataPlaneStale && on) ...[
          const SizedBox(height: 4),
          Text(
            'The engine still reports this session up, but '
            'repeated checks through it are failing — the '
            'tunnel may have stopped carrying traffic.',
            style: Ember.caption,
          ),
        ],
        if (error != null && !controller.connected) ...[
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                Icons.error_outline_rounded,
                size: 15,
                color: Ember.red,
              ),
              const SizedBox(width: 6),
              Expanded(child: Text(error, style: Ember.caption)),
            ],
          ),
        ],
      ],
    );
  }
}

/// The exit card: the Cloudflare trace through the tunnel —
/// shown only when a trace actually answered.
/// Build 2056 (audit Batch 11): the exit card renders nothing
/// without a trace — the spacers around it must not render either.
/// Mirrors the card's own empty condition (no trace, or no IP).
bool _hasExit(AetherController c) {
  final t = c.exitTrace;
  return t != null && (t['ip'] ?? '').isNotEmpty;
}

/// Build 2115: the session is up on the data proof alone and
/// no trace ever landed — the page says the exit is
/// unverified instead of showing no exit card at all (which
/// read as "not connected" when the old flow tore the engine
/// down; the session is alive now and must not look dead).
bool _showUnverifiedExit(AetherController c) =>
    c.connected && c.exitUnverified && !_hasExit(c);

class _AetherExitCard extends StatelessWidget {
  const _AetherExitCard({required this.controller});

  final AetherController controller;

  @override
  Widget build(BuildContext context) {
    final t = controller.exitTrace;
    if (t == null) return const SizedBox.shrink();
    final ip = t['ip'] ?? '';
    final loc = t['loc'] ?? '';
    final colo = t['colo'] ?? '';
    final warp = t['warp'] ?? '';
    if (ip.isEmpty) return const SizedBox.shrink();
    // Build 2145 (composition rebuild, pro6-warp): the trace
    // reads as the sample's hairline panel of rows — WARP,
    // COLO, IP, PROTOCOL — only the fields the trace really
    // returned (PROTOCOL is the slot's real carrier, from its
    // options), mono values; rows a trace lacks are omitted.
    // Refresh keeps its own line at the right, as before
    // (build 2074, audit item 16).
    final rows = <(String, Widget)>[
      if (warp.isNotEmpty)
        (
          'WARP',
          // Batch 4 (pro6-warp): the row is the boolean the
          // sample shows (ON / OFF) — the tier rides the
          // status card's hero word (WARP+), not this row.
          _aetherMono(
            warp == 'off' ? 'OFF' : 'ON',
            // Build 2147 (strict-audit F2): ON reads green —
            // the status colour, not the accent.
            color: warp == 'off' ? Ember.red : Ember.green,
          ),
        ),
      if (colo.isNotEmpty)
        ('COLO', _aetherMono(loc.isNotEmpty ? '$colo · $loc' : colo)),
      ('IP', _aetherMono(ip)),
      ('PROTOCOL', _aetherMono(_aetherProtocolLabel(controller))),
    ];
    // Batch 4: the flat hairline panel (was MapGlass).
    return _HairlinePanel(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < rows.length; i++)
            _AetherTraceRow(
              label: rows[i].$1,
              value: rows[i].$2,
              last: i == rows.length - 1,
            ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: MapActionPill(
              icon: Icons.refresh_rounded,
              label: 'Refresh',
              onTap: controller.tunRunning
                  ? () => controller.refreshTrace()
                  : null,
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

/// Build 2115: the exit card for a session the data proof
/// carried but no trace ever verified. The session is up and
/// moving traffic; what is missing is the exit's identity,
/// and the card says exactly that — with the trace fetch's
/// own recorded failure when the native side has one — plus
/// the same Refresh the verified card offers, since a trace
/// that lands later closes the question.
class _AetherUnverifiedExitCard extends StatelessWidget {
  const _AetherUnverifiedExitCard({required this.controller});

  final AetherController controller;

  @override
  Widget build(BuildContext context) {
    final error = controller.exitTraceError;
    // Batch 4: the flat hairline panel (was MapGlass).
    return _HairlinePanel(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.public_off_rounded, size: 16, color: MapUi.dim),
              const SizedBox(width: 8),
              Expanded(child: Text('Exit unverified', style: Ember.body)),
              EmberChip(label: 'WARP ?', dot: Ember.orange),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'The tunnel is carrying your traffic, but the exit '
            'check did not answer, so the exit is not confirmed '
            'as WARP.',
            style: Ember.caption,
          ),
          if (error.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text('Last check: $error', style: Ember.caption),
          ],
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: MapActionPill(
              icon: Icons.refresh_rounded,
              label: 'Refresh',
              onTap: controller.tunRunning
                  ? () => controller.refreshTrace()
                  : null,
            ),
          ),
        ],
      ),
    );
  }
}

/// Build 2092 (item 19): the status card's error line in
/// plain words. The engine's own short failure strings are
/// already user-facing and pass through; anything shaped
/// like a Dart/platform exception becomes one plain
/// sentence — the raw text stays in the engine log below.
String aetherErrorText(String raw) {
  if (raw.contains('Exception') ||
      raw.contains('MissingPlugin') ||
      raw.contains('PlatformException')) {
    return 'The engine reported an error — the detail is in '
        'the engine log.';
  }
  return raw;
}

/// The engine log tail (the shim's ring of real core lines).
/// Build 2092 (item 60): the card no longer clips silently
/// to the last 14 lines while Copy takes all — a Show all /
/// Show less pill expands it in place.
class _AetherLogCard extends StatefulWidget {
  const _AetherLogCard({required this.controller});

  final AetherController controller;

  @override
  State<_AetherLogCard> createState() => _AetherLogCardState();
}

class _AetherLogCardState extends State<_AetherLogCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final log = widget.controller.state.log;
    if (log.isEmpty) return const SizedBox.shrink();
    final lines = log.split('\n');
    final clipped = !_expanded && lines.length > 14;
    // Batch 4: the flat hairline panel (was MapGlass).
    return _HairlinePanel(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text('Engine log', style: Ember.heading)),
              if (lines.length > 14)
                MapActionPill(
                  icon: _expanded
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  label: _expanded ? 'Show less' : 'Show all',
                  onTap: () => setState(() => _expanded = !_expanded),
                ),
              const SizedBox(width: 8),
              MapActionPill(
                icon: Icons.copy_rounded,
                label: 'Copy',
                onTap: () => Clipboard.setData(ClipboardData(text: log)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SelectableText(
            clipped ? lines.skip(lines.length - 14).join('\n') : log,
            style: Ember.caption.copyWith(fontFamily: 'monospace'),
          ),
        ],
      ),
    );
  }
}

Widget _chipRow({
  required List<String> values,
  required String current,
  required String Function(String) label,
  required ValueChanged<String>? onPick,
}) {
  return Wrap(
    spacing: 7,
    runSpacing: 7,
    children: [
      for (final v in values)
        EmberChip(
          label: label(v),
          selected: current == v,
          onTap: onPick == null ? null : () => onPick(v),
        ),
    ],
  );
}

/// The WARP home (mode 6): the status card, the exit card,
/// and the engine's own controls (scan profile, address
/// family, endpoint scan + pin, identity). (s23's radar was
/// decoration only and left in batch 4.)
class WarpHomePage extends StatelessWidget {
  const WarpHomePage({super.key, required this.warp});

  final AetherController warp;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: warp,
      builder: (context, _) {
        final o = warp.options;
        final locked = warp.tunRunning || warp.connecting;
        // Build 2116 (AP-05): the top gap reads this page's
        // own height via LayoutBuilder, as the V2Ray/Psiphon
        // homes do — not the full device height.
        return LayoutBuilder(
          builder: (context, constraints) => ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            children: [
              // Build 2074 (audit item 3): the top spacer is a
              // capped fraction of the viewport height, not a
              // fixed 150dp.
              SizedBox(
                // Build 2092 (item 39): the shared home top gap.
                height: emberHomeTopGap(constraints.maxHeight),
              ),
              // Build 2145 (pro6-warp): hero first — the status
              // composition, then the trace panel; the radar is
              // demoted below them. WarpRadar is purely
              // presentational (its own doc: the rings say
              // nothing the status card does not), so it carries
              // no data or interaction the panel order depends
              // on.
              // Batch 4 (pro6 fidelity rollout): the radar
              // leaves the page — the sample's composition has
              // no radar, and the widget was decoration only.
              _AetherStatusCard(controller: warp, title: 'Cloudflare WARP'),
              if (_hasExit(warp)) ...[
                const SizedBox(height: 12),
                _AetherExitCard(controller: warp),
              ],
              if (_showUnverifiedExit(warp)) ...[
                const SizedBox(height: 12),
                _AetherUnverifiedExitCard(controller: warp),
              ],
              const SizedBox(height: 12),
              // Batch 4: the flat hairline panel (was MapGlass).
              _HairlinePanel(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Build 2095 (whole-app journey audit #37):
                    // the page says why there is no transport
                    // row here — this slot is WireGuard by
                    // construction (the MASQUE slot carries the
                    // carrier choice).
                    Text(
                      'WARP runs over WireGuard — there is no '
                      'carrier transport to choose for this slot.',
                      style: Ember.caption,
                    ),
                    const SizedBox(height: 13),
                    Text('Scan profile', style: Ember.microLabelOrange),
                    const SizedBox(height: 9),
                    _chipRow(
                      values: _scanModes,
                      current: o.scan,
                      label: _scanLabel,
                      onPick: locked
                          ? null
                          : (v) => warp.setOptions(o.copyWith(scan: v)),
                    ),
                    const SizedBox(height: 13),
                    // Build 2095 (whole-app journey audit #36):
                    // the noise (obfuscation) profile, wired to
                    // the engine's aethernoize set for WireGuard.
                    Text('Noise profile', style: Ember.microLabelOrange),
                    const SizedBox(height: 9),
                    _chipRow(
                      values: const [
                        '',
                        'off',
                        'light',
                        'balanced',
                        'aggressive',
                      ],
                      current: o.noize,
                      label: (v) => switch (v) {
                        'off' => 'Off',
                        'light' => 'Light',
                        'aggressive' => 'Aggressive',
                        'balanced' => 'Balanced',
                        _ => 'Default',
                      },
                      onPick: locked
                          ? null
                          : (v) => warp.setOptions(o.copyWith(noize: v)),
                    ),
                    const SizedBox(height: 13),
                    Text('Address family', style: Ember.microLabelOrange),
                    const SizedBox(height: 9),
                    _chipRow(
                      values: _ipModes,
                      current: o.ip,
                      label: (v) => switch (v) {
                        'v4' => 'IPv4',
                        'v6' => 'IPv6',
                        _ => 'Both',
                      },
                      onPick: locked
                          ? null
                          : (v) => warp.setOptions(o.copyWith(ip: v)),
                    ),
                    if (o.peer != null && o.peer!.isNotEmpty) ...[
                      const SizedBox(height: 13),
                      Row(
                        children: [
                          const Icon(
                            Icons.push_pin_rounded,
                            size: 14,
                            color: MapUi.dim,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              'Pinned endpoint ${o.peer}',
                              style: Ember.body,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          MapActionPill(
                            icon: Icons.clear_rounded,
                            label: 'Clear',
                            onTap: locked
                                ? null
                                : () => warp.setOptions(
                                    o.copyWith(clearPeer: true),
                                  ),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 14),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        MapActionPill(
                          icon: Icons.radar_rounded,
                          label: 'Scan endpoints',
                          onTap: locked
                              ? null
                              : () async {
                                  try {
                                    await warp.scanEndpoints();
                                    if (context.mounted) {
                                      final s = warp.lastScan;
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        SnackBar(
                                          content: Text(
                                            s != null && s.server.isNotEmpty
                                                ? 'Best endpoint: ${s.server}'
                                                      '${s.rtt.isNotEmpty ? ' • ${s.rtt}' : ''}'
                                                : 'The scan finished',
                                          ),
                                        ),
                                      );
                                    }
                                  } catch (e) {
                                    // Build 2070 (review §3.4): a
                                    // plain line, not the raw
                                    // exception — the scan's detail
                                    // stays in the controller's
                                    // lastScan/lastError state.
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(context)
                                          .showSnackBar(
                                            const SnackBar(
                                              content: Text('The scan failed'),
                                            ),
                                          );
                                    }
                                  }
                                },
                        ),
                        if (warp.lastScan != null &&
                            warp.lastScan!.server.isNotEmpty)
                          MapActionPill(
                            icon: Icons.push_pin_rounded,
                            label: 'Pin scanned endpoint',
                            onTap: locked
                                ? null
                                : () => warp.setOptions(
                                    o.copyWith(peer: warp.lastScan!.server),
                                  ),
                          ),
                        MapActionPill(
                          icon: Icons.fingerprint_rounded,
                          label: 'Reset identity',
                          onTap: locked || !warp.state.identity
                              ? null
                              : () async {
                                  // Build 2092 (item 27): the
                                  // reset discards the registered
                                  // identity — it confirms first.
                                  final confirmed = await showEmberConfirm(
                                    context,
                                    title: 'Reset identity?',
                                    message:
                                        'The registered WARP identity '
                                        'is discarded. The next connect '
                                        'registers a fresh one.',
                                    confirmLabel: 'Reset',
                                  );
                                  if (!confirmed) return;
                                  await warp.resetIdentity();
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text(
                                          'Identity cleared — the next connect '
                                          'registers a fresh one',
                                        ),
                                      ),
                                    );
                                  }
                                },
                        ),
                      ],
                    ),
                    if (warp.state.running) ...[
                      const SizedBox(height: 12),
                      Text(
                        'Local proxy  SOCKS 127.0.0.1:'
                        '${latDigits(AetherPlatform.cfwarpSocksPort)}',
                        style: Ember.caption,
                      ),
                    ],
                  ],
                ),
              ),
              if (warp.state.log.isNotEmpty) ...[
                const SizedBox(height: 12),
                _AetherLogCard(controller: warp),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// The MASQUE home (mode 7): s24's protocol shells — MASQUE,
/// WireGuard or WARP-in-WARP from the one Aether binary — with
/// the carrier options ralysnd exposes (transport, fragment,
/// scan, keepalive, noise profile).
class MasqueHomePage extends StatelessWidget {
  const MasqueHomePage({super.key, required this.masque});

  final AetherController masque;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: masque,
      builder: (context, _) {
        final o = masque.options;
        final locked = masque.tunRunning || masque.connecting;
        final carrier =
            o.protocol == 'masque' ||
            o.protocol == 'gool' ||
            o.protocol == 'mim';
        // Build 2116 (AP-05): LayoutBuilder page height, as
        // on the V2Ray/Psiphon homes — not the device height.
        return LayoutBuilder(
          builder: (context, constraints) => ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            children: [
              // Build 2074 (audit item 3): the top spacer is a
              // capped fraction of the viewport height, not a
              // fixed 150dp.
              SizedBox(
                // Build 2092 (item 39): the shared home top gap.
                height: emberHomeTopGap(constraints.maxHeight),
              ),
              _AetherStatusCard(controller: masque, title: 'Aether'),
              if (_hasExit(masque)) ...[
                const SizedBox(height: 12),
                _AetherExitCard(controller: masque),
              ],
              if (_showUnverifiedExit(masque)) ...[
                const SizedBox(height: 12),
                _AetherUnverifiedExitCard(controller: masque),
              ],
              const SizedBox(height: 12),
              // Batch 4 (pro6 fidelity rollout): the flat
              // hairline panel — the luminous MapGlass rim
              // leaves; the hairline dividers between the
              // section groups (below) carry the separation.
              _HairlinePanel(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Protocol', style: Ember.microLabelOrange),
                    const SizedBox(height: 9),
                    _chipRow(
                      values: const ['masque', 'wg', 'gool', 'mim'],
                      current: o.protocol,
                      label: (v) => switch (v) {
                        'wg' => 'WireGuard',
                        'gool' => 'WARP in WARP',
                        'mim' => 'MASQUE in MASQUE',
                        _ => 'MASQUE',
                      },
                      onPick: locked
                          ? null
                          : (v) => masque.setOptions(o.copyWith(protocol: v)),
                    ),
                    const SizedBox(height: 6),
                    Text(switch (o.protocol) {
                      'wg' =>
                        'Cloudflare WARP over WireGuard, '
                            'scanned endpoints.',
                      'gool' =>
                        'Two nested WARP tunnels — the inner '
                            'one hides the outer one\u2019s exit.',
                      'mim' =>
                        'Two nested MASQUE tunnels on the one '
                            'carrier — a different exit address.',
                      _ =>
                        'Cloudflare WARP over MASQUE (HTTP/3 or '
                            'HTTP/2), with the firewall noise profile.',
                    }, style: Ember.caption),
                    if (carrier) ...[
                      const SizedBox(height: 9),
                      const Divider(color: MapUi.line, height: 1),
                      const SizedBox(height: 12),
                      Text('Transport', style: Ember.microLabelOrange),
                      const SizedBox(height: 9),
                      _chipRow(
                        // Build 2074 (MasqueCarrier): 'auto' starts
                        // on the carrier this network remembered
                        // (HTTP/2 where that is what worked, else
                        // HTTP/3) and learns from the core's own
                        // "Accepted via HTTP/2" line; explicit
                        // HTTP/3 / HTTP/2 never learn.
                        // Build 2083: 'auto' is the default and
                        // walks the full carrier ladder natively
                        // in one connect (MasqueRung); a pick here
                        // is marked explicit (transportExplicit)
                        // so the one-time migration never overrides
                        // a real choice.
                        values: const ['h3', 'h2', 'auto'],
                        current: o.transport,
                        label: (v) => switch (v) {
                          'h2' => 'HTTP/2',
                          'auto' => 'Auto',
                          _ => 'HTTP/3',
                        },
                        onPick: locked
                            ? null
                            : (v) => masque.setOptions(
                                o.copyWith(
                                  transport: v,
                                  transportExplicit: true,
                                ),
                              ),
                      ),
                      if (o.transport == 'auto') ...[
                        const SizedBox(height: 6),
                        Text(
                          'Remembers the carrier that worked on this '
                          'network — HTTP/2 where that is what '
                          'connected, HTTP/3 otherwise.',
                          style: Ember.caption,
                        ),
                      ],
                      // Build 2095 (whole-app journey audit
                      // #20): the fragment toggle is meaningful
                      // only for an explicit HTTP/2 carrier —
                      // under Auto the ladder's rungs decide, so
                      // the row hides instead of pretending.
                      if (o.transport != 'auto') ...[
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                'Fragment the HTTP/2 handshake',
                                style: Ember.body,
                              ),
                            ),
                            MapToggle(
                              value: o.fragment,
                              onChanged: locked
                                  ? null
                                  : (v) => masque.setOptions(
                                      o.copyWith(fragment: v),
                                    ),
                            ),
                          ],
                        ),
                      ],
                    ],
                    const SizedBox(height: 9),
                    const Divider(color: MapUi.line, height: 1),
                    const SizedBox(height: 12),
                    Text('Scan profile', style: Ember.microLabelOrange),
                    const SizedBox(height: 9),
                    _chipRow(
                      values: _scanModes,
                      current: o.scan,
                      label: _scanLabel,
                      onPick: locked
                          ? null
                          : (v) => masque.setOptions(o.copyWith(scan: v)),
                    ),
                    const SizedBox(height: 9),
                    const Divider(color: MapUi.line, height: 1),
                    const SizedBox(height: 12),
                    // Build 2095 (whole-app journey audit #36):
                    // the noise profile the copy claims, as a
                    // real control. The value set follows the
                    // protocol: MASQUE's table knows 'firewall';
                    // WireGuard/WARP-in-WARP read the
                    // aethernoize set (off/light/balanced/
                    // aggressive).
                    Text('Noise profile', style: Ember.microLabelOrange),
                    const SizedBox(height: 9),
                    if (o.protocol == 'masque')
                      _chipRow(
                        values: const ['', 'firewall'],
                        current: o.noize == 'firewall' ? 'firewall' : '',
                        label: (v) => v == 'firewall' ? 'Firewall' : 'Default',
                        onPick: locked
                            ? null
                            : (v) => masque.setOptions(o.copyWith(noize: v)),
                      )
                    else
                      _chipRow(
                        values: const [
                          '',
                          'off',
                          'light',
                          'balanced',
                          'aggressive',
                        ],
                        current:
                            const [
                              'off',
                              'light',
                              'balanced',
                              'aggressive',
                            ].contains(o.noize)
                            ? o.noize
                            : '',
                        label: (v) => switch (v) {
                          'off' => 'Off',
                          'light' => 'Light',
                          'aggressive' => 'Aggressive',
                          'balanced' => 'Balanced',
                          _ => 'Default',
                        },
                        onPick: locked
                            ? null
                            : (v) => masque.setOptions(o.copyWith(noize: v)),
                      ),
                    // Build 2129: mim hides the keepalive too —
                    // AETHER_WG_KEEPALIVE is written for wg/gool
                    // only, so the control would be inert on a
                    // MASQUE-hop protocol.
                    if (o.protocol != 'masque' && o.protocol != 'mim') ...[
                      const SizedBox(height: 9),
                      const Divider(color: MapUi.line, height: 1),
                      const SizedBox(height: 12),
                      Text(
                        'Keepalive (seconds)',
                        style: Ember.microLabelOrange,
                      ),
                      const SizedBox(height: 9),
                      _chipRow(
                        values: const ['5', '25', '60'],
                        current: '${o.keepalive}',
                        label: (v) => v,
                        onPick: locked
                            ? null
                            : (v) => masque.setOptions(
                                o.copyWith(keepalive: int.parse(v)),
                              ),
                      ),
                    ],
                    const SizedBox(height: 14),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        MapActionPill(
                          icon: Icons.fingerprint_rounded,
                          label: 'Reset identities',
                          onTap: locked || !masque.state.identity
                              ? null
                              : () async {
                                  // Build 2092 (item 27): same
                                  // confirmation as the WARP page.
                                  final confirmed = await showEmberConfirm(
                                    context,
                                    title: 'Reset identities?',
                                    message:
                                        'The registered identities are '
                                        'discarded. The next connect '
                                        'registers fresh ones.',
                                    confirmLabel: 'Reset',
                                  );
                                  if (!confirmed) return;
                                  await masque.resetIdentity();
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text(
                                          'Identities cleared — the next '
                                          'connect registers fresh ones',
                                        ),
                                      ),
                                    );
                                  }
                                },
                        ),
                      ],
                    ),
                    if (masque.state.running) ...[
                      const SizedBox(height: 12),
                      Text(
                        'Local proxy  SOCKS 127.0.0.1:'
                        '${latDigits(AetherPlatform.masqueSocksPort)}',
                        style: Ember.caption,
                      ),
                    ],
                  ],
                ),
              ),
              if (masque.state.log.isNotEmpty) ...[
                const SizedBox(height: 12),
                _AetherLogCard(controller: masque),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// The Servers tab in WARP/MASQUE mode: there is no picker —
/// the engine scans Cloudflare's edge itself. What the user
/// controls is the scan and the pinned endpoint.
/// The Aether slot's own options page (build 2095,
/// whole-app journey audit #6): the Settings row in WARP /
/// MASQUE mode used to open WarpSettingsPage — the
/// EmberWarp profile, a DIFFERENT slot — so the on-screen
/// engine's options (scan, transport, endpoint pin) were
/// unreachable from Settings and the row silently edited
/// another engine's profile. This page edits the slot it
/// names, through the same setOptions store path the home
/// pages use; the EmberWarp profile keeps its own page,
/// linked at the bottom and labelled as a different slot.
/// Build 2116 (A-02): the ECH value editor — a plain text
/// field in the shared form dialog; whatever is saved is
/// handed to the engine verbatim as AETHER_ECH, and an
/// empty value restores the engine default.
Future<String?> _editEch(BuildContext context, String current) async {
  final field = TextEditingController(text: current);
  final saved = await showEmberFormDialog<bool>(
    context,
    title: 'ECH (Encrypted Client Hello)',
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Handed to the engine as-is. Leave empty for the '
          'engine default.',
          style: Ember.body,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: field,
          autofocus: true,
          style: Ember.body,
          decoration: emberField(context, 'Engine default'),
          onSubmitted: (_) => Navigator.of(context).pop(true),
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(false),
        child: const Text('Cancel'),
      ),
      TextButton(
        onPressed: () => Navigator.of(context).pop(true),
        child: const Text('Save'),
      ),
    ],
  );
  final value = saved == true ? field.text.trim() : null;
  field.dispose();
  return value;
}

class AetherOptionsPage extends StatelessWidget {
  const AetherOptionsPage({
    super.key,
    required this.controller,
    required this.xray,
  });

  final AetherController controller;
  final XrayController xray;

  @override
  Widget build(BuildContext context) {
    final isWarp = controller.isWarp;
    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Ember.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Ember.text,
        title: Text(
          isWarp ? 'WARP options' : 'MASQUE options',
          style: Ember.heading,
        ),
      ),
      body: EmberBackground(banded: true, 
        child: ListenableBuilder(
          listenable: controller,
          builder: (context, _) {
            final o = controller.options;
            final locked = controller.tunRunning || controller.connecting;
            final carrier =
                o.protocol == 'masque' ||
                o.protocol == 'gool' ||
                o.protocol == 'mim';
            return ListView(
              padding: EdgeInsets.fromLTRB(
                16,
                MediaQuery.of(context).padding.top + kToolbarHeight + 12,
                16,
                24,
              ),
              children: [
                MapGlass(
                  blur: false,
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (!isWarp) ...[
                        Text('Protocol', style: Ember.microLabelOrange),
                        const SizedBox(height: 9),
                        _chipRow(
                          values: const ['masque', 'wg', 'gool', 'mim'],
                          current: o.protocol,
                          label: (v) => switch (v) {
                            'wg' => 'WireGuard',
                            'gool' => 'WARP in WARP',
                            'mim' => 'MASQUE in MASQUE',
                            _ => 'MASQUE',
                          },
                          onPick: locked
                              ? null
                              : (v) => controller.setOptions(
                                  o.copyWith(protocol: v),
                                ),
                        ),
                        const SizedBox(height: 13),
                      ],
                      if (!isWarp && carrier) ...[
                        Text('Transport', style: Ember.microLabelOrange),
                        const SizedBox(height: 9),
                        _chipRow(
                          values: const ['h3', 'h2', 'auto'],
                          current: o.transport,
                          label: (v) => switch (v) {
                            'h2' => 'HTTP/2',
                            'auto' => 'Auto',
                            _ => 'HTTP/3',
                          },
                          onPick: locked
                              ? null
                              : (v) => controller.setOptions(
                                  o.copyWith(
                                    transport: v,
                                    transportExplicit: true,
                                  ),
                                ),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                'Fragment the HTTP/2 handshake',
                                style: Ember.body,
                              ),
                            ),
                            MapToggle(
                              value: o.fragment,
                              // In Auto the carrier ladder
                              // chooses per rung — the
                              // fragment choice only applies
                              // to a fixed HTTP/2 transport.
                              onChanged: locked || o.transport == 'auto'
                                  ? null
                                  : (v) => controller.setOptions(
                                      o.copyWith(fragment: v),
                                    ),
                            ),
                          ],
                        ),
                        if (o.transport == 'auto') ...[
                          const SizedBox(height: 6),
                          Text(
                            'Fragment applies when a fixed HTTP/2 '
                            'transport is chosen — Auto walks its '
                            'own ladder.',
                            style: Ember.caption,
                          ),
                        ],
                        const SizedBox(height: 13),
                      ],
                      Text('Scan profile', style: Ember.microLabelOrange),
                      const SizedBox(height: 9),
                      _chipRow(
                        values: _scanModes,
                        current: o.scan,
                        label: _scanLabel,
                        onPick: locked
                            ? null
                            : (v) => controller.setOptions(o.copyWith(scan: v)),
                      ),
                      // Build 2098 (post-2097 audit L19): the
                      // address-family row is no longer
                      // WARP-only — the option is
                      // protocol-agnostic (the scan caption
                      // below already reads it for MASQUE),
                      // but MASQUE's settings never showed the
                      // control, so its family could not be
                      // chosen at all.
                      ...[
                        const SizedBox(height: 13),
                        Text('Address family', style: Ember.microLabelOrange),
                        const SizedBox(height: 9),
                        _chipRow(
                          values: _ipModes,
                          current: o.ip,
                          label: (v) => switch (v) {
                            'v4' => 'IPv4',
                            'v6' => 'IPv6',
                            _ => 'Both',
                          },
                          onPick: locked
                              ? null
                              : (v) => controller.setOptions(o.copyWith(ip: v)),
                        ),
                      ],
                      // Build 2129: no keepalive row for mim
                      // (inert there — see the home page).
                      if (!isWarp &&
                          o.protocol != 'masque' &&
                          o.protocol != 'mim') ...[
                        const SizedBox(height: 13),
                        Text(
                          'Keepalive (seconds)',
                          style: Ember.microLabelOrange,
                        ),
                        const SizedBox(height: 9),
                        _chipRow(
                          values: const ['5', '25', '60'],
                          current: '${o.keepalive}',
                          label: (v) => v,
                          onPick: locked
                              ? null
                              : (v) => controller.setOptions(
                                  o.copyWith(keepalive: int.parse(v)),
                                ),
                        ),
                      ],
                      // Build 2116 (A-02): the ECH value the
                      // engine has accepted all along
                      // (AETHER_ECH) — the options never
                      // carried it, so it was always the
                      // engine default. Free-form: whatever
                      // is typed is handed to the engine
                      // verbatim; empty restores the default.
                      const SizedBox(height: 13),
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'ECH (Encrypted Client Hello)',
                                  style: Ember.heading,
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  o.ech.isEmpty
                                      ? 'Engine default'
                                      : 'Custom value set',
                                  style: Ember.body,
                                ),
                              ],
                            ),
                          ),
                          TextButton(
                            onPressed: locked
                                ? null
                                : () async {
                                    final v = await _editEch(context, o.ech);
                                    if (v != null) {
                                      await controller.setOptions(
                                        o.copyWith(ech: v),
                                      );
                                    }
                                  },
                            child: const Text('Edit'),
                          ),
                        ],
                      ),
                      if (o.peer != null && o.peer!.isNotEmpty) ...[
                        const SizedBox(height: 13),
                        Row(
                          children: [
                            const Icon(
                              Icons.push_pin_rounded,
                              size: 14,
                              color: MapUi.dim,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                'Pinned endpoint ${o.peer}',
                                style: Ember.body,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            MapActionPill(
                              icon: Icons.clear_rounded,
                              label: 'Clear',
                              onTap: locked
                                  ? null
                                  : () => controller.setOptions(
                                      o.copyWith(clearPeer: true),
                                    ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                MapGlass(
                  blur: false,
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Clean-IP scanner', style: Ember.microLabelOrange),
                      const SizedBox(height: 6),
                      Text(
                        'Find a Cloudflare edge that answers from '
                        'this network and pin it as this engine\'s '
                        'endpoint.',
                        style: Ember.caption,
                      ),
                      const SizedBox(height: 10),
                      MapActionPill(
                        icon: Icons.radar_rounded,
                        label: 'Open the CF scanner',
                        onTap: () =>
                            openCfScanner(context, xray, aether: controller),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                MapGlass(
                  blur: false,
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('EmberWarp profile', style: Ember.microLabelOrange),
                      const SizedBox(height: 6),
                      Text(
                        'A different slot: the standalone EmberWarp '
                        'card and the V2Ray underlay. Its settings '
                        'live on their own page.',
                        style: Ember.caption,
                      ),
                      const SizedBox(height: 10),
                      MapActionPill(
                        icon: Icons.settings_rounded,
                        label: 'Open EmberWarp settings',
                        onTap: () => openWarpSettings(context, xray),
                      ),
                    ],
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

class AetherServersView extends StatelessWidget {
  const AetherServersView({super.key, required this.controller, this.onClose});

  final AetherController controller;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final state = controller.state;
        final scan = controller.lastScan;
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          children: [
            MapGlass(
              blur: false,
              luminous: true,
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          controller.isWarp ? 'WARP endpoints' : 'Endpoints',
                          style: Ember.heading,
                        ),
                      ),
                      if (onClose != null)
                        // Build 2074 (audit item 4): a ≥48dp hit
                        // area for the panel close button.
                        IconButton(
                          tooltip: 'Close',
                          onPressed: onClose,
                          icon: const Icon(Icons.close_rounded, size: 19),
                          color: MapUi.dim,
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.only(left: 4),
                          constraints: const BoxConstraints(
                            minWidth: 48,
                            minHeight: 48,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    state.server.isNotEmpty
                        ? 'Current endpoint: ${state.server}'
                              '${state.rtt.isNotEmpty ? ' • ${state.rtt}' : ''}'
                        : scan != null && scan.server.isNotEmpty
                        ? 'Last scan picked ${scan.server}'
                              '${scan.rtt.isNotEmpty ? ' • ${scan.rtt}' : ''}'
                        : 'No endpoint yet — the engine scans '
                              'Cloudflare\u2019s edge when it connects, and '
                              'keeps the fastest that carries traffic.',
                    style: Ember.body,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Scanning tries ${_scanLabel(controller.options.scan)} '
                    'mode over ${controller.options.ip == 'both'
                        ? 'IPv4 + IPv6'
                        : controller.options.ip == 'v6'
                        ? 'IPv6'
                        : 'IPv4'}'
                    '${controller.options.peer != null ? '; a pinned endpoint (${controller.options.peer}) overrides the scan' : ''}.',
                    style: Ember.caption,
                  ),
                  // Build 2095 (whole-app journey audit #57):
                  // this view used to be display-only — the
                  // scan/pin actions lived only on the home
                  // page. They are here now, and the scan
                  // result persists across restarts.
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      MapActionPill(
                        icon: Icons.radar_rounded,
                        label: 'Scan now',
                        // Build 2098 (post-2097 audit L20): the
                        // home card's connected guard, which
                        // this settings copy never had — the
                        // pill stays inert while the engine
                        // runs or connects, and a refusal is a
                        // plain sentence, not the raw
                        // StateError text.
                        onTap: controller.tunRunning || controller.connecting
                            ? null
                            : () async {
                                try {
                                  await controller.scanEndpoints();
                                  if (context.mounted) {
                                    final sc = controller.lastScan;
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text(
                                          sc != null && sc.server.isNotEmpty
                                              ? 'Best endpoint: ${sc.server}'
                                              : 'The scan finished',
                                        ),
                                      ),
                                    );
                                  }
                                } on StateError catch (e) {
                                  // Build 2098 (verification
                                  // F5): only the busy guard
                                  // means "disconnect first" —
                                  // scanEndpoints also throws
                                  // StateError for identity and
                                  // engine-start failures while
                                  // fully disconnected, and
                                  // telling that user to
                                  // disconnect loops them. The
                                  // home card's generic copy
                                  // covers the rest.
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text(
                                          e.message ==
                                                  'disconnect before scanning'
                                              ? 'Disconnect before scanning'
                                              : 'The scan failed',
                                        ),
                                      ),
                                    );
                                  }
                                } catch (_) {
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text('The scan failed'),
                                      ),
                                    );
                                  }
                                }
                              },
                      ),
                      if ((state.server.isNotEmpty ||
                              (scan != null && scan.server.isNotEmpty)) &&
                          controller.options.peer == null)
                        MapActionPill(
                          icon: Icons.push_pin_rounded,
                          label: 'Pin this endpoint',
                          onTap: () {
                            final server = state.server.isNotEmpty
                                ? state.server
                                : scan!.server;
                            unawaited(
                              controller.setOptions(
                                controller.options.copyWith(
                                  peer: server.contains(':')
                                      ? server
                                      : '$server:2408',
                                ),
                              ),
                            );
                          },
                        ),
                      if (controller.options.peer != null)
                        MapActionPill(
                          icon: Icons.push_pin_outlined,
                          label: 'Unpin endpoint',
                          onTap: () => unawaited(
                            controller.setOptions(
                              controller.options.copyWith(clearPeer: true),
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// The Accounts tab in WARP/MASQUE mode: no account — WARP is
/// free and anonymous; the identity state instead.
class AetherAboutView extends StatelessWidget {
  const AetherAboutView({super.key, required this.controller});

  final AetherController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final state = controller.state;
        final t = controller.exitTrace;
        return ListView(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
          children: [
            Center(
              child: Text(
                controller.isWarp ? 'WARP' : 'MASQUE',
                // Build 2145: the About title at the samples'
                // hero scale, like the WireGuard About title.
                style: Ember.hero,
              ),
            ),
            Center(child: Text('Cloudflare WARP • free', style: Ember.caption)),
            const SizedBox(height: 16),
            MapGlass(
              blur: false,
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(Icons.person_off_rounded, color: Ember.dim),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'No account — the engine registers an anonymous '
                      'WARP identity on this device and keeps it. '
                      // Build 2095 (whole-app journey audit
                      // #35): stated plainly — the identity is
                      // device-only; it cannot be exported or
                      // moved, and another device registers its
                      // own.
                      'The identity lives on this device only: it '
                      'cannot be exported or transferred, and a new '
                      'device registers a fresh one.',
                      style: Ember.body,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            MapGlass(
              blur: false,
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
                          color: controller.connected
                              ? Ember.green
                              : state.running
                              ? Ember.amber
                              : Ember.faint,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        controller.connected
                            ? 'Connected'
                            : state.running
                            ? 'Connecting…'
                            : 'Not connected',
                        style: Ember.heading,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    state.identity
                        ? 'Identity: registered on this device'
                        : 'Identity: not registered yet',
                    style: Ember.body,
                  ),
                  if (t != null && (t['ip'] ?? '').isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      'Exit: ${t['ip']}${(t['loc'] ?? '').isNotEmpty ? ' • ${t['loc']}' : ''}'
                      '${(t['warp'] ?? '').isNotEmpty ? ' • WARP ${t['warp']}' : ''}',
                      style: Ember.body,
                    ),
                  ],
                  if (controller.upBytes > 0 || controller.downBytes > 0) ...[
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
                          Text(
                            fmtBytes(controller.downBytes),
                            // Build 2145: transfer figures as
                            // monospace data, pro6-style.
                            style: Ember.body.copyWith(fontFamily: 'monospace'),
                          ),
                          const SizedBox(width: 10),
                          const Icon(
                            Icons.arrow_upward_rounded,
                            size: 14,
                            color: Ember.dim,
                          ),
                          const SizedBox(width: 3),
                          Text(
                            fmtBytes(controller.upBytes),
                            style: Ember.body.copyWith(fontFamily: 'monospace'),
                          ),
                        ],
                      ),
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
