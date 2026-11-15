// Build 2072 — fix round 3 from the full review
// (full-review-2026-11-15.md §9 item 4): DNSTT + wstunnel,
// feature queue #15 and the WireGuard-over-WebSocket half of
// the wstunnel finding. The two feasibility binaries were
// lost with their /var/tmp scratch; both are re-created here
// and vendored DURABLY under ~/workspace/ember-app/engines/
// (never scratch again), then wired for real:
//
//  * DNSTT is a third chain underlay (settings.underlay =
//    'dnstt'): the client (a plain DNS-tunnel port forward,
//    NOT a SOCKS proxy — dnstt_args.dart states why the SOCKS
//    outbound shape still works) is started by the
//    controller, health-gated on its listener, supervised +
//    respawned + reaped by the native ChainSupervisor.
//  * wstunnel forwards a WireGuard peer through a ws/wss
//    server: an engine-level option on the WireGuard page;
//    the session config's peer endpoint is rewritten to the
//    local forwarder — the stored profile never changes.
//
// Both helpers run under the native-subprocess discipline:
// separate stdout/stderr drains into separate files, an
// unexpected exit surfaces as stage=error with the last
// stderr line, orphans are reaped by pid file. End-to-end
// tunnels need the owner's server-side counterparts
// (dnstt-server / wstunnel server) and cannot be proven in
// this VM — these pins prove the wiring, not the tunnel.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/xray/config_builder.dart';
import 'package:firefox_vpn/xray/dnstt_args.dart';
import 'package:firefox_vpn/xray/sha256.dart';
import 'package:firefox_vpn/xray/wstunnel_args.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

String ktSrc(String rel) =>
    File('android/app/src/main/kotlin/com/ralysnd/ember/$rel')
        .readAsStringSync();

String dartSrc(String rel) => File('lib/$rel').readAsStringSync();

const _dnsttSha =
    'bd61d12860c429833e7559d6ba852f0a6a11e09c310dda82ceaa8e4ada943ca3';
const _wstunnelSha =
    '4e3bcaf352f6a1d00b897fe7de3716b3ae15f8d35df426948a05a03659cb4abf';
const _wstunnelTarballSha =
    '6f00cc63740f1602168e5d6a5b0bc5dab6bbe77ef613e2b11fe68f881641ce7f';

