/// The Cloudflare clean-IP scanner page (build 2026, Stage A
/// of the MLM port): probes curated Cloudflare edge ranges from
/// THIS network and lists the IPs that answer for a host — the
/// CfEdge technique (TCP + TLS with the host as SNI + any HTTP
/// status line). For a *.workers.dev host the candidate set
/// also includes the host's own DoH-resolved addresses
/// (WorkerRoute's per-IP health check).
///
/// A found IP can be applied to one of the user's own TLS
/// profiles: ONLY the profile's address changes — its SNI and
/// Host stay exactly as they are, which is what makes a
/// Cloudflare-fronted config ride a different edge IP at all.

import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../psiphon/psiphon_controller.dart';
import '../../psiphon/psiphon_strategy.dart';
import '../../xray/cf_scanner.dart';
import '../../xray/xray_controller.dart';
import '../../xray/xray_models.dart';
import 'ember_format.dart';
import 'ember_theme.dart';
import 'map_widgets.dart';

Future<void> openCfScanner(
  BuildContext context,
  XrayController xray, {
  PsiphonController? psiphon,
}) => Navigator.of(context).push(
  MaterialPageRoute(
    builder: (_) => CfScannerPage(xray: xray, psiphon: psiphon),
  ),
);

class CfScannerPage extends StatefulWidget {
  const CfScannerPage({super.key, required this.xray, this.psiphon});
  final XrayController xray;

  /// Build 2065 (item 3): when present, a found edge can also be
  /// added to the Psiphon CDN edge list.
  final PsiphonController? psiphon;

  @override
  State<CfScannerPage> createState() => _CfScannerPageState();
}

class _CfScannerPageState extends State<CfScannerPage> {
  final _host = TextEditingController(text: 'www.cloudflare.com');
  bool _scanning = false;
  bool _stop = false;
  int _done = 0;
  int _total = 0;
  List<CfProbeResult> _found = [];
  String _note = '';

  XrayController get xray => widget.xray;

  @override
  void dispose() {
    _stop = true;
    _host.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    final host = _host.text.trim().isEmpty
        ? 'www.cloudflare.com'
        : _host.text.trim();
    setState(() {
      _scanning = true;
      _stop = false;
      _done = 0;
      _total = 0;
      _found = [];
      _note = '';
    });
    final extraFirst = <String>[...xray.cfGoodIps];
    {
      // Build 2065 (item 3): the host's own DoH-resolved
      // neighbours are candidates for ANY host now, not only
      // *.workers.dev — a front hostname's live addresses are
      // the freshest clean-IP candidates there are.
      final resolved = await resolveViaDoh(host);
      extraFirst.insertAll(0, resolved);
      if (mounted) {
        setState(() {
          _note = resolved.isEmpty
              ? 'The host did not resolve over DoH; probing the '
                    'curated edges with its name as SNI.'
              : 'Probing its ${latDigits(resolved.length)} resolved addresses '
                    'plus the curated edges.';
        });
      }
    }
    final candidates = cfCandidates(Random(), extraFirst: extraFirst);
    final found = await scanCfEdges(
      candidates: candidates,
      host: host,
      onProgress: (done, total, soFar) {
        if (mounted) {
          setState(() {
            _done = done;
            _total = total;
            _found = soFar;
          });
        }
      },
      cancelled: () => _stop,
    );
    if (found.isNotEmpty) {
      await xray.saveCfGoodIps([for (final r in found) r.ip]);
    }
    if (mounted) {
      setState(() {
        _scanning = false;
        _found = found;
        if (found.isEmpty && !_stop) {
          _note = 'No edge answered for $host on this network.';
        }
      });
    }
  }

  List<Profile> get _applicable => [
    for (final p in xray.profiles)
      if (p.security == 'tls' &&
          (p.protocol == Protocol.vless ||
              p.protocol == Protocol.vmess ||
              p.protocol == Protocol.trojan))
        p,
  ];

