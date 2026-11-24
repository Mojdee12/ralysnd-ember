import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:firefox_vpn/app_settings.dart';
import 'package:firefox_vpn/core/core_api.dart';
import 'package:firefox_vpn/core/core_controller.dart';
import 'package:firefox_vpn/core/models.dart';
import 'package:firefox_vpn/openvpn/openvpn_models.dart';
import 'package:firefox_vpn/ui/ember/ember_updater.dart';
import 'package:firefox_vpn/xray/link_parser.dart';
import 'package:firefox_vpn/xray/mieru_config.dart';

/// Build 2119 — audit-fix pins.
///
/// F-01 (Dart half): the core's journal-worthy log lines
/// are mirrored into the diagnostics journal through
/// CoreController.journalLine, so the one Diagnostics
/// export the owner pastes carries both halves of a
/// Mozilla degradation — the Dart boundary lines and the
/// Go renewal/failure lines.

class _LoggingApi implements CoreApi {
  final List<Map<String, Object?>> entries = [];
  int _nextId = 0;

  void log(String level, String message) {
    _nextId++;
    entries.add({
      'id': _nextId,
      'time': '2026-11-19T00:00:00Z',
      'level': level,
      'message': message,
    });
  }

  @override
  Future<CoreStatus> status() async => CoreStatus.fromJson({
    'state': {'phase': 'off', 'message': 'Proxy off'},
  });

  @override
  Future<AccountList> accounts() async => AccountList.fromJson({});

  @override
  Future<List<LogEntry>> logs(int after) async => [
    for (final e in entries)
      if ((e['id'] as int) > after) LogEntry.fromJson(e),
  ];

  @override
  void close() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('F-01 core log mirror', () {
    test('worthy lines are journalled, routine lines are not', () async {
      final api = _LoggingApi();
      api.log('INFO', 'proxy pass renewal scheduled next_expiry=x delay=1s');
      api.log('DEBUG', 'HTTP proxy request unreadable client=x');
      api.log('INFO', 'upstream proxy session opened on the next server');
      api.log('WARN', 'proxy pass renewal failed code=x upstream_failures=server=1');
      api.log('ERROR', 'proxy pass renewal is stuck after timing out');
      api.log('INFO', 'upstream failure summary open=server=1 established=none');
      final core = CoreController(
        () async => api,
        pollInterval: const Duration(hours: 1),
      );
      final lines = <String>[];
      core.journalLine = lines.add;
      await core.refresh();
      expect(lines, hasLength(4));
      expect(lines[0], contains('proxy pass renewal scheduled'));
      expect(lines[1], contains('proxy pass renewal failed'));
      expect(lines[2], contains('renewal is stuck'));
      expect(lines[3], contains('upstream failure summary'));
      for (final l in lines) {
        expect(l, startsWith('core log ['));
      }
      // A second poll with nothing new mirrors nothing.
      await core.refresh();
      expect(lines, hasLength(4));
      // A new worthy line after the watermark is mirrored.
      // Build 2125 re-point (A25-21): the mirror runs on
      // every 3rd tick (ticks 0, 3, 6, …) — the watermark
      // only advances on a mirror tick, so a line is
      // delayed by at most one cadence, never lost. Two
      // more polls reach the next mirror tick.
      api.log('WARN', 'quota check failed: x');
      await core.refresh();
      await core.refresh();
      expect(lines, hasLength(5));
      expect(lines[4], contains('quota check failed'));
      core.dispose();
    });

    test('the journal-worthy filter itself', () {
      LogEntry e(String level, String message) => LogEntry.fromJson({
        'id': 1,
        'time': '2026-11-19T00:00:00Z',
        'level': level,
        'message': message,
      });
      expect(CoreController.coreLogLineIsJournalWorthy(e('WARN', 'any')), isTrue);
      expect(CoreController.coreLogLineIsJournalWorthy(e('ERROR', 'any')), isTrue);
      expect(
        CoreController.coreLogLineIsJournalWorthy(
          e('INFO', 'proxy pass renewal succeeded route=direct'),
        ),
        isTrue,
      );
      expect(
        CoreController.coreLogLineIsJournalWorthy(
          e('INFO', 'established session failure class=server count=1'),
        ),
        isFalse,
        reason: 'established lines ride the upstream-failure summary instead',
      );
      expect(
        CoreController.coreLogLineIsJournalWorthy(e('INFO', 'OAuth token refreshed')),
        isFalse,
      );
      expect(CoreController.coreLogLineIsJournalWorthy(e('DEBUG', 'any')), isFalse);
    });
  });

  group('build identity', () {
    test('pubspec is 2.2.0+2119', () {
      expect(
        File('pubspec.yaml').readAsStringSync(),
        contains('version: 2.2.0+2148'),
      );
    });
  });

