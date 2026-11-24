/// Build 2123 — THE FIX BUILD (owner order 2026-11-20:
/// «مشکلاتم حل کن، فقط باز ۱۰ تا چیز خراب نکنی»).
///
/// Source pins for the audit-fix half of the build (the
/// Psiphon half's pins live in psiphon_transplant_test.dart):
///  - P-06: underlying-network handling for the Xray,
///    Lantern and OpenVPN services (Mozilla's pattern,
///    shared via UnderlyingNetworkWatch).
///  - P-03: IPv6 capture-or-surface for default V2Ray/WARP
///    sessions.
///  - P-09/P-10: stats cadence + store write amplification.
///  - P-02: the completed Mozilla evidence path.
///
/// The behavioural proof for the native items is the
/// owner's device acceptance; these pins keep the wiring
/// from silently regressing out of the tree.
library;

import 'dart:io';

import 'package:firefox_vpn/xray/xray_models.dart';
import 'package:flutter_test/flutter_test.dart';

String src(String rel) => File(rel).readAsStringSync();
String kotlinSrc(String name) => src(
      'android/app/src/main/kotlin/com/ralysnd/ember/$name',
    );
String dartSrc(String rel) => File('lib/$rel').readAsStringSync();
String goSrc(String rel) => File('../core/$rel').readAsStringSync();

