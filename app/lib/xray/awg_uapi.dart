/// AmneziaWG run-mode (build 2040, Iran-priority queue 2h): the
/// Dart side of the new native engine.
///
/// The bundled Xray core has no AmneziaWG obfuscation, so a
/// profile that carries Jc/Jmin/Jmax/S1/S2/H1–H4 now runs on a
/// dedicated userspace engine instead: `libwg-go.so`, built from
/// `github.com/amnezia-vpn/amneziawg-go` (the AmneziaWG fork of
/// wireguard-go) with a small CGO/JNI bridge. The Kotlin side
/// (AwgBackend + XrayVpnService ACTION_START_AWG) owns the TUN
/// file descriptor and the device handle; this file owns only
/// the two pure, unit-testable pieces:
///
/// * [buildAwgUapi] — the UAPI settings string the bridge feeds
///   to the device (`device.IpcSet`). One peer per profile, the
///   same shape a `wg set` call produces.
/// * [parseAwgStatus] — the handshake/transfer figures out of
///   the device's UAPI dump (`device.IpcGet`), which is what
///   proves the obfuscated tunnel really carries traffic:
///   a WireGuard handshake only completes when the peer answers
///   with the right keys AND the right obfuscation values, so a
///   fresh `latest_handshake` is the proof. A peer that never
///   answers (wrong values, or DPI eating the handshake) shows
///   `handshakeAgeSec == -1` and the controller falls back to
///   the plain-WireGuard Xray path for that peer.
///
/// Only the obfuscation parameters the config actually carried
/// are sent: a profile with no AWG fields behaves exactly like
/// plain WireGuard on this engine (and the controller only
/// routes profiles WITH parameters here at all).
import 'dart:convert';

import 'xray_models.dart';

