// Build 2129, leg 1 — the Lantern gomobile swap.
//
// The radiance CLI daemon (liblantern.so, driven by
// ProcessBuilder + a stdout contract + a tunlink fd handoff)
// is replaced wholesale by the official Lantern client's
// gomobile library (liblantern_gojni.so — the official
// v10.0.5-beta.1 APK's libgojni.so, byte-identical, renamed;
// trust gate in build2129-phase0.md), driven in-process in
// the :lantern process through the official Java bindings in
// a plugin dex and Ember's own libbox PlatformInterface
// bridge. Server selection (getAvailableServers /
// connectToServer), true private-server pinning
// (addServerManagerInstance), and the real smart-routing API
// all come from that surface.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:firefox_vpn/lantern/lantern_platform.dart';

String ktSrc(String rel) =>
    File('android/app/src/main/kotlin/com/ralysnd/ember/$rel')
        .readAsStringSync();

String dartSrc(String rel) => File('lib/$rel').readAsStringSync();

void main() {
  final kt = ktSrc('LanternVpnService.kt');
  final mainActivity = ktSrc('MainActivity.kt');
  final manifest = File(
    'android/app/src/main/AndroidManifest.xml',
  ).readAsStringSync();
  final gradle = File('android/app/build.gradle.kts').readAsStringSync();
  final platform = dartSrc('lantern/lantern_platform.dart');
  final controller = dartSrc('lantern/lantern_controller.dart');
  final privateDart = dartSrc('lantern/lantern_private.dart');
  final pages = dartSrc('ui/ember/lantern_pages.dart');
  final bridge = File(
    'android/lantern-plugin-src/com/ralysnd/ember/lanternplugin/LanternEngine.java',
  ).readAsStringSync();

  group('packaging — the renamed gomobile lib in, the CLI daemon out', () {
    test('liblantern_gojni.so is packaged, liblantern.so is gone', () {
      final dir = Directory('android/app/src/main/jniLibs/arm64-v8a');
      expect(
        File('${dir.path}/liblantern_gojni.so').existsSync(),
        isTrue,
        reason: 'the renamed official gomobile library must ship',
      );
      expect(
        File('${dir.path}/liblantern.so').existsSync(),
        isFalse,
        reason: 'the radiance CLI daemon leaves the APK in 2129',
      );
      // The gomobile lib's DT_NEEDED names libc++_shared.so.
      expect(File('${dir.path}/libc++_shared.so').existsSync(), isTrue);
    });

    test('the gomobile lib ships byte-exact (no strip)', () {
      expect(gradle.contains('keepDebugSymbols += "**/liblantern_gojni.so"'), isTrue);
      expect(gradle.contains('keepDebugSymbols += "**/libc++_shared.so"'), isTrue);
    });

    test('the plugin dexes are packaged as assets', () {
      expect(
        File('android/app/src/main/assets/lantern-plugin.dex').existsSync(),
        isTrue,
      );
      expect(
        File('android/app/src/main/assets/lantern-bridge.dex').existsSync(),
        isTrue,
      );
    });

    test('the service runs in its own :lantern process', () {
      final at = manifest.indexOf('.LanternVpnService');
      expect(at, greaterThanOrEqualTo(0));
      final region = manifest.substring(at, at + 200);
      expect(region.contains('android:process=":lantern"'), isTrue);
    });
  });

  group('the service is no longer a subprocess driver', () {
    test('no ProcessBuilder, no liblantern.so, no CLI contract', () {
      expect(kt.contains('ProcessBuilder('), isFalse);
      expect(kt.contains('"liblantern.so"'), isFalse);
      expect(kt.contains('object LanternCore'), isFalse);
      expect(kt.contains('fun carriesWarm'), isFalse);
      expect(kt.contains('fun forceSmartRoutingOff'), isFalse);
      expect(kt.contains('"settings.json"'), isFalse);
      expect(kt.contains('libtunlink.so'), isFalse);
      expect(kt.contains('fun sendVia'), isFalse);
    });

    test('the plugin dex loads child-first for the binding packages', () {
      expect(kt.contains('DexClassLoader'), isTrue);
      expect(kt.contains('"lantern-plugin.dex"'), isTrue);
      expect(kt.contains('"lantern-bridge.dex"'), isTrue);
      expect(kt.contains('name.startsWith("go.")'), isTrue);
      expect(kt.contains('name.startsWith("lantern.io.")'), isTrue);
      expect(
        kt.contains('com.ralysnd.ember.lanternplugin.LanternEngine'),
        isTrue,
      );
    });

    test('state crosses processes through the published snapshot', () {
      expect(kt.contains('lantern_state.json'), isTrue);
      expect(kt.contains('publishedState'), isTrue);
      expect(mainActivity.contains('LanternStateStore.publishedState'), isTrue);
    });

    test('the dead CLI channels are out of MainActivity', () {
      expect(mainActivity.contains('lanternVia'), isFalse);
      expect(mainActivity.contains('lanternFetchList'), isFalse);
      expect(mainActivity.contains('lanternRotateList'), isFalse);
      expect(mainActivity.contains('lanternFetchServers'), isTrue);
      expect(mainActivity.contains('lanternAddPrivateServer'), isTrue);
      expect(mainActivity.contains('lanternSetSmartRouting'), isTrue);
    });
  });

  group('the bridge — init, TUN, per-app, API wiring', () {
    test('init copies the LML Opts faithfully', () {
      expect(bridge.contains('opts.setAppVersion("10.0.5-beta.1")'), isTrue);
      expect(bridge.contains('opts.setEnv("prod")'), isTrue);
      expect(bridge.contains('opts.setTelemetryConsent(false)'), isTrue);
      expect(bridge.contains('Mobile.startIPCServer(this, opts)'), isTrue);
      expect(bridge.contains('Mobile.setupRadiance(opts, this)'), isTrue);
      expect(bridge.contains('Mobile.isRadianceConnected()'), isTrue);
      // dataDir is the gomobile layout: filesDir/lantern.
      expect(bridge.contains('new File(this.service.getFilesDir(), "lantern")'), isTrue);
    });

    test('smart routing and core split tunneling are forced off at init', () {
      final initAt = bridge.indexOf('public void initialize()');
      final smartAt = bridge.indexOf('Mobile.setSmartRoutingEnabled(false)');
      final splitAt = bridge.indexOf('Mobile.setSplitTunnelingEnabled(false)');
      expect(smartAt, greaterThan(initAt));
      expect(splitAt, greaterThan(initAt));
    });

    test('openTun carries Ember\'s Builder values and per-app logic', () {
      expect(bridge.contains('addAddress("10.10.16.1", 30)'), isTrue);
      expect(bridge.contains('addAddress("fdfe:dcba:9876::1", 126)'), isTrue);
      // The applyApps logic reads the same "vpn" preferences
      // CoreService writes (app_mode / bypass_apps / only_apps).
      expect(bridge.contains('getSharedPreferences(\n                "vpn"'), isTrue);
      expect(bridge.contains('"app_mode"'), isTrue);
      expect(bridge.contains('"only_apps"'), isTrue);
      expect(bridge.contains('"bypass_apps"'), isTrue);
      expect(bridge.contains('addAllowedApplication'), isTrue);
      expect(bridge.contains('addDisallowedApplication'), isTrue);
    });

    test('connect: empty tag is automatic, a tag pins', () {
      expect(bridge.contains('Mobile.startVPN()'), isTrue);
      expect(bridge.contains('Mobile.connectToServer(str)'), isFalse);
      expect(bridge.contains('Mobile.connectToServer(tag)'), isTrue);
    });

    test('addServerManagerInstance argument order: ip, port, token, tag', () {
      // The gomobile order (delta §1.7) — all strings, the
      // port included. The call site in the bridge:
      expect(
        bridge.contains(
          'Mobile.addServerManagerInstance(ip, port, accessToken, tag,',
        ),
        isTrue,
      );
      // And the Kotlin side hands the port as a string of the
      // parsed int.
      expect(kt.contains('port.toString()'), isTrue);
      expect(kt.contains('"error|Your server could not be added: "'), isTrue);
    });

    test('the kill-switch TUN duplicate survives in the bridge', () {
      expect(bridge.contains('dupTunFd'), isTrue);
      expect(kt.contains('bridge.dupTunFd()'), isTrue);
      expect(kt.contains('killSwitchHeld = true'), isTrue);
    });
  });

  group('private server — the API replaces the H8 merge', () {
    test('no servers.json merge remains in lantern_private.dart', () {
      expect(privateDart.contains('servers.json'), isFalse);
      expect(privateDart.contains('registerLanternPrivateServer'), isFalse);
      expect(privateDart.contains('fetchLanternPrivateOutbound'), isFalse);
      expect(privateDart.contains('restoreLanternServersBackup'), isFalse);
      expect(privateDart.contains('connect-config'), isFalse);
    });

    test('the tag rule stays: name, else alias, else ip', () {
      expect(privateDart.contains('lanternPrivateTag'), isTrue);
      expect(controller.contains('LanternPlatform.addPrivateServer('), isTrue);
      expect(controller.contains('LanternPlatform.removePrivateServer('), isTrue);
    });

    test('private mode connects pinned to the private tag', () {
      expect(
        controller.contains('tag = lanternPrivateTag('),
        isTrue,
      );
    });
  });

  group('Dart/UI — picker, defaults, paste intake', () {
    test('picker default is automatic (empty tag)', () {
      expect(controller.contains("String selectedTag = '';"), isTrue);
      expect(
        controller.contains("selectedTag = (doc['selectedTag'] as String?) ?? '';"),
        isTrue,
      );
      expect(pages.contains("label: 'Automatic'"), isTrue);
      expect(pages.contains('lantern.setSelectedTag(server.tag)'), isTrue);
    });

    test('smart routing defaults OFF and is a real toggle', () {
      expect(controller.contains('bool smartRouting = false;'), isTrue);
      expect(controller.contains('LanternPlatform.setSmartRouting(on)'), isTrue);
      expect(pages.contains("'Smart routing'"), isTrue);
      expect(pages.contains('lantern.smartRouting'), isTrue);
      expect(platform.contains("'lanternSetSmartRouting'"), isTrue);
    });

    test('the server list parses from the bridge JSON', () {
      final servers = parseLanternServers(
        '[{"tag":"a","city":"Berlin","country":"Germany","countryCode":"DE"},'
        '{"tag":"","city":"x"},{"tag":"b"}]',
      );
      expect(servers.length, 2);
      expect(servers.first.label, 'Germany · Berlin');
      expect(servers.last.tag, 'b');
      expect(parseLanternServers('not json'), isEmpty);
      expect(parseLanternServers('[]'), isEmpty);
    });

    test('a lantern:// key on the Lantern page reaches the private path', () {
      // The page's intake is the Lantern key sheet, which
      // stores the key on the Lantern controller and turns
      // Private mode on — never the V2Ray paste sheet.
      expect(pages.contains('showLanternKeySheet'), isTrue);
      expect(pages.contains('findLanternPrivateServerLink(controller.text)'), isTrue);
      expect(pages.contains('lantern.setPrivateKey(controller.text.trim())'), isTrue);
      expect(pages.contains('lantern.setPrivateMode(true)'), isTrue);
      expect(pages.contains('showPasteSheet'), isFalse);
    });

    test('connected display comes from the core verdict only', () {
      // LanternState.connected is a published field; the
      // controller's wait returns on it, and the platform
      // never derives it from running/stage.
      expect(controller.contains('if (_state.connected) return;'), isTrue);
      expect(platform.contains("connected: m['connected'] == true"), isTrue);
    });

    test('the dead Dart code is gone', () {
      expect(controller.contains('viaWarpLeg'), isFalse);
      expect(controller.contains('LanternPlatform.via'), isFalse);
      expect(controller.contains('fetchList'), isFalse);
      expect(controller.contains('rotateList'), isFalse);
      expect(platform.contains('socksPort'), isFalse);
      expect(pages.contains('Local proxies'), isFalse);
    });
  });
}
