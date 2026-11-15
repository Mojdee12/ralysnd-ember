// Build 2069 — the TRANSPLANT build: ralysnd's complete
// Psiphon stack replaces Ember's rebuilt core, by the
// owner's direct order («چرا کامل همون هسته ralysnd که کار
// میکنه نمیزاری» — why don't you use ralysnd's working core
// completely).
//
// The evidence chain: 2068's breadcrumbs proved Ember's
// entire start path healthy through openLog, with no crash
// record and no caught throwable — the death is native,
// inside core start, fresh-install only. The host-diff
// (psiphon-fresh-install-diff.md) then cleared every
// host-side difference: both hosts drive the identical
// upstream wrapper sequence into the same Go start sequence.
// The one unshared component in the dying setup was Ember's
// rebuilt v2.0.42 + fork-patch libpsiphoncore.so (build
// 2065). So 2069 changes the variable:
//
//  1. TRANSPLANT: libs/psiphon.aar is now ralysnd's own
//     psiphontunnel-2.0.39-ns-recovered.aar, byte-exact
//     (sha256 426c0fda…): the stock tunnel-core v2.0.39
//     wrapper (44 classes: ca.psiphon + pg + psi) and
//     libpgjni.so (sha256 4f625112…, verified byte-identical
//     to the lib inside ralysnd's shipped APK, whose dex
//     carries the identical wrapper class set). Ember's
//     rebuilt AAR is preserved at
//     ~/workspace/ember-app/psiphon/psiphon-aar-2065.aar.
//     libpsiphoncore.so no longer exists in the package.
//  2. HOST ADAPTATION: the v2.0.39 HostService interface is
//     Ember's old one minus onAccessToken (v2.0.42-only,
//     never used) — every callback Ember overrides exists
//     unchanged. The one real adaptation: loadLibrary is
//     NOT overridden any more. Ralysnd has no override; the
//     renamed wrapper's default loads "pgjni" itself. The
//     old override forced "psiphoncore" and is gone.
//  3. CONFIG PARITY: the host emits only fields the stock
//     binary contains. Gone: AggressiveEstablishment (Beast
//     — toggle, setting, channel key, extra, emission all
//     removed; never a dead toggle), FrontedMeekDialOverrides
//     / FrontedMeekCDNScanSpec / FrontedMeekCDNScanUseBuiltInSpec
//     (0 occurrences in the stock binary), the fork-only
//     FRONTED-MEEK-CDN-* protocol names, and the
//     AdditionalParameters blob (it silently overrode
//     Ember's explicit official server-list URLs with a
//     different channel's). Tested edges now steer the
//     fronted rungs as preresolved provider CIDRs —
//     ralysnd's own clean-IP mechanism. The ladder,
//     fronting, clean-IP, Conduit, pairing and winner memory
//     all survive through standard fields.
//  4. KEPT from the earlier briefs: start-phase synchronous
//     log flushing (a failure between openLog and connected
//     can never again hide behind the 2055 buffer — the
//     2068 empty log was partly that buffer), and
//     startTunnel's catch widened to Throwable, recorded
//     to crash.log before fail(). All 2068 recorder /
//     breadcrumb machinery stands untouched.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/psiphon/psiphon_controller.dart';

String ktSrc(String rel) =>
    File('android/app/src/main/kotlin/com/ralysnd/ember/$rel')
        .readAsStringSync();

String dartSrc(String rel) => File('lib/$rel').readAsStringSync();

/// The source from one marker to the next.
String segmentOf(String source, String from, String to) {
  final start = source.indexOf(from);
  expect(start, isNonNegative, reason: '"$from" exists');
  final end = source.indexOf(to, start);
  expect(end, isNonNegative, reason: '"$to" bounds "$from"');
  return source.substring(start, end);
}

/// All entry names in a zip, from its central directory.
List<String> zipEntryNames(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  var eocd = -1;
  final floor = bytes.length > 65557 ? bytes.length - 65557 : 0;
  for (var i = bytes.length - 22; i >= floor; i--) {
    if (data.getUint32(i, Endian.little) == 0x06054b50) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) return const [];
  final count = data.getUint16(eocd + 10, Endian.little);
  var at = data.getUint32(eocd + 16, Endian.little);
  final names = <String>[];
  for (var n = 0; n < count; n++) {
    if (data.getUint32(at, Endian.little) != 0x02014b50) break;
    final nameLen = data.getUint16(at + 28, Endian.little);
    final extraLen = data.getUint16(at + 30, Endian.little);
    final commentLen = data.getUint16(at + 32, Endian.little);
    names.add(
      String.fromCharCodes(bytes.sublist(at + 46, at + 46 + nameLen)),
    );
    at += 46 + nameLen + extraLen + commentLen;
  }
  return names;
}

