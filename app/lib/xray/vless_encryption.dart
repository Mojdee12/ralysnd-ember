/// VLESS Encryption (mlkem768) validation — build 2046.
///
/// The bundled core (patterniha/xray-core @ 12fd84e = XTLS v26.11.1)
/// supports a post-quantum-encrypted VLESS user: the outbound user's
/// `encryption` field carries
/// `mlkem768x25519plus.<mode>.<rtt>.<key parts>`, validated in the
/// core's `infra/conf/vless.go` (client branch). This file mirrors
/// that rule exactly — the core is the authority, so a value the
/// core accepts must be storable here, and a value the core would
/// refuse must never reach the emitted config.
///
/// The rule, from the core source:
/// - dot-separated parts, at least 4, the first `mlkem768x25519plus`;
/// - the second part is the mode: `native`, `xorpub` or `random`;
/// - the third part is the round-trip mode: `0rtt` or `1rtt`;
/// - every part after that is either a short padding prefix (under
///   20 characters — the core treats it as padding and skips it)
///   or a base64url (no padding) key that decodes to 32 or 1184
///   bytes. At least one real key part is required: the core's
///   validator accepts a value made only of short padding parts,
///   then panics slicing the empty remainder
///   (`account.Encryption[padding:]` past the end) — such a value
///   can never connect, so it is not valid here.
///
/// The core REQUIRES the field be set for every VLESS user
/// (`'none'` or a valid value); an empty or invalid value makes the
/// core refuse the whole config. The builder therefore re-validates
/// at emit time and falls back to `'none'`, so a corrupt store can
/// never break a connect (the build 2041 lesson).
library;

import 'dart:convert';

/// True when [value] is a VLESS Encryption string the bundled core
/// accepts as an outbound user's `encryption` value.
bool isValidVlessEncryption(String value) {
  final parts = value.split('.');
  if (parts.length < 4) return false;
  if (parts[0] != 'mlkem768x25519plus') return false;
  switch (parts[1]) {
    case 'native':
    case 'xorpub':
    case 'random':
      break;
    default:
      return false;
  }
  switch (parts[2]) {
    case '0rtt':
    case '1rtt':
      break;
    default:
      return false;
  }
  var sawKey = false;
  for (final part in parts.skip(3)) {
    // Short parts are padding prefixes — the core skips them
    // without decoding.
    if (part.length < 20) continue;
    // The core decodes with base64.RawURLEncoding — no padding
    // allowed — so a padded part is one the core would refuse.
    if (part.contains('=')) return false;
    try {
      final decoded = base64Url.decode(base64Url.normalize(part));
      if (decoded.length != 32 && decoded.length != 1184) return false;
      sawKey = true;
    } on FormatException {
      return false;
    }
  }
  // A value with no real key part is one the core's own slicing
  // panics on — it can never connect, so it is not valid here.
  return sawKey;
}

/// The short display form of a valid encryption value — the scheme,
/// the mode and the round-trip mode — for editor captions and
/// diagnostics. Returns '' for an invalid value.
String vlessEncryptionSummary(String value) {
  if (!isValidVlessEncryption(value)) return '';
  final parts = value.split('.');
  return 'mlkem768x25519plus · ${parts[1]} · ${parts[2] == '0rtt' ? '0-RTT' : '1-RTT'}';
}