  group('F-02 adoption proof wiring (source pins)', () {
    test('the controller runs the proof once per adopted session', () {
      final src = File('lib/xray/xray_controller.dart').readAsStringSync();
      expect(src, contains('_adoptionProofFor'));
      expect(src, contains('awaitXrayCarries'));
      expect(src, contains('withVerified(true)'));
    });

    test('the shell bars show the unverified word until proven', () {
      final src = File('lib/ui/ember/ember_shell.dart').readAsStringSync();
      expect(src, contains('Connected — not answering'));
      expect(src, contains('_xray.state.verified'));
    });
  });

  group('F-04 Aether EngineClaim identity (source pins)', () {
    test('EngineClaim carries WARP and AETHER identities', () {
      final src = File(
        'android/app/src/main/kotlin/com/ralysnd/ember/EngineClaim.kt',
      ).readAsStringSync();
      expect(src, contains('const val WARP = "warp"'));
      expect(src, contains('const val AETHER = "aether"'));
      expect(src, contains('isXrayHosted('));
    });

    test('the service claims per start action and releases its own name', () {
      final src = File(
        'android/app/src/main/kotlin/com/ralysnd/ember/XrayVpnService.kt',
      ).readAsStringSync();
      expect(src, contains('EngineClaim.WARP'));
      expect(src, contains('EngineClaim.AETHER'));
      expect(src, contains('claimName'));
    });

    test('the Dart re-arbitration families know warp and aether', () {
      final src = File('lib/ui/ember/ember_shell.dart').readAsStringSync();
      expect(src, contains("'warp': {6}"));
      expect(src, contains("'aether': {6, 7}"));
    });
  });

  group('F-07 OpenVPN compression directives are flagged', () {
    test('comp-lzo and compress land in the unsupported list', () {
      final p = OvpnProfile.parse(
        id: 't1',
        name: 't',
        text: 'client\ndev tun\ncomp-lzo\ncompress lz4\nremote vpn.example.com 1194\n',
      );
      expect(p.unsupported, contains('comp-lzo'));
      expect(p.unsupported, contains('compress'));
    });
  });

  group('F-08 Mieru log level follows the setting', () {
    test('the mapping speaks Mieru names, none is its quietest', () {
      expect(mieruLogLevel('debug'), 'DEBUG');
      expect(mieruLogLevel('info'), 'INFO');
      expect(mieruLogLevel('warning'), 'WARN');
      expect(mieruLogLevel('error'), 'ERROR');
      expect(mieruLogLevel('none'), 'ERROR');
      expect(mieruLogLevel('bogus'), 'INFO');
    });

    test('the built config carries the mapped level', () {
      final p = parseLink('mieru://user:pass@mi.example.com:2023#M')!;
      expect(buildMieruConfig(p)['loggingLevel'], 'INFO');
      expect(buildMieruConfig(p, logLevel: 'debug')['loggingLevel'], 'DEBUG');
      expect(buildMieruConfig(p, logLevel: 'none')['loggingLevel'], 'ERROR');
    });
  });

  group('F-10 absent keys decode OFF outside the reset block', () {
    Future<AppSettings> loadDoc(Map<String, Object?> doc) async {
      final dir = await Directory.systemTemp.createTemp('ember2119');
      addTearDown(() => dir.delete(recursive: true));
      await File('${dir.path}/app-settings.json').writeAsString(
        // A hand-built encoder is unnecessary: the doc is tiny.
        _jsonEncode(doc),
      );
      final s = await AppSettings.load(dir.path);
      addTearDown(s.dispose);
      return s;
    }

    test('reset flag present, keys absent -> both OFF', () async {
      final s = await loadDoc({'defaults_reset_2114': true});
      expect(s.udpNotice, isFalse);
      expect(s.launcherShortcutsEnabled, isFalse);
    });

    test('a stored true (owner choice after the reset) is honoured', () async {
      final s = await loadDoc({
        'defaults_reset_2114': true,
        'udp_notice': true,
        'launcher_shortcuts': true,
      });
      expect(s.udpNotice, isTrue);
      expect(s.launcherShortcutsEnabled, isTrue);
    });
  });

