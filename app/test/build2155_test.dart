/// Build 2155 — the 2153 bridge swap, shipped under the
/// 2155 number (Android refuses versionCode 2153 over the
/// owner's installed 2154).
///
/// The V2Ray path's TUN → SOCKS bridge changes from the
/// tunlink subprocess (xjasonlyu/tun2socks, gVisor — TCP
/// terminated in a userspace stack; the 2151 profile fix
/// on that bridge was device-verdict NEGATIVE) to
/// hev-socks5-tunnel (heiher, C + lwIP, in-process via
/// JNI — packets forwarded, TCP not terminated in gVisor),
/// the v2rayNG TProxyService pattern. The legacy bridge
/// stays in the APK behind the Settings 'Tunnel bridge'
/// choice for on-device A/B.
///
/// These tests pin the wiring: the settings field and its
/// 'hev' default, the Dart → platform → MainActivity →
/// service plumbing, the service's hev branch + stop/watch
/// wiring, the legacy path's survival, and the shipped
/// .so's presence. The behavioural proof is the owner's
/// device acceptance; nothing here claims the bridge
/// carries traffic.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/xray/xray_models.dart';

String dartSrc(String rel) => File('lib/$rel').readAsStringSync();
String kotlinSrc(String rel) =>
    File('android/app/src/main/kotlin/com/ralysnd/ember/$rel')
        .readAsStringSync();
