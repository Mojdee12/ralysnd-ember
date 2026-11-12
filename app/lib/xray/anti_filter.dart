/// Anti-filter TLS shaping for V2Ray profiles (build 2026,
/// Stage A): reshapes a profile's TLS ClientHello in the
/// generated Xray config so filtered networks see a different
/// handshake than the stock one.
///
/// Ported logic (Kotlin → Dart, behaviour only):
/// - the "unfilter" SNI mode, the ECH shape and the default
///   tlshello fragment mask: XrayJsonGenerator.kt /
///   CfUnfilter.kt / CfShape.kt (FRAG_FP / ECH shapes, the
///   PattNG semi-python cipher order, the transport ALPN rules,
///   and the precedence: ECH beats unfilter; an explicit
///   fragment shape beats the unfilter default mask).
/// - the F-family ClientHello split recipes: cfdoctor/Wire.kt
///   (ClientHelloSplit.recipe), expressed through the bundled
///   core's own finalmask fragmenter (streamSettings.finalmask,
///   packets "tlshello": each segment is re-wrapped in its own
///   TLS record — the record structure a filter sees).
/// - mixed-case SNI: AntiDpi.kt (generateMixedCaseSNI).
///
/// Two Wire recipes are NOT portable to a static config and are
/// deliberately absent: F4 (sni-dynamic) and F5 (sni+chunk16)
/// search the live ClientHello bytes for the SNI offset at
/// runtime; Xray's finalmask fragmenter accepts only numeric
/// segment lengths (transport/internet/finalmask/fragment/
/// config.proto), so no JSON can express them. Mixed-case SNI
/// covers part of their intent. Stated in BUILD-LOG-2 (2026).

import 'dart:math';

import 'xray_models.dart';

/// The unfilter cipher-suite order (the "PattNG semi-python
/// list"): offering exactly these suites, in this order, is
/// part of the unfilter fingerprint.
const afUnfilterCipherSuites =
    'TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384:'
    'TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384:'
    'TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256:'
    'TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256:'
    'TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256:'
    'TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256:'
    'TLS_ECDHE_ECDSA_WITH_AES_256_CBC_SHA:'
    'TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA:'
    'TLS_ECDHE_ECDSA_WITH_AES_128_CBC_SHA256:'
    'TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA256';

/// The ECH shape's config-list source: Cloudflare's public ECH
/// keys, fetched by the core over DoH at handshake time.
const afEchConfigList = 'cloudflare-ech.com+udp://1.1.1.1';

/// One ClientHello fragmentation shape: the segment lengths
/// (bytes) the finalmask fragmenter cuts the hello into, the
/// per-segment delays (ms, clamped to the last entry for later
/// segments), and the optional split cap. Mirrors Wire.kt's
/// F-recipes as closely as a static finalmask can.
class AfFragmentShape {
  const AfFragmentShape(
    this.id,
    this.label,
    this.lengths,
    this.delays, {
    this.maxSplit = '',
  });

  /// The stored shape id on [Profile.afFragment].
  final String id;

  /// The picker label (English, Latin digits).
  final String label;
  final List<String> lengths;
  final List<String> delays;

  /// '' = no cap (the key is omitted, like the recipes that
  /// chunk to the end of the hello).
  final String maxSplit;

  /// The finalmask tcp entry for this shape.
  Map<String, dynamic> entry() => {
        'type': 'fragment',
        'settings': {
          'packets': 'tlshello',
          'lengths': lengths,
          'delays': delays,
          if (maxSplit.isNotEmpty) 'maxSplit': maxSplit,
        },
      };
}

/// The shipped F-family shapes, in recipe order. F4/F5 are
/// absent for the reason in this file's header.
const afFragmentShapes = <AfFragmentShape>[
  AfFragmentShape('f1', 'F1 · First byte alone', ['1'], ['0'], maxSplit: '2'),
  AfFragmentShape(
      'f2', 'F2 · Split after 5 bytes', ['5'], ['0'], maxSplit: '2'),
  AfFragmentShape(
      'f3', 'F3 · Split at 5, then 1-byte records', ['5', '1'], ['0']),
  AfFragmentShape('f6', 'F6 · 16-byte records, 10 ms apart', ['16'], ['10']),
  AfFragmentShape('f7', 'F7 · 32-byte records, 50 ms apart', ['32'], ['50']),
  AfFragmentShape('f8', 'F8 · Two records, split in the middle', ['300'],
      ['0'],
      maxSplit: '2'),
  AfFragmentShape('f9', 'F9 · 300-byte record, then 32-byte records',
      ['300', '32'], ['0']),
  AfFragmentShape(
      'f12', 'F12 · 75-byte records, 15 ms apart', ['75'], ['15']),
  AfFragmentShape(
      'f13', 'F13 · 150-byte records, 15 ms apart', ['150'], ['15']),
  AfFragmentShape('f14', 'F14 · 1-byte records, 1 ms apart', ['1'], ['1']),
  AfFragmentShape('f15', 'F15 · Split at 5, then 1-byte records, 1 ms apart',
      ['5', '1'], ['0', '1']),
];

/// The shape stored under [id], or null ('' and unknown ids
/// both mean "no explicit shape").
AfFragmentShape? afShapeById(String id) {
  for (final shape in afFragmentShapes) {
    if (shape.id == id) return shape;
  }
  return null;
}

