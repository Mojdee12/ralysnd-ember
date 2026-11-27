/// Build 2147 surfaces: the quarantine list (#20/#21a), the
/// whitelist SNI scan (#4) and the guided diagnosis ladder
/// (#16). All three are reached from the Iran-features panel
/// in Settings; every feature behind them is DEFAULT OFF.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../xray/iran_features_2147.dart';
import '../../xray/xray_controller.dart';
import 'ember_theme.dart';
import 'map_widgets.dart';

Widget _pageShell({
  required String title,
  required List<Widget> children,
}) {
  return Scaffold(
    extendBodyBehindAppBar: true,
    backgroundColor: Ember.bg,
    appBar: AppBar(
      backgroundColor: Colors.transparent,
      elevation: 0,
      foregroundColor: Ember.text,
      centerTitle: true,
      title: Text(
        title,
        style: Ember.heading.copyWith(fontSize: Ember.fontHeadline),
      ),
    ),
    body: EmberBackground(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 110, 16, 24),
        children: children,
      ),
    ),
  );
}

// ---------------------------------------------------------------------
// #20/#21a — the quarantine list
// ---------------------------------------------------------------------

class QuarantinePage2147 extends StatelessWidget {
  const QuarantinePage2147({super.key, required this.xray});
  final XrayController xray;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: xray,
      builder: (context, _) {
        final cut = xray.quarantinedProfiles;
        return _pageShell(
          title: 'Quarantine',
          children: [
            Text(
              'Configs cut by the quarantine rule or the ping '
              'sweep live here — disabled, never deleted. '
              'Restoring one clears its strike count; it can '
              'connect again immediately.',
              style: Ember.caption,
            ),
            const SizedBox(height: 14),
            if (cut.isEmpty)
              Text('Nothing is quarantined.', style: Ember.body)
            else
              for (final p in cut)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: MapGlass(
                    blur: false,
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(p.name, style: Ember.title),
                              const SizedBox(height: 2),
                              Text(
                                p.quarantineReason.isEmpty
                                    ? 'Quarantined'
                                    : p.quarantineReason,
                                style: Ember.caption,
                              ),
                            ],
                          ),
                        ),
                        TextButton(
                          onPressed: () =>
                              xray.restoreFromQuarantine(p.id),
                          child: const Text('RESTORE'),
                        ),
                      ],
                    ),
                  ),
                ),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------
// #4 — the whitelist SNI scan
// ---------------------------------------------------------------------

class SniScanPage2147 extends StatefulWidget {
  const SniScanPage2147({super.key});
  @override
  State<SniScanPage2147> createState() => _SniScanPage2147State();
}

class _SniScanPage2147State extends State<SniScanPage2147> {
  bool _scanning = false;
  bool _stop = false;
  List<SniScanResult> _results = [];
  String _note = '';

  @override
  void dispose() {
    _stop = true;
    super.dispose();
  }

