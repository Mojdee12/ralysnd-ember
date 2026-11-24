/// WARP endpoint scan (build 2098 — the owner's
/// WarpScout-style flow, inside the WireGuard section):
/// probes sampled Cloudflare WARP endpoints with REAL
/// WireGuard handshakes built from the selected config's
/// own keys and AmneziaWG parameters, lists only the
/// endpoints that answered — with the measured handshake
/// time — and applies a tapped endpoint to the config
/// and connects, the way a manual endpoint edit would.
///
/// The probe itself lives in xray/wg_probe.dart and was
/// verified end to end against a real amneziawg-go
/// device during development; an endpoint that does not
/// complete a verified handshake never appears here.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../xray/wg_probe.dart';
import '../../xray/xray_controller.dart';
import '../../xray/xray_models.dart';
import 'ember_format.dart';
import 'ember_theme.dart';
import 'map_widgets.dart';

/// Cloudflare WARP's anycast peer key: endpoint scanning
/// only makes sense for a config whose peer is WARP —
/// the handshake is keyed to the peer's public key, so
/// WARP endpoints can only ever answer a WARP config.
const warpPeerPublicKey = 'bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=';

class WgScanPage extends StatefulWidget {
  const WgScanPage({super.key, required this.xray, required this.profile});

  final XrayController xray;
  final Profile profile;

  @override
  State<WgScanPage> createState() => _WgScanPageState();
}

class _WgScanPageState extends State<WgScanPage> {
  WgEndpointScanner? _scanner;

  /// Build 2098 (verification F1): bumped on every scan
  /// start and every cancel. A scan's completion applies
  /// its results only while its generation is still the
  /// current one — a cancelled scan's late completion used
  /// to publish its partial results as a finished scan,
  /// and, a rescan having already started, overwrote the
  /// new scan's state mid-flight.
  int _scanGen = 0;
  bool _scanning = false;
  bool _connecting = false;
  int _done = 0;
  int _total = 0;
  List<WgScanResult>? _results;
  String? _error;

  XrayController get xray => widget.xray;
  Profile get profile => widget.profile;

  bool get _isWarpPeer => profile.peerPublicKey == warpPeerPublicKey;
  bool get _sessionBusy => xray.state.running || xray.connecting;

  @override
  void initState() {
    super.initState();
    // Build 2098 (verification, iteration 2): the page
    // LISTENS to the controller. It used to read
    // _sessionBusy only at build time, so a session that
    // started behind the page (tile, notification,
    // auto-reconnect) left stale, tappable results and an
    // enabled scan button — and a session starting
    // MID-SCAN was never noticed at all, so its probes
    // travelled through the very tunnel they were meant to
    // measure around. A session arriving mid-scan cancels
    // the scan (its results would be meaningless).
    xray.addListener(_onXrayChanged);
  }

  void _onXrayChanged() {
    if (!mounted) return;
    if (_scanning && _sessionBusy) {
      _scanner?.cancel();
      _scanGen++;
      setState(() => _scanning = false);
    } else {
      setState(() {});
    }
  }

  @override
  void dispose() {
    xray.removeListener(_onXrayChanged);
    _scanner?.cancel();
    super.dispose();
  }

  Future<void> _startScan() async {
    // Build 2098 (verification F2): the busy conditions are
    // re-checked HERE, not only at build time — the page
    // does not listen to the controller, so a tunnel that
    // came up behind the page (tile, notification,
    // auto-reconnect) left the button enabled, and probes
    // would have travelled through the tunnel they were
    // meant to measure around.
    if (_scanning || _connecting || _sessionBusy) return;
    final gen = ++_scanGen;
    final scanner = WgEndpointScanner();
    setState(() {
      _scanner = scanner;
      _scanning = true;
      _results = null;
      _error = null;
      _done = 0;
      _total = 0;
    });
    try {
      final candidates = warpScanCandidates(profile);
      setState(() => _total = candidates.length);
      final results = await scanner.scan(
        profile,
        candidates,
        onProgress: (done, total) {
          // Build 2098 (verification, iteration 2): the
          // generation guard covers progress too — after a
          // cancel + rescan, the old scanner's workers kept
          // writing their done count into the new scan's
          // progress line.
          if (mounted && gen == _scanGen) {
            setState(() {
              _done = done;
              _total = total;
            });
          }
        },
      );
      if (!mounted || gen != _scanGen) return;
      setState(() {
        _results = results;
        _scanning = false;
      });
    } on FormatException {
      // The profile's keys or signature values are ones
      // the engine itself would refuse — say so plainly
      // instead of scanning with a degraded probe.
      if (!mounted || gen != _scanGen) return;
      setState(() {
        _scanning = false;
        _error =
            'This config\u2019s keys or AmneziaWG values could not be '
            'used for a handshake probe. Check the config in the '
            'editor first.';
      });
    } catch (_) {
      if (!mounted || gen != _scanGen) return;
      setState(() {
        _scanning = false;
        _error = 'The scan could not run. Try again.';
      });
    }
  }

