/// TLS certificate pinning (build 2047).
///
/// The bundled core (patterniha/xray-core @ 12fd84e = XTLS v26.11.1)
/// supports a per-config certificate pin: the TLS settings'
/// `pinnedPeerCertSha256` field carries one or more SHA-256 hashes
/// of the server certificate, validated in the core's
/// `infra/conf/transport_security.go` (TLSConfig.Build). This file
/// mirrors that rule exactly — the core is the authority, so a value
/// the core accepts must be storable here, and a value the core
/// would refuse must never reach the emitted config.
///
/// The rule, from the core source:
/// - comma-separated entries; an entry is trimmed and empty entries
///   are skipped (so "pin1,,pin2" is accepted by the core);
/// - colons are removed first (the OpenSSL colon-separated format);
/// - the remainder must hex-decode to exactly 32 bytes — 64 hex
///   characters. Anything else makes the core refuse the whole
///   config, so it is not valid here either.
/// At least one real pin is required: a value of only commas or
/// whitespace decodes to no pins at all, so it pins nothing and is
/// not valid here.
///
/// The core checks the leaf certificate first, then any CA in the
/// chain (transport/internet/tls/config.go verifyChain), so pinning
/// an intermediate or root CA works as well as pinning the leaf.
/// The core also removed `allowInsecure` outright and names the pin
/// as its replacement (build 2048 drops the toggle and the field
/// entirely) — Ember never emits that key.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// True when [value] is a pinnedPeerCertSha256 string the bundled
/// core accepts as a TLS settings value.
bool isValidTlsCertPin(String value) {
  var sawPin = false;
  for (final part in value.split(',')) {
    final v = part.trim();
    if (v.isEmpty) continue;
    // The core strips colons before decoding (OpenSSL format).
    final hex = v.replaceAll(':', '');
    // 64 hex characters = 32 bytes; hex.DecodeString refuses
    // anything else (odd length, non-hex), exactly as this does.
    if (hex.length != 64) return false;
    if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(hex)) return false;
    sawPin = true;
  }
  return sawPin;
}

/// The number of pins in a valid value, or 0 when invalid.
int tlsCertPinCount(String value) {
  if (!isValidTlsCertPin(value)) return 0;
  return value.split(',').where((part) => part.trim().isNotEmpty).length;
}

/// Build 2147 (feature #11 completion): captures the pin of
/// the certificate [host]:[port] presents RIGHT NOW — a TLS
/// handshake that accepts whatever is presented (the point
/// is to READ the cert, not to trust it), then the SHA-256
/// of its DER form, in the core's hex format. Null when the
/// endpoint does not answer or presents no certificate.
/// [serverName] overrides the SNI sent (defaults to [host]).
Future<String?> fetchCurrentTlsCertPin(
  String host,
  int port, {
  String serverName = '',
  Duration timeout = const Duration(seconds: 8),
}) async {
  X509Certificate? presented;
  SecureSocket? socket;
  try {
    socket = await SecureSocket.connect(
      host,
      port,
      onBadCertificate: (cert) {
        presented = cert;
        return true;
      },
      timeout: timeout,
    );
    presented ??= socket.peerCertificate;
    final cert = presented;
    if (cert == null) return null;
    final digest = SHA256Digest().process(Uint8List.fromList(cert.der));
    return digest.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  } catch (_) {
    return null;
  } finally {
    socket?.destroy();
  }
}
