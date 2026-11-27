/// The Psiphon engine's constants for the desktop ConsoleClient
/// core: a verbatim port of Android's PsiphonConstants.kt (build
/// 2157 — the MLM identity set plus the build-2129 Shiro set), so
/// the two platforms can never drift. Regenerate by copying any
/// changed value from PsiphonConstants.kt.
///
/// Two complete bootstrap identity sets live here and are never
/// mixed: the MLM set (the default) and the Shiro set (behind the
/// DEFAULT-OFF Shiro bootstrap setting). The tunnel core is
/// Psiphon tunnel-core v2.0.42 (GPLv3), the same pinned release
/// the Android AAR wraps.
library;

import 'dart:convert';

/// One remote-server-list location: the core's expected
/// {URL: base64(url), OnlyAfterAttempts, SkipVerify} triple.
typedef PsiphonUrlEntry = ({String url, int onlyAfterAttempts, bool skipVerify});

abstract final class PsiphonConstants {
  static const socksPort = 11808;
  static const httpPort = 11809;

  // ---- The MLM identity set (build 2091) ----
  static const clientVersion = '1';
  static const propagationChannelId = 'FFFFFFFFFFFFFFFF';
  static const sponsorId = '1111111111111111';
  static const remoteServerListSignaturePublicKey =
      'MIICIDANBgkqhkiG9w0BAQEFAAOCAg0AMIICCAKCAgEAt7Ls+/39r+T6zNW7GiVpJfzq/xvL9SBH5rIFnk0RXYEYavax3WS6HOD35eTAqn8AniOwiH+DOkvgSKF2caqk/y1dfq47Pdymtwzp9ikpB1C5OfAysXzBiwVJlCdajBKvBZDerV1cMvRzCKvKwRmvDmHgphQQ7WfXIGbRbmmk6opMBh3roE42KcotLFtqp0RRwLtcBRNtCdsrVsjiI1Lqz/lH+T61sGjSjQ3CHMuZYSQJZo/KrvzgQXpkaCTdbObxHqb6/+i1qaVOfEsvjoiyzTxJADvSytVtcTjijhPEV6XskJVHE1Zgl+7rATr/pDQkw6DPCNBS1+Y6fy7GstZALQXwEDN/qhQI9kWkHijT8ns+i1vGg00Mk/6J75arLhqcodWsdeG/M/moWgqQAnlZAGVtJI1OgeF5fsPpXu4kctOfuZlGjVZXQNW34aOzm8r8S0eVZitPlbhcPiR4gT/aSMz/wd8lZlzZYsje/Jr8u/YtlwjjreZrGRmG8KMOzukV3lLmMppXFMvl4bxv6YFEmIuTsOhbLTwFgh7KYNjodLj/LsqRVfwz31PgWQFTEPICV7GCvgVlPRxnofqKSjgTWI4mxDhBpVcATvaoBl1L/6WLbFvBsoAUBItWwctO2xalKxF5szhGm8lccoc5MZr8kfE0uxMgsxz4er68iCID+rsCAQM=';
  static const serverEntrySignaturePublicKey =
      'sHuUVTWaRyh5pZwy4UguSgkwmBe0EHtJJkoF5WrxmvA=';
  static const exchangeObfuscationKey =
      'DpXzloJk1Hw6aSzmKKky0xcahsEHubch81Mi6K0XMlU=';
  static const serverEntriesAsset = 'assets/psiphon/server_entries.txt';

  static const remoteServerListUrls = <PsiphonUrlEntry>[
    (
      url:
          'https://s3.amazonaws.com/psiphon/web/iohq-waa4-q4dt/server_list_compressed',
      onlyAfterAttempts: 0,
      skipVerify: false,
    ),
    (
      url:
          'https://www.gpallthingsnumberweather.com/web/iohq-waa4-q4dt/server_list_compressed',
      onlyAfterAttempts: 2,
      skipVerify: true,
    ),
    (
      url:
          'https://www.storagejsstrategiesfabulous.com/web/iohq-waa4-q4dt/server_list_compressed',
      onlyAfterAttempts: 2,
      skipVerify: true,
    ),
    (
      url:
          'https://www.diamondberlingamerplanet.com/web/iohq-waa4-q4dt/server_list_compressed',
      onlyAfterAttempts: 2,
      skipVerify: true,
    ),
  ];

  static const obfuscatedServerListRootUrls = <PsiphonUrlEntry>[
    (
      url: 'https://s3.amazonaws.com/psiphon/web/iohq-waa4-q4dt/osl',
      onlyAfterAttempts: 0,
      skipVerify: false,
    ),
    (
      url: 'https://www.gpallthingsnumberweather.com/web/iohq-waa4-q4dt/osl',
      onlyAfterAttempts: 2,
      skipVerify: true,
    ),
    (
      url: 'https://www.storagejsstrategiesfabulous.com/web/iohq-waa4-q4dt/osl',
      onlyAfterAttempts: 2,
      skipVerify: true,
    ),
    (
      url: 'https://www.diamondberlingamerplanet.com/web/iohq-waa4-q4dt/osl',
      onlyAfterAttempts: 2,
      skipVerify: true,
    ),
  ];

  /// The anti-hijack DNS trio (MLM's): public resolvers on
  /// non-standard ports, preferred over the operator's.
  static const dnsPreferredAlternateServers = <String>[
    '208.67.222.222:5353',
    '9.9.9.9:9953',
    '208.67.220.220:5353',
  ];

