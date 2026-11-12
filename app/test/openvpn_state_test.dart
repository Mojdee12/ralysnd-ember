import 'package:firefox_vpn/openvpn/openvpn_platform.dart';
import 'package:flutter_test/flutter_test.dart';

/// Build 2025: the OpenVPN platform-state decoding.
void main() {
  group('OpenVpnState.fromMap', () {
    test('decodes a connected session', () {
      final s = OpenVpnState.fromMap({
        'available': true,
        'running': true,
        'connected': true,
        'phase': 'connected',
        'profileId': 'tb-de',
        'profileName': 'Germany',
        'sinceMs': 123,
        'up': 100,
        'down': 250,
        'exitIp': '203.0.113.7',
        'exitCountry': 'Germany',
        'exitCode': 'DE',
        'error': null,
        'logTail': ['one', 'two'],
      });
      expect(s.connected, isTrue);
      expect(s.phaseLabel, 'Connected');
      expect(s.exitLine, '203.0.113.7 · Germany');
      expect(s.logTail, hasLength(2));
      expect(s.starting, isFalse);
    });

    test('an empty map is the stopped state', () {
      final s = OpenVpnState.fromMap({});
      expect(s.running, isFalse);
      expect(s.phase, 'idle');
      expect(s.phaseLabel, 'Not connected');
      expect(s.exitLine, isEmpty);
    });

    test('connecting phases read as starting', () {
      for (final phase in ['connecting', 'verifying', 'reconnecting']) {
        expect(OpenVpnState.fromMap({'phase': phase}).starting, isTrue);
      }
    });
  });

  group('OvpnPing.fromMap', () {
    test('decodes a measurement', () {
      final p = OvpnPing.fromMap({'ms': 42, 'method': 'TCP_CONNECT'});
      expect(p.measured, isTrue);
      expect(p.ms, 42);
    });

    test('an unmeasured result stays unmeasured', () {
      final p = OvpnPing.fromMap({
        'ms': -1,
        'method': 'UNSUPPORTED_CONTROL_AUTH',
      });
      expect(p.measured, isFalse);
      expect(p.method, 'UNSUPPORTED_CONTROL_AUTH');
    });
  });
}
