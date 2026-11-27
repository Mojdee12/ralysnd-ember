/// Build 2095 (fourth-pass audit 4.1 / 2.1 / 1.4 / 1.5):
/// the ONE import-boundary validation module. The editor
/// has range-checked its own fields since build 2092, but
/// every other route in — share links, subscription
/// bodies, Clash YAML, Xray JSON, .conf files, backup and
/// sync documents, the store itself — admitted values the
/// cores reject wholesale (port 99999, MTU 0, a Snell
/// version sing-box does not know, enum strings like
/// `type=banana`). One bad value made the whole emitted
/// config unloadable, surfacing only as a failed start.
///
/// Every parser and [Profile.fromJson] runs its products
/// through [sanitizeImportedProfile]: numerics are
/// repaired to the documented ranges, enum-like strings
/// are whitelisted to the values the bundled cores
/// accept, unsupported combinations (vision flow on a
/// WebSocket transport) are coerced to the nearest
/// supported shape, AWG values are stripped of anything
/// that could break out of their UAPI line, and display
/// names lose the control characters that forge log
/// lines and spoof list text. Build 2096 narrowed the
/// flattening the first version over-applied: repairs
/// that would change what a profile MEANS (Mieru's UDP
/// transport, AWG ranges, a REALITY pairing, an unknown
/// security value) are no longer made silently here —
/// see the per-fix notes below.
/// Repairs are silent at this layer because the repaired
/// values are what the UI then shows — the profile never
/// displays a number the core will not be given.
library;

import 'xray_models.dart';

// The name sanitizer lives on the model (build 2096) so
// Profile.fromJson can apply it without an import cycle;
// re-exported here for this module's existing callers.
export 'xray_models.dart' show sanitizeProfileName;

/// Transport networks the bundled Xray fork's stream
/// layer implements (config_builder's switch).
const Set<String> kProfileNetworks = {
  'tcp',
  'kcp',
  'ws',
  'grpc',
  'quic',
  'http',
  'h2',
  'httpupgrade',
  'xhttp',
  'splithttp',
  'raw',
};

/// Stream security values the core accepts.
const Set<String> kProfileSecurities = {'', 'none', 'tls', 'reality'};

/// XHTTP modes the core accepts (the editor's clamp set).
const Set<String> kXhttpModes = {
  'auto',
  'packet-up',
  'stream-up',
  'stream-one',
};

/// TUIC congestion controllers sing-box accepts.
const Set<String> kTuicCongestion = {'cubic', 'new_reno', 'bbr'};

/// TUIC UDP relay modes sing-box accepts.
const Set<String> kTuicUdpRelayModes = {'native', 'quic'};

/// The most profiles one import (paste, subscription
/// fetch, backup) may add — past this the excess counts
/// as skipped (fourth-pass audit 1.1).
const int kMaxImportedProfiles = 5000;

/// The largest subscription body the fetcher will read,
/// counted AFTER decompression (fourth-pass audit 1.1).
const int kMaxSubscriptionBodyBytes = 16 * 1024 * 1024;

/// A port the cores will accept; anything else becomes
/// the parsers' own default.
int sanitizeProfilePort(int v) => (v >= 1 && v <= 65535) ? v : 443;

/// WireGuard MTU inside the range the editor enforces.
int sanitizeWgMtu(int v) => (v >= 576 && v <= 9000) ? v : 1420;

/// Snell versions the bundled sing-box 1.14.4 loads:
/// 1–4. Its version-5 shape is refused by the core's
/// config check (the model's own note and the editor's
/// maximum agree), so a v5 import is clamped to 4 here
/// instead of being admitted as a profile that can
/// never connect (build 2096, post-2095 audit M3).
/// Build 2097 (post-2096 audit L-b): a real clamp — build
/// 2096 mapped EVERY out-of-range value to 4, so a 0 or
/// negative version (a corrupt or hand-written link)
/// became v4 instead of the minimum v1.
int sanitizeSnellVersion(int v) => v < 1 ? 1 : (v > 4 ? 4 : v);

/// VMess alterId: negative is meaningless, huge values
/// are rejected by the core.
int sanitizeAlterId(int v) => v < 0 ? 0 : (v > 65535 ? 65535 : v);

/// Hysteria2 bandwidth ceiling (audit 4.2): the value is
/// stringified into the core's Bps parser, so an
/// unbounded positive from a link is bounded here.
int sanitizeBandwidthMbps(int v) => v < 0 ? 0 : (v > 100000 ? 100000 : v);