/// One zip central-directory entry's fingerprint (uncompressed
/// size + CRC-32), read without inflating anything: the
/// End-Of-Central-Directory record sits at the file's tail and
/// the central directory lists every entry's CRC and sizes in
/// the clear. Enough to pin WHICH binaries the AAR carries.
({int size, int crc})? zipEntryFingerprint(Uint8List bytes, String name) {
  final data = ByteData.sublistView(bytes);
  var eocd = -1;
  final floor = bytes.length > 65557 ? bytes.length - 65557 : 0;
  for (var i = bytes.length - 22; i >= floor; i--) {
    if (data.getUint32(i, Endian.little) == 0x06054b50) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) return null;
  final count = data.getUint16(eocd + 10, Endian.little);
  var at = data.getUint32(eocd + 16, Endian.little);
  for (var n = 0; n < count; n++) {
    if (data.getUint32(at, Endian.little) != 0x02014b50) return null;
    final crc = data.getUint32(at + 16, Endian.little);
    final size = data.getUint32(at + 24, Endian.little);
    final nameLen = data.getUint16(at + 28, Endian.little);
    final extraLen = data.getUint16(at + 30, Endian.little);
    final commentLen = data.getUint16(at + 32, Endian.little);
    final entryName =
        String.fromCharCodes(bytes.sublist(at + 46, at + 46 + nameLen));
    if (entryName == name) return (size: size, crc: crc);
    at += 46 + nameLen + extraLen + commentLen;
  }
  return null;
}

