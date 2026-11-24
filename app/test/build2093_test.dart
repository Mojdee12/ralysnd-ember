/// Build 2093 gates, host side: launcher shortcuts for one-tap
/// connect (feature-watch 2026-11-16, FlClash 0.9.x) — long-press
/// the app icon to connect straight to a starred config. These
/// tests pin the Dart side of the contract: the shortcut list (at
/// most 4, list order, dedupe, blank filtering, label cut), the
/// inbound intent parsing, the outbound channel contract (publish
/// when on, clear when off, never throws), the settings
/// round-trip, and the controller's republish on the starred-set
/// changes. The Kotlin ShortcutManager calls and the shell's
/// connect-from-shortcut flow are not host-testable without a
/// device; the tests pin the state and payloads they read.

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/app_settings.dart';
import 'package:firefox_vpn/net/launcher_shortcuts.dart';
import 'package:firefox_vpn/xray/xray_controller.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

Profile vless(String id, String address, {bool starred = false}) => Profile(
  id: id,
  protocol: Protocol.vless,
  name: id,
  address: address,
  port: 443,
  uuidOrPassword: '00000000-0000-4000-8000-000000000000',
  security: 'tls',
  sni: address,
  starred: starred,
);

const _channel = MethodChannel('app/android');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('Shortcut list (build 2093)', () {
    test('empty in, empty out', () {
      expect(buildShortcutTargets([]), isEmpty);
    });

    test('at most four, in list order', () {
      final targets = buildShortcutTargets([
        for (var i = 0; i < 6; i++)
          ShortcutTarget(id: 'p$i', name: 'Node $i'),
      ]);
      expect(targets.map((t) => t.id), ['p0', 'p1', 'p2', 'p3']);
    });

    test('a repeated id keeps its first occurrence', () {
      final targets = buildShortcutTargets([
        const ShortcutTarget(id: 'a', name: 'First'),
        const ShortcutTarget(id: 'b', name: 'Second'),
        const ShortcutTarget(id: 'a', name: 'Duplicate'),
      ]);
      expect(targets.map((t) => t.id), ['a', 'b']);
      expect(targets.first.name, 'First');
    });

    test('blank ids and blank names never publish', () {
      final targets = buildShortcutTargets([
        const ShortcutTarget(id: '', name: 'No id'),
        const ShortcutTarget(id: 'a', name: ''),
        const ShortcutTarget(id: 'b', name: 'Keeps'),
      ]);
      expect(targets.map((t) => t.id), ['b']);
    });

    test('a long name is cut to 25 characters', () {
      final long = 'A very long config name that keeps going';
      final targets = buildShortcutTargets([
        ShortcutTarget(id: 'a', name: long),
      ]);
      expect(targets.single.name, long.substring(0, 25));
      expect(targets.single.name.length, 25);
    });

    test('a 25-character name is unchanged', () {
      const name = '1234567890123456789012345';
      expect(name.length, 25);
      final targets = buildShortcutTargets([
        const ShortcutTarget(id: 'a', name: name),
      ]);
      expect(targets.single.name, name);
    });
  });

  group('Shortcut intent parsing (build 2093)', () {
    test('a valid map yields the profile id', () {
      expect(
        parseShortcutConnectArgs({'profileId': 'p123-0'}),
        'p123-0',
      );
    });

    test('missing, blank, wrong-typed and non-map args yield null', () {
      expect(parseShortcutConnectArgs({}), isNull);
      expect(parseShortcutConnectArgs({'profileId': ''}), isNull);
      expect(parseShortcutConnectArgs({'profileId': 42}), isNull);
      expect(parseShortcutConnectArgs('p123-0'), isNull);
      expect(parseShortcutConnectArgs(null), isNull);
    });
  });

  group('Shortcut channel contract (build 2093)', () {
    final calls = <MethodCall>[];

    setUp(() {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
            calls.add(call);
            return null;
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, null);
    });

    test('enabled publishes the targets', () async {
      final ok = await LauncherShortcuts.sync(
        enabled: true,
        targets: const [
          ShortcutTarget(id: 'a', name: 'Alpha'),
          ShortcutTarget(id: 'b', name: 'Beta'),
        ],
      );
      expect(ok, isTrue);
      expect(calls, hasLength(1));
      expect(calls.single.method, 'publishShortcuts');
      expect(calls.single.arguments, {
        'shortcuts': [
          {'id': 'a', 'name': 'Alpha'},
          {'id': 'b', 'name': 'Beta'},
        ],
      });
    });

    test('disabled clears every shortcut', () async {
      final ok = await LauncherShortcuts.sync(enabled: false, targets: []);
      expect(ok, isTrue);
      expect(calls, hasLength(1));
      expect(calls.single.method, 'clearShortcuts');
    });

    test('a refused channel answers false, never throws', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (_) async {
            throw PlatformException(code: 'no-activity');
          });
      final ok = await LauncherShortcuts.sync(enabled: true, targets: []);
      expect(ok, isFalse);
    });
  });

  group('Shortcut setting (build 2093)', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('shortcuts_'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('off by default (build 2114), and the choice round-trips', () async {
      final s = await AppSettings.load(dir.path);
      // Build 2114 (defaults reset): launcher shortcuts are
      // an Ember extra — default OFF.
      expect(s.launcherShortcutsEnabled, isFalse);
      s.update(launcherShortcutsEnabled: true);
      final file = File('${dir.path}/app-settings.json');
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      var landed = false;
      while (!landed && DateTime.now().isBefore(deadline)) {
        try {
          if (await file.exists() &&
              (await file.readAsString()).contains(
                'launcher_shortcuts',
              )) {
            landed = true;
          }
        } catch (_) {}
        if (!landed) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
      expect(landed, isTrue, reason: 'settings file never landed');
      final reloaded = await AppSettings.load(dir.path);
      expect(reloaded.launcherShortcutsEnabled, isTrue);
    });
  });

  group('Controller republish (build 2093)', () {
    final calls = <MethodCall>[];

    setUp(() {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
            calls.add(call);
            return null;
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, null);
    });

    Future<void> waitForCall({int count = 1}) async {
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (calls.length < count && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }

    test('sync publishes the starred profiles, in order', () async {
      final c = XrayController();
      c.profiles = [
        vless('a', 'a.example.com', starred: true),
        vless('b', 'b.example.com'),
        vless('c', 'c.example.com', starred: true),
      ];
      await c.syncLauncherShortcuts();
      expect(calls, hasLength(1));
      expect(calls.single.method, 'publishShortcuts');
      expect(calls.single.arguments, {
        'shortcuts': [
          {'id': 'a', 'name': 'a'},
          {'id': 'c', 'name': 'c'},
        ],
      });
    });

    test('sync clears when the switch is off', () async {
      final c = XrayController();
      c.launcherShortcutsEnabled = () => false;
      c.profiles = [vless('a', 'a.example.com', starred: true)];
      await c.syncLauncherShortcuts();
      expect(calls, hasLength(1));
      expect(calls.single.method, 'clearShortcuts');
    });

    test('starring republishes without awaiting the platform', () async {
      final c = XrayController();
      final a = vless('a', 'a.example.com');
      c.profiles = [a];
      await c.toggleStarred(a);
      await waitForCall();
      expect(calls, hasLength(1));
      expect(calls.single.method, 'publishShortcuts');
      expect(calls.single.arguments, {
        'shortcuts': [
          {'id': 'a', 'name': 'a'},
        ],
      });
    });

    test('deleting a starred profile republishes the remainder', () async {
      final c = XrayController();
      final a = vless('a', 'a.example.com', starred: true);
      final b = vless('b', 'b.example.com', starred: true);
      c.profiles = [a, b];
      await c.deleteProfile(a);
      await waitForCall();
      expect(calls, hasLength(1));
      expect(calls.single.arguments, {
        'shortcuts': [
          {'id': 'b', 'name': 'b'},
        ],
      });
    });

    test('renaming republishes the new label', () async {
      final c = XrayController();
      final a = vless('a', 'a.example.com', starred: true);
      c.profiles = [a];
      await c.updateProfile(
        vless('a', 'a.example.com', starred: true)..localName = 'Home node',
      );
      await waitForCall();
      expect(calls, hasLength(1));
      expect(calls.single.arguments, {
        'shortcuts': [
          {'id': 'a', 'name': 'Home node'},
        ],
      });
    });
  });
}
