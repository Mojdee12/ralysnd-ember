/// Build 2095 (feature 8 — leak test): one page that says,
/// in plain language, what the outside world can see while
/// a session runs — and, just as plainly, what the app
/// cannot measure on-device. The verdict rows are built by
/// the pure [leakRows] so the wording is unit-tested.

import 'package:flutter/material.dart';

import '../../aether/aether_controller.dart';
import '../../core/core_controller.dart';
import '../../core/models.dart' show Phase;
import '../../lantern/lantern_controller.dart';
import '../../l10n/app_localizations.dart';
import '../../openvpn/openvpn_controller.dart';
import '../../psiphon/psiphon_controller.dart';
import '../../xray/config_builder.dart' show primaryResolvers;
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
                  height: 46,
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