  static const frontingProviderAkamai = 'BACEC04E64813F2B';
  static const frontingProviderFastly = '089D05B86ACE8D3B';

  static const frontedProtocols = <String>[
    'FRONTED-MEEK-OSSH',
    'FRONTED-MEEK-HTTP-OSSH',
    'FRONTED-MEEK-QUIC-OSSH',
  ];

  static const chainableProtocols = <String>[
    'FRONTED-MEEK-OSSH',
    'FRONTED-MEEK-HTTP-OSSH',
    'TLS-OSSH',
    'UNFRONTED-MEEK-HTTPS-OSSH',
    'UNFRONTED-MEEK-OSSH',
    'SHADOWSOCKS-OSSH',
    'OSSH',
    'SSH',
  ];

  static const directProtocols = <String>[
    'QUIC-OSSH',
    'TLS-OSSH',
    'UNFRONTED-MEEK-HTTPS-OSSH',
    'UNFRONTED-MEEK-OSSH',
    'SHADOWSOCKS-OSSH',
    'CONJURE-OSSH',
    'OSSH',
    'SSH',
  ];

  // ---- Build 2129 (Leg 2): the Shiro bootstrap identity set ----
  // The public bootstrap published with the Shirokhorshid
  // Android release (Shirokhorshid/MehrON, GPL-3.0-or-later),
  // adopted WHOLESALE as one set; the two signature keys and
  // the exchange key are the same values as the MLM set's.
  static const shiroClientVersion = '453';
  static const shiroPropagationChannelId = 'EE0B7486ACAE75AA';
  static const shiroSponsorId = '07D1ACD69B3AC7A2';
  static const shiroRemoteServerListSignaturePublicKey =
      remoteServerListSignaturePublicKey;
  static const shiroServerEntrySignaturePublicKey =
      serverEntrySignaturePublicKey;
  static const shiroExchangeObfuscationKey = exchangeObfuscationKey;
  static const shiroServerEntriesAsset =
      'assets/psiphon/server_list_shiro.dat';
  static const shiroFrontingAsset =
      'assets/psiphon/shiro_fronting_default.json';

  static const shiroRemoteServerListUrls = <PsiphonUrlEntry>[
    (
      url:
          'https://s3.amazonaws.com/psiphon/web/frh2-29ub-lhe0/server_list_compressed',
      onlyAfterAttempts: 0,
      skipVerify: false,
    ),
    (
      url:
          'https://s3.amazonaws.com/psiphon/web/mjr4-p23r-puwl/server_list_compressed',
      onlyAfterAttempts: 0,
      skipVerify: false,
    ),
    (
      url:
          'https://s3.amazonaws.com/psiphon/web/yttm-zeis-pjjd/server_list_compressed',
      onlyAfterAttempts: 0,
      skipVerify: false,
    ),
  ];

  static const shiroObfuscatedServerListRootUrls = <PsiphonUrlEntry>[
    (
      url: 'https://s3.amazonaws.com/psiphon/web/frh2-29ub-lhe0/osl',
      onlyAfterAttempts: 0,
      skipVerify: false,
    ),
    (
      url: 'https://s3.amazonaws.com/psiphon/web/mjr4-p23r-puwl/osl',
      onlyAfterAttempts: 0,
      skipVerify: false,
    ),
    (
      url: 'https://s3.amazonaws.com/psiphon/web/yttm-zeis-pjjd/osl',
      onlyAfterAttempts: 0,
      skipVerify: false,
    ),
  ];

  static const shiroUseIndistinguishableTls = true;
  static const shiroFrontedMeekCdnScanUseBuiltInSpec = true;
  static const shiroTunnelPoolSize = 1;

  // ---- The ladder (PsiphonMethods.kt) ----

  /// The automatic ladder's order, before the remembered rung
  /// is moved to the front. (P is in the list MLM ships; the
  /// ladder builder filters it out of automatic runs.)
  static const ladderOrder = <String>['A', 'E', 'D', 'C', 'P'];

  /// Seconds one rung may take before the next one gets its
  /// turn. X: per proxy.
  static int methodSeconds(String name) => switch (name) {
        'A' => 60,
        'E' => 45,
        'D' => 45,
        'C' => 75,
        'P' => 90,
        'X' => 45,
        _ => 45,
      };

  static String methodLabel(String name) => switch (name) {
        'A' => 'Domain fronting (CDN)',
        'E' => 'Clean IP',
        'D' => 'All protocols (direct)',
        'C' => 'Relay through other users',
        'P' => 'Personal Conduit',
        'X' => 'Proxy server',
        _ => 'Automatic',
      };

  /// The preferred-country phase's budget (seconds).
  static const regionPhaseTimeoutSeconds = 25;

  /// Grace added to a rung's budget before escalation, so the
  /// core's own timeout fires first.
  static const ladderGraceSeconds = 8;

  /// The pause between stopping one rung's core and starting
  /// the next (milliseconds).
  static const rungRestartPauseMs = 1200;
}

/// The URL list in the core's expected object shape
/// (PsiphonVpnService.psiphonUrlList).
List<Map<String, dynamic>> psiphonUrlList(List<PsiphonUrlEntry> entries) => [
      for (final e in entries)
        {
          'URL': base64Encode(utf8.encode(e.url)),
          'OnlyAfterAttempts': e.onlyAfterAttempts,
          'SkipVerify': e.skipVerify,
        },
    ];