  Future<void> _tapResult(CfProbeResult result) async {
    final targets = _applicable;
    final host = _host.text.trim().isEmpty
        ? 'www.cloudflare.com'
        : _host.text.trim();
    final picked = await showModalBottomSheet<Object>(
      context: context,
      backgroundColor: Ember.card,
      builder: (context) => SafeArea(
        // Build 2056 (audit A-H8): with many profiles the lower
        // targets were unreachable — the sheet scrolled nowhere.
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 6),
                child: Text('Use ${result.ip}…', style: Ember.heading),
              ),
              // Build 2065 (item 3): the two extra apply targets.
              // Build 2074 (audit item 16): every apply-sheet
              // title/subtitle is capped with an ellipsis —
              // user config names and endpoints are unbounded.
              ListTile(
                leading: const Icon(Icons.hub_outlined, color: Ember.orange),
                title: Text(
                  'As the WARP endpoint',
                  style: Ember.body,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  'Pins the WARP gateway to ${result.ip}:2408',
                  style: Ember.caption,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => Navigator.of(context).pop('warp'),
              ),
              if (widget.psiphon != null)
                ListTile(
                  leading: const Icon(Icons.dns_outlined, color: Ember.orange),
                  title: Text(
                    'As a Psiphon CDN edge',
                    style: Ember.body,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    'SNI $host, on the Psiphon edge list',
                    style: Ember.caption,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () => Navigator.of(context).pop('psiphon'),
                ),
              if (targets.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 10, 18, 2),
                  child: Text(
                    'As the address of a config (SNI and Host stay '
                    'as they are):',
                    style: Ember.caption,
                  ),
                ),
              for (final p in targets)
                ListTile(
                  // Build 2045: the name the user sees.
                  title: Text(
                    p.displayName,
                    style: Ember.body,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '${p.protocol.label} · ${p.address}:${p.port}',
                    style: Ember.caption,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () => Navigator.of(context).pop(p),
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
    if (picked == null || !mounted) return;
    if (picked == 'warp') {
      xray.warpProfile.peer = '${result.ip}:2408';
      await xray.saveWarpProfile();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'EmberWarp gateway pinned to ${result.ip}:2408. '
              'Clear it in EmberWarp settings to go back to '
              'the core scan.',
            ),
          ),
        );
      }
      return;
    }
    if (picked == 'psiphon') {
      final psiphon = widget.psiphon!;
      final next = PsiphonSettings.fromJson(psiphon.settings.toJson());
      next.cdnEdges.removeWhere((e) => e.address == result.ip && e.sni == host);
      next.cdnEdges.add(
        CdnEdge(
          address: result.ip,
          sni: host,
          provider: 'custom',
          lastMs: result.ms,
          lastOk: true,
          lastTestAtMs: DateTime.now().millisecondsSinceEpoch,
          testedIp: result.ip,
        ),
      );
      await psiphon.updateSettings(next);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${result.ip} added to the Psiphon CDN edges.'),
          ),
        );
      }
      return;
    }
    final profile = picked as Profile;
    final updated = profile.copy()..address = result.ip;
    await xray.updateProfile(updated);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${profile.name} now uses ${result.ip} — its SNI and '
            'Host are unchanged.',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Ember.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Ember.text,
        // 2027 (v7 audit): the shell's page treatment —
        // centered bold title, not the stock start-aligned
        // app bar the audit flagged.
        centerTitle: true,
        title: Text(
          'Cloudflare clean IP',
          style: Ember.heading.copyWith(fontSize: 18),
        ),
      ),
      body: EmberBackground(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 24),
          children: [
            MapGlass(
              luminous: true,
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Finds Cloudflare edge IPs that answer from this '
                    'network, for your own Cloudflare-fronted configs. '
                    'An edge answers when it takes a TLS handshake for '
                    'the host and replies to a HEAD request.',
                    style: Ember.caption,
                  ),
                  const SizedBox(height: 12),
                  // 2027 (v7 audit): the SNI/HOST micro-label
                  // above the input.
                  Text(
                    'SNI / HOST',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.2,
                      color: MapUi.faint,
                    ),
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: _host,
                    style: Ember.body,
                    textDirection: TextDirection.ltr,
                    decoration: emberField(context, 'Host (SNI)'),
                  ),
                  const SizedBox(height: 12),
                  EmberButton(
                    label: _scanning ? 'Stop' : 'Scan',
                    icon: _scanning ? Icons.stop_rounded : Icons.radar_rounded,
                    onTap: () {
                      if (_scanning) {
                        setState(() => _stop = true);
                      } else {
                        unawaited(_scan());
                      }
                    },
                  ),
                  if (_scanning || _total > 0) ...[
                    const SizedBox(height: 12),
                    LinearProgressIndicator(
                      value: _total > 0 ? _done / _total : null,
                      minHeight: 3,
                      backgroundColor: MapUi.line,
                      color: Ember.orange,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${latDigits(_done)}/${latDigits(_total)} probed · '
                      '${latDigits(_found.length)} answering',
                      style: Ember.caption,
                    ),
                  ],
                  if (_note.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(_note, style: Ember.caption),
                  ],
                ],
              ),
            ),
            // 2027 (v7 audit): the RESULTS section always
            // exists — before the first scan it holds the
            // placeholder instead of leaving the page's lower
            // two-thirds empty.
            const SizedBox(height: 12),
            MapGlass(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'RESULTS',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.2,
                      color: MapUi.faint,
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (_found.isEmpty)
                    Text(
                      _total > 0 && !_scanning
                          ? 'No answering edges on this network.'
                          : 'No edge IPs tested yet',
                      style: Ember.caption,
                    )
                  else ...[
                    Text(
                      'Tap one to use it as a profile\'s address. '
                      'Only the address changes — the SNI and Host '
                      'stay as they are.',
                      style: Ember.caption,
                    ),
                    const SizedBox(height: 8),
                    for (final r in _found)
                      InkWell(
                        onTap: () => unawaited(_tapResult(r)),
                        borderRadius: BorderRadius.circular(10),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 9,
                          ),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.cloud_done_rounded,
                                size: 17,
                                color: MapUi.dim,
                              ),
                              const SizedBox(width: 10),
                              Expanded(child: Text(r.ip, style: Ember.body)),
                              Text(
                                '${latDigits(r.ms)} ms',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  color: mapPingColor(r.ms),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
