import 'package:firefox_vpn/lantern/lantern_platform.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Lantern engine's state parsing (build 2024): the map the
/// Kotlin LanternVpnService/LanternCore pair reports, the stage
/// labels the UI speaks, and the mode-3 contract (a state with
/// no error and no binary is inert, never a crash).
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
        'exhausted': false,
        'sinceMs': 1700000000000,
        'up': 1024,
        'down': 2048,
        'error': null,
        'stdoutTail': ['[lantern] listening', '[lantern] proxy ok'],
        'stderrTail': <String>[],
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
      expect(s.stdoutTail, hasLength(2));
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
    });

    test('stage labels track the contract', () {
      expect(
        const LanternState(stage: 'starting').stageLabel,
        'Starting the core…',
      );
      expect(
        const LanternState(stage: 'fetching').stageLabel,
        'Fetching the server list…',
      );
      expect(const LanternState(stage: 'error').stageLabel, 'Failed');
      expect(const LanternState(stage: 'fetching').starting, isTrue);
      expect(
        const LanternState(running: true, stage: 'fetching').starting,
        isTrue,
      );
    });

    test('a country-only exit still names the line', () {
      const s = LanternState(exitCountry: 'Germany');
      expect(s.exitLine, 'Germany');
    });

    test('ports are the MLM-proven pair', () {
      expect(LanternPlatform.socksPort, 20840);
      expect(LanternPlatform.httpPort, 20841);
    });
  });
}
