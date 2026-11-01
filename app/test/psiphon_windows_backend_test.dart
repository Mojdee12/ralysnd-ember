/// Regression test for the 2.0.0–2.0.5 Windows Psiphon defect: the
/// ConsoleClient writes its JSON notices to STDERR (its notice
/// writer defaults to os.Stderr), but the backend parsed STDOUT —
/// so a healthy core's ListeningSocksProxyPort notice landed in
/// psiphon.log via the raw tee while the listener wait timed out
/// and stopped the core. This test stages a fake psiphon-core.exe
/// that emits the exact notice lines from a real failed run (the
/// user's 2.0.5 log, 2026-11-01) on stderr, and drives the real
/// WindowsPsiphonBackend end to end: setOn must pass its listener
/// wait, and the notice-fed state must flip.
///
/// POSIX hosts only: the fake core is a shell script. On Windows CI
/// the test is skipped (the CI sidecar smoke in
/// scripts/fetch-windows-sidecars.ps1 covers the real core there).
@TestOn('linux || mac-os')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:firefox_vpn/psiphon/psiphon_platform_windows.dart';

/// The fake core: the user's real notice lines, on stderr (where
/// the ConsoleClient actually puts them), then stay alive.
const _fakeCore = r'''#!/bin/sh
echo '{"data":{"message":"RemoteServerListURLs overridden by AdditionalParameters"},"noticeType":"Info","timestamp":"2026-11-01T20:53:38.600Z"}' >&2
sleep 0.2
echo '{"data":{"regions":["AT","DE","GB","US"]},"noticeType":"AvailableEgressRegions","timestamp":"2026-11-01T20:53:46.011Z"}' >&2
echo '{"data":{"port":11808},"noticeType":"ListeningSocksProxyPort","timestamp":"2026-11-01T20:53:40.960Z"}' >&2
echo '{"data":{"port":11809},"noticeType":"ListeningHttpProxyPort","timestamp":"2026-11-01T20:53:40.960Z"}' >&2
echo '{"data":{"region":"DE"},"noticeType":"ClientRegion","timestamp":"2026-11-01T20:53:47.000Z"}' >&2
echo '{"data":{"count":1},"noticeType":"Tunnels","timestamp":"2026-11-01T20:53:48.000Z"}' >&2
exec sleep 60
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'notices on stderr drive the backend state (2.0.6 regression)',
    () async {
      // Stage the fake at the exact sidecar path the backend
      // derives from the running executable.
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      final sidecarDir = Directory('$exeDir/psiphon');
      await sidecarDir.create(recursive: true);
      final sidecar = File('${sidecarDir.path}/psiphon-core.exe');
      final prior = await sidecar.exists() || await Link(sidecar.path).exists();
      if (await Link(sidecar.path).exists()) await Link(sidecar.path).delete();
      if (await sidecar.exists()) await sidecar.delete();
      await sidecar.writeAsString(_fakeCore, flush: true);
      await Process.run('chmod', ['+x', sidecar.path]);
      addTearDown(() async {
        if (!prior && await sidecar.exists()) await sidecar.delete();
      });

      final backend = WindowsPsiphonBackend();
      final sw = Stopwatch()..start();
      await backend.setOn(
        vpnMode: false,
        region: '',
        upstream: '',
        protocols: const [],
        dns: '1.1.1.1',
      );
      // The listener wait passed — quickly, not via the 15 s timeout.
      expect(sw.elapsed, lessThan(const Duration(seconds: 10)));
      final s = await backend.state();
      expect(s.running, isTrue);
      expect(s.connected, isTrue);
      expect(s.regions, contains('DE'));
      expect(s.region, 'DE');
      expect(s.lastError, isEmpty);
      await backend.stop();
      expect((await backend.state()).running, isFalse);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
