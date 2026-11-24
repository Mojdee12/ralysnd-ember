// Build 2116, batch B7 — single-engine arbitration
// (AB-08), landed last per the plan:
//   - a native single-writer claim (EngineClaim.kt): every
//     VpnService start funnel claims the device's one VPN
//     slot, displacing a different previous owner through
//     its own stop entry point; stops/destroys release it;
//   - the WG Tunnel resurrection (the one start path with
//     no funnel) is reconciled against the claim when the
//     backend restores a tunnel at process start;
//   - the Dart shell re-arbitrates on foreground: it adopts
//     the mode of a natively-started engine that is
//     verifiably live, and clears a marker nothing lives
//     behind.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String read(String path) => File(path).readAsStringSync();

const kotlinDir = 'android/app/src/main/kotlin/com/ralysnd/ember';

void main() {
  group('B7-1 the native claim (EngineClaim.kt)', () {
    final claim = read('$kotlinDir/EngineClaim.kt');

    test('is a marker file written atomically, read defensively', () {
      expect(claim, contains('object EngineClaim'));
      expect(claim, contains('AtomicFile.writeText'));
      expect(claim, contains('fun owner(context: Context): String?'));
      expect(claim, contains('fun claim(context: Context, engine: String)'));
      expect(claim, contains('fun release(context: Context, engine: String)'));
    });

    test('claiming displaces a different owner via its own stop funnel', () {
      // Build 2125 re-point (A25-01): the displaced owner's
      // variable is named in full now.
      expect(claim, contains('stopEngine(context, previous)'));
      expect(claim, contains('MOZILLA -> CoreService.turnOff(context)'));
      expect(claim, contains('XRAY -> XrayVpnService.stop(context)'));
      expect(claim, contains('WIREGUARD -> WgTunnelEngine.stop(context)'));
      expect(claim, contains('LanternVpnService.ACTION_STOP'));
      expect(claim, contains('OpenVpnService.ACTION_STOP'));
      expect(claim, contains('PsiphonVpnService.ACTION_STOP'));
    });

    test('release is owner-checked', () {
      expect(claim, contains('if (owner(context) == engine)'));
    });
  });

  group('B7-1 every start funnel claims', () {
    test('CoreService claims on start, releases on stop + destroy', () {
      final s = read('$kotlinDir/CoreService.kt');
      expect(s, contains('EngineClaim.claim(this, EngineClaim.MOZILLA)'));
      expect(
        'EngineClaim.release(this, EngineClaim.MOZILLA)'.allMatches(s).length,
        2,
        reason: 'ACTION_STOP + onDestroy',
      );
    });

    test('XrayVpnService claims on start/resume, releases on stop + destroy',
        () {
      final s = read('$kotlinDir/XrayVpnService.kt');
      // PIN UPDATED by build 2119 (audit F-04): the claim
      // is per-start-action now — plain starts claim XRAY,
      // standalone WARP starts claim WARP, SOCKS (Aether)
      // starts claim AETHER, a resume re-claims the running
      // session's own name, and stop/destroy release THAT
      // name (claimName), not a hard-coded XRAY. The intent
      // stands: every start funnel claims; both exits
      // release.
      expect(s, contains('ACTION_START_WARP -> EngineClaim.WARP'));
      // Build 2125 re-point (A25-13): the SOCKS branch is
      // validated before it may claim — invalid extras map
      // to NO claim (null) instead of claiming AETHER for a
      // start that will be refused.
      expect(s, contains('ACTION_START_SOCKS ->'));
      expect(s, contains('EXTRA_SOCKS_PORT, 0) <= 0'));
      expect(s, contains('EngineClaim.AETHER'));
      // (The ACTION_RESUME pin below is re-pointed by
      // build 2125 too: the resume branch is validated
      // now — it re-claims claimName only for a live,
      // unlocked paused session.)
      expect(s, contains('ACTION_RESUME ->'));
      expect(s, contains('claimName'));
      expect(s, contains('EngineClaim.claim(this, startClaim)'));
      expect(
        'EngineClaim.release(this, claimName)'.allMatches(s).length,
        2,
      );
    });

    test('Lantern / OpenVPN / Psiphon claim on ACTION_START', () {
      final lantern = read('$kotlinDir/LanternVpnService.kt');
      expect(lantern, contains('EngineClaim.claim(this, EngineClaim.LANTERN)'));
      expect(
        'EngineClaim.release(this, EngineClaim.LANTERN)'
            .allMatches(lantern)
            .length,
        2,
      );
      final openvpn = read('$kotlinDir/OpenVpnService.kt');
      expect(openvpn, contains('EngineClaim.claim(this, EngineClaim.OPENVPN)'));
      expect(
        'EngineClaim.release(this, EngineClaim.OPENVPN)'
            .allMatches(openvpn)
            .length,
        2,
      );
      final psiphon = read('$kotlinDir/PsiphonVpnService.kt');
      expect(psiphon, contains('EngineClaim.claim(this, EngineClaim.PSIPHON)'));
      expect(
        'EngineClaim.release(this, EngineClaim.PSIPHON)'
            .allMatches(psiphon)
            .length,
        2,
      );
    });

    test('WgTunnelEngine claims in start, releases in stop', () {
      final s = read('$kotlinDir/WgTunnelEngine.kt');
      expect(
        s,
        contains('EngineClaim.claim(appContext, EngineClaim.WIREGUARD)'),
      );
      // Build 2125 re-point (A25-46): the release call is
      // formatted across lines now (it passes the
      // application context explicitly); matched
      // whitespace-insensitively.
      expect(
        s.replaceAll(RegExp(r'\s+'), ' '),
        contains(
          'EngineClaim.release( context.applicationContext ?: context, '
          'EngineClaim.WIREGUARD, )',
        ),
      );
    });

    test('a restored WG tunnel is arbitrated against the claim', () {
      final s = read('$kotlinDir/WgTunnelEngine.kt');
      expect(s, contains('created.status.first { it.activeTunnels.isNotEmpty() }'));
      expect(s, contains('created.stopAllActiveTunnels()'));
      expect(s, contains('EngineClaim.owner(appContext)'));
    });
  });

  group('B7-1 the Dart re-arbitration', () {
    test('the channel face exists and fails soft', () {
      final core = read('lib/core/android_core.dart');
      expect(core, contains('abstract final class EngineClaimChannel'));
      expect(core, contains("'engineClaimOwner'"));
      expect(core, contains("'engineClaimClear'"));
    });

    test('MainActivity serves the two channel cases', () {
      final main = read('$kotlinDir/MainActivity.kt');
      expect(main, contains('"engineClaimOwner" ->'));
      expect(main, contains('"engineClaimClear" ->'));
      expect(main, contains('EngineClaim.owner(this)'));
    });

    test('the shell re-arbitrates on resume', () {
      final shell = read('lib/ui/ember/ember_shell.dart');
      expect(shell, contains('unawaited(_reArbitrateFromClaim())'));
      expect(shell, contains('Future<void> _reArbitrateFromClaim() async'));
      // Adoption is gated on the controllers' own liveness
      // view, and a dead marker is cleared.
      final at = shell.indexOf('Future<void> _reArbitrateFromClaim() async');
      final body = shell.substring(at, at + 2200);
      expect(body, contains('final running = _runningMode;'));
      expect(body, contains('setState(() => mode = running);'));
      expect(body, contains('await EngineClaimChannel.clear();'));
    });
  });
}
