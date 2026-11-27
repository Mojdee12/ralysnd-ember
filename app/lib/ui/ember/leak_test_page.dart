/// Build 2095 (feature 8 — leak test): one page that says,
/// in plain language, what the outside world can see while
/// a session runs — and, just as plainly, what the app
/// cannot measure on-device. The verdict rows are built by
/// the pure [leakRows] so the wording is unit-tested.

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:pointycastle/export.dart' hide State, Padding;

import '../../aether/aether_controller.dart';
import '../../core/core_controller.dart';
import '../../core/models.dart' show Phase;
import '../../lantern/lantern_controller.dart';
import '../../l10n/app_localizations.dart';
import '../../openvpn/openvpn_controller.dart';
import '../../psiphon/psiphon_controller.dart';
import '../../xray/config_builder.dart' show primaryResolvers;
import '../../xray/iran_features_2147.dart';
import '../../xray/xray_controller.dart';
import 'ember_format.dart';
import 'ember_theme.dart';
import 'map_widgets.dart';

/// The measured facts the verdict is built from. Null /
/// empty fields mean "could not be read", never zero.
class LeakFacts {
  const LeakFacts({
    required this.engineLabel,
    this.exitIp = '',
    this.exitCountryCode = '',
    this.dnsEndpoint = '',
    this.dnsTunneled = false,
  });

  /// '' when nothing is connected.
  final String engineLabel;
  final String exitIp;
  final String exitCountryCode;

  /// The DNS endpoint the session is configured to use.
  final String dnsEndpoint;

  /// True when DNS queries ride the tunnel encrypted
  /// (DoH / DNS-over-TCP / DNSCrypt through the session
  /// rather than the LAN's plain resolver). DNS-over-QUIC
  /// is NOT tunneled in this core — it resolves on the
  /// local endpoint (build 2125, audit A25-34).
  final bool dnsTunneled;
}

typedef LeakRow = ({String label, String value, bool? ok});

/// The plain-language rows. [ok] is null for the rows that
/// are honest unknowns — the page renders those dim, never
/// green.
List<LeakRow> leakRows(LeakFacts f) {
  if (f.engineLabel.isEmpty) {
    return [
      (
        label: 'Connection',
        value: 'Nothing is connected — connect first, then run the test.',
        ok: false,
      ),
    ];
  }
  return [
    (label: 'Engine', value: f.engineLabel, ok: true),
    (
      label: 'Exit IP',
      value: f.exitIp.isEmpty
          ? 'Could not be read for this engine yet — give the session a few seconds.'
          // Build 2096 (post-2095 audit M20): informational,
          // never a green check — Ember holds no pre-VPN
          // baseline of the real address, so a bypassing
          // tunnel (exit IP = the real ISP address) would
          // read exactly like this row.
          : '${f.exitIp} — the address the internet sees. Ember has '
              'no pre-VPN reading of your real address to compare '
              'it with, so this row cannot prove the tunnel is '
              'carrying you.',
      ok: null,
    ),
    (
      label: 'Exit country',
      value: f.exitCountryCode.isEmpty
          ? 'Not read yet.'
          : f.exitCountryCode,
      ok: f.exitCountryCode.isEmpty ? null : true,
    ),
    (
      label: 'DNS',
      value: f.dnsEndpoint.isEmpty
          ? 'This engine manages its own DNS; the app cannot see which resolver answers.'
          : f.dnsTunneled
              // Build 2097 (post-2096 audit L-m): the row
              // states the CONFIGURATION, not a measured
              // fact — build 2096 demoted the green check
              // (L7) but the text still asserted "your
              // provider sees none of them" from the
              // remote-DNS protocol setting alone.
              ? '${f.dnsEndpoint} — this session is configured to '
                  'reach its resolver through the tunnel, encrypted. '
                  'That is the configuration; the app cannot watch '
                  'the queries themselves.'
              : '${f.dnsEndpoint} — check whether this resolver is reached through the tunnel.',
      // Build 2096 (post-2095 audit L7): the DNS row is a
      // configuration inference (which resolver the
      // session is set to use), not a measurement — it
      // renders as information, never a green check.
      ok: null,
    ),
    (
      label: 'DNS country vs exit country',
      value:
          'Cannot be measured from the app: only the resolver knows '
          'where it answers from. What the app controls is WHICH '
          'resolver is used (above).',
      ok: null,
    ),
    (
      label: 'WebRTC',
      value:
          'WebRTC lives in browsers and calling apps, not in the '
          'tunnel — the app cannot measure it. While connected, a '
          'browser leak-test page shows what WebRTC reveals; with '
          'the VPN up it should show the exit IP, not your real one.',
      ok: null,
    ),
  ];
}

