/// The Windows Psiphon host's ConsoleClient config must carry
/// Android build 2157's buildPsiphonConfig contract (the MLM
/// host in PsiphonVpnService.kt) with the same constants
/// (PsiphonConstants.kt) — the network only accepts the real
/// set. The long opaque values are pinned by length and
/// endpoints so a transcription slip fails here instead of on
/// a user's machine.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:firefox_vpn/psiphon/psiphon_bootstrap.dart';
import 'package:firefox_vpn/psiphon/psiphon_platform_windows.dart';

void main() {
  test('constants are the pinned 2157 MLM set', () {
    expect(PsiphonConstants.clientVersion, '1');
    expect(PsiphonConstants.propagationChannelId, 'FFFFFFFFFFFFFFFF');
    expect(PsiphonConstants.sponsorId, '1111111111111111');
    expect(
      PsiphonConstants.serverEntrySignaturePublicKey,
      'sHuUVTWaRyh5pZwy4UguSgkwmBe0EHtJJkoF5WrxmvA=',
    );
    expect(
      PsiphonConstants.exchangeObfuscationKey,
      'DpXzloJk1Hw6aSzmKKky0xcahsEHubch81Mi6K0XMlU=',
    );
    final rsl = PsiphonConstants.remoteServerListSignaturePublicKey;
    expect(rsl.length, 732);
    expect(rsl, startsWith('MIICIDANBgkqhkiG9w0BAQEFAAOCAg0AMIICCAKCAgEA'));
    expect(rsl, endsWith('CAQM='));
    expect(PsiphonConstants.dnsPreferredAlternateServers, [
      '208.67.222.222:5353',
      '9.9.9.9:9953',
      '208.67.220.220:5353',
    ]);
    expect(PsiphonConstants.ladderOrder, ['A', 'E', 'D', 'C', 'P']);
    expect(PsiphonConstants.methodSeconds('A'), 60);
    expect(PsiphonConstants.methodSeconds('C'), 75);
    expect(PsiphonConstants.methodSeconds('P'), 90);
  });

  test('the Shiro set is whole and never mixed', () {
    expect(PsiphonConstants.shiroClientVersion, '453');
    expect(PsiphonConstants.shiroPropagationChannelId, 'EE0B7486ACAE75AA');
    expect(PsiphonConstants.shiroSponsorId, '07D1ACD69B3AC7A2');
    expect(
      PsiphonConstants.shiroRemoteServerListSignaturePublicKey,
      PsiphonConstants.remoteServerListSignaturePublicKey,
    );
    expect(PsiphonConstants.shiroRemoteServerListUrls.length, 3);
    expect(
      PsiphonConstants.shiroRemoteServerListUrls.first.url,
      contains('/web/frh2-29ub-lhe0/'),
    );
  });

  test('base config keys match buildPsiphonConfig', () {
    final built = buildPsiphonSessionConfig(
      shiro: false,
      strongMode: false,
      dataRootPath: 'D',
      socksPort: 11808,
      httpPort: 11809,
      rung: null,
      regionPhase: false,
      region: '',
      regionFronted: false,
      cleanCidrs: null,
      shiroCidrs: const {},
      compartment: '',
    );
    final cfg = built.config;
    expect(cfg['ClientVersion'], '1');
    expect(cfg['PropagationChannelId'], 'FFFFFFFFFFFFFFFF');
    expect(cfg['SponsorId'], '1111111111111111');
    expect(cfg['DataRootDirectory'], 'D');
    expect(cfg['LocalSocksProxyPort'], 11808);
    expect(cfg['LocalHttpProxyPort'], 11809);
    expect(cfg['EgressRegion'], '');
    expect(cfg['EstablishTunnelTimeoutSeconds'], 120);
    expect(cfg['EmitBytesTransferred'], isTrue);
    expect(cfg['EmitDiagnosticNotices'], isTrue);
    expect(cfg['DeviceRegion'], 'IR');
    expect(cfg['ConnectionWorkerPoolSize'], 12);
    expect(cfg['DNSResolverPreferAlternateServerProbability'], 1.0);
    expect(cfg['DNSResolverAttemptsPerPreferredServer'], 2);
    expect(cfg.containsKey('AdditionalParameters'), isFalse);
    expect(cfg.containsKey('AggressiveEstablishment'), isFalse);
    expect(cfg.containsKey('UseIndistinguishableTLS'), isFalse);
    // The URL list rides in the core's object shape.
    final urls = cfg['RemoteServerListURLs'] as List;
    expect(urls.length, 4);
    final first = urls.first as Map;
    expect(
      utf8.decode(base64Decode(first['URL'] as String)),
      'https://s3.amazonaws.com/psiphon/web/iohq-waa4-q4dt/server_list_compressed',
    );
    expect(first['OnlyAfterAttempts'], 0);
    expect(first['SkipVerify'], isFalse);
  });

  test('rung A limits to the fronted set with the tactics override', () {
    final built = buildPsiphonSessionConfig(
      shiro: false,
      strongMode: false,
      dataRootPath: 'D',
      socksPort: 11808,
      httpPort: 11809,
      rung: const PsiphonRung(
        'A',
        preferredProtocols: PsiphonConstants.frontedProtocols,
      ),
      regionPhase: false,
      region: '',
      regionFronted: false,
      cleanCidrs: null,
      shiroCidrs: const {},
      compartment: '',
    );
    final cfg = built.config;
    expect(cfg['LimitTunnelProtocols'], PsiphonConstants.frontedProtocols);
    expect(cfg['InitialLimitTunnelProtocolsCandidateCount'], 30);
    expect(cfg['EstablishTunnelTimeoutSeconds'], 60);
    expect(cfg['NetworkLatencyMultiplier'], 2.0);
    expect(cfg['DisableTactics'], isTrue);
    expect(cfg['InproxyEnabled'], isFalse);
  });

  test('rung X rides the upstream with the chainable set, no tactics cut', () {
    final built = buildPsiphonSessionConfig(
      shiro: false,
      strongMode: false,
      dataRootPath: 'D',
      socksPort: 11808,
      httpPort: 11809,
      rung: const PsiphonRung(
        'X',
        preferredProtocols: PsiphonConstants.directProtocols,
        dataRootName: 'psiphon-upstream',
        upstream: 'socks5://127.0.0.1:8080',
      ),
      regionPhase: false,
      region: '',
      regionFronted: false,
      cleanCidrs: null,
      shiroCidrs: const {},
      compartment: '',
    );
    final cfg = built.config;
    expect(cfg['UpstreamProxyURL'], 'socks5://127.0.0.1:8080');
    expect(cfg['LimitTunnelProtocols'], PsiphonConstants.chainableProtocols);
    expect(cfg['EstablishTunnelTimeoutSeconds'], 45);
    expect(cfg.containsKey('DisableTactics'), isFalse);
  });

  test('region phase owns the timeout and drops the limit when unfronted', () {
    final built = buildPsiphonSessionConfig(
      shiro: false,
      strongMode: false,
      dataRootPath: 'D',
      socksPort: 11808,
      httpPort: 11809,
      rung: const PsiphonRung(
        'A',
        preferredProtocols: PsiphonConstants.frontedProtocols,
      ),
      regionPhase: true,
      region: 'JP',
      regionFronted: false,
      cleanCidrs: null,
      shiroCidrs: const {},
      compartment: '',
    );
    final cfg = built.config;
    expect(cfg['EgressRegion'], 'JP');
    expect(cfg['EstablishTunnelTimeoutSeconds'], 25);
    expect(cfg.containsKey('LimitTunnelProtocols'), isFalse);
  });

  test('shiro swaps the whole identity and adds its shaping keys', () {
    final built = buildPsiphonSessionConfig(
      shiro: true,
      strongMode: true,
      dataRootPath: 'D',
      socksPort: 11808,
      httpPort: 11809,
      rung: null,
      regionPhase: false,
      region: '',
      regionFronted: false,
      cleanCidrs: null,
      shiroCidrs: const {},
      compartment: '',
    );
    final cfg = built.config;
    expect(cfg['ClientVersion'], '453');
    expect(cfg['PropagationChannelId'], 'EE0B7486ACAE75AA');
    expect(cfg['SponsorId'], '07D1ACD69B3AC7A2');
    expect(cfg['UseIndistinguishableTLS'], isTrue);
    expect(cfg['TunnelPoolSize'], 1);
    expect(cfg['AggressiveEstablishment'], isTrue);
    final urls = cfg['RemoteServerListURLs'] as List;
    expect(urls.length, 3);
  });

  test('upstream splitting and proxy masking', () {
    expect(
      parsePsiphonUpstreams('socks5://a:1, http://b:2\nsocks5://c:3'),
      ['socks5://a:1', 'http://b:2', 'socks5://c:3'],
    );
    expect(
      maskedPsiphonProxy('socks5://user:pass@127.0.0.1:8080'),
      'socks5://•••@127.0.0.1:8080',
    );
    expect(maskedPsiphonProxy('socks5://127.0.0.1:8080'),
        'socks5://127.0.0.1:8080');
  });
}
