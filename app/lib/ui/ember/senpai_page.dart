/// The Senpai scanner page (build 2129, Leg 3) — a DPI
/// Lab tool surface. The vendored SenPaiScanner binary
/// (SenpaiCore.kt / senpai.dart) discovers answering
/// endpoints on this network with its own embedded Xray
/// core: public IP sources, neighbour scan, and anti-DPI
/// probes.
///
/// Gates, both default OFF: the Lab's opt-in
/// (XraySettings.dpiLabEnabled) gates reaching the Lab at
/// all, and the scanner's own toggle
/// (XraySettings.senpaiEnabled) gates this page's
/// controls. With the toggle off the page is an
/// explanation and a switch — nothing runs.
///
/// Import honesty (delta §3(c)): the scanner's Xray is a
/// different version from Ember's, so its measurements
/// are candidates, not verdicts. Importing clones a
/// template profile the owner picks (the CF scanner's
/// applicability rule: TLS + VLESS/VMess/Trojan) onto each
/// top endpoint, serializes the clones to share links and
/// feeds them through the EXISTING import path
/// (XrayController.importLinks) so they land as ordinary
/// profiles — then runs Ember's own testDelay over the
/// imported set, and only a profile Ember itself measured
/// is shown as working. Importing never connects.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../xray/profile_codec.dart';
import '../../xray/senpai.dart';
import '../../xray/xray_controller.dart';
import '../../xray/xray_models.dart';
import 'ember_theme.dart';
import 'map_widgets.dart';

class SenpaiPage extends StatefulWidget {
  const SenpaiPage({super.key, required this.xray});

  final XrayController xray;

  @override
  State<SenpaiPage> createState() => _SenpaiPageState();
}

class _SenpaiPageState extends State<SenpaiPage> {
  XrayController get xray => widget.xray;

  SenpaiState _state = SenpaiState.idle;
  Timer? _poll;
  bool _starting = false;
  bool _importing = false;
  String _note = '';

  /// Ember's own delay verdicts for imported profiles
  /// (profile id -> ms; -1 = Ember's test failed it).
  final Map<String, int> _verdicts = {};
  List<Profile> _imported = [];

  String _templateId = '';

