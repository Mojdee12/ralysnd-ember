/// Connection shapes for the watchdog escalation and the
/// winning-shape cache (build 2029A, after the Alan-RIP-Dpi
/// audit's shape-rotation pattern): three pre-built variants
/// of a profile's outbound, tried in order when a session
/// stalls. Shapes only reshape the TLS layer, so they exist
/// only for TLS profiles; anything else has the stock shape
/// alone and the watchdog falls through to a core restart +
/// the adaptive failover, as before.
///
/// - s0 "stock": the profile exactly as stored (which may
///   itself carry the user's anti-filter options).
/// - s1 "tls-fragment": s0 plus the F12 ClientHello fragment
///   shape (75-byte records, 15 ms apart).
/// - s2 "unsafe-ciphers": s0 with the "unsafe" fingerprint
///   and the unfilter cipher-suite order — the combination
///   stock Xray's cipherSuites support (PR #6450) requires.
/// - s3 "dialmode-oob" (build 2030): s0 with the patched
///   core's dialMode set to PattNG's preset "oob.0" — an
///   urgent byte appended to the first write, desyncing a
///   DPI middlebox's view of the ClientHello. Only the
///   patched core honours the field, so this shape ships
///   with the patched binary and never before it.

import 'anti_filter.dart';
import 'xray_models.dart';

const shapeStock = 's0';
const shapeFragment = 's1';
const shapeUnsafeCiphers = 's2';
const shapeDialMode = 's3';

/// The fragment shape the s1 escalation uses.
const watchdogFragmentShape = 'f12';

/// The dialMode preset the s3 escalation uses.
const watchdogDialModePreset = 'oob.0';

/// Human label for a shape id (diagnostics + UI).
String shapeLabel(String shapeId) => switch (shapeId) {
  shapeFragment => 'TLS fragment (F12)',
  shapeUnsafeCiphers => 'unsafe fingerprint + cipher suites',
  shapeDialMode => 'dialMode urgent byte (oob.0)',
  _ => 'stock',
};

/// The shapes worth trying for [p], in escalation order.
/// Only TLS profiles have anywhere to escalate to.
List<String> shapesFor(Profile p) => p.security == 'tls'
    ? const [shapeStock, shapeFragment, shapeUnsafeCiphers, shapeDialMode]
    : const [shapeStock];

/// A copy of [p] reshaped as [shapeId] (s0 returns [p] itself:
/// the stock shape is the stored profile, unmodified). The
/// copy keeps the profile's id — it is the same profile,
/// dialed differently.
Profile profileWithShape(Profile p, String shapeId) {
  switch (shapeId) {
    case shapeFragment:
      return p.copy()..afFragment = watchdogFragmentShape;
    case shapeUnsafeCiphers:
      return p.copy()
        ..fingerprint = 'unsafe'
        ..cipherSuites = afUnfilterCipherSuites;
    case shapeDialMode:
      return p.copy()..dialMode = watchdogDialModePreset;
    default:
      return p;
  }
}