  Future<void> _applyAndConnect(WgScanResult r) async {
    // Build 2098 (verification, iteration 2): the same
    // entry guard as _startScan — a result tapped while a
    // session is up (or a scan is running) must not
    // supersede the live session via the connect walk.
    if (_connecting || _scanning || _sessionBusy) return;
    setState(() => _connecting = true);
    profile.address = r.address;
    profile.port = r.port;
    await xray.updateProfile(profile);
    try {
      await xray.connectWireGuardWithFallback(profile);
      if (mounted) Navigator.of(context).pop();
    } on StateError {
      if (!mounted) return;
      setState(() => _connecting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'That endpoint answered the scan but the tunnel did '
            'not start — check the core logs.',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Ember.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Ember.text,
        title: Text('Scan endpoints', style: Ember.heading),
      ),
      body: EmberBackground(
        child: ListView(
          padding: EdgeInsets.fromLTRB(16, MediaQuery.of(context).padding.top + kToolbarHeight + 6, 16, 24),
          children: [
            MapGlass(
        blur: false,
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(profile.displayName, style: Ember.heading),
                  const SizedBox(height: 6),
                  Text(
                    'Current endpoint: ${profile.address}:${profile.port}',
                    style: Ember.body,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'The scan samples endpoints from Cloudflare\u2019s '
                    'WARP ranges and probes each with a real '
                    'WireGuard handshake using this config\u2019s own '
                    'keys and AmneziaWG parameters. Only endpoints '
                    'that answer the handshake are listed, with '
                    'the handshake time.',
                    style: Ember.caption,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            if (!_isWarpPeer)
              MapGlass(
        blur: false,
                padding: const EdgeInsets.all(16),
                child: Text(
                  'Endpoint scanning probes Cloudflare WARP '
                  'endpoints — this config\u2019s peer is not a WARP '
                  'peer, so a scan could never find an answer for '
                  'it.',
                  style: Ember.body,
                ),
              )
            else if (_sessionBusy)
              MapGlass(
        blur: false,
                padding: const EdgeInsets.all(16),
                child: Text(
                  'Disconnect before scanning — the probes must '
                  'travel directly, not through the running '
                  'tunnel.',
                  style: Ember.body,
                ),
              )
            else ...[
              Row(
                children: [
                  Expanded(
                    child: EmberButton(
                      label: _scanning
                          ? 'Scanning…'
                          : _results == null
                          ? 'Start scan'
                          : 'Scan again',
                      icon: Icons.radar_rounded,
                      onTap: _scanning || _connecting ? null : _startScan,
                    ),
                  ),
                  if (_scanning) ...[
                    const SizedBox(width: 10),
                    Expanded(
                      child: EmberButton(
                        label: 'Cancel',
                        icon: Icons.close_rounded,
                        onTap: () {
                          _scanner?.cancel();
                          // Build 2098 (verification F1):
                          // invalidate the in-flight scan's
                          // completion — it must not publish
                          // its partial results as a finished
                          // scan, nor overwrite a rescan.
                          _scanGen++;
                          setState(() => _scanning = false);
                        },
                      ),
                    ),
                  ],
                ],
              ),
              if (_scanning) ...[
                const SizedBox(height: 10),
                Text(
                  'Probed ${latDigits(_done)} of ${latDigits(_total)} '
                  'endpoints…',
                  style: Ember.caption,
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(
                  _error!,
                  style: Ember.body.copyWith(color: Ember.warn),
                ),
              ],
              if (_results != null) ...[
                const SizedBox(height: 14),
                Text(
                  _results!.isEmpty
                      ? 'No endpoint answered the handshake. The '
                            'network may be filtering WireGuard, or '
                            'the sampled endpoints are down.'
                      : '${latDigits(_results!.length)} working '
                            'endpoint${_results!.length == 1 ? '' : 's'} '
                            '— tap one to use it and connect.',
                  style: Ember.body,
                ),
                const SizedBox(height: 10),
                for (final r in _results!)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: MapGlass(
        blur: false,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                      onTap: _connecting
                          ? null
                          : () => _applyAndConnect(r),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.bolt_rounded,
                            color: Ember.orange,
                            size: 18,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(r.endpoint, style: Ember.body),
                          ),
                          Text(
                            'handshake ${latDigits(r.handshakeMs)} ms',
                            style: Ember.caption,
                          ),
                          const SizedBox(width: 6),
                          const Icon(
                            Icons.chevron_right_rounded,
                            color: Ember.faint,
                            size: 18,
                          ),
                        ],
                      ),
                    ),
                  ),
                if (_connecting)
                  Text('Connecting…', style: Ember.caption),
              ],
            ],
          ],
        ),
      ),
    );
  }
}