  final _count = TextEditingController(text: '1000');
  final _workers = TextEditingController(text: '50');
  final _timeoutSec = TextEditingController(text: '5');
  final _ports = TextEditingController(text: '443');
  final _targets = TextEditingController();
  final _topN = TextEditingController(text: '20');
  final _speedKb = TextEditingController(text: '512');
  final _minSpeed = TextEditingController(text: '0');
  bool _gentle = false;
  bool _requireWS = false;
  bool _neighborScan = false;
  bool _directOnly = false;
  bool _antiDpi = false;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  @override
  void dispose() {
    _poll?.cancel();
    for (final c in [
      _count,
      _workers,
      _timeoutSec,
      _ports,
      _targets,
      _topN,
      _speedKb,
      _minSpeed,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _refresh() async {
    final s = await SenpaiPlatform.state();
    if (!mounted) return;
    setState(() => _state = s);
    _syncPoll();
  }

  void _syncPoll() {
    if (_state.running && _poll == null) {
      _poll = Timer.periodic(const Duration(seconds: 2), (_) {
        unawaited(_refresh());
      });
    } else if (!_state.running && _poll != null) {
      _poll!.cancel();
      _poll = null;
    }
  }

  SenpaiRequest _formRequest() {
    int parse(TextEditingController c, int d) =>
        int.tryParse(c.text.trim()) ?? d;
    final ports = _ports.text
        .split(RegExp(r'[,;\s]+'))
        .where((s) => s.isNotEmpty)
        .map((s) => int.tryParse(s))
        .whereType<int>()
        .toList();
    return SenpaiRequest(
      count: parse(_count, 1000),
      workers: parse(_workers, 50),
      timeoutMs: parse(_timeoutSec, 5) * 1000,
      ports: ports.isEmpty ? const [443] : ports,
      targets: _targets.text,
      gentle: _gentle,
      requireWS: _requireWS,
      neighborScan: _neighborScan,
      directOnly: _directOnly,
      topN: parse(_topN, 20),
      speedKb: parse(_speedKb, 512),
      minSpeed: double.tryParse(_minSpeed.text.trim()) ?? 0,
      antiDpiEnabled: _antiDpi,
    );
  }

  Future<void> _start(String action) async {
    if (_starting) return;
    setState(() {
      _starting = true;
      _note = '';
    });
    try {
      final state = await SenpaiPlatform.state();
      final workDir = state.workDir;
      String wire;
      if (action == 'resume') {
        if (workDir.isEmpty) {
          setState(() => _note = 'The scanner is not available.');
          return;
        }
        final last = await SenpaiLastRequest(workDir).load();
        final req = last ?? _formRequest();
        req.targets = '';
        wire = req.toWireJson('resume');
      } else if (action == 'speed') {
        if (_state.rows.isEmpty) {
          setState(
            () => _note = 'Scan first — there is nothing to speed-test.',
          );
          return;
        }
        wire = _formRequest().speedWireJson(_state.rows);
      } else {
        final req = _formRequest();
        wire = req.toWireJson('scan');
        if (workDir.isNotEmpty) {
          await SenpaiLastRequest(workDir).save(req);
        }
      }
      final ok = await SenpaiPlatform.start(wire);
      if (!mounted) return;
      setState(() {
        _note = ok
            ? ''
            : 'The scanner did not start — see its state below.';
      });
      await _refresh();
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<void> _stop() async {
    await SenpaiPlatform.stop();
    await _refresh();
  }

  /// The CF scanner's applicability rule, mirrored: the
  /// template's address is replaced by the scanned
  /// endpoint, so it must be a TLS config whose handshake
  /// shape survives an address swap.
  List<Profile> get _templates => [
    for (final p in xray.profiles)
      if (p.security == 'tls' &&
          (p.protocol == Protocol.vless ||
              p.protocol == Protocol.vmess ||
              p.protocol == Protocol.trojan))
        p,
  ];

  Profile? get _template {
    for (final p in _templates) {
      if (p.id == _templateId) return p;
    }
    return _templates.isEmpty ? null : _templates.first;
  }

  /// Imports the top [SenpaiRequest.topN] rows as ordinary
  /// profiles through the existing link import path, then
  /// validates the imported set with Ember's own delay
  /// test. Never connects.
  Future<void> _importTop() async {
    final template = _template;
    if (template == null || _state.rows.isEmpty || _importing) return;
    setState(() {
      _importing = true;
      _note = '';
      _verdicts.clear();
      _imported = [];
    });
    try {
      final topN = int.tryParse(_topN.text.trim()) ?? 20;
      final rows = _state.rows.take(topN <= 0 ? 20 : topN).toList();
      final before = xray.profiles.map((p) => p.id).toSet();
      final links = StringBuffer();
      for (final row in rows) {
        final clone = template.copy()
          ..address = row.ip
          ..port = row.port
          ..name = 'Senpai ${row.endpoint}';
        links.writeln(profileToLink(clone));
      }
      final added = xray.importLinks(links.toString());
      final fresh = [
        for (final p in xray.profiles)
          if (!before.contains(p.id)) p,
      ];
      setState(() {
        _imported = fresh;
        _note = added == 0
            ? 'Nothing was imported — the generated links did '
                'not parse.'
            : 'Imported $added profile${added == 1 ? '' : 's'} — '
                'now testing them with Ember\u2019s own delay '
                'test\u2026';
      });
      // Ember's own verdict, one by one: only a profile
      // this test answers for is presented as working.
      for (final p in fresh) {
        final ms = await xray.testDelay(p);
        if (!mounted) return;
        setState(() => _verdicts[p.id] = ms);
      }
      if (mounted) {
        final working = _verdicts.values.where((ms) => ms > 0).length;
        setState(() {
          _note = 'Imported ${fresh.length} profile'
              '${fresh.length == 1 ? '' : 's'}: $working measured '
              'working by Ember\u2019s own test, '
              '${fresh.length - working} not confirmed. '
              'Nothing was connected.';
        });
      }
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final enabled = xray.settings.senpaiEnabled;
    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Ember.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Ember.text,
        title: Text('Senpai scanner', style: Ember.heading),
      ),
      body: EmberBackground(
        child: ListView(
          padding: EdgeInsets.fromLTRB(16, MediaQuery.of(context).padding.top + kToolbarHeight + 8, 16, 24),
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
                          'Senpai scanner',
                          style: Ember.heading,
                        ),
                      ),
                      MapToggle(
                        value: enabled,
                        onChanged: (v) async {
                          xray.settings.senpaiEnabled = v;
                          await xray.save();
                          xray.notifySettingsChanged();
                          if (mounted) setState(() {});
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Off by default. When on, the SenPaiScanner '
                    'engine scans this network for answering '
                    'endpoints (public IP sources, neighbour '
                    'scan, anti-DPI probes with its own Xray '
                    'core). A long scan lives with the app: if '
                    'the app is killed mid-scan, the scan\u2019s '
                    'saved state makes it resumable here — it '
                    'never dies silently.',
                    style: Ember.body,
                  ),
                ],
              ),
            ),
            if (enabled) ...[
              const SizedBox(height: 14),
              _formCard(),
              const SizedBox(height: 14),
              _statusCard(),
              if (_state.rows.isNotEmpty) ...[
                const SizedBox(height: 14),
                _resultsCard(),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _formCard() {
    final running = _state.running;
    return MapGlass(
        blur: false,
      luminous: true,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Scan', style: Ember.heading),
          const SizedBox(height: 10),
          _numField(_count, 'Candidates to try'),
          _numField(_workers, 'Workers'),
          _numField(_timeoutSec, 'Timeout (seconds)'),
          _textField(_ports, 'Ports (comma separated)'),
          _textField(_targets, 'Targets (optional, one per line)'),
          _numField(_topN, 'Top results to keep'),
          _numField(_speedKb, 'Speed-test size (KiB)'),
          _textField(_minSpeed, 'Minimum speed (Mbit/s)'),
          _switchRow('Gentle mode', _gentle, (v) => _gentle = v),
          _switchRow(
            'Require WebSocket',
            _requireWS,
            (v) => _requireWS = v,
          ),
          _switchRow(
            'Neighbour scan',
            _neighborScan,
            (v) => _neighborScan = v,
          ),
          _switchRow(
            'Direct only (targets required)',
            _directOnly,
            (v) => _directOnly = v,
          ),
          _switchRow(
            'Anti-DPI probes (finalmask + uTLS shaping)',
            _antiDpi,
            (v) => _antiDpi = v,
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _actionButton(
                'Start scan',
                Icons.play_arrow_rounded,
                running || _starting ? null : () => _start('scan'),
              ),
              if (_state.resumable && !running)
                _actionButton(
                  'Resume',
                  Icons.restore_rounded,
                  _starting ? null : () => _start('resume'),
                ),
              if (!running && _state.rows.isNotEmpty)
                _actionButton(
                  'Speed-test results',
                  Icons.speed_rounded,
                  _starting ? null : () => _start('speed'),
                ),
              if (running)
                _actionButton(
                  'Stop (saves state)',
                  Icons.stop_rounded,
                  _stop,
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _statusCard() {
    final s = _state;
    final phaseLabel = s.phase == 2
        ? 'measuring direct speed'
        : s.phase == 1
        ? 'checking addresses'
        : '';
    return MapGlass(
        blur: false,
      luminous: true,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Status', style: Ember.heading),
          const SizedBox(height: 6),
          Text(
            s.available
                ? 'Stage: ${s.stage}'
                      '${phaseLabel.isEmpty ? '' : ' · $phaseLabel'}'
                      ' · tested ${s.tested}/${s.total}'
                      ' · healthy ${s.healthy}'
                      ' · results ${s.rowsTotal}'
                      '${s.resumable ? ' · resumable' : ''}'
                      '${s.cancelled ? ' · stopped by you' : ''}'
                : 'The scanner binary is not available in this build.',
            style: Ember.body,
          ),
          if (s.error.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(s.error, style: Ember.caption),
          ],
          if (_note.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(_note, style: Ember.caption),
          ],
        ],
      ),
    );
  }

  Widget _resultsCard() {
    final template = _template;
    return MapGlass(
        blur: false,
      luminous: true,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Results', style: Ember.heading),
          const SizedBox(height: 6),
          Text(
            'Measured by the scanner\u2019s own Xray — '
            'candidates, not verdicts. Import re-tests them '
            'with Ember\u2019s core.',
            style: Ember.caption,
          ),
          const SizedBox(height: 8),
          for (final row in _state.rows.take(50))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      row.endpoint,
                      style: Ember.body.copyWith(color: Ember.text),
                    ),
                  ),
                  Text(
                    '${row.latencyMs} ms'
                    '${row.colo.isEmpty ? '' : ' · ${row.colo}'}'
                    '${row.speedTested ? (row.speedOk ? ' · ${row.mbps.toStringAsFixed(1)} Mbit/s' : ' · speed failed') : ''}',
                    style: Ember.caption,
                  ),
                ],
              ),
            ),
          const SizedBox(height: 12),
          Text('Import as profiles of', style: Ember.heading),
          const SizedBox(height: 6),
          if (_templates.isEmpty)
            Text(
              'No TLS VLESS/VMess/Trojan profile to use as a '
              'template yet — import or create one first.',
              style: Ember.caption,
            )
          else
            DropdownButton<String>(
              value: template?.id,
              isExpanded: true,
              dropdownColor: Ember.surface,
              items: [
                for (final p in _templates)
                  DropdownMenuItem(
                    value: p.id,
                    child: Text(p.name, style: Ember.body),
                  ),
              ],
              onChanged: (v) => setState(() => _templateId = v ?? ''),
            ),
          const SizedBox(height: 10),
          _actionButton(
            _importing ? 'Importing…' : 'Import top results',
            Icons.download_rounded,
            template == null || _importing ? null : _importTop,
          ),
          if (_imported.isNotEmpty) ...[
            const SizedBox(height: 10),
            for (final p in _imported)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        p.name,
                        style: Ember.body.copyWith(color: Ember.text),
                      ),
                    ),
                    Text(
                      _verdicts.containsKey(p.id)
                          ? (_verdicts[p.id]! > 0
                                ? 'Ember test: ${_verdicts[p.id]} ms'
                                : 'Ember test: no answer')
                          : 'Ember test: pending',
                      style: Ember.caption,
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _numField(TextEditingController c, String label) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: TextField(
      controller: c,
      style: Ember.body,
      keyboardType: TextInputType.number,
      autocorrect: false,
      enableSuggestions: false,
      decoration: emberField(context, label),
    ),
  );

  Widget _textField(TextEditingController c, String label) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: TextField(
      controller: c,
      style: Ember.body,
      autocorrect: false,
      enableSuggestions: false,
      decoration: emberField(context, label),
    ),
  );

  Widget _switchRow(
    String label,
    bool value,
    void Function(bool) apply,
  ) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      children: [
        Expanded(child: Text(label, style: Ember.body)),
        MapToggle(
          value: value,
          onChanged: (v) => setState(() => apply(v)),
        ),
      ],
    ),
  );

  Widget _actionButton(
    String label,
    IconData icon,
    VoidCallback? onTap,
  ) {
    final enabledBtn = onTap != null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: enabledBtn ? Ember.orange : Ember.surface,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 18,
              color: enabledBtn ? Colors.white : Ember.dim,
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: Ember.body.copyWith(
                color: enabledBtn ? Colors.white : Ember.dim,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
