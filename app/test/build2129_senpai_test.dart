/// Build 2129, Leg 3 gates — the Senpai scanner.
///
/// Pinned here:
///   1. The vendored binary: byte-exact against the LML
///      extract (size + sha256), staged in jniLibs, pinned
///      against stripping, MIT text bundled + credited.
///   2. The request JSON shape: LML's defaults and bounds,
///      the anti-DPI default substitution, speedSize in
///      bytes, the speed action's candidates shape, and
///      the last-request round-trip.
///   3. The gates: senpaiEnabled defaults OFF and persists;
///      the Lab's dpiLabEnabled gate is untouched; the
///      settings surface carries both rows.
///   4. The import path: the page imports through
///      profileToLink + XrayController.importLinks and
///      validates with Ember's own testDelay; nothing in
///      the Senpai surface connects a profile.
///   5. The Kotlin bridge: SenpaiCore's wire contract
///      (stdin request line, {"stop":true}, the resumable
///      state path), the MainActivity channels, and the
///      process-birth orphan reap.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/xray/senpai.dart';
import 'package:firefox_vpn/xray/senpai_defaults.dart';
import 'package:firefox_vpn/xray/sha256.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

String src(String rel) => File(rel).readAsStringSync();
String kotlinSrc(String name) => src(
      'android/app/src/main/kotlin/com/ralysnd/ember/$name',
    );
String dartSrc(String rel) => File('lib/$rel').readAsStringSync();

