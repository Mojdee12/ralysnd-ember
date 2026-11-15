/// The Aether engines' pages, Map Control edition (build
/// 2032): WARP (sample s23 — the radar) and MASQUE (sample
/// s24 — the broken shells), rebuilt in Ember's theme over the
/// ralysnd engines taken as they are. Every number on these
/// pages rides from the engine's real state (its stage
/// vocabulary, its selected endpoint, a Cloudflare trace
/// through the tunnel) — nothing is decorative data.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../aether/aether_controller.dart';
import '../../aether/aether_platform.dart';
import 'ember_format.dart';
import 'ember_theme.dart';
import 'map_widgets.dart';

const _scanModes = ['turbo', 'balanced', 'thorough', 'stealth', 'ironclad'];
const _ipModes = ['v4', 'v6', 'both'];

String _scanLabel(String m) => switch (m) {
  'turbo' => 'Turbo',
  'balanced' => 'Balanced',
  'thorough' => 'Thorough',
  'stealth' => 'Stealth',
  'ironclad' => 'Ironclad',
  _ => m,
};

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
    final error = controller.lastError;
    return MapGlass(
      rim: on,
      luminous: !on,
      borderColor: on ? Ember.orange.withValues(alpha: 0.55) : null,
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
                  color: on
                      ? Ember.green
                      : state.running || controller.connecting
                      ? Ember.amber
                      : Ember.faint,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  on
                      ? 'Connected'
                      : state.running || controller.connecting
                      ? (state.stageLabel.isNotEmpty
                            ? state.stageLabel
                            : 'Connecting…')
                      : 'Not connected',
                  style: Ember.heading,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              // Build 2056 (audit Batch 11): the engine name is a
              // label, not a chip — a chip reads as a button.
              Text(
                title.toUpperCase(),
                style: const TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.1,
                  color: MapUi.faint,
                ),
              ),
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
            style: Ember.body,
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
      ),
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

class _AetherExitCard extends StatelessWidget {
  const _AetherExitCard({required this.controller});

  final AetherController controller;

  @override
  Widget build(BuildContext context) {
    final t = controller.exitTrace;
    if (t == null) return const SizedBox.shrink();
    final ip = t['ip'] ?? '';
    final loc = t['loc'] ?? '';
    final warp = t['warp'] ?? '';
    if (ip.isEmpty) return const SizedBox.shrink();
    // Build 2074 (audit item 16): two rows, not one squeezed
    // row — the exit line gets the card's full width beside the
    // WARP chip, and Refresh keeps its own line at the right
    // instead of crushing the IP/location to a few characters.
    return MapGlass(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.public_rounded, size: 16, color: MapUi.dim),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Exit $ip${loc.isNotEmpty ? ' • $loc' : ''}',
                  style: Ember.body,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (warp.isNotEmpty) ...[
                const SizedBox(width: 8),
                EmberChip(
                  label: warp == 'off' ? 'WARP off' : 'WARP $warp',
                  dot: warp == 'off' ? Ember.red : Ember.green,
                ),
              ],
            ],
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
        ],
      ),
    );
  }
}

/// The engine log tail (the shim's ring of real core lines).
class _AetherLogCard extends StatelessWidget {
  const _AetherLogCard({required this.controller});

  final AetherController controller;

