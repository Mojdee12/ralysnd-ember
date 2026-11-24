/// Build 2085 gates, host side: audit remainders F-H15 (the
/// VIEW/SEND intent filter for .ovpn) and the F-M15 deviation
/// closure (the fingerprint/pin split, closed in substance).
///
/// F-H15: "Open with Ember" from Files/Telegram — the manifest
/// filters, the MainActivity intake, the Dart-side stream, and
/// the shared import path. The release build is deferred this
/// run (free RAM below the 1000 MB floor — see the LOG entry);
/// the next run must still verify the filters land in the
/// packaged manifest (aapt2 dump xmltree) and that Kotlin
/// compiles, before the build ships.
/// F-M15: the literal `hyPinSha256` field was never built; the
/// split lives in `fingerprint` (uTLS name) vs `tlsCertPin` (the
/// pin, all protocols) since 2053/2057, with the audit's named
/// gate test (editor save refusal) in build2057_batch13_test.
/// This file pins the model contract that makes a second pin
/// field a duplicate: the two fields round-trip independently,
/// and a pin in tlsCertPin survives a protocol switch, so no
/// Hy2 pin can land in a TLS fingerprint and hard-fail the core.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/net/network_info.dart';
import 'package:firefox_vpn/ui/ember/openvpn_pages.dart';
import 'package:firefox_vpn/xray/config_builder.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

String _read(String path) => File(path).readAsStringSync();
String _manifest() => _read('android/app/src/main/AndroidManifest.xml');
String _kt(String name) =>
    _read('android/app/src/main/kotlin/com/ralysnd/ember/$name');

const _pin64 =
    'aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899';

Profile _base(Protocol protocol) => Profile(
      id: 't1',
      protocol: protocol,
      name: 'Test',
      address: 'example.com',
      port: 8443,
      uuidOrPassword: '11111111-1111-1111-1111-111111111111',
    );

Future<void> _sendOpenVpnFile(Map<String, dynamic> args) async {
  final data = const StandardMethodCodec()
      .encodeMethodCall(MethodCall('openOvpnFile', args));
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage('app/android', data, (_) {});
}

void main() {
  group('F-H15 intent intake (Dart side)', () {
    test('OvpnIntentFile parses name, content and error', () {
      final ok = OvpnIntentFile.fromMap({
        'name': 'work.ovpn',
        'content': 'client\nremote x 1194\n',
      });
      expect(ok.name, 'work.ovpn');
      expect(ok.content, contains('remote x 1194'));
      expect(ok.isError, isFalse);
      expect(ok.error, isNull);

      final err = OvpnIntentFile.fromMap({'error': 'file-too-large'});
      expect(err.isError, isTrue);
      expect(err.name, 'profile.ovpn');
      expect(err.content, isEmpty);
    });

    test('the intake errors render as the picker sentences', () {
      expect(
        ovpnIntakeErrorText('file-too-large'),
        'That file is too large to import (256 KB max)',
      );
      expect(ovpnIntakeErrorText('unreadable'), 'Could not read that file');
      expect(
        ovpnIntakeErrorText('anything-else'),
        'Could not read that file',
      );
    });

    test('openOvpnFile platform calls surface on the stream', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final seen = <OvpnIntentFile>[];
      final sub = NetworkInfoService.openOvpnFiles.listen(seen.add);
      await _sendOpenVpnFile({
        'name': 'work.ovpn',
        'content': 'client\nremote x 1194\n',
      });
      await _sendOpenVpnFile({'error': 'unreadable'});
      // The handler is async; let the posted events land.
      await Future<void>.delayed(Duration.zero);
      expect(seen, hasLength(2));
      expect(seen.first.name, 'work.ovpn');
      expect(seen.first.isError, isFalse);
      expect(seen.last.isError, isTrue);
      expect(seen.last.error, 'unreadable');
      await sub.cancel();
    });

    test('the manifest carries VIEW + SEND filters for .ovpn', () {
      final manifest = _manifest();
      expect(
        manifest,
        contains('<action android:name="android.intent.action.VIEW" />'),
      );
      expect(
        manifest,
        contains('<action android:name="android.intent.action.SEND" />'),
      );
      expect(manifest, contains('android:pathPattern=".*\\\\.ovpn"'));
      expect(
        manifest,
        contains('android:mimeType="application/x-openvpn-profile"'),
      );
      expect(
        manifest,
        contains('android:mimeType="application/octet-stream"'),
      );
    });

    test('MainActivity forwards VIEW/SEND .ovpn intents to Dart', () {
      final kt = _kt('MainActivity.kt');
      expect(kt, contains('extractOvpnIntent'));
      expect(kt, contains('Intent.ACTION_VIEW'));
      expect(kt, contains('Intent.ACTION_SEND'));
      expect(kt, contains('Intent.EXTRA_STREAM'));
      expect(kt, contains('Intent.EXTRA_TEXT'));
      // The intake reuses the picker's reader (256 KB cap),
      // and forwards the same {name, content} shape.
      expect(kt, contains('readPickedProfile(uri)'));
      expect(kt, contains('invokeMethod("openOvpnFile"'));
      expect(kt, contains('pendingOvpnFile'));
    });
  });

  group('F-M15 field split (model contract)', () {
    test('fingerprint and tlsCertPin round-trip independently', () {
      final p = _base(Protocol.hysteria2)
        ..security = 'tls'
        ..fingerprint = 'chrome'
        ..tlsCertPin = _pin64;
      final back = Profile.fromJson(p.toJson());
      expect(back.fingerprint, 'chrome');
      expect(back.tlsCertPin, _pin64);
      // The split is the fix: the pin never needs the
      // fingerprint field, in either direction.
      final tls = _base(Protocol.vless)
        ..security = 'tls'
        ..fingerprint = 'chrome'
        ..tlsCertPin = _pin64;
      final tlsBack = Profile.fromJson(tls.toJson());
      expect(tlsBack.fingerprint, 'chrome');
      expect(tlsBack.tlsCertPin, _pin64);
    });

    test('a pin in tlsCertPin survives a protocol switch', () {
      // The audit's failure was a Hy2 pin carried into a TLS
      // fingerprint on protocol switch; with the pin in its own
      // field the switch changes nothing about it, and the
      // builder emits the uTLS name and the pin side by side.
      final p = _base(Protocol.hysteria2)..tlsCertPin = _pin64;
      final switched = Profile.fromJson(p.toJson())
        ..protocol = Protocol.vless
        ..security = 'tls'
        ..fingerprint = 'chrome';
      expect(switched.tlsCertPin, _pin64);
      final out = buildOutbound(switched, XraySettings());
      final tls = (out!['streamSettings'] as Map)['tlsSettings'] as Map;
      expect(tls['fingerprint'], 'chrome');
      expect(tls['pinnedPeerCertSha256'], _pin64);
    });
  });
}