class LeakTestPage extends StatefulWidget {
  const LeakTestPage({
    super.key,
    required this.core,
    required this.xray,
    required this.psiphon,
    required this.lantern,
    required this.openvpn,
    this.warp,
    this.masque,
  });

  final CoreController core;
  final XrayController xray;
  final PsiphonController psiphon;
  final LanternController lantern;
  final OpenVpnController openvpn;
  final AetherController? warp;
  final AetherController? masque;

  @override
  State<LeakTestPage> createState() => _LeakTestPageState();
}

class _LeakTestPageState extends State<LeakTestPage> {
  // Build 2147 (feature #14): RUN ALL state — the fresh
  // exit read plus the in-app WebRTC probe's note ('' =
  // not run yet).
  bool _runningAll = false;
  String _webrtcNote = '';
  // The Windows probe rides flutter_inappwebview (WebView2)
  // instead of webview_flutter, which has no Windows
  // implementation: while a probe runs, a 1x1 InAppWebView
  // is mounted and its 'IceProbe' JS handler completes
  // [_iceCompleter].
  Completer<String>? _iceCompleter;
  bool _iceProbeActive = false;

  static const _iceProbeHtml = '''
<html><body><script>
const post = (m) => {
  if (window.flutter_inappwebview) {
    window.flutter_inappwebview.callHandler('IceProbe', m);
  }
};
const pc = new RTCPeerConnection({iceServers: []});
pc.createDataChannel('probe');
const found = [];
pc.onicecandidate = (e) => {
  if (e.candidate) { found.push(e.candidate.candidate); }
  else { post(JSON.stringify(found)); }
};
pc.createOffer().then(o => pc.setLocalDescription(o));
setTimeout(() => post(JSON.stringify(found)), 6000);
</script></body></html>''';

  Future<void> _runAll() async {
    if (_runningAll) return;
    setState(() {
      _runningAll = true;
      _webrtcNote = '';
    });
    // A fresh exit read (the stored one may predate the
    // session's current route).
    widget.xray.refreshExitInfo();
    final note = await _probeWebRtc();
    if (mounted) {
      setState(() {
        _runningAll = false;
        _webrtcNote = note;
      });
    }
  }

  /// The in-app WebRTC probe: a hidden WebView gathers ICE
  /// candidates the way a web page would, and the host
  /// candidates it exposes are reported verbatim — the
  /// tunnel interface's address is expected among them; a
  /// LAN address is what a leak looks like. Informational,
  /// like every row on this page that is not a measurement
  /// of the tunnel itself.
  Future<String> _probeWebRtc() async {
    final completer = Completer<String>();
    _iceCompleter = completer;
    if (mounted) setState(() => _iceProbeActive = true);
    String raw;
    try {
      raw = await completer.future.timeout(
        const Duration(seconds: 9),
        onTimeout: () => '[]',
      );
    } catch (_) {
      raw = '[]';
    }
    _iceCompleter = null;
    if (mounted) setState(() => _iceProbeActive = false);
    final ips = <String>{};
    try {
      final list = jsonDecode(raw) as List;
      final ipPattern = RegExp(
        r'(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})|([0-9a-fA-F:]{2,}:[0-9a-fA-F:]+)',
      );
      for (final c in list) {
        for (final m in ipPattern.allMatches('$c')) {
          final ip = m.group(0)!;
          if (!ip.startsWith('0.') && ip != '0.0.0.0') ips.add(ip);
        }
      }
    } catch (_) {
      // An unreadable probe result reads as no candidates.
    }
    if (ips.isEmpty) {
      return 'The in-app WebRTC probe gathered no ICE host '
          'candidates — WebRTC exposes no local address from '
          'inside the app right now.';
    }
    return 'The in-app WebRTC probe saw ${ips.length} ICE '
        'host candidate(s): ${ips.join(', ')}. The tunnel '
        'interface\'s own address is expected here; an '
        'address from your home or office LAN in this list '
        'is what a WebRTC leak looks like to a page that asks.';
  }

