import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Build 2117 — Persian (fa) localization completeness.
///
/// The English ARB is the source of truth. Persian must carry every key,
/// keep every placeholder, and never fall back to the English text except
/// for the allowlisted brand/protocol tokens below.
void main() {
  final en = jsonDecode(File('lib/l10n/app_en.arb').readAsStringSync())
      as Map<String, dynamic>;
  final fa = jsonDecode(File('lib/l10n/app_fa.arb').readAsStringSync())
      as Map<String, dynamic>;

  Map<String, String> strings(Map<String, dynamic> arb) => {
        for (final e in arb.entries)
          if (!e.key.startsWith('@')) e.key: e.value as String,
      };

  final enStrings = strings(en);
  final faStrings = strings(fa);

  /// Values that are correct left identical to English: the brand name,
  /// protocol/product names and acronyms that Persian UI keeps in Latin
  /// script, and the `Seed` config-field token as it appears in configs.
  const identicalAllowlist = {
    'appTitle', // Ralysnd Ember — brand name
    'sectionDns', // DNS
    'dnsSection', // DNS
    'transportH3', // HTTP/3 (QUIC)
    'transportH2', // HTTP/2 (TCP)
    'modeVpn', // VPN
    'psiphonVpnMode', // VPN
    'modeV2ray', // V2Ray
    'fieldSeed', // Seed — config token
  };

  Set<String> placeholders(String s) => RegExp(r'\{([A-Za-z_][A-Za-z0-9_]*)\s*(?:,|\})')
      .allMatches(s)
      .map((m) => m.group(1)!)
      .toSet();

  test('fa has every en key and no extras', () {
    final missing = enStrings.keys.toSet().difference(faStrings.keys.toSet());
    final extra = faStrings.keys.toSet().difference(enStrings.keys.toSet());
    expect(missing, isEmpty, reason: 'keys missing in fa: $missing');
    expect(extra, isEmpty, reason: 'keys only in fa: $extra');
  });

  test('no fa string is left identical to English outside the allowlist', () {
    final identical = <String>[
      for (final k in enStrings.keys)
        if (faStrings[k] == enStrings[k] && !identicalAllowlist.contains(k)) k,
    ];
    expect(identical, isEmpty,
        reason: 'untranslated (identical to en): $identical');
  });

  test('every fa string is non-empty and keeps the en placeholders', () {
    for (final k in enStrings.keys) {
      final v = faStrings[k];
      expect(v, isNotNull, reason: '$k missing in fa');
      expect(v!.trim(), isNotEmpty, reason: '$k is empty in fa');
      expect(placeholders(v), placeholders(enStrings[k]!),
          reason: '$k placeholders differ from en');
    }
  });
}
