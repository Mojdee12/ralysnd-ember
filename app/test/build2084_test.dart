/// Build 2084 gates — the MASQUE cleartext fix (diagnosis:
/// ~/workspace/ember-app/masque-probe-diagnosis-2026-11-15.md).
///
/// Build 2083's carrier ladder rejected every rung with
/// "data did not pass (http204=no)" although the core's own
/// log showed the tunnel validated: Ember's dataProbe check
/// #1 is a plain-HTTP request via HttpURLConnection, and the
/// manifest set neither usesCleartextTraffic nor a
/// networkSecurityConfig, so with targetSdk >= 28 the
/// platform refused the request in-process before any packet
/// existed. ralysnd escapes via manifest
/// usesCleartextTraffic="true" + bundled OkHttp.
///
/// The fix is surgical: a network security config that keeps
/// cleartext denied app-wide and permits it for exactly the
/// probe's two hosts, plus probe diagnostics — the helpers
/// no longer swallow their exceptions, so the next failure
/// names its cause in the fail detail. The probe recipe,
/// endpoints, order and timeouts are NOT changed.
///
/// What only the owner's phone can prove — MASQUE now
/// connecting end to end on his filtered line — is NOT
/// claimed here.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String ktSrc(String rel) =>
    File('android/app/src/main/kotlin/com/ralysnd/ember/$rel')
        .readAsStringSync();

String _manifest() =>
    File('android/app/src/main/AndroidManifest.xml').readAsStringSync();

String _netSec() =>
    File('android/app/src/main/res/xml/network_security_config.xml')
        .readAsStringSync();

/// The text of one function in a source file: from [start]
/// up to (not including) the next occurrence of [end].
String region(String src, String start, String end) {
  final a = src.indexOf(start);
  expect(a, greaterThanOrEqualTo(0), reason: '$start is present');
  final b = src.indexOf(end, a);
  expect(b, greaterThan(a), reason: '$end follows $start');
  return src.substring(a, b);
}

int occurrences(String haystack, String needle) =>
    haystack.split(needle).length - 1;

void main() {
  group('build 2084 — the manifest wires the network security config', () {
    test('the application element references @xml/network_security_config',
        () {
      final manifest = _manifest();
      expect(
        manifest,
        contains('android:networkSecurityConfig='
            '"@xml/network_security_config"'),
      );
    });

    test('no app-wide usesCleartextTraffic is set anywhere', () {
      expect(_manifest(), isNot(contains('usesCleartextTraffic')));
      expect(_netSec(), isNot(contains('usesCleartextTraffic')));
    });
  });

  group('build 2084 — cleartext is permitted for exactly the probe hosts',
      () {
    test('base-config keeps cleartext denied', () {
      expect(
        _netSec(),
        contains('<base-config cleartextTrafficPermitted="false" />'),
      );
    });

    test('one domain-config permits cleartext', () {
      final xml = _netSec();
      expect(occurrences(xml, '<domain-config'), 1);
      expect(
        xml,
        contains('<domain-config cleartextTrafficPermitted="true">'),
      );
    });

    test('exactly the two probe hosts are listed, no others', () {
      final xml = _netSec();
      expect(occurrences(xml, '<domain '), 2);
      expect(
        xml,
        contains(
            '<domain includeSubdomains="false">www.gstatic.com</domain>'),
      );
      expect(
        xml,
        contains('<domain includeSubdomains="false">'
            'connectivitycheck.gstatic.com</domain>'),
      );
    });

    test('the permitted hosts are the probe recipe\'s HTTP hosts', () {
      final kt = ktSrc('AetherCore.kt');
      final urls = region(kt, 'private val http204Urls', 'private val https204Urls');
      expect(urls, contains('"http://www.gstatic.com/generate_204"'));
      expect(
        urls,
        contains('"http://connectivitycheck.gstatic.com/generate_204"'),
      );
      // Recipe order unchanged: www first, connectivitycheck second.
      expect(
        urls.indexOf('www.gstatic.com'),
        lessThan(urls.indexOf('connectivitycheck.gstatic.com')),
      );
    });
  });

  group('build 2084 — probe failures carry their exception', () {
    test('the pure formatter appends the error in brackets', () {
      final kt = ktSrc('AetherCore.kt');
      expect(kt, contains('fun probeFailDetail(reason: String, error: String?)'));
      expect(
        kt,
        contains('if (error.isNullOrBlank()) reason else "\$reason [\$error]"'),
      );
      expect(kt, contains('fun probeErrorText(e: Exception): String'));
      expect(kt, contains('"\${e.javaClass.simpleName}: \$msg"'));
    });

    test('dataProbe folds the recorded error into every fail detail', () {
      final kt = ktSrc('AetherCore.kt');
      final probe = region(kt, 'fun dataProbe()', 'private fun probeRequest');
      expect(probe, contains('probeFailDetail("http204=no", lastProbeError)'));
      expect(probe, contains('probeFailDetail("https204=no", lastProbeError)'));
      expect(probe, contains('probeFailDetail("down=\$down", lastProbeError)'));
      expect(probe, contains('probeFailDetail("up=0", lastProbeError)'));
      // The standing wrapper in bringUp is untouched.
      expect(kt, contains('"data did not pass (\${detail.ifEmpty { "no detail" }})"'));
    });

    test('the success detail string is unchanged', () {
      final kt = ktSrc('AetherCore.kt');
      final probe = region(kt, 'fun dataProbe()', 'private fun probeRequest');
      expect(probe, contains('"detail" to "http=204 https=204 down=\$down " +'));
      expect(probe, contains('"up=\$DATA_PROBE_UP_BYTES"'));
    });

    test('no probe helper swallows its exception silently anymore', () {
      final kt = ktSrc('AetherCore.kt');
      for (final helper in [
        region(kt, 'private fun probe204', 'private fun probeDownload'),
        region(kt, 'private fun probeDownload', 'private fun probeUploadEcho'),
        region(kt, 'private fun probeUploadEcho', 'private fun topProbeReason'),
      ]) {
        expect(helper, isNot(contains('catch (_: Exception)')));
        expect(helper, contains('lastProbeError = probeErrorText(e)'));
        expect(helper, contains('lastProbeError = null'));
      }
    });
  });
}