  /// Build 2147 (feature #19): the encrypted diagnostics
  /// export — the same log text as EXPORT LOG, sealed with
  /// a password (AES-GCM, PBKDF2 key) before it touches
  /// the clipboard.
  Future<void> _exportEncrypted() async {
    final password = await _askExportPassword();
    if (password == null || !mounted) return;
    final text = await widget.xray.readLogs();
    final envelope = encryptDiagExport2147(text, password);
    await copySensitive(envelope);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Encrypted diagnostics copied — the password is '
            'the only way back in; Ember does not keep it.',
          ),
        ),
      );
    }
  }

  Future<String?> _askExportPassword() async {
    final first = TextEditingController();
    final second = TextEditingController();
    var error = '';
    final result = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Encrypt diagnostics'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: first,
                obscureText: true,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Password',
                ),
              ),
              TextField(
                controller: second,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Repeat the password',
                ),
              ),
              if (error.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    error,
                    style: Ember.caption.copyWith(color: Ember.red),
                  ),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('CANCEL'),
            ),
            TextButton(
              onPressed: () {
                if (first.text.length < 8) {
                  setDialogState(
                    () => error = 'Use at least 8 characters.',
                  );
                  return;
                }
                if (first.text != second.text) {
                  setDialogState(
                    () => error = 'The passwords do not match.',
                  );
                  return;
                }
                Navigator.of(context).pop(first.text);
              },
              child: const Text('ENCRYPT & COPY'),
            ),
          ],
        ),
      ),
    );
    first.dispose();
    second.dispose();
    return result;
  }

  LeakFacts _facts() {
    final xray = widget.xray;
    if (xray.state.running) {
      final exit = xray.exitInfo;
      return LeakFacts(
        engineLabel: xray.warpSession
            ? 'EmberWarp'
            : (xray.sessionProfile?.protocol.name == 'wireguard'
                  ? 'WireGuard'
                  : 'V2Ray'),
        exitIp: exit?.ip ?? '',
        exitCountryCode: exit?.countryCode ?? '',
        // Build 2125 (audit A25-34 / P-27): name the
        // EFFECTIVE resolver (the transport-mapped primary
        // list the core actually runs), not the raw stored
        // string; and judge "tunneled" from the transport
        // that will really carry the queries. The old test
        // compared against 'plain' — a value the setting
        // never holds (doh|doq|tcp|dnscrypt) — so EVERY
        // session read "tunneled", including DNS-over-QUIC,
        // whose mapped form is quic+local: the core
        // resolves it on the local endpoint, outside the
        // tunnel.
        dnsEndpoint: primaryResolvers(xray.settings).join(', '),
        dnsTunneled: xray.settings.remoteDnsProto != 'doq',
      );
    }
    for (final (label, c) in [
      ('WARP', widget.warp),
      ('MASQUE', widget.masque),
    ]) {
      if (c != null && (c.tunRunning || c.state.running)) {
        final t = c.exitTrace;
        return LeakFacts(
          engineLabel: label,
          exitIp: t?['ip'] ?? '',
          exitCountryCode: t?['loc'] ?? '',
        );
      }
    }
    final status = widget.core.status;
    if (status != null && status.state.phase == Phase.running) {
      return LeakFacts(
        engineLabel: 'Mozilla',
        exitIp: status.exit?.ipv4 ?? '',
        exitCountryCode: status.exit?.countryCode ?? '',
      );
    }
    if (widget.lantern.state.running) {
      return const LeakFacts(engineLabel: 'Lantern');
    }
    if (widget.openvpn.state.running) {
      return const LeakFacts(engineLabel: 'OpenVPN');
    }
    if (widget.psiphon.state.running) {
      return const LeakFacts(engineLabel: 'Psiphon');
    }
    return const LeakFacts(engineLabel: '');
  }

  @override
  Widget build(BuildContext context) {
    final rows = leakRows(_facts());
    // Batch 5 (fidelity rollout, pro7-diagnostics sample):
    // the page recomposes into the sample's diagnostics
    // composition — hero title, hero stats, the live
    // journal, the verdict rows on the ground, and the
    // export as a slim pill. Every figure is real state or
    // it is not shown:
    //   LEAKS  — the verdict rows that failed (ok == false);
    //   PING   — the live V2Ray session profile's last
    //            measured delay, only while one is recorded;
    //   PROVEN — of the rows that carry a verdict at all
    //            (ok != null), the share that passed.
    // The sample's 'Connection doctor' row is a GAP: the
    // guided check exists only as the connect-time stages
    // on Home — no standalone doctor surface exists to
    // start from here, and none is invented.
    final leaks = rows.where((r) => r.ok == false).length;
    final definitive = rows.where((r) => r.ok != null).toList();
    final proven = definitive.isEmpty
        ? null
        : (definitive.where((r) => r.ok == true).length *
                  100 /
                  definitive.length)
              .round();
    final pingMs = widget.xray.state.running
        ? (widget.xray.sessionProfile?.delayMs ?? -1)
        : -1;
    final journal = widget.xray.diagnostics.entries;
    final journalTail = journal.length <= 4
        ? journal
        : journal.sublist(journal.length - 4);
    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Ember.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Ember.text,
        actions: [
          IconButton(
            tooltip: 'Run again',
            icon: const Icon(Icons.refresh_rounded, color: Ember.text),
            onPressed: () => setState(() {}),
          ),
        ],
      ),
      body: EmberBackground(child: ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          MediaQuery.of(context).padding.top + kToolbarHeight + 8,
          16,
          24,
        ),
        children: [
          Text('Leak test', style: Ember.hero),
            const SizedBox(height: 8),
            Text(
              'What the outside world sees while you are connected — '
              'and what no app can measure from the phone itself.',
              style: Ember.body,
            ),
            const SizedBox(height: 22),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _DiagStat(value: latDigits('$leaks'), label: 'LEAKS'),
                if (pingMs >= 0) ...[
                  const SizedBox(width: 34),
                  _DiagStat(
                    value: latDigits('$pingMs'),
                    unit: 'ms',
                    label: 'PING',
                  ),
                ],
                if (proven != null) ...[
                  const SizedBox(width: 34),
                  _DiagStat(
                    value: latDigits('$proven'),
                    unit: '%',
                    label: 'PROVEN',
                  ),
                ],
              ],
            ),
            if (journalTail.isNotEmpty) ...[
              const SizedBox(height: 26),
              const Divider(color: Ember.line, height: 1, thickness: 1),
              const SizedBox(height: 16),
              Text('LIVE JOURNAL', style: Ember.microLabel),
              const SizedBox(height: 12),
              for (final e in journalTail)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        e.ok == null
                            ? Icons.remove_rounded
                            : e.ok!
                            ? Icons.check_rounded
                            : Icons.close_rounded,
                        size: 17,
                        color: e.ok == null
                            ? Ember.dim
                            : e.ok!
                            ? Ember.orange
                            : Ember.red,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(e.text, style: Ember.body),
                      ),
                    ],
                  ),
                ),
            ],
            const SizedBox(height: 14),
            const Divider(color: Ember.line, height: 1, thickness: 1),
            for (var i = 0; i < rows.length; i++) ...[
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 11),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      rows[i].ok == null
                          ? Icons.help_outline_rounded
                          : rows[i].ok!
                          ? Icons.check_circle_outline_rounded
                          : Icons.error_outline_rounded,
                      size: 18,
                      color: rows[i].ok == null
                          ? Ember.dim
                          : rows[i].ok!
                          ? Ember.green
                          : Ember.red,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            rows[i].label,
                            style: Ember.heading.copyWith(
                              fontSize: Ember.fontBody,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(rows[i].value, style: Ember.body),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              if (i < rows.length - 1)
                const Divider(color: Ember.line, height: 1, thickness: 1),
            ],
            if (_webrtcNote.isNotEmpty) ...[
              const Divider(color: Ember.line, height: 1, thickness: 1),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 11),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.help_outline_rounded,
                      size: 18,
                      color: Ember.dim,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'WebRTC (in-app probe)',
                            style: Ember.heading.copyWith(
                              fontSize: Ember.fontBody,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(_webrtcNote, style: Ember.body),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 18),
            // The export: the same diagnostics bundle the
            // log viewer's Copy All carries (readLogs rides
            // the self-clearing clipboard, build 2119 F-20).
            Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () async {
                  final text = await widget.xray.readLogs();
                  await copySensitive(text);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          AppLocalizations.of(context).logsCopied,
                        ),
                      ),
                    );
                  }
                },
                borderRadius: BorderRadius.circular(999),
                child: Container(
                  height: 48,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: MapUi.card,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: MapUi.lineStrong),
                  ),
                  child: const Text(
                    'EXPORT LOG',
                    style: TextStyle(
                      fontSize: Ember.fontBody,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 2,
                      color: MapUi.text,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            // Build 2147 (feature #19): the encrypted
            // export — same text, sealed with a password.
            Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () => unawaited(_exportEncrypted()),
                borderRadius: BorderRadius.circular(999),
                child: Container(
                  height: 48,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: MapUi.card,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: MapUi.lineStrong),
                  ),
                  child: const Text(
                    'EXPORT ENCRYPTED',
                    style: TextStyle(
                      fontSize: Ember.fontBody,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 2,
                      color: MapUi.text,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            // Build 2147 (feature #14): RUN ALL — a fresh
            // exit read plus the in-app WebRTC probe.
            Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: _runningAll ? null : () => unawaited(_runAll()),
                borderRadius: BorderRadius.circular(999),
                child: Container(
                  height: 48,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: MapUi.card,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: MapUi.lineStrong),
                  ),
                  child: Text(
                    _runningAll ? 'RUNNING…' : 'RUN ALL CHECKS',
                    style: const TextStyle(
                      fontSize: Ember.fontBody,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 2,
                      color: MapUi.text,
                    ),
                  ),
                ),
              ),
            ),
            if (_iceProbeActive)
              SizedBox(
                width: 1,
                height: 1,
                child: InAppWebView(
                  initialData: InAppWebViewInitialData(
                    data: _iceProbeHtml,
                    mimeType: 'text/html',
                  ),
                  initialSettings: InAppWebViewSettings(
                    javaScriptEnabled: true,
                  ),
                  onWebViewCreated: (controller) {
                    controller.addJavaScriptHandler(
                      handlerName: 'IceProbe',
                      callback: (args) {
                        final c = _iceCompleter;
                        if (c != null && !c.isCompleted && args.isNotEmpty) {
                          c.complete('${args.first}');
                        }
                        return null;
                      },
                    );
                  },
                ),
              ),
        ],
      )),
    );
  }
}