/// AWG parameters are NUMBERS carried as strings into a
/// line-based native protocol (audit 1.4): the sanitizer's
/// job is anti-injection ONLY — a stored value must never
/// break out of its UAPI line. The values themselves may
/// be ranges ("5-10", documented on the model and carried
/// verbatim by the .conf parser/serializer and the UAPI
/// composer), so a well-formed single number or range is
/// preserved exactly; the build-2095 version stripped the
/// dash too and silently rewrote "5-10" to "510", which
/// broke the obfuscation the value described (build 2096,
/// post-2095 audit H2). A malformed shape reduces to its
/// leading number; no digits at all clears the value.
/// Build 2098 (Item A): hygiene for an AmneziaWG 2.0
/// signature value (I1–I5 / J1–J3) — a DSL string of
/// "<r 2><b 0x…>" segments, NOT a number, so the numeric
/// [sanitizeAwgParam] must never touch it (it would strip
/// the value to its digits). The value is stored verbatim
/// apart from line breaks (it is emitted into UAPI lines,
/// where a break would split the value into a bogus key)
/// and a length cap no real signature packet approaches;
/// whether the DSL itself parses is the engine's call at
/// IpcSet, and a refusal degrades to the plain fallback,
/// never a crash.
String sanitizeAwgDsl(String v) {
  var cleaned = v.replaceAll('\r', '').replaceAll('\n', '').trim();
  if (cleaned.length > 4096) cleaned = cleaned.substring(0, 4096);
  return cleaned;
}

String sanitizeAwgParam(String v) {
  final cleaned = v.replaceAll(RegExp(r'[^0-9-]'), '');
  final single = RegExp(r'^\d{1,10}$');
  if (single.hasMatch(cleaned)) return cleaned;
  final range = RegExp(r'^(\d{1,10})-(\d{1,10})$').firstMatch(cleaned);
  if (range != null) {
    final lo = int.parse(range.group(1)!);
    final hi = int.parse(range.group(2)!);
    // A reversed range is a typo, not a different intent:
    // order it rather than emitting a range the engine
    // reads as empty.
    return lo <= hi ? cleaned : '$hi-$lo';
  }
  final lead = RegExp(r'^\d{1,10}').firstMatch(cleaned);
  return lead?.group(0) ?? '';
}

/// AllowedIPs entries ride the same line-based protocol:
/// an entry containing whitespace or control characters
/// is dropped, never repaired into a different network.
String sanitizeAllowedIps(String csv) {
  final kept = <String>[];
  for (final part in csv.split(',')) {
    final e = part.trim();
    if (e.isEmpty) continue;
    if (e.codeUnits.any((u) => u <= 0x20 || u == 0x7F)) continue;
    kept.add(e);
  }
  return kept.join(',');
}

/// The WireGuard `reserved` triple (audit 2.4 + 4.1):
/// kept only when it is exactly three bytes in range —
/// anything else is cleared HERE, at the boundary, so
/// the profile never displays a value the builder would
/// silently drop at connect time.
String sanitizeReserved(String raw) {
  final parts = raw.split(',').map((e) => e.trim()).toList();
  if (parts.length != 3) return '';
  for (final part in parts) {
    final v = int.tryParse(part);
    if (v == null || v < 0 || v > 255) return '';
  }
  return parts.join(',');
}