void main() {
  final service = ktSrc('PsiphonVpnService.kt');
  final constants = ktSrc('PsiphonConstants.kt');
  final mainActivity = ktSrc('MainActivity.kt');
  final controller = dartSrc('psiphon/psiphon_controller.dart');
  final platform = dartSrc('psiphon/psiphon_platform.dart');
  final pages = dartSrc('ui/ember/psiphon_pages.dart');

  group('the transplant: the AAR is ralysnd\u2019s complete stack',
      () {
    test('libpgjni.so in psiphon.aar is ralysnd\u2019s binary '
        '(size + CRC-32 fingerprint), and no libpsiphoncore '
        'exists in it', () {
      final aar = File('android/app/libs/psiphon.aar');
      expect(aar.existsSync(), isTrue);
      final bytes = aar.readAsBytesSync();
      final names = zipEntryNames(bytes);
      // ralysnd's shipped core: 31,185,552 B, sha256
      // 4f625112…, CRC-32 0xf34ffa72 — byte-identical to the
      // lib inside ralysnd-1.2.45.apk.
      final core =
          zipEntryFingerprint(bytes, 'jni/arm64-v8a/libpgjni.so');
      expect(core, isNotNull, reason: 'the AAR carries pgjni');
      expect(core!.size, 31185552);
      expect(core.crc, 0xf34ffa72);
      // ralysnd's artifact ships the v7a lib too (packaging
      // strips the final APK to arm64, as for every engine).
      expect(names, contains('jni/armeabi-v7a/libpgjni.so'));
      // The rebuilt core is OUT of the package entirely:
      // no dead native lib ships.
      expect(names.where((n) => n.contains('psiphoncore')), isEmpty);
      expect(
        zipEntryFingerprint(bytes, 'jni/arm64-v8a/libpsiphoncore.so'),
        isNull,
      );
    });

    test('the wrapper classes are ralysnd\u2019s v2.0.39 set '
        '(classes.jar fingerprint)', () {
      final bytes = File('android/app/libs/psiphon.aar').readAsBytesSync();
      final classes = zipEntryFingerprint(bytes, 'classes.jar');
      expect(classes, isNotNull);
      // ralysnd's recovered AAR classes.jar: 38,357 B,
      // CRC-32 0x06052ad3 (44 classes: ca.psiphon wrapper +
      // pg runtime + psi bindings; the class set was verified
      // identical to the set in ralysnd's shipped APK dex,
      // modulo the generated R class and the host-side
      // Tun2SocksJniLoader, which Ember supplies itself).
      expect(classes!.size, 38357);
      expect(classes.crc, 0x06052ad3);
    });
  });

  group('the recovered wrapper\u2019s dead references are '
      'documented, not hidden', () {
    test('proguard carries exactly the three -dontwarn rules '
        'the recovered AAR needs, with the evidence comment',
        () {
      final proguard =
          File('android/app/proguard-rules.pro').readAsStringSync();
      // wf.c / w3.z / f0.a: ralysnd-R8-renamed types that
      // appear only in Signature attributes and throws
      // clauses of the recovered wrapper classes. None is
      // defined in any of ralysnd's shipped APK's dexes;
      // no bytecode instruction references them; the
      // referencing utilities are called by neither host.
      // R8's missing-class check needs the explicit
      // -dontwarn; ART never did.
      expect(proguard.contains('-dontwarn wf.c'), isTrue);
      expect(proguard.contains('-dontwarn w3.z'), isTrue);
      expect(proguard.contains('-dontwarn f0.a'), isTrue);
      expect(proguard.contains('Build 2069 (Psiphon transplant)'),
          isTrue);
    });
  });

  group('host adaptation to the v2.0.39 wrapper', () {
    test('loadLibrary is NOT overridden — the wrapper\u2019s '
        'default loads pgjni, exactly as ralysnd runs it', () {
      expect(service.contains('override fun loadLibrary'), isFalse);
      expect(service.contains('loadLibrary("psiphoncore")'), isFalse);
      expect(service.contains('System.loadLibrary("psiphoncore")'),
          isFalse);
    });

    test('every HostService callback Ember implements exists '
        'in the stock wrapper contract (source shape)', () {
      // The v2.0.39 interface\u2019s callback set equals the old
      // one minus onAccessToken; these overrides are the ones
      // the service relies on, and each is a default method
      // of ralysnd\u2019s wrapper too.
      for (final cb in [
        'override fun getContext()',
        'override fun getPsiphonConfig()',
        'override fun bindToDevice(',
        'override fun onDiagnosticMessage(',
        'override fun onAvailableEgressRegions(',
        'override fun onConnecting()',
        'override fun onConnected()',
        'override fun onClientRegion(',
        'override fun onClientAddress(',
        'override fun onBytesTransferred(',
        'override fun onUpstreamProxyError(',
        'override fun onExiting()',
      ]) {
        expect(service.contains(cb), isTrue, reason: cb);
      }
      // The one v2.0.42-only callback is not implemented
      // (it has no stock counterpart to call it; the class
      // header names it in prose, so the pin targets the
      // override shape).
      expect(service.contains('override fun onAccessToken'), isFalse);
    });
  });

  group('config parity: only fields the stock binary contains',
      () {
    test('the AdditionalParameters blob is gone — from the '
        'emission and from the constants', () {
      expect(service.contains('put("AdditionalParameters"'), isFalse);
      expect(constants.contains('ADDITIONAL_PARAMETERS'), isFalse);
      // And the explicit official lists it used to override
      // are still emitted, now authoritative.
      expect(service.contains('RemoteServerListURLs'), isTrue);
      expect(service.contains('ObfuscatedServerListRootURLs'), isTrue);
    });

    test('no fork-only fields are emitted, and the fork-only '
        'protocol names are gone', () {
      expect(service.contains('put("AggressiveEstablishment"'), isFalse);
      expect(service.contains('put("FrontedMeekDialOverrides"'), isFalse);
      expect(
          service.contains('put("FrontedMeekCDNScanUseBuiltInSpec"'),
          isFalse);
      expect(service.contains('put("FrontedMeekCDNScanSpec"'), isFalse);
      expect(service.contains('FRONTED_CDN_PROTOCOLS'), isFalse);
      expect(constants.contains('FRONTED_CDN_PROTOCOLS'), isFalse);
      // The quoted protocol literal (the withdrawal comments
      // name the family in unquoted prose).
      expect(constants.contains('"FRONTED-MEEK-CDN-OSSH"'), isFalse);
      expect(service.contains('"FRONTED-MEEK-CDN-OSSH"'), isFalse);
    });

    test('the fronted rungs steer through preresolved '
        'provider CIDRs — ralysnd\u2019s clean-IP mechanism', () {
      expect(service.contains('private fun putPreresolvedCidrs('), isTrue);
      expect(
        service.contains('put("DNSResolverPreresolvedIPAddressCIDRs"'),
        isTrue,
      );
      final rungA = segmentOf(service, '"A" -> {', '"E" -> {');
      expect(rungA.contains('putPreresolvedCidrs(cfg)'), isTrue);
      expect(
        rungA.contains('JSONArray(PsiphonConstants.FRONTED_PROTOCOLS)'),
        isTrue,
      );
    });

    test('the dial-override channel is gone end to end', () {
      expect(service.contains('EXTRA_EDGE_OVERRIDES'), isFalse);
      expect(service.contains('ladderEdgeOverrides'), isFalse);
      expect(mainActivity.contains('argument<String>("edgeOverrides")'),
          isFalse);
      expect(platform.contains("'edgeOverrides'"), isFalse);
      expect(controller.contains('_edgeOverridesJson'), isFalse);
    });
  });

  group('Beast honesty: no dead toggle survives the transplant',
      () {
    test('the UI has no Beast row, and fronting no longer '
        'claims a fork core', () {
      expect(pages.contains("'Beast Mode'"), isFalse);
      expect(pages.contains('settings.beastMode'), isFalse);
      expect(pages.contains('CDN fronting (fork core)'), isFalse);
      expect(pages.contains("'CDN fronting'"), isTrue);
    });

    test('the setting, its persistence, and the channel key '
        'are gone', () {
      expect(controller.contains('bool beastMode'), isFalse);
      expect(controller.contains("'beastMode':"), isFalse);
      expect(platform.contains("'beast':"), isFalse);
      expect(platform.contains('bool beast'), isFalse);
      expect(mainActivity.contains('argument<Boolean>("beast")'), isFalse);
    });

    test('the service carries no beast plumbing', () {
      expect(service.contains('EXTRA_BEAST'), isFalse);
      expect(service.contains('ladderBeast'), isFalse);
    });

    test('a carried-over store with a beastMode key still '
        'loads — the key is simply unknown now', () {
      final s = PsiphonSettings.fromJson({
        'beastMode': false,
        'region': 'NL',
        'cdnFronting': false,
      });
      expect(s.region, 'NL');
      expect(s.cdnFronting, isFalse);
      expect(s.toJson().containsKey('beastMode'), isFalse);
    });
  });

  group('start-phase synchronous flushing: no failure can '
      'hide behind the buffer again', () {
    test('the flag exists and is volatile', () {
      expect(
        service.contains(
            '@Volatile\n    private var logStartPhaseSync = false'),
        isTrue,
      );
    });

    test('openLog enters the start phase and flushes the '
        'header immediately', () {
      final openLog = segmentOf(
        service,
        'private fun openLog',
        'private fun logLine',
      );
      expect(openLog.contains('logStartPhaseSync = true'), isTrue);
      expect(
        openLog.indexOf('logStartPhaseSync = true'),
        greaterThan(openLog.indexOf('psiphon session')),
      );
      expect(
        openLog.indexOf('logWriter?.flush()'),
        greaterThan(openLog.indexOf('logStartPhaseSync = true')),
      );
    });

    test('writeLogRawLocked flushes every line while the '
        'flag holds, buffered policy otherwise', () {
      final raw = segmentOf(
        service,
        'private fun writeLogRawLocked',
        'private fun closeLogLocked',
      );
      expect(
        raw.contains('logStartPhaseSync || logBytesSinceFlush >= 8192'),
        isTrue,
      );
    });

    test('connected, fail, and stop each end the start phase',
        () {
      final onConnected = segmentOf(
        service,
        'override fun onConnected()',
        'override fun onClientRegion',
      );
      expect(onConnected.contains('logStartPhaseSync = false'), isTrue);
      final failFn = segmentOf(
        service,
        'private fun fail()',
        'private fun stopTunnel()',
      );
      expect(failFn.contains('logStartPhaseSync = false'), isTrue);
      final stopFn = segmentOf(
        service,
        'private fun stopTunnel()',
        'private fun stopProcesses()',
      );
      expect(stopFn.contains('logStartPhaseSync = false'), isTrue);
    });
  });

  group('startTunnel catch: Throwable, recorded, then fail', () {
    test('the catch is Throwable-wide and records to '
        'crash.log before failing', () {
      final start = segmentOf(
        service,
        'private fun startTunnel',
        'private fun waitForConnected',
      );
      expect(start.contains('catch (e: Throwable)'), isTrue);
      expect(start.contains('catch (e: Exception)'), isFalse);
      expect(
        start.contains(
            'CrashLog.append(this, "PsiphonVpnService.startTunnel", e)'),
        isTrue,
      );
      expect(
        start.indexOf(
            'CrashLog.append(this, "PsiphonVpnService.startTunnel", e)'),
        lessThan(start.lastIndexOf('fail()')),
      );
    });
  });
}
