/// Build 2078 — feature queue #9 completion (WireGuard
/// handshake noise): the socket-recovery half's registration
/// echo guard.
///
/// The two halves of #9 were both shipped before this build —
/// the junk half (buildAwgUapi emits jc/jmin/jmax/s1/s2/h1–h4,
/// pinned in build2065_test.dart) and the recovery half (the
/// AWG network callback re-applies the session's UAPI config
/// on a network change, also pinned in build2065_test.dart).
/// What was missing: Android delivers onAvailable at once for
/// the network that is ALREADY the default when a
/// default-network callback is registered, so the recovery
/// hook fired once spuriously at EVERY AWG session start —
/// re-applying the identical config and rebinding the
/// device's UDP sockets in the middle of the first handshake
/// initiation. This build skips that registration echo (the
/// network captured at registration) and recovers only on a
/// genuinely different network — the same echo-guard pattern
/// CoreService.watchNetwork already uses for Mozilla.
/// These tests pin the guard and close #9: both halves present
/// and the echo no longer rebinds.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

String _kt(String name) =>
    _read('android/app/src/main/kotlin/com/ralysnd/ember/$name');

String _dart(String path) => _read('lib/$path');

void main() {
  // Build 2104: feature #9's recovery half changed owners.
  // Builds 2078–2103 implemented socket recovery in Ember's
  // own service (a network callback that re-applied the
  // config and re-protected the device sockets, with a
  // registration-echo guard). The WG Tunnel backend owns
  // that machinery now — its engine watches the network,
  // re-resolves endpoints and protects its sockets through
  // its own BypassSocket plumbing. What remains Ember's is
  // the NetworkMonitor the backend consumes: it must track
  // the non-VPN underlay truthfully and republish on every
  // change. The echo-guard tests are retired with the code
  // they pinned; the group below pins the surviving half.
  group('feature #9 — AWG network recovery (build 2104 form)', () {
    late String engine;

    setUpAll(() {
      engine = _kt('WgTunnelEngine.kt');
    });

    test('the monitor registers a non-VPN network callback', () {
      // Verification iteration 1, finding 4: NOT the
      // default-network callback — once Ember's own
      // full-tunnel VPN is up it IS the default network,
      // and reporting it as the underlay would feed the
      // backend its own tunnel. The request asks for
      // NOT_VPN networks only.
      expect(engine.contains('registerNetworkCallback'), isTrue);
      expect(engine.contains('NET_CAPABILITY_NOT_VPN'), isTrue);
      expect(engine.contains('EmberNetworkMonitor'), isTrue);
    });

    test('the monitor republishes on every kind of change', () {
      expect(engine.contains('override fun onAvailable'), isTrue);
      expect(engine.contains('override fun onCapabilitiesChanged'),
          isTrue);
      expect(engine.contains('override fun onLinkPropertiesChanged'),
          isTrue);
      expect(engine.contains('override fun onLost'), isTrue);
    });

    test('the snapshot is truthful: identity, v6 footprint, usability',
        () {
      expect(engine.contains('NetworkSnapshot('), isTrue);
      expect(engine.contains('hasIpv6 = hasIpv6'), isTrue);
      expect(engine.contains('NET_CAPABILITY_INTERNET'), isTrue);
    });

    test('the backend is constructed with the monitor', () {
      expect(engine.contains('TunnelBackend('), isTrue);
      expect(engine.contains('EmberNetworkMonitor(appContext)'), isTrue);
    });
  });

  group('feature #9 — closure: both halves present', () {
    test('junk half: all nine AWG noise values reach the hand-off', () {
      // Build 2104: the hand-off is wgConfFromProfile's .conf
      // text; the serializer writes each noise value under
      // its .conf label.
      final wgConf = _dart('xray/wg_conf.dart');
      for (final line in [
        "awg('Jc', p.awgJc)",
        "awg('Jmin', p.awgJmin)",
        "awg('Jmax', p.awgJmax)",
        "awg('S1', p.awgS1)",
        "awg('S2', p.awgS2)",
        "awg('H1', p.awgH1)",
        "awg('H2', p.awgH2)",
        "awg('H3', p.awgH3)",
        "awg('H4', p.awgH4)",
      ]) {
        expect(wgConf.contains(line), isTrue, reason: 'missing $line');
      }
    });

    test('junk half: the editor binds all nine fields for editing', () {
      // Build 2104 (finding 17) extended the set with S3/S4
      // — the list below is the full eleven now.
      final editor = _dart('ui/ember/profile_editor.dart');
      for (final field in [
        'awgJc',
        'awgJmin',
        'awgJmax',
        'awgS1',
        'awgS2',
        'awgS3',
        'awgS4',
        'awgH1',
        'awgH2',
        'awgH3',
        'awgH4',
      ]) {
        expect(editor.contains("'$field'"), isTrue, reason: 'missing $field');
      }
    });

    test('recovery half: the backend owns it; the monitor feeds it',
        () {
      // Build 2104 form of the 2078 closure pin (the
      // callback/guard/unregister trio it used to assert
      // lived in the deleted service): the engine is built
      // with Ember's NetworkMonitor, whose callback is the
      // registration the backend's recovery consumes.
      // Verification iteration 1, finding 4 corrected the
      // registration's shape: a default-network callback
      // reports Ember's OWN VPN as the underlay once the
      // tunnel is up, so the monitor now requests NOT_VPN
      // networks explicitly.
      final engine = _kt('WgTunnelEngine.kt');
      expect(engine.contains('TunnelBackend('), isTrue);
      expect(engine.contains('registerNetworkCallback'), isTrue);
      expect(engine.contains('NET_CAPABILITY_NOT_VPN'), isTrue);
    });

    test('plain WireGuard stays honest: no junk invented for it', () {
      // Only profiles that carry AWG parameters route to the
      // AWG engine at all — a plain-WG profile has no junk
      // values to emit, and the .conf serializer emits
      // nothing it was not given (its awg() helper writes a
      // line only for a non-empty value).
      // Build 2106 (journey audit F-05): the routing keys on
      // the SUPPORTED parameter set — a profile whose only
      // Amnezia parameters are J1–J3 (which the WG Tunnel
      // engine discards) no longer routes to the AWG engine.
      final wgConf = _dart('xray/wg_conf.dart');
      expect(
        wgConf.contains('if (value.isNotEmpty) b.writeln'),
        isTrue,
      );
      final controller = _dart('xray/xray_controller.dart');
      expect(
          controller.contains('if (candidate.hasSupportedAmneziaParams)'),
          isTrue);
    });
  });
}
