// Build 2110 — the fix-only build for the two problems the
// owner reported still broken after builds 2103–2107
// (2026-11-18 20:19–20:25), on the evidence of the two
// diagnosis reports (fugui-hostname-diagnosis-2109.md,
// wg-start-diagnosis-2109.md) and his device export
// (device-logs-2026-11-18-2022.md, taken on build 2104).
//
// Part A (V2Ray): C1 — a hostname-form server address was
// emitted as-is and the core's system dialer resolved it
// through Go's pure resolver (CGO_ENABLED=0 → 127.0.0.1:53
// on Android → outright failure). The fix is v2rayNG's
// resolve method "1", the mechanism Ember's 2103 alignment
// missed: resolve app-side, pin through the existing
// serverHostPins plumbing, stamp the outbound sockopt
// UseIP + happyEyeballs. C3/A2 — the policy level-0 byte
// budgets, non-causal parity. NO DNS value changes; the
// closed-pipe DoH defect (C2) is deliberately untouched —
// this build's device test is its discriminator.
//
// Part B (WireGuard / start cluster): D1 — profiles whose
// S/H parameters rewrite the handshake itself are silently
// dropped by vanilla servers (WARP); the walk gains ONE
// de-shaped retry leg, and _connectAwg journals the
// effective shaping parameters. A1 — the backend's TUN
// builder family-filters DNS and Ember passed no fallback,
// so a mismatch left the TUN with zero resolvers ("connects
// but only Telegram opens"); the hand-off is now
// family-guarded. Defect 2 — engine switches assumed the
// previous engine was down; both sides now observe/refuse.
// Defect 3 — silent pre-foreground stopSelf() branches
// armed an unfulfillable FGS deadline (the two
// ForegroundServiceDidNotStartInTimeException crashes), and
// WgTunnelEngine.stop() blocked the main thread. Defect 4 —
// the orphan sweep's blanket guard blinded it to this
// instance's own tracked core (the "port stayed busy"
// starts); fresh starts now stopProcesses() first, sweep
// excluding this process's own children by parentage, and
// hold coreLock across sweep+spawn — the fresh-start pin
// build2049_fix_test.dart's header always said was
// missing.
//
// All fixtures use dummy values — the owner's real configs
// and keys never appear in tests.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/xray/config_builder.dart';
import 'package:firefox_vpn/xray/wg_conf.dart';
import 'package:firefox_vpn/xray/xray_models.dart';
import 'package:firefox_vpn/xray/xray_platform.dart';

String dartSrc(String rel) => File('lib/$rel').readAsStringSync();
String ktSrc(String rel) =>
    File('android/app/src/main/kotlin/com/ralysnd/ember/$rel')
        .readAsStringSync();

String _segment(String source, String start, [String? end]) {
  final at = source.indexOf(start);
  expect(at, isNonNegative, reason: 'marker not found: $start');
  final rest = source.substring(at);
  if (end == null) return rest;
  final cut = rest.indexOf(end, start.length);
  return cut < 0 ? rest : rest.substring(0, cut);
}

Map<String, dynamic> decode(String json) =>
    jsonDecode(json) as Map<String, dynamic>;