void main() {
  group('vendored binaries (never lost again)', () {
    test('dnstt-client is vendored, hashed and aarch64', () {
      final f = File('../../engines/dnstt/dnstt-client');
      expect(f.existsSync(), isTrue, reason: 'vendored binary exists');
      final bytes = f.readAsBytesSync();
      expect(bytes.length, 9074944);
      expect(sha256Hex(bytes), _dnsttSha);
      // ELF, little-endian, EM_AARCH64 (183).
      expect(bytes.sublist(0, 4), [0x7f, 0x45, 0x4c, 0x46]);
      expect(bytes[18] | (bytes[19] << 8), 183);
      // The recipe + provenance are recorded beside it.
      final recipe = File('../../engines/dnstt/BUILD-RECIPE.md');
      expect(recipe.existsSync(), isTrue);
      expect(recipe.readAsStringSync(), contains(_dnsttSha));
      expect(
        File('../../engines/dnstt/src/dnstt-client/main.go').existsSync(),
        isTrue,
        reason: 'the source snapshot is vendored too',
      );
    });

    test('wstunnel is vendored with its release checksum proof', () {
      final f = File('../../engines/wstunnel/wstunnel');
      expect(f.existsSync(), isTrue, reason: 'vendored binary exists');
      final bytes = f.readAsBytesSync();
      expect(bytes.length, 11454320);
      expect(sha256Hex(bytes), _wstunnelSha);
      expect(bytes[18] | (bytes[19] << 8), 183);
      final tarball =
          File('../../engines/wstunnel/wstunnel_11.1.0_android_arm64.tar.gz');
      expect(sha256Hex(tarball.readAsBytesSync()), _wstunnelTarballSha);
      // The tarball hash matches the release's own checksums.
      final checksums =
          File('../../engines/wstunnel/checksums.txt').readAsStringSync();
      expect(checksums, contains(_wstunnelTarballSha));
      final prov = File('../../engines/wstunnel/PROVENANCE.md');
      expect(prov.readAsStringSync(), contains(_wstunnelSha));
    });

    test('the staged jniLibs copies are byte-identical', () {
      const dir = 'android/app/src/main/jniLibs/arm64-v8a';
      expect(
        sha256Hex(File('$dir/libdnstt.so').readAsBytesSync()),
        _dnsttSha,
      );
      expect(
        sha256Hex(File('$dir/libwstunnel.so').readAsBytesSync()),
        _wstunnelSha,
      );
      // Packaging keeps them byte-exact (the 2069 rule).
      final gradle = File('android/app/build.gradle.kts').readAsStringSync();
      expect(gradle, contains('keepDebugSymbols += "**/libdnstt.so"'));
      expect(gradle, contains('keepDebugSymbols += "**/libwstunnel.so"'));
    });
  });

  group('dnstt args', () {
    XraySettings full() => XraySettings()
      ..dnsttResolver = 'https://dns.google/dns-query'
      ..dnsttDomain = 't.example.com'
      ..dnsttPubkey = 'a' * 64;

    test('the DoH command line matches the client CLI', () {
      expect(buildDnsttArgs(full()), [
        '-doh',
        'https://dns.google/dns-query',
        '-pubkey',
        'a' * 64,
        't.example.com',
        '127.0.0.1:20860',
      ]);
    });

    test('the DoT and UDP transports map to their flags', () {
      final s = full()
        ..dnsttResolverType = 'dot'
        ..dnsttResolver = '1.1.1.1:853';
      expect(buildDnsttArgs(s).first, '-dot');
      s.dnsttResolverType = 'udp';
      expect(buildDnsttArgs(s).first, '-udp');
    });

    test('configured requires resolver, domain and a real key', () {
      expect(dnsttConfigured(full()), isTrue);
      expect(dnsttConfigured(full()..dnsttResolver = ''), isFalse);
      expect(dnsttConfigured(full()..dnsttDomain = ' '), isFalse);
      expect(dnsttConfigured(full()..dnsttPubkey = 'a' * 63), isFalse);
      expect(dnsttConfigured(full()..dnsttPubkey = 'g' * 64), isFalse);
      expect(isDnsttPubkey('ABCDEF0123456789' * 4), isTrue);
    });
  });

  group('wstunnel args', () {
    test('the forward disables the UDP idle timeout', () {
      expect(
        buildWstunnelArgs(
          url: 'wss://ws.example.com:443',
          host: 'wg.example.com',
          port: 51820,
        ),
        [
          'client',
          '-L',
          'udp://127.0.0.1:20861:wg.example.com:51820?timeout_sec=0',
          'wss://ws.example.com:443',
        ],
      );
    });

    test('an IPv6 endpoint is bracketed', () {
      final args = buildWstunnelArgs(
        url: 'ws://10.0.0.2:8080',
        host: '2001:db8::1',
        port: 51820,
      );
      expect(args[2], contains('[2001:db8::1]:51820'));
    });

    test('URL validation accepts ws/wss only', () {
      expect(isWstunnelUrl('wss://a.example'), isTrue);
      expect(isWstunnelUrl(' ws://a.example '), isTrue);
      expect(isWstunnelUrl('https://a.example'), isFalse);
      expect(isWstunnelUrl(''), isFalse);
    });
  });

  group('config emission', () {
    Profile vless() => Profile(
      id: 'v1',
      protocol: Protocol.vless,
      address: 'example.com',
      port: 443,
      uuidOrPassword: '00000000-0000-0000-0000-000000000000',
      security: 'tls',
    );

    Profile wg() => Profile(
      id: 'wg1',
      protocol: Protocol.wireguard,
      address: '203.0.113.7',
      port: 51820,
      secretKey: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
      peerPublicKey: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
    );

    Map<String, dynamic> decode(String json) =>
        jsonDecode(json) as Map<String, dynamic>;

    test('the DNSTT underlay emits its outbound and chains the proxy', () {
      final cfg = decode(
        buildTunnelConfig(vless(), XraySettings(), dnsttUnderlay: true),
      );
      final outbounds = (cfg['outbounds'] as List)
          .cast<Map<String, dynamic>>();
      final under = outbounds.firstWhere(
        (o) => o['tag'] == dnsttUnderlayTag,
      );
      expect(under['protocol'], 'socks');
      final server =
          ((under['settings'] as Map)['servers'] as List).first as Map;
      expect(server['address'], '127.0.0.1');
      expect(server['port'], dnsttListenPort);
      final proxy = outbounds.first;
      final sockopt =
          (proxy['streamSettings'] as Map)['sockopt'] as Map;
      expect(sockopt['dialerProxy'], dnsttUnderlayTag);
    });

    test('no DNSTT outbound without the flag', () {
      final cfg = decode(buildTunnelConfig(vless(), XraySettings()));
      final tags = (cfg['outbounds'] as List)
          .map((o) => (o as Map)['tag'])
          .toList();
      expect(tags, isNot(contains(dnsttUnderlayTag)));
    });

    test('the WG peer endpoint rewrites to the forwarder only', () {
      final on = decode(
        buildTunnelConfig(
          wg(),
          XraySettings(),
          wgWstunnelPort: wstunnelListenPort,
        ),
      );
      final peers =
          ((on['outbounds'] as List).first['settings'] as Map)['peers']
              as List;
      expect(
        (peers.first as Map)['endpoint'],
        '127.0.0.1:$wstunnelListenPort',
      );
      // The stored profile is never the thing rewritten.
      expect(wg().address, '203.0.113.7');
      final off = decode(buildTunnelConfig(wg(), XraySettings()));
      final offPeers =
          ((off['outbounds'] as List).first['settings'] as Map)['peers']
              as List;
      expect((offPeers.first as Map)['endpoint'], '203.0.113.7:51820');
    });
  });

  group('settings round-trip', () {
    test('the DNSTT + wstunnel fields survive JSON', () {
      final s = XraySettings()
        ..underlay = 'dnstt'
        ..dnsttResolverType = 'dot'
        ..dnsttResolver = '1.1.1.1:853'
        ..dnsttDomain = 't.example.com'
        ..dnsttPubkey = 'b' * 64
        ..wgWstunnel = true
        ..wgWstunnelUrl = 'wss://ws.example.com';
      final back = XraySettings.fromJson(s.toJson());
      expect(back.underlay, 'dnstt');
      expect(back.dnsttResolverType, 'dot');
      expect(back.dnsttResolver, '1.1.1.1:853');
      expect(back.dnsttDomain, 't.example.com');
      expect(back.dnsttPubkey, 'b' * 64);
      expect(back.wgWstunnel, isTrue);
      expect(back.wgWstunnelUrl, 'wss://ws.example.com');
    });

    test('a bad stored resolver type falls back to DoH', () {
      final j = XraySettings().toJson()..['dnsttResolverType'] = 'smoke';
      expect(XraySettings.fromJson(j).dnsttResolverType, 'doh');
    });
  });

  group('native wiring pins', () {
    test('the subprocess cores drain the streams separately', () {
      final base = ktSrc('SubprocessCore.kt');
      // Separate files per stream, per-line flush, a waiter
      // that turns an unexpected exit into stage=error.
      expect(base, contains('\$dirName-stdout.log'));
      expect(base, contains('\$dirName-stderr.log'));
      expect(base, contains('fun drain('));
      expect(base, contains('exited (code'));
      // Orphan reaping by pid file + cmdline match.
      expect(base, contains('/proc/\$pid/cmdline'));
      expect(ktSrc('DnsttCore.kt'), contains('libdnstt.so'));
      expect(ktSrc('DnsttCore.kt'), contains('20860'));
      expect(ktSrc('WstunnelCore.kt'), contains('libwstunnel.so'));
      expect(ktSrc('WstunnelCore.kt'), contains('20861'));
    });

    test('MainActivity serves the six channel calls', () {
      final main = ktSrc('MainActivity.kt');
      for (final call in [
        'dnsttStart',
        'dnsttStop',
        'dnsttState',
        'wstunnelStart',
        'wstunnelStop',
        'wstunnelState',
      ]) {
        expect(main, contains('"$call"'), reason: call);
      }
      expect(main, contains('call.argument<List<String>>("dnsttArgs")'));
      expect(main, contains('call.argument<Boolean>("wgWstunnel")'));
    });

    test('the service supervises, respawns and reaps both helpers', () {
      final svc = ktSrc('XrayVpnService.kt');
      // Health: DNSTT by process + readiness + TCP listener.
      expect(svc, contains('"dnstt" -> DnsttCore.running'));
      expect(svc, contains('probeTcp(DnsttCore.PORT)'));
      expect(svc, contains('DnsttCore.restart(this, sessionDnsttArgs)'));
      // wstunnel: fail-closed supervision with a budget.
      expect(svc, contains('if (sessionWgWstunnel)'));
      expect(svc, contains('WstunnelCore.restart(this, sessionWstunnelArgs)'));
      // Reaps on every stop path.
      expect(svc, contains('DnsttCore.stop()'));
      expect(svc, contains('WstunnelCore.stop()'));
      // The command lines ride the start intent.
      expect(svc, contains('EXTRA_DNSTT_ARGS'));
      expect(svc, contains('EXTRA_WSTUNNEL_ARGS'));
    });
  });

  group('controller + UI pins', () {
    test('the controller starts, gates and reaps the helpers', () {
      final c = dartSrc('xray/xray_controller.dart');
      expect(c, contains('_startDnsttUnderlay'));
      expect(c, contains("StateError('dnstt-not-configured')"));
      expect(c, contains('_startWstunnel'));
      expect(c, contains('dnsttUnderlay: dnsttChained'));
      expect(c, contains('wgWstunnelPort: _sessionWgWstunnelPort'));
      expect(c, contains('unawaited(DnsttPlatform.stop())'));
      expect(c, contains('unawaited(WstunnelPlatform.stop())'));
      // Seamless switch refuses a wstunnel session.
      expect(c, contains('wstunnelSession: _sessionWgWstunnelPort != 0'));
      // The helper logs are in the viewer + Clear.
      expect(c, contains('dnstt/dnstt-stderr.log'));
      expect(c, contains('wstunnel/wstunnel-stderr.log'));
    });

    test('the UI surfaces exist and state the server requirement', () {
      final home = dartSrc('ui/ember/ember_home.dart');
      expect(home, contains("label: 'DNSTT'"));
      expect(home, contains('openDnsttSettings(context, xray)'));
      final page = dartSrc('ui/ember/dnstt_settings_page.dart');
      expect(page, contains('dnstt-server must run'));
      expect(page, contains('Server public key'));
      expect(page, contains('saveDnsttSettings'));
      final wg = dartSrc('ui/ember/wireguard_pages.dart');
      expect(wg, contains('WireGuard over WebSocket'));
      expect(wg, contains('AmneziaWG-engine sessions are not wrapped'));
      expect(wg, contains('setWgWstunnelUrl'));
    });
  });
}