/// The unfilter shape's default fragment mask ("tlshello-0-len"
/// in the source): a zero-length first record, a 104-byte
/// record, then 1-byte records; then a second mask pass over
/// the first raw packet. Emitted verbatim.
List<Map<String, dynamic>> afUnfilterFinalmask() => [
      {
        'type': 'fragment',
        'settings': {
          'packets': 'tlshello',
          'lengths': ['0', '104', '1'],
          'delays': ['0'],
          'maxSplit': '0',
        },
      },
      {
        'type': 'fragment',
        'settings': {
          'packets': '1-1',
          'lengths': ['114', '1'],
          'delays': ['1'],
          'maxSplit': '11',
        },
      },
    ];

bool _isIpLiteral(String a) =>
    a.contains(':') || RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(a);

/// Randomises the letter case of a host name ("blog.example.com"
/// → "BlOG.ExamPle.coM"): DNS and TLS server names are
/// case-insensitive, but a case-sensitive SNI filter sees a
/// different string. Non-letters pass through unchanged.
String mixCaseSni(String host, {Random? rng}) {
  final random = rng ?? Random();
  final out = StringBuffer();
  for (final unit in host.codeUnits) {
    final isLetter =
        (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A);
    if (!isLetter) {
      out.writeCharCode(unit);
    } else if (random.nextBool()) {
      out.write(String.fromCharCode(unit).toUpperCase());
    } else {
      out.write(String.fromCharCode(unit).toLowerCase());
    }
  }
  return out.toString();
}

/// Plain-language findings about a profile's TLS settings
/// (build 2029A): the checks the editor shows before a config
/// is saved and the diagnostics surface can quote. Empty when
/// the settings are consistent. Only TLS profiles are checked
/// — the fields named here exist only there.
List<String> tlsSettingsCheck(Profile p) {
  final findings = <String>[];
  if (p.security != 'tls') return findings;
  if (p.cipherSuites.isNotEmpty && p.fingerprint != 'unsafe') {
    findings.add(
      'Cipher suites are set, but the core only honours them '
      'with the "unsafe" fingerprint. Set the fingerprint to '
      'unsafe, or clear the cipher suites.',
    );
  }
  if (p.network == 'ws' || p.network == 'httpupgrade') {
    final alpn = p.alpn
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    if (alpn.isNotEmpty && !alpn.contains('http/1.1')) {
      findings.add(
        'This transport usually needs ALPN http/1.1 (the '
        'profile currently offers ${p.alpn}).',
      );
    }
  }
  return findings;
}

/// Applies [p]'s anti-filter options to a built streamSettings
/// map (mutates [stream]). Called at the end of config building
/// for the standard transports; a no-op unless the profile's
/// security is TLS (REALITY and plain streams are never
/// reshaped, and Hysteria2 builds its own stream settings and
/// is not shaped here).
///
/// Precedence (the source's): ECH on → the ECH shape alone
/// (chrome fingerprint + echConfigList; the unfilter ciphers
/// and every fragment mask are suppressed). Otherwise the
/// unfilter shape applies (unsafe fingerprint, the PattNG
/// cipher order, transport ALPN defaults, the tlshello-0-len
/// mask), and an explicit fragment shape replaces that default
/// mask. Mixed-case SNI applies on top of either.
void applyAntiFilter(Map<String, dynamic> stream, Profile p, {Random? rng}) {
  if (p.security != 'tls') return;
  final tls = stream['tlsSettings'];
  if (tls is! Map<String, dynamic>) return;

  if (p.afEch) {
    tls['fingerprint'] = 'chrome';
    tls['echConfigList'] = afEchConfigList;
    stream.remove('finalmask');
  } else {
    if (p.afUnfilter) {
      tls['fingerprint'] = 'unsafe';
      tls['cipherSuites'] = afUnfilterCipherSuites;
      // Transport ALPN defaults, only when the profile carries
      // no ALPN of its own (the source's applyLinkedAlpn rule).
      if (tls['alpn'] == null) {
        if (p.network == 'ws' || p.network == 'httpupgrade') {
          tls['alpn'] = ['http/1.1'];
        } else if (p.network == 'xhttp' || p.network == 'splithttp') {
          tls['alpn'] = ['h2', 'http/1.1'];
        }
      }
      stream['finalmask'] = {'tcp': afUnfilterFinalmask()};
    }
    final shape = afShapeById(p.afFragment);
    if (shape != null) {
      // An explicit shape wins over the unfilter default mask.
      stream['finalmask'] = {
        'tcp': [shape.entry()],
      };
    }
  }

  if (p.afMixedSni) {
    final sni = tls['serverName'];
    if (sni is String && sni.isNotEmpty && !_isIpLiteral(sni)) {
      final mixed = mixCaseSni(sni, rng: rng);
      tls['serverName'] = mixed;
      // The same host name rides the transport's Host fields;
      // the source mixes the link's sni and host params together.
      final ws = stream['wsSettings'];
      if (ws is Map<String, dynamic>) {
        final headers = ws['headers'];
        if (headers is Map<String, dynamic> && headers['Host'] != null) {
          headers['Host'] = mixed;
        }
      }
      final hu = stream['httpupgradeSettings'];
      if (hu is Map<String, dynamic> && hu['host'] != null) {
        hu['host'] = mixed;
      }
      final xh = stream['xhttpSettings'];
      if (xh is Map<String, dynamic> && xh['host'] != null) {
        xh['host'] = mixed;
      }
    }
  }
}
