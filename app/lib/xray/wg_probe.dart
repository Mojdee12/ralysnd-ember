/// WireGuard handshake probe (build 2098 — the WARP
/// endpoint scanner): a REAL WireGuard handshake
/// initiation, built from a profile's own keys and its
/// AmneziaWG parameters, sent over UDP; an endpoint counts
/// as working only when it answers with a handshake
/// response whose MAC verifies AND whose encrypted empty
/// payload decrypts under the completed Noise chain. That
/// is the same proof the tunnel itself needs — no ICMP or
/// TCP substitute is dressed up as a handshake ping.
///
/// The crypto is the WireGuard protocol's own (Noise
/// IKpsk2, Blake2s, X25519, ChaCha20-Poly1305). Blake2s
/// and X25519 are implemented here from RFC 7693 / RFC
/// 7748 (PointyCastle 3.9 carries neither); the AEAD is
/// PointyCastle's ChaCha20-Poly1305. The implementations
/// are pinned by the RFCs' published test vectors in the
/// build-2098 test file, and the whole probe was verified
/// against a real amneziawg-go device over loopback UDP
/// during development.
///
/// The AWG wire shape mirrors the bundled engine
/// (amneziawg-go v1.0.4, device/send.go): signature
/// packets (I1–I5) first, else controlled junk (J1–J3),
/// then Jc junk packets, then the initiation itself —
/// S1 junk bytes prepended, H1 as the packet's type field
/// when set, MACs computed over the packet as sent.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart' hide State;

import 'xray_models.dart';

// ---------------------------------------------------------------- Blake2s

const _blake2sIv = [
  0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A,
  0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19,
];