  Future<SniScanResult> _probe(String host) async {
    final sw = Stopwatch()..start();
    SecureSocket? socket;
    try {
      socket = await SecureSocket.connect(
        host,
        443,
        timeout: const Duration(seconds: 6),
      );
      sw.stop();
      return (
        host: host,
        handshakeOk: true,
        firstByteMs: sw.elapsedMilliseconds,
        note: 'TLS handshake completed',
      );
    } catch (e) {
      sw.stop();
      return (
        host: host,
        handshakeOk: false,
        firstByteMs: -1,
        note: e is SocketException
            ? 'No answer (${e.osError?.message ?? 'socket error'})'
            : 'Handshake failed',
      );
    } finally {
      socket?.destroy();
    }
  }

  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _stop = false;
      _results = [];
      _note = 'Probing ${kSniScanHosts.length} candidate fronts…';
    });
    final found = <SniScanResult>[];
    for (var i = 0; i < kSniScanHosts.length && !_stop; i += 6) {
      final chunk = kSniScanHosts.skip(i).take(6).toList();
      found.addAll(await Future.wait([for (final h in chunk) _probe(h)]));
      if (mounted) {
        setState(() => _results = rankSniResults(found));
      }
    }
    if (mounted) {
      final pass = found.where((r) => r.handshakeOk).length;
      setState(() {
        _scanning = false;
        _note = _stop
            ? 'Stopped.'
            : '$pass of ${found.length} fronts answered a TLS '
                  'handshake on this network. Tap a passer to copy '
                  'it — paste it as a config\'s SNI in its editor.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return _pageShell(
      title: 'Whitelist SNI scan',
      children: [
        Text(
          'On whitelist-style filtering, only approved names '
          'pass. This scan tries a real TLS handshake with '
          'each candidate front FROM this network and ranks '
          'the ones that answer.',
          style: Ember.caption,
        ),
        const SizedBox(height: 14),
        MapGlass(
          blur: false,
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_note.isNotEmpty) Text(_note, style: Ember.caption),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: _scanning
                      ? () => setState(() => _stop = true)
                      : _scan,
                  child: Text(_scanning ? 'STOP' : 'RUN SCAN'),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        for (final r in _results)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: MapGlass(
              blur: false,
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
              child: InkWell(
                onTap: r.handshakeOk
                    ? () async {
                        await Clipboard.setData(
                          ClipboardData(text: r.host),
                        );
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                '${r.host} copied — paste it as the '
                                'SNI in a config\'s editor.',
                              ),
                            ),
                          );
                        }
                      }
                    : null,
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(r.host, style: Ember.title),
                          Text(r.note, style: Ember.caption),
                        ],
                      ),
                    ),
                    if (r.handshakeOk)
                      Text(
                        '${r.firstByteMs} ms',
                        style: Ember.body.copyWith(
                          color: mapPingColor(r.firstByteMs),
                        ),
                      )
                    else
                      Text(
                        'Blocked',
                        style: Ember.body.copyWith(color: Ember.red),
                      ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------
// #16 — the guided diagnosis ladder
// ---------------------------------------------------------------------

class DiagnosisPage2147 extends StatefulWidget {
  const DiagnosisPage2147({super.key, required this.xray});
  final XrayController xray;
  @override
  State<DiagnosisPage2147> createState() => _DiagnosisPage2147State();
}

class _DiagnosisPage2147State extends State<DiagnosisPage2147> {
  bool _running = false;
  List<DiagnosisRung> _rungs = [];

  String _remedyIdFor(String title) {
    final t = title.toLowerCase();
    if (t.contains('dns') || t.contains('domain')) return 'dns';
    if (t.contains('tls') || t.contains('handshake')) return 'tls';
    if (t.contains('real request') || t.contains('crosses')) {
      return 'firstByte';
    }
    return 'tcp';
  }

  Future<void> _run() async {
    final xray = widget.xray;
    setState(() {
      _running = true;
      _rungs = [];
    });
    final rungs = <DiagnosisRung>[];
    final selected = xray.selected;
    if (!xray.state.running && selected != null) {
      // Rung 1 (the page's own): does the profile's host
      // resolve at all on this network?
      try {
        final found = await InternetAddress.lookup(
          selected.address,
        ).timeout(const Duration(seconds: 6));
        rungs.add((
          step: 'DNS resolves the server name',
          ok: found.isNotEmpty,
          finding: found.isEmpty
              ? '${selected.address} did not resolve.'
              : '${selected.address} resolved to '
                    '${found.first.address}.',
          remedy: diagnosisRemedyFor('dns'),
        ));
      } catch (_) {
        rungs.add((
          step: 'DNS resolves the server name',
          ok: false,
          finding: '${selected.address} did not resolve.',
          remedy: diagnosisRemedyFor('dns'),
        ));
      }
    }
    final stages = await xray.runConnectionCheck();
    for (final stage in stages) {
      rungs.add((
        step: stage.title,
        ok: stage.ok,
        finding: stage.detail,
        remedy: diagnosisRemedyFor(_remedyIdFor(stage.title)),
      ));
    }
    if (mounted) {
      setState(() {
        _running = false;
        _rungs = rungs;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final xray = widget.xray;
    return _pageShell(
      title: 'Guided diagnosis',
      children: [
        Text(
          xray.state.running
              ? 'Walks the running tunnel rung by rung and '
                    'names the remedy for the first rung that '
                    'fails.'
              : 'Walks the selected config rung by rung — '
                    'DNS, TCP, TLS, first request — and names '
                    'the remedy for the first rung that fails.',
          style: Ember.caption,
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: _running ? null : _run,
            child: Text(_running ? 'RUNNING…' : 'RUN DIAGNOSIS'),
          ),
        ),
        const SizedBox(height: 8),
        for (final rung in _rungs)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: MapGlass(
              blur: false,
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        rung.ok
                            ? Icons.check_circle_outline
                            : Icons.error_outline,
                        size: 18,
                        color: rung.ok ? Ember.green : Ember.red,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(rung.step, style: Ember.title),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(rung.finding, style: Ember.caption),
                  if (!rung.ok) ...[
                    const SizedBox(height: 6),
                    Text(
                      'Remedy: ${rung.remedy}',
                      style: Ember.caption.copyWith(color: Ember.orange),
                    ),
                  ],
                ],
              ),
            ),
          ),
      ],
    );
  }
}
