/// Build 2095, batch 6 — OpenVPN (whole-app journey audit
/// #8, #9, #15, #34, #51).
///
/// - #8: deleting the profile the live tunnel is running
///   disconnects first; deleting any other profile does not
///   touch the tunnel.
/// - #15: a config pointing at external files is blocked
///   at connect with a plain reason, before validation or
///   any tunnel start.
/// - #34: rename changes the display name only — id and
///   credKey (and so the saved credentials) survive.
/// - #9: the AUTH_FAILED classifier + the re-prompt flow's
///   source pins.
/// - #51: the credentials sheet has a visible row button,
///   not only the long-press.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/openvpn/openvpn_controller.dart';
import 'package:firefox_vpn/ui/ember/openvpn_pages.dart';

const _cfgA = '''
client
dev tun
proto udp
remote alpha.example.com 1194
auth-user-pass
''';

const _cfgExternal = '''
client
dev tun
proto udp
remote gamma.example.com 1194
ca ca.crt
key client.key
cert client.crt
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  final channelCalls = <String>[];
  var stateMap = <String, Object?>{};

  Map<String, Object?> stateFor({bool running = false, String profileId = ''}) =>
      <String, Object?>{
        'available': true,
        'running': running,
        'connected': running,
        'phase': running ? 'connected' : 'idle',
        'profileId': profileId,
        'profileName': '',
        'sinceMs': 0,
        'up': 0,
        'down': 0,
        'exitIp': '',
        'exitCountry': '',
        'exitCode': '',
        'error': null,
        'logTail': <String>[],
        'lastExitReason': '',
        'lastStage': '',
        'lastException': '',
      };

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('ovpn2095');
    channelCalls.clear();
    stateMap = stateFor();
    final dir = Directory('${tempDir.path}/openvpn');
    await dir.create(recursive: true);
    await File('${dir.path}/state.json').writeAsString(
      jsonEncode({
        'selectedId': 'user-a',
        'profiles': [
          {'id': 'user-a', 'name': 'Alpha', 'config': _cfgA},
          {'id': 'user-x', 'name': 'External', 'config': _cfgExternal},
        ],
      }),
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('app/android'), (
          call,
        ) async {
          channelCalls.add(call.method);
          switch (call.method) {
            case 'dataDir':
              return '${tempDir.path}/core';
            case 'openVpnState':
              return stateMap;
            case 'openVpnStop':
              stateMap = stateFor();
              return null;
            case 'openVpnCredentialStatus':
              return 'ok';
            case 'openVpnHasCredentials':
              return true;
            default:
              return null;
          }
        });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('app/android'), null);
    await tempDir.delete(recursive: true);
  });

  group('delete-while-connected (audit #8)', () {
    test('deleting the running profile disconnects first', () async {
      final c = OpenVpnController();
      addTearDown(c.dispose);
      await c.load();
      stateMap = stateFor(running: true, profileId: 'user-a');
      await c.refresh();
      expect(c.state.running, isTrue);
      await c.deleteProfile('user-a');
      expect(
        channelCalls,
        contains('openVpnStop'),
        reason: 'the tunnel stops before its profile is deleted',
      );
      expect(c.userProfiles.map((p) => p.id), ['user-x']);
    });

    test('deleting another profile leaves the tunnel alone', () async {
      final c = OpenVpnController();
      addTearDown(c.dispose);
      await c.load();
      stateMap = stateFor(running: true, profileId: 'user-a');
      await c.refresh();
      await c.deleteProfile('user-x');
      expect(channelCalls, isNot(contains('openVpnStop')));
      expect(c.userProfiles.map((p) => p.id), ['user-a']);
    });
  });

  group('external-file configs (audit #15)', () {
    test('connect is blocked with the reason, before the core', () async {
      final c = OpenVpnController();
      addTearDown(c.dispose);
      await c.load();
      c.select('user-x');
      Object? error;
      try {
        await c.connect();
      } catch (e) {
        error = e;
      }
      expect(error, isA<StateError>());
      expect(
        (error! as StateError).message,
        contains('points at external files'),
      );
      expect((error as StateError).message, contains('ca file (ca.crt)'));
      expect(channelCalls, isNot(contains('openVpnValidate')));
      expect(channelCalls, isNot(contains('openVpnSetOn')));
    });

    test('the parse names the external references', () {
      final c = OpenVpnController();
      addTearDown(c.dispose);
      // Seeded through load in the other tests; parse here
      // directly through a fresh import-free path: the
      // profile in the store carries them after load.
      return c.load().then((_) {
        final p = c.userProfiles.firstWhere((p) => p.id == 'user-x');
        expect(p.unsupported, contains('ca file (ca.crt)'));
        expect(p.unsupported, contains('key file (client.key)'));
      });
    });
  });

  group('rename (audit #34)', () {
    test('rename changes the name only; id + credKey survive', () async {
      final c = OpenVpnController();
      addTearDown(c.dispose);
      await c.load();
      final before = c.userProfiles.firstWhere((p) => p.id == 'user-a');
      await c.renameProfile('user-a', 'Alpha Prime');
      final after = c.userProfiles.firstWhere((p) => p.id == 'user-a');
      expect(after.name, 'Alpha Prime');
      expect(after.id, before.id);
      expect(after.credKey, before.credKey);
      expect(after.config, before.config);
      // Persisted: the store file carries the new name.
      final stored = await File(
        '${tempDir.path}/openvpn/state.json',
      ).readAsString();
      expect(stored, contains('Alpha Prime'));
    });
  });

  group('auth failure (audit #9, #51)', () {
    test('the classifier recognises the core terminal', () {
      expect(isOvpnAuthFailure('AUTH_FAILED'), isTrue);
      expect(isOvpnAuthFailure('Authentication failed'), isTrue);
      expect(isOvpnAuthFailure('CONNECTION_TIMEOUT'), isFalse);
      expect(isOvpnAuthFailure('credentials-required'), isFalse);
    });

    test('the re-prompt flow + visible credentials button exist', () {
      final pages = File('lib/ui/ember/openvpn_pages.dart').readAsStringSync();
      expect(pages, contains('The server rejected the saved password'));
      expect(pages, contains('OpenVpnPlatform.deleteCredentials(p.credKey)'));
      expect(pages, contains("tooltip: 'Saved credentials'"));
      expect(pages, contains("tooltip: 'Rename profile'"));
      final controller = File(
        'lib/openvpn/openvpn_controller.dart',
      ).readAsStringSync();
      expect(controller, contains('Future<void> renameProfile('));
    });
  });
}