/// One hero stat of the diagnostics composition: the light
/// numeral (with its small unit) over a tracked label.
class _DiagStat extends StatelessWidget {
  const _DiagStat({required this.value, required this.label, this.unit});

  final String value;
  final String label;
  final String? unit;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              value,
              style: const TextStyle(
                fontSize: Ember.fontStat,
                fontWeight: FontWeight.w200,
                color: Ember.text,
                height: 1.0,
              ),
            ),
            if (unit != null)
              Padding(
                padding: const EdgeInsets.only(top: 5, left: 2),
                child: Text(unit!, style: Ember.caption),
              ),
          ],
        ),
        const SizedBox(height: 6),
        Text(label, style: Ember.microLabel),
      ],
    );
  }
}

/// Build 2147 (feature #19): seals [plaintext] with
/// [password] — PBKDF2-HMAC-SHA256 ([kDiagKdfIterations]
/// rounds, 16-byte salt) into an AES-256-GCM seal (12-byte
/// nonce), wrapped in the diag-export envelope. The
/// ciphertext is self-authenticating: a wrong password or
/// a tampered file fails the GCM tag on open.
String encryptDiagExport2147(String plaintext, String password) {
  final random = FortunaRandom();
  final seed = Uint8List(32);
  final rng = Random.secure();
  for (var i = 0; i < seed.length; i++) {
    seed[i] = rng.nextInt(256);
  }
  random.seed(KeyParameter(seed));
  final salt = random.nextBytes(16);
  final nonce = random.nextBytes(12);
  final derivator = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
    ..init(Pbkdf2Parameters(salt, kDiagKdfIterations, 32));
  final key = derivator.process(Uint8List.fromList(utf8.encode(password)));
  final cipher = GCMBlockCipher(AESEngine())
    ..init(
      true,
      AEADParameters(KeyParameter(key), 128, nonce, Uint8List(0)),
    );
  final sealed = cipher.process(Uint8List.fromList(utf8.encode(plaintext)));
  return diagExportEnvelope(
    saltB64: base64.encode(salt),
    nonceB64: base64.encode(nonce),
    cipherB64: base64.encode(sealed),
  );
}