/// A stored WireGuard key in the form the UAPI parser accepts
/// (build 2050, audit C-1). Profiles store keys in base64 — the
/// `.conf` / `wireguard://` form — but amneziawg-go's `IpcSet`
/// parses key fields with `hex.DecodeString` (its
/// `FromMaybeZeroHex`): exactly 32 bytes written as 64 hex
/// characters. Builds up to 2049 fed the base64 text verbatim,
/// so EVERY AmneziaWG start failed `IpcSet` and the engine
/// could never run at all — the controller's plain-WireGuard
/// fallback was the only path that ever carried an AWG profile.
///
/// Accepts the stored base64 form (padding optional), or a
/// value that is already 64 hex characters. Anything that does
/// not decode to exactly 32 bytes throws a [FormatException]:
/// a bad key must fail loudly here, never reach the device.
String uapiKeyHex(String stored) {
  final v = stored.trim();
  if (RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(v)) {
    return v.toLowerCase();
  }
  final List<int> bytes;
  try {
    bytes = _decodeKeyBytes(v);
  } on FormatException {
    throw FormatException('not a WireGuard key (base64 or hex)', stored);
  }
  if (bytes.length != 32) {
    throw FormatException(
      'a WireGuard key decodes to 32 bytes, this one to ${bytes.length}',
      stored,
    );
  }
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// Decodes a base64 key the way every other WireGuard tool
/// does: leniently. Dart's decoder rejects encodings whose
/// final character carries non-zero discarded bits (a
/// non-canonical but byte-identical spelling some exporters
/// produce); the BYTES are the key, so on that failure the
/// discarded bits are zeroed and the decode retried.
List<int> _decodeKeyBytes(String v) {
  final s = base64.normalize(v);
  try {
    return base64.decode(s);
  } on FormatException {
    final pad = s.endsWith('==') ? 2 : (s.endsWith('=') ? 1 : 0);
    if (pad == 0) rethrow;
    final body = s.substring(0, s.length - pad);
    if (body.isEmpty) rethrow;
    const alphabet =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    final idx = alphabet.indexOf(body[body.length - 1]);
    if (idx < 0) rethrow;
    // One pad discards the final char's low 2 bits; two pads
    // discard its low 4.
    final masked = pad == 1 ? idx & ~3 : idx & ~15;
    final fixed =
        body.substring(0, body.length - 1) + alphabet[masked] + ('=' * pad);
    return base64.decode(fixed);
  }
}

/// The UAPI settings string for [p]: private key, the single
/// peer (public key, endpoint, allowed IPs, pre-shared key and
/// keepalive when set), then the AmneziaWG obfuscation values
/// the config carried — nothing else. Keys are written in the
/// hex form [uapiKeyHex] produces — the only form `IpcSet`
/// accepts. An IPv6 endpoint is bracketed, as UAPI requires.
String buildAwgUapi(Profile p) {
  final b = StringBuffer();
  b.writeln('private_key=${uapiKeyHex(p.secretKey)}');
  b.writeln('public_key=${uapiKeyHex(p.peerPublicKey)}');
  if (p.preSharedKey.isNotEmpty) {
    b.writeln('preshared_key=${uapiKeyHex(p.preSharedKey)}');
  }
  final host = p.address.contains(':') ? '[${p.address}]' : p.address;
  b.writeln('endpoint=$host:${p.port}');
  // The .conf's split-tunnel list (build 2057, audit §6 WG
  // .conf divergences): applied here too, so the AWG engine
  // agrees with the Xray outbound — an empty list keeps the
  // old full-tunnel default, as before.
  final wgAllowed = p.wgAllowedIPs
      .split(',')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();
  if (wgAllowed.isEmpty) {
    b.writeln('allowed_ip=0.0.0.0/0');
    b.writeln('allowed_ip=::/0');
  } else {
    for (final ip in wgAllowed) {
      b.writeln('allowed_ip=$ip');
    }
  }
  if (p.keepAlive > 0) {
    b.writeln('persistent_keepalive_interval=${p.keepAlive}');
  }
  if (p.awgJc.isNotEmpty) b.writeln('jc=${p.awgJc}');
  if (p.awgJmin.isNotEmpty) b.writeln('jmin=${p.awgJmin}');
  if (p.awgJmax.isNotEmpty) b.writeln('jmax=${p.awgJmax}');
  if (p.awgS1.isNotEmpty) b.writeln('s1=${p.awgS1}');
  if (p.awgS2.isNotEmpty) b.writeln('s2=${p.awgS2}');
  if (p.awgH1.isNotEmpty) b.writeln('h1=${p.awgH1}');
  if (p.awgH2.isNotEmpty) b.writeln('h2=${p.awgH2}');
  if (p.awgH3.isNotEmpty) b.writeln('h3=${p.awgH3}');
  if (p.awgH4.isNotEmpty) b.writeln('h4=${p.awgH4}');
  return b.toString();
}

/// The liveness figures from a UAPI dump of the running device.
class AwgStatus {
  const AwgStatus({
    required this.handshakeAgeSec,
    required this.rxBytes,
    required this.txBytes,
  });

  /// Seconds since the last completed handshake with the peer,
  /// or -1 when no handshake has ever completed (the peer never
  /// answered). -1 also covers a dump that carries no peer at all.
  final int handshakeAgeSec;

  /// Bytes received/sent through the tunnel since the device started.
  final int rxBytes;
  final int txBytes;

  static const never = AwgStatus(handshakeAgeSec: -1, rxBytes: 0, txBytes: 0);

  bool get hasHandshake => handshakeAgeSec >= 0;
}

/// Parses a UAPI dump (the `wg show`-style text `IpcGet`
/// returns) into [AwgStatus]. [nowMs] is the wall clock in
/// milliseconds, passed in so tests can pin it. Only the first
/// peer block is read — the engine runs one peer per profile.
AwgStatus parseAwgStatus(String dump, {required int nowMs}) {
  var handshakeSec = -1;
  var rx = 0;
  var tx = 0;
  var sawPeer = false;
  for (final raw in dump.split('\n')) {
    final line = raw.trim();
    if (line.startsWith('public_key=')) {
      if (sawPeer) break; // Second peer: the engine never has one.
      sawPeer = true;
      continue;
    }
    if (!sawPeer) continue;
    if (line.startsWith('latest_handshake=')) {
      final v = int.tryParse(line.substring('latest_handshake='.length)) ?? 0;
      if (v > 0) {
        handshakeSec = ((nowMs ~/ 1000) - v).clamp(0, 1 << 62);
      }
    } else if (line.startsWith('transfer_rx=')) {
      rx = int.tryParse(line.substring('transfer_rx='.length)) ?? 0;
    } else if (line.startsWith('transfer_tx=')) {
      tx = int.tryParse(line.substring('transfer_tx='.length)) ?? 0;
    }
  }
  if (!sawPeer) return AwgStatus.never;
  return AwgStatus(handshakeAgeSec: handshakeSec, rxBytes: rx, txBytes: tx);
}