/// Runs every boundary repair over [p] in place and
/// returns it. Idempotent: a profile the editor produced
/// passes through unchanged.
Profile sanitizeImportedProfile(Profile p) {
  p.name = sanitizeProfileName(p.name);
  p.port = sanitizeProfilePort(p.port);
  p.mtu = sanitizeWgMtu(p.mtu);
  p.snellVersion = sanitizeSnellVersion(p.snellVersion);
  p.aid = sanitizeAlterId(p.aid);
  p.upMbps = sanitizeBandwidthMbps(p.upMbps);
  p.downMbps = sanitizeBandwidthMbps(p.downMbps);
  // The network whitelist is protocol-aware (build 2096,
  // post-2095 audit H1): for Mieru the field is not an
  // Xray transport at all — the Mieru builder reads it to
  // choose the UDP/TCP port binding, and 'udp' is a real
  // value the link parser sets. Flattening it to 'tcp'
  // dialled UDP-only Mieru servers over TCP forever.
  if (p.protocol == Protocol.mieru) {
    // Build 2097 (post-2096 audit C-L15): case-normalize
    // first — the check used to be case-sensitive where
    // the Mieru builder is not, so a 'UDP' value from a
    // case-preserving source was flattened to 'tcp' here
    // while the builder would have honoured it as UDP.
    p.network = p.network.toLowerCase();
    if (p.network != 'udp' && p.network != 'tcp') p.network = 'tcp';
  } else if (!kProfileNetworks.contains(p.network)) {
    p.network = 'tcp';
  }
  // An unknown security value fails CLOSED (build 2096,
  // post-2095 audit L26): the build-2095 whitelist reset
  // it to '' — plaintext — so a value the core would have
  // rejected became an unencrypted tunnel on a
  // plaintext-accepting endpoint. 'tls' either matches
  // the endpoint's encryption or fails the handshake;
  // it never silently runs clear.
  if (!kProfileSecurities.contains(p.security)) {
    // Build 2097 (post-2096 audit C6): the fail-closed
    // coercion is scoped to the stream-security protocols
    // (VLESS/VMess/Trojan), whose `security` field this
    // actually is. Applied protocol-blindly it rewrote a
    // stray Xray-JSON Shadowsocks "security":"xtls" to
    // 'tls', and the Test-All TLS-SNI pre-check then
    // marked a working SS profile dead without ever
    // dialing it. For protocols with no stream security
    // the value is meaningless metadata — normalize it
    // away instead of inventing an encryption the profile
    // never had.
    p.security = switch (p.protocol) {
      Protocol.vless || Protocol.vmess || Protocol.trojan => 'tls',
      _ => '',
    };
  }
  // Build 2098 (post-2097 audit M10): the same normalization
  // for IN-SET values on the protocols that have no stream
  // security at all (Shadowsocks / SOCKS / HTTP). A valid
  // 'tls' (or 'reality') there — from an Xray-JSON import,
  // the editor, or a restore — is meaningless metadata, but
  // it survived precisely because it was in the set, and
  // the Test-All TLS-SNI pre-check then ran a handshake the
  // endpoint cannot answer and marked a working profile
  // dead (keepOnlyWorking could delete it). The pre-check
  // is protocol-aware now too (xray_controller's funnel);
  // this keeps the stored value itself honest.
  if ((p.protocol == Protocol.shadowsocks ||
          p.protocol == Protocol.socks ||
          p.protocol == Protocol.http) &&
      (p.security == 'tls' || p.security == 'reality')) {
    p.security = '';
  }
  // REALITY over QUIC/KCP is NOT repaired here (build
  // 2096, post-2095 audit M1): the build-2095 coercion
  // silently rewrote the stored security to TLS and the
  // rewrite became permanent on the next save, with no
  // note anywhere. The profile now keeps the value its
  // source carried; the config builder substitutes TLS
  // at emit time (the pairing the core loads) and the
  // connect path journals the substitution — see
  // [Profile.hasRealityTransportMismatch].
  // The vision flow loads only on TCP-family/XHTTP with
  // TLS or REALITY (audit 2.2); anywhere else it is
  // dropped at the boundary instead of failing the whole
  // config at start. 'raw' is the TCP alias the parser
  // admits and the editor treats as TCP (build 2096,
  // post-2095 audit M2) — it belongs to the TCP family.
  if (p.flow.isNotEmpty &&
      !(p.protocol == Protocol.vless &&
          (p.network == 'tcp' ||
              p.network == 'raw' ||
              p.network == 'xhttp' ||
              p.network == 'splithttp') &&
          (p.security == 'tls' || p.security == 'reality'))) {
    p.flow = '';
  }
  if ((p.network == 'xhttp' || p.network == 'splithttp') &&
      !kXhttpModes.contains(p.mode)) {
    p.mode = 'auto';
  }
  if (p.protocol == Protocol.tuic) {
    if (!kTuicCongestion.contains(p.congestionControl)) {
      p.congestionControl = '';
    }
    if (!kTuicUdpRelayModes.contains(p.udpRelayMode)) {
      p.udpRelayMode = '';
    }
  }
  p.reserved = sanitizeReserved(p.reserved);
  p.awgJc = sanitizeAwgParam(p.awgJc);
  p.awgJmin = sanitizeAwgParam(p.awgJmin);
  p.awgJmax = sanitizeAwgParam(p.awgJmax);
  p.awgS1 = sanitizeAwgParam(p.awgS1);
  p.awgS2 = sanitizeAwgParam(p.awgS2);
  // Build 2104 (verification iteration 2, M1): S3/S4 take
  // the same numeric hygiene — without it a crafted value
  // (letters, an embedded newline) would be stored
  // verbatim, serialized raw into the hand-off .conf and
  // rejected by the engine's parser, silently costing the
  // profile its obfuscation.
  p.awgS3 = sanitizeAwgParam(p.awgS3);
  p.awgS4 = sanitizeAwgParam(p.awgS4);
  p.awgH1 = sanitizeAwgParam(p.awgH1);
  p.awgH2 = sanitizeAwgParam(p.awgH2);
  p.awgH3 = sanitizeAwgParam(p.awgH3);
  p.awgH4 = sanitizeAwgParam(p.awgH4);
  // Build 2098 (Item A): the signature family rides the
  // DSL hygiene, not the numeric one.
  p.awgI1 = sanitizeAwgDsl(p.awgI1);
  p.awgI2 = sanitizeAwgDsl(p.awgI2);
  p.awgI3 = sanitizeAwgDsl(p.awgI3);
  p.awgI4 = sanitizeAwgDsl(p.awgI4);
  p.awgI5 = sanitizeAwgDsl(p.awgI5);
  p.awgJ1 = sanitizeAwgDsl(p.awgJ1);
  p.awgJ2 = sanitizeAwgDsl(p.awgJ2);
  p.awgJ3 = sanitizeAwgDsl(p.awgJ3);
  // If hygiene drops EVERY AllowedIPs entry of a
  // non-empty source list, the builders read the empty
  // result as their full-tunnel default — a split tunnel
  // silently becoming full (build 2096, post-2095 audit
  // L27). Write the default explicitly instead, so the
  // profile itself shows the full-tunnel list it will
  // actually run with.
  final allowedBefore = p.wgAllowedIPs;
  p.wgAllowedIPs = sanitizeAllowedIps(p.wgAllowedIPs);
  if (allowedBefore.trim().isNotEmpty && p.wgAllowedIPs.isEmpty) {
    p.wgAllowedIPs = '0.0.0.0/0, ::/0';
  }
  return p;
}