String javaSrc(String rel) =>
    File('android/app/src/main/java/$rel').readAsStringSync();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('build 2155 — the bridge setting', () {
    test('defaults to hev', () {
      expect(XraySettings().v2rayBridge, 'hev');
    });

    test('round-trips through toJson/fromJson', () {
      final legacy = XraySettings()..v2rayBridge = 'tunlink';
      expect(legacy.toJson()['v2rayBridge'], 'tunlink');
      expect(
        XraySettings.fromJson(legacy.toJson()).v2rayBridge,
        'tunlink',
      );
      final hev = XraySettings();
      expect(hev.toJson()['v2rayBridge'], 'hev');
      expect(XraySettings.fromJson(hev.toJson()).v2rayBridge, 'hev');
    });

    test('an absent key keeps the hev default', () {
      final j = XraySettings().toJson()..remove('v2rayBridge');
      expect(XraySettings.fromJson(j).v2rayBridge, 'hev');
    });

    test('a wrong-typed stored value keeps the hev default', () {
      final j = XraySettings().toJson();
      j['v2rayBridge'] = 42;
      expect(XraySettings.fromJson(j).v2rayBridge, 'hev');
    });
  });

  group('build 2155 — the plumbing', () {
    test('the controller passes the settings choice at connect', () {
      final controller = dartSrc('xray/xray_controller.dart');
      expect(controller, contains('bridge: settings.v2rayBridge'));
    });

    test('the platform channel carries the bridge argument', () {
      final platform = dartSrc('xray/xray_platform.dart');
      expect(platform, contains("String bridge = 'hev'"));
      expect(platform, contains("'bridge': bridge"));
    });

    test('MainActivity forwards the bridge argument', () {
      final main = kotlinSrc('MainActivity.kt');
      expect(main, contains('call.argument<String>("bridge") ?: "hev"'));
    });

    test('the Settings page offers the Tunnel bridge chips', () {
      final settings = dartSrc('ui/ember/ember_settings.dart');
      expect(settings, contains("label: 'Tunnel bridge'"));
      expect(settings, contains("label: 'Hev'"));
      expect(settings, contains("label: 'Legacy tunlink'"));
      expect(settings, contains("s.v2rayBridge = 'tunlink'"));
      expect(settings, contains("s.v2rayBridge = 'hev'"));
    });
  });

  group('build 2155 — the service wiring', () {
    final service = kotlinSrc('XrayVpnService.kt');

    test('the bridge rides its own intent extra', () {
      expect(service, contains('EXTRA_BRIDGE = "bridge"'));
      expect(service, contains('putExtra(EXTRA_BRIDGE, bridge)'));
      expect(
        service,
        contains('intent.getStringExtra(EXTRA_BRIDGE) ?: "hev"'),
      );
    });

    test('startTunnel retains the bridge as a session arg', () {
      expect(service, contains('bridge: String = "hev"'));
      expect(service, contains('sessionBridge = bridge'));
      // Resume restarts on the retained bridge.
      expect(service, contains('sessionOlcrtcArgs, sessionBridge'));
    });

    test('the hev branch starts the in-process bridge', () {
      expect(service, contains('if (bridge == "hev")'));
      expect(service, contains('HevTunManager.start(hevConfig, pfd)'));
      expect(service, contains('hevConfigYaml('));
      // UDP rides SOCKS5 UDP ASSOCIATE ('udp' mode).
      expect(service, contains('udp: \'udp\''));
      // The Builder's IPv6 address is hev's too, flag-gated.
      expect(service, contains("ipv6: 'fdfe:dcba:9876::1'"));
    });

    test('the legacy branch survives verbatim', () {
      expect(service, contains('libPath("libtunlink.so")'));
      expect(service, contains('"-socket", socketFile.absolutePath'));
      expect(service, contains('setFileDescriptorsForSend'));
    });

    test('stop funnels through the hev stop', () {
      expect(
        service,
        contains('if (HevTunManager.isRunning) HevTunManager.stop()'),
      );
    });

    test('the watch loop proves a hev session by the bridge flag', () {
      expect(service, contains('sessionBridge == "hev"'));
      expect(service, contains('!HevTunManager.isRunning'));
      expect(service, contains('"the tunnel bridge stopped"'));
    });
  });

  group('build 2155 — the native side', () {
    test('the JNI holder matches the vendored registration', () {
      final holder = javaSrc('hev/htproxy/TProxyService.java');
      expect(holder, contains('package hev.htproxy;'));
      expect(holder, contains('System.loadLibrary("hevbridge")'));
      expect(
        holder,
        contains(
          'native boolean TProxyStartService(String configPath, int fd)',
        ),
      );
      expect(holder, contains('native boolean TProxyStopService()'));
      expect(holder, contains('native boolean TProxyIsRunning()'));
      expect(holder, contains('native long[] TProxyGetStats()'));
    });

    test('the manager dups the fd and stops synchronously', () {
      final manager = kotlinSrc('HevTunManager.kt');
      expect(manager, contains('tunFd.dup()'));
      expect(manager, contains('TProxyService.TProxyStartService'));
      expect(manager, contains('TProxyService.TProxyStopService()'));
      expect(manager, contains('TProxyService.TProxyIsRunning()'));
    });

    test('libhevbridge.so ships in jniLibs (arm64)', () {
      final so = File(
        'android/app/src/main/jniLibs/arm64-v8a/libhevbridge.so',
      );
      expect(so.existsSync(), isTrue);
      // The 2.17.1 NDK build of record: 321,184 B.
      expect(so.lengthSync(), 321184);
    });

    test('jniLibs does not shadow the wgtunnel hev library', () {
      // com.wgtunnel:backend-android-jni ships its own
      // libhev-socks5-tunnel.so (for com.wgtunnel.hevtunnel,
      // the WireGuard engine's data path). Shipping ours under
      // that name would replace it in the APK and break the
      // WireGuard engine — ours ships as libhevbridge.so.
      final shadow = File(
        'android/app/src/main/jniLibs/arm64-v8a/libhev-socks5-tunnel.so',
      );
      expect(shadow.existsSync(), isFalse);
    });

    test('the legacy bridge library still ships', () {
      final so = File(
        'android/app/src/main/jniLibs/arm64-v8a/libtunlink.so',
      );
      expect(so.existsSync(), isTrue);
    });
  });

  group('build 2155 — version', () {
    test('pubspec carries 2155', () {
      expect(
        File('pubspec.yaml').readAsStringSync(),
        contains('version: 2.2.0+2156'),
      );
    });
  });
}
