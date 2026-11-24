import 'package:firefox_vpn/lantern/lantern_platform.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Lantern engine's state parsing: the map the :lantern
/// process's LanternVpnService publishes (build 2129 — the
/// published snapshot; up to 2128 it was the CLI service's
/// live report), the stage labels the UI speaks, and the
/// mode-3 contract (a state with no error and no binary is
/// inert, never a crash).
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
        'selectedTag': 'nl-amsterdam',
        'servers': 42,
        'serversJson':
            '[{"tag":"nl-amsterdam","city":"Amsterdam",'
            '"country":"Netherlands","countryCode":"NL"}]',
        'smartRouting': false,
        'privateResult': '',
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
      expect(s.selectedTag, 'nl-amsterdam');
      expect(s.servers, 42);
      expect(s.serverList, hasLength(1));
      expect(s.serverList.single.label, 'Netherlands · Amsterdam');
      expect(s.smartRouting, isFalse);
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
      expect(s.serverList, isEmpty);
      expect(s.smartRouting, isFalse);
      expect(s.exitLine, '');
      expect(s.stageLabel, 'Not connected');
    });

    test('stage labels track the contract', () {
      expect(
        const LanternState(stage: 'starting').stageLabel,
        'Starting the core…',
      );
      expect(const LanternState(stage: 'error').stageLabel, 'Failed');
      // Starting is a running session the core has not yet
      // confirmed — the honesty rule (no "Connected" without
      // the core's own verdict).
      expect(const LanternState(running: true).starting, isTrue);
      expect(const LanternState(running: true, connected: true).starting,
          isFalse);
      expect(const LanternState().starting, isFalse);
    });

    test('a country-only exit still names the line', () {
      const s = LanternState(exitCountry: 'Germany');
      expect(s.exitLine, 'Germany');
    });
  });
}