Map<String, dynamic> outboundByTag(Map<String, dynamic> config, String tag) =>
    (config['outbounds'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((o) => o['tag'] == tag);

Map<String, dynamic> sockoptOf(Map<String, dynamic> outbound) =>
    (outbound['streamSettings'] as Map<String, dynamic>)['sockopt']
        as Map<String, dynamic>;

/// The fugui acceptance shape (build 2103's fixture):
/// VLESS+REALITY addressed by HOSTNAME.
Profile hostnameVless() => Profile(
  id: 'p1',
  name: 'hostname-vless',
  protocol: Protocol.vless,
  address: 'free.example.net',
  port: 443,
  uuidOrPassword: '00000000-0000-4000-8000-000000000000',
  network: 'tcp',
  security: 'reality',
  sni: 'www.example.com',
  fingerprint: 'ios',
  flow: 'xtls-rprx-vision',
  publicKey: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
  shortId: '01ab',
);

const pins = {
  'free.example.net': ['192.0.2.10', '2001:db8::10'],
};

Profile wgProfile({
  String localAddress = '10.0.0.2/32',
  String wgDns = '',
  String wgAllowedIPs = '0.0.0.0/0',
  String awgS1 = '',
  String awgS2 = '',
  String awgH1 = '',
  String awgH2 = '',
  String awgH3 = '',
  String awgH4 = '',
}) => Profile(
  id: 'wg1',
  name: 'wg-fixture',
  protocol: Protocol.wireguard,
  address: '203.0.113.7',
  port: 51820,
  secretKey: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
  peerPublicKey: 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=',
  localAddress: localAddress,
  wgDns: wgDns,
  wgAllowedIPs: wgAllowedIPs,
  awgS1: awgS1,
  awgS2: awgS2,
  awgH1: awgH1,
  awgH2: awgH2,
  awgH3: awgH3,
  awgH4: awgH4,
);

void main() {
  group('A1 — the server-name resolution stamp', () {
    test('tunnel config: pin + UseIP + happyEyeballs ride the '
        'proxy outbound; the address stays the domain', () {
      final config = decode(
        buildTunnelConfig(hostnameVless(), XraySettings(), serverHostPins: pins),
      );
      final proxy = outboundByTag(config, 'proxy');
      final sock = sockoptOf(proxy);
      expect(sock['domainStrategy'], 'UseIP');
      // Build 2113: the stamp's happyEyeballs takes
      // upstream's full serialized shape (the bean's
      // maxConcurrentTry and tryDelayMs defaults ride too).
      expect(sock['happyEyeballs'], {
        'prioritizeIPv6': false,
        'maxConcurrentTry': 4,
        'tryDelayMs': 250,
        'interleave': 2,
      });
      // The stored hostname stays the dialed address (the
      // core replaces it with a pinned IP at dial time via
      // the hosts entry + the strategy — v2rayNG's shape).
      final vnext = (proxy['settings']['vnext'] as List).first
          as Map<String, dynamic>;
      expect(vnext['address'], 'free.example.net');
      final hosts = (config['dns'] as Map<String, dynamic>)['hosts']
          as Map<String, dynamic>;
      expect(hosts['free.example.net'], ['192.0.2.10', '2001:db8::10']);
    });

    test('no pins: the outbound is exactly the pre-2110 shape', () {
      final config = decode(buildTunnelConfig(hostnameVless(), XraySettings()));
      final sock = sockoptOf(outboundByTag(config, 'proxy'));
      expect(sock.containsKey('domainStrategy'), isFalse);
      expect(sock.containsKey('happyEyeballs'), isFalse);
    });

    test('pins for a DIFFERENT name do not stamp this outbound', () {
      final config = decode(
        buildTunnelConfig(
          hostnameVless(),
          XraySettings(),
          serverHostPins: const {
            'other.example.net': ['192.0.2.99'],
          },
        ),
      );
      final sock = sockoptOf(outboundByTag(config, 'proxy'));
      expect(sock.containsKey('domainStrategy'), isFalse);
    });

    test('the stamp MERGES into an existing sockopt (dialMode '
        'survives)', () {
      final p = hostnameVless()..dialMode = 'oob.0';
      final config = decode(
        buildTunnelConfig(p, XraySettings(), serverHostPins: pins),
      );
      final sock = sockoptOf(outboundByTag(config, 'proxy'));
      expect(sock['dialMode'], 'oob.0');
      expect(sock['domainStrategy'], 'UseIP');
    });

    test('test config: same pin + stamp (a hostname profile '
        'must pass its delay test)', () {
      final config = decode(
        buildTestConfig(hostnameVless(), XraySettings(), serverHostPins: pins),
      );
      final sock = sockoptOf(outboundByTag(config, 'proxy'));
      expect(sock['domainStrategy'], 'UseIP');
      final hosts = (config['dns'] as Map<String, dynamic>)['hosts']
          as Map<String, dynamic>;
      expect(hosts['free.example.net'], ['192.0.2.10', '2001:db8::10']);
      final bare = decode(buildTestConfig(hostnameVless(), XraySettings()));
      expect(
        sockoptOf(outboundByTag(bare, 'proxy'))
            .containsKey('domainStrategy'),
        isFalse,
      );
    });

    test('the controller computes, merges and carries the pins '
        '(source pin)', () {
      final c = dartSrc('xray/xray_controller.dart');
      expect(c, contains('Future<Map<String, List<String>>> _serverNamePins('));
      expect(c, contains('_mergedServerPins('));
      expect(c, contains('_sessionServerPins'));
      expect(c, contains('_serverPinsAdoptedFor'));
      // Test configs and the DPI Lab ride the same path.
      expect(c, contains('serverHostPins: await _serverNamePins(p)'));
      expect(c, contains('await _serverNamePins(dialProfile, journal: true)'));
      expect(c, contains('_sessionServerPins = await _serverNamePins('));
      // The switch funnel + the AWG funnel both observe the
      // previous engine down (defect 2, Dart half).
      expect(c, contains('_awaitPreviousEngineDown'));
    });
  });

  group('A2 — policy parity (non-causal)', () {
    test('level 0 carries the explicit byte budgets', () {
      final config = decode(buildTunnelConfig(hostnameVless(), XraySettings()));
      final level0 = ((config['policy'] as Map<String, dynamic>)['levels']
          as Map<String, dynamic>)['0'] as Map<String, dynamic>;
      expect(level0['uplinkOnly'], 0);
      expect(level0['downlinkOnly'], 0);
      expect(level0['statsUserUplink'], false);
      expect(level0['statsUserDownlink'], false);
    });
  });

  group('B1 — initiation shaping', () {
    test('the truth table: S/H rewrite the handshake, junk '
        'and signatures do not', () {
      expect(wgProfile().hasInitiationShaping, isFalse);
      expect(wgProfile(awgS1: '5').hasInitiationShaping, isTrue);
      expect(wgProfile(awgS1: '0').hasInitiationShaping, isFalse);
      expect(wgProfile(awgS2: '0-5').hasInitiationShaping, isTrue);
      expect(wgProfile(awgS2: '0-0').hasInitiationShaping, isFalse);
      expect(wgProfile(awgH1: '5').hasInitiationShaping, isTrue);
      expect(wgProfile(awgH1: '1').hasInitiationShaping, isFalse);
      expect(wgProfile(awgH2: '2').hasInitiationShaping, isFalse);
      expect(wgProfile(awgH3: '3-4').hasInitiationShaping, isTrue);
      expect(wgProfile(awgH4: '4').hasInitiationShaping, isFalse);
      // Junk + I1 only: separate datagrams, no shaping.
      final junkOnly = wgProfile()
        ..awgJc = '6'
        ..awgJmin = '10'
        ..awgJmax = '50'
        ..awgI1 = '<r 2><b 0x8580aabbccdd>';
      expect(junkOnly.hasInitiationShaping, isFalse);
      // An unparseable non-empty value counts (conservative).
      expect(wgProfile(awgS1: 'abc').hasInitiationShaping, isTrue);
    });

    test('the neutralized copy: S/H standard, junk + I1 kept, '
        'the stored profile untouched', () {
      final p = wgProfile(awgS1: '40', awgH1: '100')
        ..awgJc = '6'
        ..awgI1 = '<r 2><b 0x8580aabbccdd>';
      final copy = p.copyWithoutInitiationShaping();
      expect(copy.awgS1, '0');
      expect(copy.awgS2, '0');
      expect(copy.awgH1, '1');
      expect(copy.awgH2, '2');
      expect(copy.awgH3, '3');
      expect(copy.awgH4, '4');
      expect(copy.awgJc, '6');
      expect(copy.awgI1, '<r 2><b 0x8580aabbccdd>');
      expect(copy.hasInitiationShaping, isFalse);
      expect(p.awgS1, '40');
      expect(p.awgH1, '100');
    });

    test('the walk carries the de-shaped leg and the journal '
        '(source pin)', () {
      final c = dartSrc('xray/xray_controller.dart');
      final walk = _segment(
        c,
        'Future<void> connectWireGuardWithFallback',
        'Future<bool> _connectAwg',
      );
      expect(walk, contains('candidate.hasInitiationShaping'));
      expect(walk, contains('candidate.copyWithoutInitiationShaping()'));
      expect(walk, contains('awgFailureWasSilence'));
      final connect = _segment(
        c,
        'Future<bool> _connectAwg',
        'Future<bool> switchServer',
      );
      expect(connect, contains('AmneziaWG parameters for'));
      expect(connect, contains('awgDnsGuardedFor(p, settings)'));
    });
  });

  group('B2 — the DNS family guard', () {
    test('families mirror the backend on the effective shape', () {
      expect(awgTunnelFamilies(wgProfile()).v4, isTrue);
      expect(awgTunnelFamilies(wgProfile()).v6, isFalse);
      final v6 = wgProfile(
        localAddress: 'fd00::2/128',
        wgAllowedIPs: '::/0',
      );
      expect(awgTunnelFamilies(v6).v4, isFalse);
      expect(awgTunnelFamilies(v6).v6, isTrue);
      // Blank AllowedIPs: the hand-off's family-gated
      // default decides.
      final blankV6 = wgProfile(
        localAddress: 'fd00::2/128',
        wgAllowedIPs: '',
      );
      expect(awgTunnelFamilies(blankV6).v6, isTrue);
      expect(awgTunnelFamilies(blankV6).v4, isFalse);
    });

    test('a v6-only tunnel handed the IPv4 Settings DNS gets '
        'the v6 Cloudflare resolver + a journal note', () {
      final v6 = wgProfile(
        localAddress: 'fd00::2/128',
        wgAllowedIPs: '::/0',
      );
      final (dns, note) = awgDnsGuardedFor(v6, XraySettings());
      expect(dns, '2606:4700:4700::1111');
      expect(note, isNotNull);
      expect(note, contains('no resolver at all'));
    });

    test('an IPv4 tunnel handed only IPv6 resolvers gets '
        '1.1.1.1', () {
      final p = wgProfile(wgDns: '2606:4700:4700::1111');
      final (dns, note) = awgDnsGuardedFor(p, XraySettings());
      expect(dns, '1.1.1.1');
      expect(note, isNotNull);
    });

    test('a set with a surviving entry passes through '
        'untouched', () {
      final v6 = wgProfile(
        localAddress: 'fd00::2/128',
        wgAllowedIPs: '::/0',
        wgDns: '2606:4700:4700::1111, 2606:4700:4700::1001',
      );
      final (dns, note) = awgDnsGuardedFor(v6, XraySettings());
      expect(dns, '2606:4700:4700::1111, 2606:4700:4700::1001');
      expect(note, isNull);
      final (dns4, note4) = awgDnsGuardedFor(wgProfile(), XraySettings());
      expect(dns4, '1.1.1.1');
      expect(note4, isNull);
    });
  });

  group('B3/B4/B5 — the Kotlin start path (source pins)', () {
    test('the state carries awgTunnelPresent end to end', () {
      const stopped = XrayState.stopped;
      expect(stopped.awgTunnelPresent, isFalse);
      expect(
        dartSrc('xray/xray_platform.dart'),
        contains("m['awgTunnelPresent']"),
      );
      expect(
        ktSrc('MainActivity.kt'),
        contains('"awgTunnelPresent" to'),
      );
      expect(ktSrc('WgTunnelEngine.kt'), contains('fun tunnelPresent()'));
    });

    test('the AWG engine refuses a start over a still-stopping '
        'tunnel, and names a resume-gap revocation', () {
      final engine = ktSrc('WgTunnelEngine.kt');
      expect(engine, contains('the previous tunnel is still '));
      expect(engine, contains('awg:start-refused-previous-stopping'));
      expect(engine, contains('awg:start-revoked-in-resume-gap'));
      // The 2100-pinned problem text is unchanged.
      expect(engine, contains('the AmneziaWG engine stopped; '));
    });

    test("stop()'s bounded wait runs inside the serialized "
        'body, not on the calling thread', () {
      final engine = ktSrc('WgTunnelEngine.kt');
      final stop = _segment(
        engine,
        'fun stop(context: Context)',
        'fun tunnelPresent()',
      );
      expect(stop, contains('delay(50)'));
      expect(stop, isNot(contains('Thread.sleep')));
    });

    test('FGS starts go foreground BEFORE their validity '
        'checks, breadcrumbed', () {
      final service = ktSrc('XrayVpnService.kt');
      final start = _segment(
        service,
        'ACTION_START -> {',
        'ACTION_START_WARP -> {',
      );
      expect(
        start.indexOf('startInForeground(name)'),
        lessThan(start.indexOf('config.isEmpty()')),
      );
      expect(start, contains('xray:start-empty-config'));
      final socks = _segment(
        service,
        'ACTION_START_SOCKS -> {',
        'else -> {',
      );
      expect(
        socks.indexOf('startInForeground(name)'),
        lessThan(socks.indexOf('socksPort <= 0')),
      );
      expect(socks, contains('xray:start-socks-invalid'));
    });

    test('a fresh start stops its own core first and spawns '
        'under coreLock; the sweep excludes this process\'s '
        'own children by parentage (the fresh-start pin '
        'build 2049 lacked)', () {
      final service = ktSrc('XrayVpnService.kt');
      final start = _segment(
        service,
        'private fun startTunnel(',
        'private fun spawnCoreLocked(',
      );
      expect(start, contains('stopProcesses(keepTun = blackholeHeld)'));
      expect(start, contains('synchronized(coreLock)'));
      expect(start, contains('spawnCoreLocked('));
      final spawn = _segment(
        service,
        'private fun spawnCoreLocked(',
        'private fun startWarpTunnel(',
      );
      expect(spawn, contains('sweepOrphans()'));
      expect(spawn, contains('waitPortFree(socksPort, 3000)'));
      final sweep = _segment(
        service,
        'private fun sweepOrphans()',
        'private fun createFdListener(',
      );
      // The exclusion is by parentage, not by Process.pid():
      // java.lang.Process.pid() is absent from android.jar
      // at every platform level — the first 2110 release
      // build's Kotlin compile proved it ("Unresolved
      // reference 'pid'") — so the sweep reads each entry's
      // PPid from /proc/<pid>/status and skips this process's
      // own children (see ppidOf in the service).
      expect(sweep, contains('if (ppidOf(entry) == myPid) continue'));
      expect(service, contains('private fun ppidOf(entry: File): Int'));
      expect(
        service,
        isNot(contains(
          'if (xrayProcess?.isAlive == true || tunProcess?.isAlive == true) return',
        )),
      );
    });
  });
}
