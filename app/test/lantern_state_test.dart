import 'package:firefox_vpn/lantern/lantern_platform.dart';
import 'package:firefox_vpn/lantern/lantern_platform_windows.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Lantern engine's state parsing (the 2157 contract,
/// W3 radiance port): the map the platform reports, the
/// stage labels the UI speaks, and the mode-3 contract (a
/// state with no error and no binary is inert, never a
/// crash). The Windows backend serves its mixed inbound on
/// 127.0.0.1:12080 (radiance novpn).
void main() {
  group('LanternState.fromMap', () {
    test('parses a full connected report', () {
      final s = LanternState.fromMap({
        'available': true,
        'running': true,
        'coreRunning': true,
        'connected': true,
        'stage': 'up',
        'exitCity': 'Amsterdam',
        'exitCountry': 'Netherlands',
        'exitCode': 'NL',
        'servers': 42,
        'sinceMs': 1700000000000,
        'up': 1024,
        'down': 2048,
        'error': null,
      });
      expect(s.available, isTrue);
      expect(s.running, isTrue);
      expect(s.connected, isTrue);
      expect(s.stage, 'up');
      expect(s.exitLine, 'Amsterdam, Netherlands');
      expect(s.exitCode, 'NL');
      expect(s.servers, 42);
      expect(s.upBytes, 1024);
      expect(s.downBytes, 2048);
      expect(s.error, isNull);
      expect(s.stageLabel, 'Connected');
      expect(s.starting, isFalse);
    });

    test('an empty report is the inert default', () {
      final s = LanternState.fromMap(const {});
      expect(s.available, isFalse);
      expect(s.running, isFalse);
      expect(s.stage, 'idle');
      expect(s.servers, -1);
      expect(s.exitLine, '');
      expect(s.stageLabel, 'Not connected');
      expect(s.countersReported, isFalse);
      expect(s.smartRouting, isFalse);
    });

    test('stage labels track the contract', () {
      expect(
        const LanternState(stage: 'starting').stageLabel,
        'Starting the core…',
      );
      expect(const LanternState(stage: 'error').stageLabel, 'Failed');
      expect(
        const LanternState(running: true, stage: 'starting').starting,
        isTrue,
      );
      expect(
        const LanternState(running: true, connected: true).starting,
        isFalse,
      );
    });

    test('a country-only exit still names the line', () {
      const s = LanternState(exitCountry: 'Germany');
      expect(s.exitLine, 'Germany');
    });

    test('the kill-switch hold and counters flags parse', () {
      // countersReported is DERIVED by fromMap (up/down
      // present as numbers), never read from a map key.
      final s = LanternState.fromMap({
        'killSwitchHeld': true,
        'up': 10,
        'down': 20,
        'selectedTag': 'lantern-nl',
        'smartRouting': true,
      });
      expect(s.killSwitchHeld, isTrue);
      expect(s.countersReported, isTrue);
      expect(s.selectedTag, 'lantern-nl');
      expect(s.smartRouting, isTrue);
    });

    test('the Windows backend serves radiance on 12080', () {
      expect(WindowsLanternBackend.socksPort, 12080);
    });
  });
}
