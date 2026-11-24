// Build 2131 — the Lantern picker / pinning hotfix.
//
// Build 2130 fixed the classloader crash; on the owner's
// device the VIP then registered and Lantern connected, but
// (1) the server picker never showed his private server,
// (2) picker rows were disabled while connected, so no
// server could be chosen mid-session, and (3) a tunnel
// restart silently dropped the pin and landed on the free
// public pool. All three were Ember-side:
//
//  F1  LanternEngine.servers() dropped every entry with
//      isLantern=false — exactly how the core stores a
//      private server (radiance Manager.AddPrivateServer).
//      The filter is gone, isLantern is emitted per entry,
//      and the picker marks private rows.
//  F2  ACTION_START returned early while running, dropping
//      a new tag. A dedicated ACTION_SWITCH re-runs the
//      bridge connect on the live tunnel (the core switches
//      via SelectServer, no TUN rebuild); picker rows and
//      the Smart/Private buttons stay live while running.
//  F3  restartService() always restarted automatic; it now
//      re-pins through the remembered lastTag.
//  F4  applySelectedServer() trusted the core's
//      SelectedServer JSON, which prefers the auto-selected
//      server; in a pinned session the exit identity is now
//      resolved from the full server list by sessionTag.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String read(String rel) => File(rel).readAsStringSync();

void main() {
  final bridgeJava = read(
    'android/lantern-plugin-src/com/ralysnd/ember/lanternplugin/'
    'LanternEngine.java',
  );
  final kt = read(
    'android/app/src/main/kotlin/com/ralysnd/ember/LanternVpnService.kt',
  );
  final mainActivity = read(
    'android/app/src/main/kotlin/com/ralysnd/ember/MainActivity.kt',
  );
  final platform = read('lib/lantern/lantern_platform.dart');
  final controller = read('lib/lantern/lantern_controller.dart');
  final pages = read('lib/ui/ember/lantern_pages.dart');
  final pubspec = read('pubspec.yaml');

  group('F1 — the picker list carries private servers', () {
    test('servers() no longer filters isLantern entries out', () {
      expect(
        bridgeJava.contains('!entry.optBoolean("isLantern", false)'),
        isFalse,
        reason: 'the 2129–2130 filter dropped private servers',
      );
    });

    test('servers() emits isLantern per entry', () {
      expect(
        bridgeJava,
        contains('.put("isLantern", entry.optBoolean("isLantern", false))'),
      );
    });

    test('Dart LanternServer carries isLantern, defaulting true '
        'for old payloads', () {
      expect(platform, contains('final bool isLantern;'));
      expect(platform, contains("isLantern: m['isLantern'] != false"));
    });

    test('private rows are marked in the picker caption', () {
      // PIN UPDATED by build 2147 (#24 sweep): the private
      // mark is the sample's micro-label caption now.
      expect(pages, contains("'PRIVATE SERVER'"));
      expect(pages, contains('server.isLantern'));
    });
  });

  group('F2 — live server switching', () {
    test('the service handles ACTION_SWITCH on the worker', () {
      expect(
        kt,
        contains('const val ACTION_SWITCH = '
            '"com.ralysnd.ember.LANTERN_SWITCH"'),
      );
      expect(kt, contains('ACTION_SWITCH ->'));
      expect(kt, contains('sessionTag = newTag'));
      expect(kt, contains('bridge.connect(newTag)'));
    });

    test('the switch is ignored when no session runs', () {
      final at = kt.indexOf('ACTION_SWITCH ->');
      expect(at, greaterThanOrEqualTo(0));
      final branch = kt.substring(at, at + 800);
      expect(branch, contains('if (!LanternStateStore.running)'));
    });

    test('a companion switchServer helper sends the intent', () {
      expect(kt, contains('fun switchServer(context: Context, tag: String)'));
    });

    test('MainActivity routes lanternSwitch to the service', () {
      expect(mainActivity, contains('"lanternSwitch" ->'));
      expect(mainActivity, contains('LanternVpnService.switchServer('));
    });

    test('the Dart platform + controller expose the switch', () {
      expect(platform, contains("invokeMethod<void>('lanternSwitch'"));
      expect(controller, contains('Future<void> liveSwitch(String tag)'));
      expect(controller, contains('LanternPlatform.switchServer(tag)'));
      expect(
        controller,
        contains('Future<bool> registerPrivateForSwitch()'),
      );
    });

    test('picker rows are NOT gated on state.running anymore', () {
      expect(pages.contains('onTap: state.running'), isFalse);
      expect(pages, contains("await lantern.liveSwitch('')"));
      expect(pages, contains('await lantern.liveSwitch(server.tag)'));
      expect(pages, contains('await lantern.liveSwitch(lantern.privateTag)'));
    });

    test('the picker copy says the switch is live', () {
      expect(pages, contains('the switch happens right away'));
      expect(pages, contains('applies at the next'));
    });
  });

  group('F3 — a tunnel restart keeps the pin', () {
    test('connect() remembers the tag', () {
      expect(bridgeJava, contains('private volatile String lastTag = "";'));
      expect(
        bridgeJava,
        contains('this.lastTag = tag == null ? "" : tag;'),
      );
    });

    test('restartService re-pins instead of going automatic', () {
      final at = bridgeJava.indexOf('public void restartService()');
      expect(at, greaterThanOrEqualTo(0));
      final body = bridgeJava.substring(at, at + 500);
      expect(body, contains('Mobile.connectToServer(this.lastTag)'));
      expect(body, contains('if (this.lastTag.isEmpty())'));
    });
  });

  group('F4 — honest exit identity while pinned', () {
    test('applySelectedServer resolves from the full list '
        'when a session tag is pinned', () {
      final at = kt.indexOf('private fun applySelectedServer()');
      expect(at, greaterThanOrEqualTo(0));
      final body = kt.substring(at, at + 2600);
      expect(body, contains('val pinned = sessionTag'));
      expect(body, contains('bridge.servers()'));
      expect(body, contains('LanternStateStore.selectedTag = pinned'));
    });
  });

  test('pubspec is build 2131', () {
    expect(pubspec, contains('version: 2.2.0+2147'));
  });
}