void main() {
  group('vendored binary (build 2129 leg 3)', () {
    test('libsenpai_lml.so is byte-exact vs the LML extract', () {
      final bytes = File(
        'android/app/src/main/jniLibs/arm64-v8a/libsenpai_lml.so',
      ).readAsBytesSync();
      expect(bytes.length, 34297928);
      expect(
        sha256Hex(bytes),
        '4ca1a8d9c05d6fba1a20ff1d887f1a9f63d430c796b0bec2ee4750bdd843db7b',
      );
    });

    test('the binary ships unstripped (hash-verifiable)', () {
      final gradle = src('android/app/build.gradle.kts');
      expect(gradle.contains('"**/libsenpai_lml.so"'), isTrue);
    });

    test('the MIT text is bundled and credited', () {
      final mit = File('assets/licenses/senpai-mit.txt');
      expect(mit.existsSync(), isTrue);
      expect(mit.readAsStringSync().contains('MIT License'), isTrue);
      final page = dartSrc('ui/ember/licenses_page.dart');
      expect(page.contains('SenPaiScanner'), isTrue);
      expect(page.contains('matinsenpai/senpaiscanner'), isTrue);
    });
  });

  group('request JSON shape', () {
    test('defaults are LML\u2019s UI defaults', () {
      final wire = SenpaiRequest().toWire('scan');
      expect(wire['action'], 'scan');
      expect(wire['count'], 1000);
      expect(wire['workers'], 50);
      expect(wire['timeoutMs'], 5000);
      expect(wire['ports'], [443]);
      expect(wire['targets'], '');
      expect(wire['gentle'], isFalse);
      expect(wire['requireWS'], isFalse);
      expect(wire['neighborScan'], isFalse);
      expect(wire['directOnly'], isFalse);
      expect(wire['topN'], 20);
      expect(wire['speedSize'], 512 * 1024);
      expect(wire['minSpeed'], 0.0);
    });

    test('bounds clamp the way the bridge clamps them', () {
      final wire = SenpaiRequest(
        count: 999999,
        workers: 0,
        timeoutMs: 5,
        ports: const [443, 443, 0, 70000, 8443],
        topN: -1,
        speedKb: 99999,
        minSpeed: 5000,
      ).toWire('scan');
      expect(wire['count'], 20000);
      expect(wire['workers'], 1);
      expect(wire['timeoutMs'], 1000);
      expect(wire['ports'], [443, 8443]);
      expect(wire['topN'], 0);
      expect(wire['speedSize'], 10240 * 1024);
      expect(wire['minSpeed'], 1000.0);
    });

    test('empty anti-DPI fields take the bridge defaults', () {
      final wire = SenpaiRequest().toWire('scan');
      final anti = wire['antiDpi'] as Map<String, dynamic>;
      expect(anti['enabled'], isFalse);
      expect(anti['finalmask'], senpaiDefaultFinalmask);
      expect(anti['fingerprint'], 'unsafe');
      expect(anti['alpn'], 'http/1.1');
      expect(anti['cipherSuites'], senpaiDefaultCipherSuites);
      // The default finalmask is a real Xray finalmask
      // document (two TCP fragment entries).
      final mask = jsonDecode(senpaiDefaultFinalmask) as Map;
      expect((mask['tcp'] as List).length, 2);
    });

    test('owner anti-DPI text passes through verbatim', () {
      final wire = SenpaiRequest(
        antiDpiEnabled: true,
        finalmask: '{"tcp":[]}',
        fingerprint: 'chrome',
        alpn: 'h2',
        cipherSuites: 'TLS_AES_128_GCM_SHA256',
      ).toWire('scan');
      final anti = wire['antiDpi'] as Map<String, dynamic>;
      expect(anti['enabled'], isTrue);
      expect(anti['finalmask'], '{"tcp":[]}');
      expect(anti['fingerprint'], 'chrome');
      expect(anti['alpn'], 'h2');
      expect(anti['cipherSuites'], 'TLS_AES_128_GCM_SHA256');
    });

    test('the speed wire carries candidates, targets blanked', () {
      final req = SenpaiRequest(targets: 'example.com');
      final wire = jsonDecode(
        req.speedWireJson(const [
          SenpaiRow(
            ip: '203.0.113.7',
            port: 443,
            latencyMs: 42,
            jitterMs: 3,
            loss: 0,
            colo: 'FRA',
            speedTested: false,
            speedOk: false,
            bytesPerSecond: 0,
          ),
        ]),
      ) as Map<String, dynamic>;
      expect(wire['action'], 'speed');
      expect(wire['targets'], '');
      expect(wire['directOnly'], isFalse);
      expect(wire['candidates'], [
        {'ip': '203.0.113.7', 'port': 443},
      ]);
    });

    test('the last-request round-trip restores the form, '
        'with defaults re-emptied', () {
      final req = SenpaiRequest(
        count: 2500,
        ports: const [443, 8443],
        neighborScan: true,
        fingerprint: 'chrome',
      );
      final restored = SenpaiRequest.fromJson(req.toJson());
      expect(restored.count, 2500);
      expect(restored.ports, [443, 8443]);
      expect(restored.neighborScan, isTrue);
      expect(restored.fingerprint, 'chrome');
      // Fields left empty stay empty (the wire form had
      // substituted defaults; fromJson maps them back).
      expect(restored.finalmask, '');
      expect(restored.cipherSuites, '');
      expect(restored.alpn, '');
    });

    test('state rows parse from the Kotlin snapshot shape', () {
      final state = SenpaiState.fromMap({
        'available': true,
        'running': true,
        'stage': 'running',
        'rows': jsonEncode([
          {
            'ip': '198.51.100.9',
            'port': 8443,
            'latency': 87,
            'jitter': 5,
            'loss': 1.5,
            'colo': 'AMS',
            'speedTested': true,
            'speedOK': true,
            'bytesPerSecond': 2500000.0,
          },
        ]),
        'rowsTotal': 1,
      });
      expect(state.rows.length, 1);
      expect(state.rows.single.endpoint, '198.51.100.9:8443');
      expect(state.rows.single.mbps, closeTo(20.0, 0.01));
    });
  });

  group('gates', () {
    test('senpaiEnabled defaults OFF and persists', () {
      expect(XraySettings().senpaiEnabled, isFalse);
      final s = XraySettings()..senpaiEnabled = true;
      expect(s.toJson()['senpaiEnabled'], isTrue);
      final restored = XraySettings.fromJson(s.toJson());
      expect(restored.senpaiEnabled, isTrue);
      expect(
        XraySettings.fromJson(const {}).senpaiEnabled,
        isFalse,
      );
    });

    test('the settings surface carries the Senpai rows '
        'inside the Lab panel', () {
      final settings = dartSrc('ui/ember/ember_settings.dart');
      expect(settings.contains("label: 'Senpai scanner'"), isTrue);
      expect(settings.contains('s.senpaiEnabled = v'), isTrue);
      expect(settings.contains('SenpaiPage(xray: xray)'), isTrue);
    });

    test('the Lab page links the scanner page', () {
      final lab = dartSrc('ui/ember/dpi_lab_page.dart');
      expect(lab.contains('SenpaiPage(xray: xray)'), isTrue);
      expect(lab.contains("Text('Senpai scanner'"), isTrue);
    });
  });

  group('import path', () {
    final page = dartSrc('ui/ember/senpai_page.dart');

    test('imports go through profileToLink + importLinks', () {
      expect(page.contains('profileToLink(clone)'), isTrue);
      expect(page.contains('xray.importLinks(links.toString())'), isTrue);
      // The clone is the picked template, re-addressed.
      expect(page.contains('template.copy()'), isTrue);
      expect(page.contains('..address = row.ip'), isTrue);
      expect(page.contains('..port = row.port'), isTrue);
    });

    test('imported profiles are validated by Ember\u2019s '
        'own testDelay before being shown as working', () {
      expect(page.contains('await xray.testDelay(p)'), isTrue);
      expect(page.contains('Ember test:'), isTrue);
    });

    test('the Senpai surface never connects', () {
      expect(page.contains('connect('), isFalse);
      expect(page.contains('Nothing was connected'), isTrue);
    });
  });

  group('Kotlin bridge (SenpaiCore)', () {
    final core = kotlinSrc('SenpaiCore.kt');

    test('the wire contract: stdin request, stop line, '
        'state path', () {
      expect(core.contains('writer.write(requestJson)'), isTrue);
      expect(core.contains('"{\\"stop\\":true}\\n"'), isTrue);
      expect(core.contains('"senpai-resume/scan-state.json"'), isTrue);
      expect(core.contains('ProcessBuilder(listOf(bin.absolutePath))'), isTrue);
      expect(core.contains('pb.environment()["HOME"]'), isTrue);
    });

    test('events are parsed by type', () {
      for (final type in [
        '"phase"',
        '"stats"',
        '"results"',
        '"direct-speed"',
        '"error"',
        '"done"',
      ]) {
        expect(core.contains(type), isTrue, reason: type);
      }
    });

    test('channels + orphan reap are wired', () {
      final main = kotlinSrc('MainActivity.kt');
      expect(main.contains('"senpaiStart"'), isTrue);
      expect(main.contains('"senpaiStop"'), isTrue);
      expect(main.contains('"senpaiState"'), isTrue);
      final app = kotlinSrc('EmberApplication.kt');
      expect(app.contains('SenpaiCore.reapOrphan(this)'), isTrue);
    });
  });
}