  group('F-11 the updater knows when a download is unverified', () {
    Map<String, Object?> feed({bool withDigest = false}) => {
      'tag_name': 'v2119',
      'name': 'Build 2119',
      'body': '',
      'assets': [
        {
          'name': emberUpdateAssetName,
          'browser_download_url': 'https://example.com/RalysndEmber2.apk',
          'size': 1000,
          if (withDigest) 'digest': 'sha256:ABCDEF0123',
        },
      ],
    };

    test('a feed without a digest parses to an empty apkDigest', () {
      final r = parseLatestRelease(feed());
      expect(r, isNotNull);
      expect(r!.apkDigest, '');
    });

    test('a feed digest is normalized to bare lowercase hex', () {
      final r = parseLatestRelease(feed(withDigest: true));
      expect(r!.apkDigest, 'abcdef0123');
    });

    test('the offer wording distinguishes verified from unverified', () {
      final settings = File(
        'lib/ui/ember/ember_settings.dart',
      ).readAsStringSync();
      expect(settings, contains('UNVERIFIED'));
      expect(settings, contains('checksum verified'));
      final updater = File(
        'lib/ui/ember/ember_updater.dart',
      ).readAsStringSync();
      expect(updater, contains('downloadedVerified = r.apkDigest.isNotEmpty'));
    });
  });

  group('F-13 the dead legacy shell is gone', () {
    test('lib/ui/mobile_shell.dart does not exist', () {
      expect(File('lib/ui/mobile_shell.dart').existsSync(), isFalse);
    });
  });

  group('appearance bundle tokens (F-14/F-15/F-16/F-18)', () {
    test('F-15 the selected wash is the softened token', () {
      final src = File('lib/ui/ember/ember_theme.dart').readAsStringSync();
      // PIN UPDATED by build 2144 (reskin): the wash follows
      // the samples' accent #FF7A29.
      expect(src, contains('Color(0x1AFF7A29), Color(0x08FF7A29)'));
      expect(src, isNot(contains('Color(0x47FF7A29)')));
    });

    test('F-16 the unselected chip wears the lifted fill', () {
      final src = File('lib/ui/ember/ember_theme.dart').readAsStringSync();
      expect(src, contains('Colors.white.withValues(alpha: 0.09)'));
    });

    test('F-14 the luminous ring alphas softened one notch', () {
      final src = File('lib/ui/ember/map_widgets.dart').readAsStringSync();
      // PIN UPDATED by build 2144 (reskin): the ring's deep
      // stop is the flat accent now, not the retired E65116.
      expect(
        src,
        contains('Color(0xD9FFC38A), Color(0x99FF8A3D), Color(0x66FF7A29)'),
      );
    });

    test('F-18 the drifted gradient pair survives nowhere as a gradient', () {
      // The toggle's orange SHADOW tint (a lone E65116 at
      // alpha 0.35) is not a gradient stop pair and stays;
      // what F-18 unified is the two-stop capsule gradient.
      for (final f in [
        'lib/ui/ember/ember_theme.dart',
        'lib/ui/ember/map_widgets.dart',
      ]) {
        final src = File(f).readAsStringSync();
        expect(src, isNot(contains('0xFFFF9E42')), reason: f);
      }
      final theme = File('lib/ui/ember/ember_theme.dart').readAsStringSync();
      // PIN UPDATED by build 2137 (visual review V-03):
      // E65116 is no longer the drifted stop — it is the
      // approved spec's deep stop of Ember.gradient itself
      // (#FF8533 → #E65116). What F-18 still forbids is a
      // SECOND pair: the gradient's stops live in the one
      // token, pinned here.
      // PIN UPDATED by build 2144 (reskin): the approved
      // samples flatten the primary to a single #FF7A29 —
      // both stops of the one token are the flat accent.
      expect(
        theme,
        contains('colors: [Color(0xFFFF7A29), Color(0xFFFF7A29)]'),
      );
      final widgets = File('lib/ui/ember/map_widgets.dart').readAsStringSync();
      // PIN UPDATED by batch 5 (fidelity rollout): the
      // value capsule's lit state FLATTENS to the single
      // accent — the approved pro6/pro7 samples wear flat
      // orange pills, never a gradient capsule (the A7
      // unification, as on EmberChip in 2144). F-18's core
      // stands: the drifted pair survives nowhere, and the
      // one gradient token (and the toggle's use of it) is
      // untouched.
      expect(widgets, contains('color: lit ? Ember.orange : MapUi.insetFill'));
      expect(widgets, isNot(contains('gradient: lit')));
      expect(widgets, contains('gradient: on ? Ember.gradient : null'));
    });
  });
}

/// Minimal JSON encoder for the tiny settings documents
/// above (avoids pulling dart:convert into a file that
/// otherwise does not need it — kept dependency-free).
String _jsonEncode(Map<String, Object?> doc) {
  final parts = <String>[];
  for (final e in doc.entries) {
    final v = e.value;
    final encoded = v is String ? '"$v"' : '$v';
    parts.add('"${e.key}": $encoded');
  }
  return '{${parts.join(', ')}}';
}