const _blake2sSigma = [
  [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
  [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
  [11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4],
  [7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8],
  [9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13],
  [2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9],
  [12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11],
  [13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10],
  [6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5],
  [10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0],
  [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
  [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
];

int _rotr32(int x, int n) => ((x >> n) | (x << (32 - n))) & 0xFFFFFFFF;

/// Blake2s (RFC 7693), one-shot: [outLen] bytes of digest
/// (32 unless given), optionally keyed (a key of up to 32
/// bytes — WireGuard's mac1/mac2 are keyed Blake2s-128;
/// its hashes and HMAC use the unkeyed 256 form).
Uint8List blake2s(List<int> data, {List<int>? key, int outLen = 32}) {
  final h = Uint32List.fromList(_blake2sIv);
  // Parameter block: digest length, key length, fanout 1,
  // depth 1.
  h[0] ^= 0x01010000 ^ ((key?.length ?? 0) << 8) ^ outLen;
  // The padded key block leads when keyed (RFC 7693 §3):
  // it is fed as a full 64-byte block and the byte
  // counter counts all 64, even when it is also the
  // final block (no data) — the reference behaviour,
  // pinned by the keyed test vectors.
  final blocks = <(Uint8List, int)>[]; // (block, countBytes)
  if (key != null) {
    final kb = Uint8List(64)..setRange(0, key.length, key);
    blocks.add((kb, 64));
  }
  var offset = 0;
  while (offset < data.length) {
    final block = Uint8List(64);
    final take = min(64, data.length - offset);
    block.setRange(0, take, data, offset);
    blocks.add((block, take));
    offset += take;
  }
  if (blocks.isEmpty) blocks.add((Uint8List(64), 0));
  var t = 0;
  for (var i = 0; i < blocks.length; i++) {
    final (block, realBytes) = blocks[i];
    final isLast = i == blocks.length - 1;
    // A non-final block counts its full 64 bytes (the key
    // block included); the final block counts its real
    // bytes only.
    t += isLast ? realBytes : 64;
    _blake2sCompress(h, block, t, isLast);
  }
  final full = Uint8List(32);
  final bd = ByteData.sublistView(full);
  for (var i = 0; i < 8; i++) {
    bd.setUint32(i * 4, h[i], Endian.little);
  }
  return Uint8List.sublistView(full, 0, outLen);
}

/// Blake2s-256, unkeyed.
Uint8List blake2s256(List<int> data) => blake2s(data);

void _blake2sCompress(Uint32List h, Uint8List block, int t, bool last) {
  final m = Uint32List(16);
  final bd = ByteData.sublistView(block);
  for (var i = 0; i < 16; i++) {
    m[i] = bd.getUint32(i * 4, Endian.little);
  }
  final v = Uint32List(16)
    ..setRange(0, 8, h)
    ..setRange(8, 16, _blake2sIv);
  v[12] ^= t & 0xFFFFFFFF;
  v[13] ^= (t >> 32) & 0xFFFFFFFF;
  if (last) v[14] ^= 0xFFFFFFFF;
  void g(int a, int b, int c, int d, int x, int y) {
    v[a] = (v[a] + v[b] + x) & 0xFFFFFFFF;
    v[d] = _rotr32(v[d] ^ v[a], 16);
    v[c] = (v[c] + v[d]) & 0xFFFFFFFF;
    v[b] = _rotr32(v[b] ^ v[c], 12);
    v[a] = (v[a] + v[b] + y) & 0xFFFFFFFF;
    v[d] = _rotr32(v[d] ^ v[a], 8);
    v[c] = (v[c] + v[d]) & 0xFFFFFFFF;
    v[b] = _rotr32(v[b] ^ v[c], 7);
  }

  for (var round = 0; round < 10; round++) {
    final s = _blake2sSigma[round];
    g(0, 4, 8, 12, m[s[0]], m[s[1]]);
    g(1, 5, 9, 13, m[s[2]], m[s[3]]);
    g(2, 6, 10, 14, m[s[4]], m[s[5]]);
    g(3, 7, 11, 15, m[s[6]], m[s[7]]);
    g(0, 5, 10, 15, m[s[8]], m[s[9]]);
    g(1, 6, 11, 12, m[s[10]], m[s[11]]);
    g(2, 7, 8, 13, m[s[12]], m[s[13]]);
    g(3, 4, 9, 14, m[s[14]], m[s[15]]);
  }
  for (var i = 0; i < 8; i++) {
    h[i] ^= v[i] ^ v[i + 8];
  }
}

/// HMAC with Blake2s-256 (block size 64).
Uint8List hmacBlake2s(List<int> key, List<int> data) {
  var k = key;
  if (k.length > 64) k = blake2s256(k);
  final inner = List<int>.filled(64, 0x36);
  final outer = List<int>.filled(64, 0x5C);
  for (var i = 0; i < k.length; i++) {
    inner[i] ^= k[i];
    outer[i] ^= k[i];
  }
  final innerHash = blake2s256([...inner, ...data]);
  return blake2s256([...outer, ...innerHash]);
}

/// WireGuard's HKDF steps (HMAC-Blake2s): KDF1/2/3.
Uint8List _kdfStep(List<int> chainKey, List<int> input, int n) {
  final t0 = hmacBlake2s(chainKey, input);
  var t = hmacBlake2s(t0, const [1]);
  if (n == 1) return t;
  final out = BytesBuilder()..add(t);
  t = hmacBlake2s(t0, [...t, 2]);
  out.add(t);
  if (n == 2) return out.toBytes();
  t = hmacBlake2s(t0, [...t, 3]);
  out.add(t);
  return out.toBytes();
}

// ---------------------------------------------------------------- X25519

final _p25519 = (BigInt.one << 255) - BigInt.from(19);

BigInt _leToBigInt(List<int> bytes) {
  var v = BigInt.zero;
  for (var i = bytes.length - 1; i >= 0; i--) {
    v = (v << 8) | BigInt.from(bytes[i]);
  }
  return v;
}

Uint8List _bigIntToLe(BigInt v, int length) {
  final out = Uint8List(length);
  var x = v;
  for (var i = 0; i < length; i++) {
    out[i] = (x & BigInt.from(0xFF)).toInt();
    x = x >> 8;
  }
  return out;
}

/// X25519 (RFC 7748 §5): the Montgomery ladder over
/// GF(2^255−19) with BigInt arithmetic. Slow by native
/// standards (a few ms) — the probe runs a handful of
/// scalar multiplications per endpoint, outside the timed
/// window.
Uint8List x25519(List<int> scalar, List<int> uBytes) {
  final kBytes = Uint8List.fromList(scalar);
  kBytes[0] &= 248;
  kBytes[31] &= 127;
  kBytes[31] |= 64;
  final k = _leToBigInt(kBytes);
  final u = Uint8List.fromList(uBytes);
  u[31] &= 127; // mask the top bit of the received u-coordinate
  final x1 = _leToBigInt(u) % _p25519;
  var x2 = BigInt.one;
  var z2 = BigInt.zero;
  var x3 = x1;
  var z3 = BigInt.one;
  var swap = 0;
  final a24 = BigInt.from(121665);
  BigInt mod(BigInt v) => v % _p25519;
  for (var t = 254; t >= 0; t--) {
    final kt = (k >> t) & BigInt.one;
    swap ^= kt.toInt();
    if (swap == 1) {
      var tmp = x2;
      x2 = x3;
      x3 = tmp;
      tmp = z2;
      z2 = z3;
      z3 = tmp;
    }
    swap = kt.toInt();
    final a = mod(x2 + z2);
    final aa = mod(a * a);
    final b = mod(x2 - z2);
    final bb = mod(b * b);
    final e = mod(aa - bb);
    final c = mod(x3 + z3);
    final d = mod(x3 - z3);
    final da = mod(d * a);
    final cb = mod(c * b);
    final daPcb = mod(da + cb);
    final daMcb = mod(da - cb);
    x3 = mod(daPcb * daPcb);
    z3 = mod(x1 * mod(daMcb * daMcb));
    x2 = mod(aa * bb);
    z2 = mod(e * mod(aa + mod(a24 * e)));
  }
  if (swap == 1) {
    final tmp = x2;
    x2 = x3;
    x3 = tmp;
    final tmpZ = z2;
    z2 = z3;
    z3 = tmpZ;
  }
  final result = mod(x2 * z2.modInverse(_p25519));
  return _bigIntToLe(result, 32);
}

/// An X25519 public key for [privateKey] (base point 9).
Uint8List x25519Public(List<int> privateKey) {
  final base = Uint8List(32)..[0] = 9;
  return x25519(privateKey, base);
}

// ---------------------------------------------------------------- AEAD

Uint8List _aeadSeal(
  List<int> key,
  List<int> nonce12,
  List<int> plaintext,
  List<int> aad,
) {
  final cipher = ChaCha20Poly1305(ChaCha7539Engine(), Poly1305());
  cipher.init(
    true,
    AEADParameters(
      KeyParameter(Uint8List.fromList(key)),
      128,
      Uint8List.fromList(nonce12),
      Uint8List.fromList(aad),
    ),
  );
  final out = Uint8List(plaintext.length + 16);
  var len = cipher.processBytes(
    Uint8List.fromList(plaintext),
    0,
    plaintext.length,
    out,
    0,
  );
  len += cipher.doFinal(out, len);
  return Uint8List.sublistView(out, 0, len);
}

/// Opens an AEAD seal; null when the tag does not verify.
Uint8List? _aeadOpen(
  List<int> key,
  List<int> nonce12,
  List<int> ciphertext,
  List<int> aad,
) {
  if (ciphertext.length < 16) return null;
  final cipher = ChaCha20Poly1305(ChaCha7539Engine(), Poly1305());
  cipher.init(
    false,
    AEADParameters(
      KeyParameter(Uint8List.fromList(key)),
      128,
      Uint8List.fromList(nonce12),
      Uint8List.fromList(aad),
    ),
  );
  final out = Uint8List(ciphertext.length);
  try {
    var len = cipher.processBytes(
      Uint8List.fromList(ciphertext),
      0,
      ciphertext.length,
      out,
      0,
    );
    len += cipher.doFinal(out, len);
    return Uint8List.sublistView(out, 0, len);
  } catch (_) {
    return null;
  }
}

// ---------------------------------------------------------------- AWG DSL

/// One built signature packet plus the wait the DSL asks
/// for before it (the `<wt>` tag produces no bytes — the
/// engine sleeps while generating; the probe sleeps before
/// sending, the same wire timing).
class AwgDslPacket {
  const AwgDslPacket({required this.bytes, required this.waitBefore});

  final Uint8List bytes;
  final Duration waitBefore;
}

/// Builds one signature packet from an AWG 2.0 DSL value
/// ("<r 2><b 0x…>"), mirroring amneziawg-go's tag parser:
/// `<b 0x…>` fixed hex bytes, `<r N>` N random bytes
/// (N ≤ 1000), `<t>` the 8-byte big-endian Unix time,
/// `<c>` an 8-byte big-endian counter, `<wt N>` a wait of
/// N ms (N ≤ 5000, no bytes). Anything else — an unknown
/// tag, a malformed segment — throws [FormatException],
/// exactly the values the engine itself would refuse at
/// IpcSet.
AwgDslPacket buildAwgDslPacket(
  String dsl, {
  required Random random,
  required int counter,
  required DateTime now,
}) {
  final out = BytesBuilder();
  var wait = Duration.zero;
  var rest = dsl.trim();
  if (rest.isEmpty) {
    throw const FormatException('empty signature value');
  }
  while (rest.isNotEmpty) {
    if (!rest.startsWith('<')) {
      throw FormatException('expected a <tag>', dsl);
    }
    final close = rest.indexOf('>');
    if (close < 0) throw FormatException('unterminated tag', dsl);
    final tag = rest.substring(1, close).trim();
    rest = rest.substring(close + 1);
    final space = tag.indexOf(RegExp(r'\s'));
    final name = space < 0 ? tag : tag.substring(0, space);
    final param = space < 0 ? '' : tag.substring(space + 1).trim();
    switch (name) {
      case 'b':
        if (!param.startsWith('0x') && !param.startsWith('0X')) {
          throw FormatException('<b> needs a 0x hex value', dsl);
        }
        var hex = param.substring(2);
        if (hex.length.isOdd) hex = '0$hex';
        try {
          for (var i = 0; i < hex.length; i += 2) {
            out.addByte(int.parse(hex.substring(i, i + 2), radix: 16));
          }
        } on FormatException {
          throw FormatException('<b> value is not hex', dsl);
        }
      case 'r':
        final n = int.tryParse(param);
        if (n == null || n < 0 || n > 1000) {
          throw FormatException('<r> needs a size up to 1000', dsl);
        }
        out.add(Uint8List.fromList(List.generate(n, (_) => random.nextInt(256))));
      case 't':
        if (param.isNotEmpty) {
          throw FormatException('<t> takes no parameter', dsl);
        }
        final b = ByteData(8)
          ..setUint64(0, now.millisecondsSinceEpoch ~/ 1000, Endian.big);
        out.add(b.buffer.asUint8List());
      case 'c':
        if (param.isNotEmpty) {
          throw FormatException('<c> takes no parameter', dsl);
        }
        final b = ByteData(8)..setUint64(0, counter, Endian.big);
        out.add(b.buffer.asUint8List());
      case 'wt':
        final n = int.tryParse(param);
        if (n == null || n < 0 || n > 5000) {
          throw FormatException('<wt> needs up to 5000 ms', dsl);
        }
        wait += Duration(milliseconds: n);
      default:
        throw FormatException('unknown tag <$name>', dsl);
    }
  }
  return AwgDslPacket(bytes: out.toBytes(), waitBefore: wait);
}

/// The junk/signature datagrams that precede an initiation
/// for [p], in the bundled engine's send order: the
/// I1–I5 signature packets when any is set, else the
/// J1–J3 controlled-junk packets, then [jc] Jc junk
/// packets of random sizes in [jmin, jmax]. Empty when the
/// profile carries no junk parameters at all.
List<AwgDslPacket> awgPrePackets(Profile p, {required Random random}) {
  final out = <AwgDslPacket>[];
  final now = DateTime.now();
  var counter = 0;
  final specials = [p.awgI1, p.awgI2, p.awgI3, p.awgI4, p.awgI5];
  final controlled = [p.awgJ1, p.awgJ2, p.awgJ3];
  final source = specials.any((v) => v.isNotEmpty)
      ? specials
      : controlled;
  for (final dsl in source) {
    if (dsl.isEmpty) continue;
    out.add(buildAwgDslPacket(dsl, random: random, counter: counter++, now: now));
  }
  final jc = int.tryParse(p.awgJc) ?? 0;
  final jmin = int.tryParse(p.awgJmin) ?? 0;
  var jmax = int.tryParse(p.awgJmax) ?? 0;
  if (jc > 0) {
    if (jmax <= jmin) jmax = jmin + 1; // the engine's own guard
    for (var i = 0; i < jc; i++) {
      final size = jmin + random.nextInt(jmax - jmin);
      out.add(
        AwgDslPacket(
          bytes: Uint8List.fromList(
            List.generate(size, (_) => random.nextInt(256)),
          ),
          waitBefore: Duration.zero,
        ),
      );
    }
  }
  return out;
}

// ---------------------------------------------------------------- Handshake

/// A built handshake initiation plus everything needed to
/// verify its response.
class WgInitiation {
  const WgInitiation({
    required this.prePackets,
    required this.datagram,
    required this.senderIndex,
    required this.chainKey,
    required this.hash,
    required this.ephemeralPrivate,
  });

  /// Junk/signature datagrams to send first, in order.
  final List<AwgDslPacket> prePackets;

  /// The initiation datagram as sent (S1 prefix included).
  final Uint8List datagram;

  final int senderIndex;
  final Uint8List chainKey;
  final Uint8List hash;
  final Uint8List ephemeralPrivate;
}

Uint8List _wgHash(List<int> data) => blake2s256(data);

Uint8List _macKey(List<int> label, List<int> publicKey) =>
    blake2s256([...label, ...publicKey]);

/// Builds the initiation for [profile] toward a peer with
/// the profile's peer key. Keys decode from the profile's
/// stored base64 (a bad key throws [FormatException] —
/// the probe reports the profile unusable, never guesses).
WgInitiation buildWgInitiation(Profile profile, {Random? random}) {
  final rnd = random ?? Random.secure();
  final privateKey = _decodeKey(profile.secretKey);
  final peerPublic = _decodeKey(profile.peerPublicKey);
  final staticPublic = x25519Public(privateKey);

  var chainKey = _wgHash(utf8.encode('Noise_IKpsk2_25519_ChaChaPoly_BLAKE2s'));
  var hash = _wgHash([...chainKey, ...utf8.encode('WireGuard v1 zx2c4 Jason@zx2c4.com')]);
  hash = _wgHash([...hash, ...peerPublic]);

  final ephemeralPrivate = Uint8List.fromList(
    List.generate(32, (_) => rnd.nextInt(256)),
  );
  final ephemeralPublic = x25519Public(ephemeralPrivate);
  hash = _wgHash([...hash, ...ephemeralPublic]);
  // Noise's mixKey: the chain key is keyed with the
  // ephemeral PUBLIC key (a KDF1 step) before the DH
  // step — omitting it produces a handshake real
  // WireGuard devices reject (found by the loopback
  // proof against amneziawg-go during development).
  chainKey = _kdfStep(chainKey, ephemeralPublic, 1);
  var kdf = _kdfStep(chainKey, x25519(ephemeralPrivate, peerPublic), 2);
  chainKey = Uint8List.sublistView(kdf, 0, 32);
  final encStatic = _aeadSeal(
    Uint8List.sublistView(kdf, 32, 64),
    _zeroNonce(),
    staticPublic,
    hash,
  );
  hash = _wgHash([...hash, ...encStatic]);
  kdf = _kdfStep(chainKey, x25519(privateKey, peerPublic), 2);
  chainKey = Uint8List.sublistView(kdf, 0, 32);
  final timestamp = _tai64n(DateTime.now());
  final encTimestamp = _aeadSeal(
    Uint8List.sublistView(kdf, 32, 64),
    _zeroNonce(),
    timestamp,
    hash,
  );
  hash = _wgHash([...hash, ...encTimestamp]);

  final senderIndex = rnd.nextInt(0xFFFFFFFE) + 1;
  // The type field: H1 replaces it when the profile sets
  // a magic header above 4 (the engine's own rule).
  final h1 = int.tryParse(profile.awgH1) ?? 0;
  final type = h1 > 4 ? h1 : 1;
  final packet = Uint8List(148);
  final bd = ByteData.sublistView(packet);
  bd.setUint32(0, type, Endian.little);
  bd.setUint32(4, senderIndex, Endian.little);
  packet.setRange(8, 40, ephemeralPublic);
  packet.setRange(40, 88, encStatic);
  packet.setRange(88, 116, encTimestamp);
  // mac1 is KEYED Blake2s-128 (not HMAC — the device's
  // cookie.go is the authority: blake2s.New128(mac1Key)),
  // and its key label is the 8-byte padded "mac1----"
  // (noise-protocol.go's WGLabelMAC1).
  final mac1 = blake2s(
    Uint8List.sublistView(packet, 0, 116),
    key: _macKey(utf8.encode('mac1----'), peerPublic),
    outLen: 16,
  );
  packet.setRange(116, 132, mac1);
  // mac2 stays zero (no cookie).

  // S1 junk bytes precede the packet on the wire.
  final s1 = int.tryParse(profile.awgS1) ?? 0;
  final datagram = s1 > 0
      ? (BytesBuilder()
            ..add(
              Uint8List.fromList(List.generate(s1, (_) => rnd.nextInt(256))),
            )
            ..add(packet))
          .toBytes()
      : packet;
  return WgInitiation(
    prePackets: awgPrePackets(profile, random: rnd),
    datagram: datagram,
    senderIndex: senderIndex,
    chainKey: chainKey,
    hash: hash,
    ephemeralPrivate: ephemeralPrivate,
  );
}

Uint8List _zeroNonce() => Uint8List(12);

Uint8List _tai64n(DateTime now) {
  final out = ByteData(12);
  final seconds = (now.millisecondsSinceEpoch ~/ 1000) + (1 << 62);
  out.setUint64(0, seconds, Endian.big);
  // Nanoseconds within the second.
  out.setUint32(8, (now.microsecondsSinceEpoch % 1000000) * 1000, Endian.big);
  return out.buffer.asUint8List();
}

Uint8List _decodeKey(String stored) {
  final v = stored.trim();
  List<int> bytes;
  try {
    bytes = base64.decode(base64.normalize(v));
  } on FormatException {
    throw FormatException('not a WireGuard key', stored);
  }
  if (bytes.length != 32) {
    throw FormatException('a WireGuard key is 32 bytes', stored);
  }
  return Uint8List.fromList(bytes);
}

/// Verifies a candidate handshake response against
/// Build 2125 (audit A25-32 / P-37): the handshake
/// builders, run on a background isolate. Each build /
/// verify performs several pure-Dart BigInt X25519
/// Montgomery ladders (a few ms apiece); a WARP/WG
/// endpoint scan runs them per endpoint, and up to 2124
/// they ran synchronously on the caller's (UI) isolate,
/// stuttering the scan page. The synchronous builders
/// above stay for tests and one-off callers; the scan
/// path uses these.
Future<WgInitiation> buildWgInitiationOffUi(Profile profile) =>
    compute(buildWgInitiation, profile);

Future<int?> verifyWgResponseOffUi(
  Profile profile,
  WgInitiation initiation,
  List<int> datagram,
) => compute(
  (args) => verifyWgResponse(args.$1, args.$2, args.$3),
  (profile, initiation, datagram),
);

/// [initiation]: strips the profile's S2 junk prefix,
/// checks the type (2, or the profile's H2 magic), the
/// receiver index, mac1, and — decisively — decrypts the
/// response's encrypted empty payload under the completed
/// Noise chain. Only a peer holding the private key for
/// the profile's peer public key can produce that.
/// Returns the responder's sender index, or null.
int? verifyWgResponse(
  Profile profile,
  WgInitiation initiation,
  List<int> datagram,
) {
  final s2 = int.tryParse(profile.awgS2) ?? 0;
  if (datagram.length != s2 + 92) return null;
  final packet = Uint8List.sublistView(
    Uint8List.fromList(datagram),
    s2,
    s2 + 92,
  );
  final bd = ByteData.sublistView(packet);
  final h2 = int.tryParse(profile.awgH2) ?? 0;
  final type = bd.getUint32(0, Endian.little);
  if (type != 2 && !(h2 > 4 && type == h2)) return null;
  final receiverIndex = bd.getUint32(8, Endian.little);
  if (receiverIndex != initiation.senderIndex) return null;
  final privateKey = _decodeKey(profile.secretKey);
  final staticPublic = x25519Public(privateKey);
  final mac1 = blake2s(
    Uint8List.sublistView(packet, 0, 60),
    key: _macKey(utf8.encode('mac1----'), staticPublic),
    outLen: 16,
  );
  for (var i = 0; i < 16; i++) {
    if (packet[60 + i] != mac1[i]) return null;
  }
  // Complete the Noise chain and open the empty payload.
  final respEphemeral = Uint8List.sublistView(packet, 12, 44);
  final encEmpty = Uint8List.sublistView(packet, 44, 60);
  var hash = _wgHash([...initiation.hash, ...respEphemeral]);
  // The responder's mixKey step (see buildWgInitiation).
  final mixedChain = _kdfStep(initiation.chainKey, respEphemeral, 1);
  var kdf = _kdfStep(
    mixedChain,
    x25519(initiation.ephemeralPrivate, respEphemeral),
    2,
  );
  var chainKey = Uint8List.sublistView(kdf, 0, 32);
  kdf = _kdfStep(chainKey, x25519(privateKey, respEphemeral), 2);
  chainKey = Uint8List.sublistView(kdf, 0, 32);
  final psk = profile.preSharedKey.isEmpty
      ? Uint8List(32)
      : _decodeKey(profile.preSharedKey);
  kdf = _kdfStep(chainKey, psk, 3);
  hash = _wgHash([
    ...hash,
    ...Uint8List.sublistView(kdf, 32, 64),
  ]);
  final opened = _aeadOpen(
    Uint8List.sublistView(kdf, 64, 96),
    _zeroNonce(),
    encEmpty,
    hash,
  );
  if (opened == null || opened.isNotEmpty) return null;
  return bd.getUint32(4, Endian.little);
}

// ---------------------------------------------------------------- Scanning

/// One probed endpoint that completed a handshake.
class WgScanResult {
  const WgScanResult({
    required this.address,
    required this.port,
    required this.handshakeMs,
  });

  final String address;
  final int port;

  /// The measured handshake round-trip: initiation send →
  /// verified response receipt, in milliseconds.
  final int handshakeMs;

  String get endpoint => '$address:$port';
}

/// The candidate endpoints for a WARP scan: Cloudflare's
/// published WARP ranges, SAMPLED in a bounded, documented
/// way — a /22 contributes 24 evenly spaced addresses, a
/// /24 contributes 8, each crossed with the two standard
/// WARP ports (2408, 500) — 208 sampled candidates. The
/// profile's current endpoint is always included first
/// (209 entries when it is not itself one of the samples).
/// A scan stays minutes-bounded even when every probe
/// times out, and the sampling is named in the UI copy
/// rather than dressed up as a full-range sweep.
List<(String, int)> warpScanCandidates(Profile profile) {
  const ranges = [
    ('188.114.96.0', 22, 24),
    ('162.159.192.0', 24, 8),
    ('162.159.195.0', 24, 8),
    ('8.6.112.0', 24, 8),
    ('8.34.70.0', 24, 8),
    ('8.34.146.0', 24, 8),
    ('8.35.211.0', 24, 8),
    ('8.39.125.0', 24, 8),
    ('8.39.204.0', 24, 8),
    ('8.39.214.0', 24, 8),
    ('8.47.69.0', 24, 8),
  ];
  const ports = [2408, 500];
  final seen = <String>{};
  final out = <(String, int)>[];
  void add(String ip, int port) {
    if (seen.add('$ip:$port')) out.add((ip, port));
  }

  if (profile.address.isNotEmpty && profile.port > 0) {
    add(profile.address, profile.port);
  }
  for (final (base, prefix, samples) in ranges) {
    final parts = base.split('.').map(int.parse).toList();
    final baseInt = (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3];
    final size = 1 << (32 - prefix);
    final stride = size ~/ samples;
    for (var i = 0; i < samples; i++) {
      final v = baseInt + i * stride + 1;
      final ip =
          '${(v >> 24) & 0xFF}.${(v >> 16) & 0xFF}.${(v >> 8) & 0xFF}.${v & 0xFF}';
      for (final port in ports) {
        add(ip, port);
      }
    }
  }
  return out;
}

/// Sorts scan results by handshake time and removes
/// duplicate endpoints (the first — fastest — wins).
List<WgScanResult> sortScanResults(Iterable<WgScanResult> results) {
  final byEndpoint = <String, WgScanResult>{};
  for (final r in results) {
    final existing = byEndpoint[r.endpoint];
    if (existing == null || r.handshakeMs < existing.handshakeMs) {
      byEndpoint[r.endpoint] = r;
    }
  }
  return byEndpoint.values.toList()
    ..sort((a, b) => a.handshakeMs.compareTo(b.handshakeMs));
}

/// Runs handshake probes with bounded concurrency. One
/// probe = one UDP socket, the pre-packets, the
/// initiation, and a wait for the verified response.
class WgEndpointScanner {
  WgEndpointScanner({
    this.concurrency = 24,
    this.timeout = const Duration(milliseconds: 1500),
  });

  final int concurrency;
  final Duration timeout;

  bool _cancelled = false;

  void cancel() {
    _cancelled = true;
  }

  /// Probes [candidates] for [profile]; [onProgress]
  /// reports (done, total). Returns the verified results,
  /// sorted. A profile whose keys or signature values the
  /// engine itself would refuse throws [FormatException]
  /// before any packet is sent.
  Future<List<WgScanResult>> scan(
    Profile profile,
    List<(String, int)> candidates, {
    void Function(int done, int total)? onProgress,
  }) async {
    _cancelled = false;
    // Build (and thereby validate) one initiation up
    // front: bad keys / bad DSL throw here, before the
    // pool starts.
    buildWgInitiation(profile);
    final results = <WgScanResult>[];
    var done = 0;
    var next = 0;
    Future<void> worker() async {
      while (!_cancelled) {
        final i = next++;
        if (i >= candidates.length) return;
        final (ip, port) = candidates[i];
        final r = await _probeOne(profile, ip, port);
        done++;
        onProgress?.call(done, candidates.length);
        if (r != null) results.add(r);
      }
    }

    await Future.wait([
      for (var i = 0; i < concurrency; i++) worker(),
    ]);
    return sortScanResults(results);
  }

  Future<WgScanResult?> _probeOne(Profile profile, String ip, int port) async {
    RawDatagramSocket? socket;
    try {
      // Build 2125 (A25-32): the handshake crypto runs on
      // a background isolate (see buildWgInitiationOffUi).
      final initiation = await buildWgInitiationOffUi(profile);
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      final target = InternetAddress(ip);
      final completer = Completer<List<int>?>();
      final sub = socket.listen((event) {
        if (event == RawSocketEvent.read) {
          final dg = socket?.receive();
          if (dg != null && !completer.isCompleted) {
            completer.complete(dg.data);
          }
        }
      });
      for (final pre in initiation.prePackets) {
        // Build 2098 (verification F3): a cancelled scan
        // (page disposed or Cancel tapped) stops spending
        // time in the pre-packet waits — they run to seconds
        // apiece on a heavy-AWG profile, and the probe used
        // to sit through all of them plus the response
        // timeout after the page was already gone.
        if (_cancelled) return null;
        if (pre.waitBefore > Duration.zero) {
          await Future<void>.delayed(pre.waitBefore);
        }
        if (_cancelled) return null;
        socket.send(pre.bytes, target, port);
      }
      if (_cancelled) return null;
      final watch = Stopwatch()..start();
      socket.send(initiation.datagram, target, port);
      final response = await completer.future.timeout(
        timeout,
        onTimeout: () => null,
      );
      watch.stop();
      await sub.cancel();
      // Build 2098 (verification, iteration 2): a cancel
      // that landed during the response wait voids the
      // probe — the scanner's cancel contract covers its
      // return value too, not only the page's display.
      if (_cancelled) return null;
      if (response == null) return null;
      // Build 2125 (A25-32): off the UI isolate, as above.
      final verified = await verifyWgResponseOffUi(
        profile,
        initiation,
        response,
      );
      if (verified == null) return null;
      return WgScanResult(
        address: ip,
        port: port,
        handshakeMs: watch.elapsedMilliseconds,
      );
    } catch (_) {
      return null;
    } finally {
      socket?.close();
    }
  }
}