void main() {
  group('build 2123 — P-06 underlying-network handling', () {
    test('the shared watch mirrors the Mozilla semantics', () {
      final watch = kotlinSrc('UnderlyingNetworkWatch.kt');
      // Best-matching NOT_VPN request on S+, default
      // callback below — the CoreService shape.
      expect(watch.contains('registerBestMatchingNetworkCallback'),
          isTrue);
      expect(watch.contains('registerDefaultNetworkCallback'), isTrue);
      expect(watch.contains('NET_CAPABILITY_NOT_VPN'), isTrue);
      // VPN-transport networks are never an underlying one.
      expect(watch.contains('TRANSPORT_VPN'), isTrue);
      // Re-point on available, clear on loss of the current.
      expect(
          watch.contains('service.setUnderlyingNetworks(arrayOf(network))'),
          isTrue);
      expect(watch.contains('service.setUnderlyingNetworks(null)'),
          isTrue);
      // A change is a different network, or any network
      // after a loss.
      expect(
          watch.contains(
              '(current != null && current != network) ||'),
          isTrue);
      expect(watch.contains('(current == null && lost)'), isTrue);
    });

    test('all three services install and remove the watch', () {
      for (final name in [
        'XrayVpnService.kt',
        'LanternVpnService.kt',
        'OpenVpnService.kt',
      ]) {
        final svc = kotlinSrc(name);
        expect(svc.contains('UnderlyingNetworkWatch(this,'), isTrue,
            reason: '$name does not construct the watch');
        expect(svc.contains('underlyingWatch.start()'), isTrue,
            reason: '$name never starts the watch');
        expect(svc.contains('underlyingWatch.stop()'), isTrue,
            reason: '$name never stops the watch');
      }
    });

    test('Xray rotates its core on a network change', () {
      final svc = kotlinSrc('XrayVpnService.kt');
      expect(svc.contains('onUnderlyingNetworkChanged()'), isTrue);
      final at = svc.indexOf('fun onUnderlyingNetworkChanged()');
      final body = svc.substring(at, at + 1400);
      // The rotation reuses the session's own config and
      // the budget-free rotate path.
      expect(body.contains('rotateCore(config)'), isTrue);
      expect(body.contains('sessionConfig'), isTrue);
      // And it stands down when nothing is running.
      expect(body.contains('if (!running || stopping.get()) return'),
          isTrue);
    });

    test('Mozilla keeps its own inline watch (untouched)', () {
      final core = kotlinSrc('CoreService.kt');
      expect(core.contains('UnderlyingNetworkWatch'), isFalse);
      expect(core.contains('registerBestMatchingNetworkCallback'),
          isTrue);
    });
  });

  group('build 2123 — P-03 IPv6 surfacing (audit C-01)', () {
    test('the note fires exactly when the route is off', () {
      final off = XraySettings()..ipv6Route = false;
      final note = ipv6UncoveredSessionNote(off);
      expect(note, isNotNull);
      expect(note, contains('IPv6 stays outside this tunnel'));
      expect(note, contains('"IPv6 route"'));
      final on = XraySettings()..ipv6Route = true;
      expect(ipv6UncoveredSessionNote(on), isNull);
      // The shipped default stays OFF (v2rayNG parity) —
      // surfacing must never become a silent default flip.
      expect(XraySettings().ipv6Route, isFalse);
    });

    test('both adoption points journal the note', () {
      final controller = dartSrc('xray/xray_controller.dart');
      expect(
        controller.contains("diagnostics.add('connect', ipv6Note"),
        isTrue,
      );
      expect(
        controller.contains("diagnostics.add('warp', warpIpv6Note"),
        isTrue,
      );
      // And the builders' v6 gate itself is untouched:
      // capture still follows the setting, both ways.
      final svc = kotlinSrc('XrayVpnService.kt');
      expect(svc.contains('fdfe:dcba:9876::1'), isTrue);
    });
  });

  group('build 2123 — P-09 stats cadence (audit B-01)', () {
    test('the native stats query is gated to a 12 s sub-cadence', () {
      final c = dartSrc('xray/xray_controller.dart');
      final at = c.indexOf('Future<void> _pollStats()');
      final body = c.substring(at, at + 2400);
      expect(body.contains('queryNowMs - _lastStatsQueryMs < 12000'),
          isTrue);
      expect(body.contains('_lastStatsQueryMs = queryNowMs;'), isTrue);
      // The gate sits BEFORE the platform query.
      expect(
        body.indexOf('_lastStatsQueryMs = queryNowMs;'),
        lessThan(body.indexOf('XrayPlatform.trafficStats')),
      );
    });
  });

  group('build 2123 — P-10 stats sidecar (audit B-02)', () {
    test('the sidecar machinery exists with its guards', () {
      final c = dartSrc('xray/xray_controller.dart');
      expect(c.contains("/stats.json'"), isTrue);
      expect(c.contains('Map<String, Object?> _buildStatsDoc()'),
          isTrue);
      expect(c.contains('Future<void> _saveStatsSidecar()'), isTrue);
      final w = c.substring(c.indexOf('Future<void> _writeStatsSidecar()'),
          c.indexOf('Future<void> _writeStatsSidecar()') + 500);
      expect(w.contains('if (!_loaded) return;'), isTrue);
      expect(w.contains('if (_storeFromNewerVersion) return;'), isTrue);
      expect(w.contains('if (_storeUnreadable) return;'), isTrue);
      // Serialized through the store's own chain.
      expect(
        c.contains(
            '_saveChain = _saveChain.then((_) => _writeStatsSidecar());'),
        isTrue,
      );
    });

    test('load overlays the sidecar, mtime-gated, before _loaded', () {
      final c = dartSrc('xray/xray_controller.dart');
      expect(
          c.contains('if (docDecoded) await _overlayStatsSidecar();'),
          isTrue);
      final overlayAt = c.indexOf('await _overlayStatsSidecar();');
      final loadedAt = c.indexOf('_loaded = true;', overlayAt - 2000);
      expect(overlayAt, greaterThanOrEqualTo(0));
      expect(loadedAt, greaterThan(overlayAt));
      final body = c.substring(
          c.indexOf('Future<void> _overlayStatsSidecar()'),
          c.indexOf('Future<void> _overlayStatsSidecar()') + 1500);
      expect(body.contains('stateModified.isAfter(statsModified)'),
          isTrue);
    });

  group('build 2123 — P-02 Mozilla evidence (audit F-01)', () {
    test('the mirror runs on failed polls too', () {
      final c = dartSrc('core/core_controller.dart');
      expect(c.contains('Future<void> _mirrorCoreLogIfAny()'), isTrue);
      // One salvage call per refresh() failure branch
      // (CoreUnavailable, CoreApiException, generic).
      expect('await _mirrorCoreLogIfAny();'.allMatches(c).length, 3);
      // The success-path mirror is untouched.
      expect(c.contains('await _mirrorCoreLog(api);'), isTrue);
    });

    test('the first-fetch mirror cap widened to 100', () {
      final c = dartSrc('core/core_controller.dart');
      expect(c.contains('worthy.length > 100'), isTrue);
      expect(c.contains('worthy.sublist(worthy.length - 100)'), isTrue);
    });

    test('the journal rotation keeps the tail, never deletes', () {
      final c = dartSrc('xray/xray_controller.dart');
      // Build 2126 supersession (A26-15): the rotation is
      // async now — its file IO no longer blocks the
      // isolate mid-connect; both call sites await it.
      expect(
          c.contains('static Future<void> _rotateDiagnosticsLog(File file)'),
          isTrue);
      expect('await _rotateDiagnosticsLog(file);'.allMatches(c).length, 2);
      final sink = c.substring(
          c.indexOf('Future<void> _wireDiagnosticsSink()'),
          c.indexOf('Future<void> _wireDiagnosticsSink()') + 3200);
      expect(sink.contains('.delete'), isFalse);
      expect(c.contains('_diagRotateBytes = 512 * 1024'), isTrue);
      expect(c.contains('_diagKeepBytes = 256 * 1024'), isTrue);
    });

    test('the export tail widened to 400 lines', () {
      final c = dartSrc('xray/xray_controller.dart');
      expect(
        c.contains('lines.length > 400 ? lines.length - 400 : 0'),
        isTrue,
      );
    });

    test('the Go counters cover pool absorption and mid-stream deaths',
        () {
      final pool = goSrc('internal/proxy/pool.go');
      expect(pool.contains('noteAbsorbed func(error)'), isTrue);
      expect('p.noteAbsorbedFailure('.allMatches(pool).length, 2);
      final ctl = goSrc('internal/proxy/controller.go');
      expect(ctl.contains('pool.noteAbsorbed = c.noteEstablishedFailure'),
          isTrue);
      expect(ctl.contains('noteFailure: c.noteEstablishedFailure'),
          isTrue);
      expect(ctl.contains('func (c *managedTunnelConn) noteStreamFailure'),
          isTrue);
      // Clean endings stay uncounted.
      expect(ctl.contains('errors.Is(err, io.EOF)'), isTrue);
    });
  });

    test('the hot writers write the sidecar, not the whole store', () {
      final c = dartSrc('xray/xray_controller.dart');
      // The session-end flush.
      final flush = c.substring(
          c.indexOf('Future<void> _flushStatsSave()'),
          c.indexOf('Future<void> _flushStatsSave()') + 1200);
      expect(flush.contains('await _saveStatsSidecar();'), isTrue);
      expect(flush.contains('await _save();'), isFalse);
      // testDelay's three non-bulk saves.
      final td = c.substring(
          c.indexOf('Future<int> testDelay('),
          c.indexOf('Asks the running Test All funnel'));
      expect('await _save();'.allMatches(td).length, 0);
      expect('await _saveStatsSidecar();'.allMatches(td).length, 3);
      // resetProfileStats writes BOTH (the store for the
      // record, the sidecar so the zeroing is not reverted
      // by an older sidecar entry at the next load).
      final reset = c.substring(
          c.indexOf('Future<void> resetProfileStats('),
          c.indexOf('Future<void> resetProfileStats(') + 600);
      expect(reset.contains('await _save();'), isTrue);
      expect(reset.contains('await _saveStatsSidecar();'), isTrue);
    });
  });
}