  @override
  Widget build(BuildContext context) {
    final log = controller.state.log;
    if (log.isEmpty) return const SizedBox.shrink();
    final lines = log.split('\n');
    return MapGlass(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text('Engine log', style: Ember.heading)),
              MapActionPill(
                icon: Icons.copy_rounded,
                label: 'Copy',
                onTap: () => Clipboard.setData(ClipboardData(text: log)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SelectableText(
            lines.skip(lines.length > 14 ? lines.length - 14 : 0).join('\n'),
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

/// The s23 radar: concentric rings around the status word,
/// with a slow sweep while the engine scans or connects. Pure
/// decoration over real state — the rings say nothing the
/// status card does not.
class WarpRadar extends StatefulWidget {
  const WarpRadar({super.key, required this.controller});

  final AetherController controller;

  @override
  State<WarpRadar> createState() => _WarpRadarState();
}

class _WarpRadarState extends State<WarpRadar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _sweep = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 3),
  );

  @override
  void initState() {
    super.initState();
    _sync();
    widget.controller.addListener(_sync);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_sync);
    _sweep.dispose();
    super.dispose();
  }

  void _sync() {
    final active =
        widget.controller.connecting ||
        (widget.controller.state.running && !widget.controller.connected);
    if (active && !_sweep.isAnimating) {
      _sweep.repeat();
    } else if (!active && _sweep.isAnimating) {
      _sweep.stop();
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final on = c.connected;
    return Center(
      child: SizedBox(
        width: 190,
        height: 190,
        child: AnimatedBuilder(
          animation: _sweep,
          // Build 2056 (audit Batch 10): the centre column is the
          // builder's cached child — it rebuilds only when the
          // engine state changes, not on every sweep tick.
          builder: (context, child) => CustomPaint(
            painter: _RadarPainter(sweep: _sweep.value, active: on),
            child: child,
          ),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.shield_rounded,
                  size: 30,
                  color: on ? Ember.green : MapUi.dim,
                ),
                const SizedBox(height: 6),
                Text(
                  on
                      ? 'WARP ON'
                      : c.state.running || c.connecting
                      ? 'SCANNING'
                      : 'WARP OFF',
                  style: Ember.heading.copyWith(letterSpacing: 1.5),
                ),
                if (c.state.server.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  // Build 2074 (audit item 16): the server line
                  // is bounded inside the fixed 190×190 radar —
                  // a long host:port ellipsizes, never spills
                  // past the rings.
                  SizedBox(
                    width: 170,
                    child: Text(
                      c.state.server,
                      style: Ember.caption,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RadarPainter extends CustomPainter {
  _RadarPainter({required this.sweep, required this.active});

  final double sweep;
  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    for (final (r, a) in [(92.0, 0.20), (68.0, 0.32), (44.0, 0.5)]) {
      ringPaint.color = (active ? Ember.orange : MapUi.dim).withValues(
        alpha: a,
      );
      canvas.drawCircle(center, r, ringPaint);
    }
    if (sweep > 0) {
      final sweepPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Ember.orange.withValues(alpha: 0.75);
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: 92),
        sweep * 6.28318,
        1.15,
        false,
        sweepPaint,
      );
    }
  }

  @override
  bool shouldRepaint(_RadarPainter old) =>
      old.sweep != sweep || old.active != active;
}

/// The WARP home (mode 6): s23's radar over the map, the
/// status card, the exit card, and the engine's own controls
/// (scan profile, address family, endpoint scan + pin,
/// identity).
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
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          children: [
            // Build 2074 (audit item 3): the top spacer is a
            // capped fraction of the viewport height, not a
            // fixed 150dp.
            SizedBox(
              height: (MediaQuery.sizeOf(context).height * 0.18).clamp(
                0.0,
                150.0,
              ),
            ),
            WarpRadar(controller: warp),
            const SizedBox(height: 10),
            _AetherStatusCard(controller: warp, title: 'Cloudflare WARP'),
            if (_hasExit(warp)) ...[
              const SizedBox(height: 12),
              _AetherExitCard(controller: warp),
            ],
            const SizedBox(height: 12),
            MapGlass(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Scan profile', style: Ember.heading),
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
                  Text('Address family', style: Ember.heading),
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
                                    ScaffoldMessenger.of(context).showSnackBar(
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
                                    ScaffoldMessenger.of(context).showSnackBar(
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
                      'Local proxy  SOCKS 127.0.0.1:${AetherPlatform.cfwarpSocksPort}',
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
        final carrier = o.protocol == 'masque' || o.protocol == 'gool';
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          children: [
            // Build 2074 (audit item 3): the top spacer is a
            // capped fraction of the viewport height, not a
            // fixed 150dp.
            SizedBox(
              height: (MediaQuery.sizeOf(context).height * 0.18).clamp(
                0.0,
                150.0,
              ),
            ),
            _AetherStatusCard(controller: masque, title: 'Aether'),
            if (_hasExit(masque)) ...[
              const SizedBox(height: 12),
              _AetherExitCard(controller: masque),
            ],
            const SizedBox(height: 12),
            MapGlass(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Protocol', style: Ember.heading),
                  const SizedBox(height: 9),
                  _chipRow(
                    values: const ['masque', 'wg', 'gool'],
                    current: o.protocol,
                    label: (v) => switch (v) {
                      'wg' => 'WireGuard',
                      'gool' => 'WARP in WARP',
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
                    _ =>
                      'Cloudflare WARP over MASQUE (HTTP/3 or '
                          'HTTP/2), with the firewall noise profile.',
                  }, style: Ember.caption),
                  if (carrier) ...[
                    const SizedBox(height: 13),
                    Text('Transport', style: Ember.heading),
                    const SizedBox(height: 9),
                    _chipRow(
                      // Build 2074 (MasqueCarrier): 'auto' starts
                      // on the carrier this network remembered
                      // (HTTP/2 where that is what worked, else
                      // HTTP/3) and learns from the core's own
                      // "Accepted via HTTP/2" line; explicit
                      // HTTP/3 / HTTP/2 never learn.
                      values: const ['h3', 'h2', 'auto'],
                      current: o.transport,
                      label: (v) => switch (v) {
                        'h2' => 'HTTP/2',
                        'auto' => 'Auto',
                        _ => 'HTTP/3',
                      },
                      onPick: locked
                          ? null
                          : (v) => masque.setOptions(o.copyWith(transport: v)),
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
                              : (v) =>
                                    masque.setOptions(o.copyWith(fragment: v)),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 13),
                  Text('Scan profile', style: Ember.heading),
                  const SizedBox(height: 9),
                  _chipRow(
                    values: _scanModes,
                    current: o.scan,
                    label: _scanLabel,
                    onPick: locked
                        ? null
                        : (v) => masque.setOptions(o.copyWith(scan: v)),
                  ),
                  if (o.protocol != 'masque') ...[
                    const SizedBox(height: 13),
                    Text('Keepalive (seconds)', style: Ember.heading),
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
                      'Local proxy  SOCKS 127.0.0.1:${AetherPlatform.masqueSocksPort}',
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
        );
      },
    );
  }
}

/// The Servers tab in WARP/MASQUE mode: there is no picker —
/// the engine scans Cloudflare's edge itself. What the user
/// controls is the scan and the pinned endpoint.
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
                style: Ember.title,
              ),
            ),
            Center(child: Text('Cloudflare WARP • free', style: Ember.caption)),
            const SizedBox(height: 16),
            MapGlass(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(Icons.person_off_rounded, color: Ember.dim),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'No account — the engine registers an anonymous '
                      'WARP identity on this device and keeps it.',
                      style: Ember.body,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            MapGlass(
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
                            style: Ember.body,
                          ),
                          const SizedBox(width: 10),
                          const Icon(
                            Icons.arrow_upward_rounded,
                            size: 14,
                            color: Ember.dim,
                          ),
                          const SizedBox(width: 3),
                          Text(fmtBytes(controller.upBytes), style: Ember.body),
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
