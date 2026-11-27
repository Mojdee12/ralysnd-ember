/// SHA-256 (FIPS 180-4) in pure Dart (build 2050).
///
/// The subscription fetcher needs the SHA-256 of a presented
/// TLS certificate to pin it per-subscription (audit C-3), and
/// the tree carries no `crypto` package — this is the whole
/// algorithm, small and deterministic. Correctness is pinned
/// by the known-answer tests in test/build2050_test.dart
/// (the FIPS vectors plus the fixture certificate's
/// fingerprint as computed by openssl).
library;

const _k = <int>[
  0x428a2f98,
  0x71374491,
  0xb5c0fbcf,
  0xe9b5dba5,
  0x3956c25b,
  0x59f111f1,
  0x923f82a4,
  0xab1c5ed5,
  0xd807aa98,
  0x12835b01,
  0x243185be,
  0x550c7dc3,
  0x72be5d74,
  0x80deb1fe,
  0x9bdc06a7,
  0xc19bf174,
  0xe49b69c1,
  0xefbe4786,
  0x0fc19dc6,
  0x240ca1cc,
  0x2de92c6f,
  0x4a7484aa,
  0x5cb0a9dc,
  0x76f988da,
  0x983e5152,
  0xa831c66d,
  0xb00327c8,
  0xbf597fc7,
  0xc6e00bf3,
  0xd5a79147,
  0x06ca6351,
  0x14292967,
  0x27b70a85,
  0x2e1b2138,
  0x4d2c6dfc,
  0x53380d13,
  0x650a7354,
  0x766a0abb,
  0x81c2c92e,
  0x92722c85,
  0xa2bfe8a1,
  0xa81a664b,
  0xc24b8b70,
  0xc76c51a3,
  0xd192e819,
  0xd6990624,
  0xf40e3585,
  0x106aa070,
  0x19a4c116,
  0x1e376c08,
  0x2748774c,
  0x34b0bcb5,
  0x391c0cb3,
  0x4ed8aa4a,
  0x5b9cca4f,
  0x682e6ff3,
  0x748f82ee,
  0x78a5636f,
  0x84c87814,
  0x8cc70208,
  0x90befffa,
  0xa4506ceb,
  0xbef9a3f7,
  0xc67178f2,
];

int _rotr(int x, int n) => ((x >> n) | (x << (32 - n))) & 0xffffffff;

List<int> _initialState() => <int>[
  0x6a09e667,
  0xbb67ae85,
  0x3c6ef372,
  0xa54ff53a,
  0x510e527f,
  0x9b05688c,
  0x1f83d9ab,
  0x5be0cd19,
];

/// One 64-byte block of [block] starting at [offset], folded
/// into the running state [h] (build 2116: extracted from
/// sha256Hex so the streaming [Sha256] shares the exact
/// compression the known-answer tests pin).
void _compress(List<int> h, List<int> block, int offset) {
  final w = List<int>.filled(64, 0);
  for (var t = 0; t < 16; t++) {
    final o = offset + t * 4;
    w[t] =
        (block[o] << 24) |
        (block[o + 1] << 16) |
        (block[o + 2] << 8) |
        block[o + 3];
  }
  for (var t = 16; t < 64; t++) {
    final s0 = _rotr(w[t - 15], 7) ^ _rotr(w[t - 15], 18) ^ (w[t - 15] >> 3);
    final s1 = _rotr(w[t - 2], 17) ^ _rotr(w[t - 2], 19) ^ (w[t - 2] >> 10);
    w[t] = (w[t - 16] + s0 + w[t - 7] + s1) & 0xffffffff;
  }
  var a = h[0], b = h[1], c = h[2], d = h[3];
  var e = h[4], f = h[5], g = h[6], hh = h[7];
  for (var t = 0; t < 64; t++) {
    final s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
    final ch = (e & f) ^ (~e & g);
    final t1 = (hh + s1 + ch + _k[t] + w[t]) & 0xffffffff;
    final s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
    final maj = (a & b) ^ (a & c) ^ (b & c);
    final t2 = (s0 + maj) & 0xffffffff;
    hh = g;
    g = f;
    f = e;
    e = (d + t1) & 0xffffffff;
    d = c;
    c = b;
    b = a;
    a = (t1 + t2) & 0xffffffff;
  }
  h[0] = (h[0] + a) & 0xffffffff;
  h[1] = (h[1] + b) & 0xffffffff;
  h[2] = (h[2] + c) & 0xffffffff;
  h[3] = (h[3] + d) & 0xffffffff;
  h[4] = (h[4] + e) & 0xffffffff;
  h[5] = (h[5] + f) & 0xffffffff;
  h[6] = (h[6] + g) & 0xffffffff;
  h[7] = (h[7] + hh) & 0xffffffff;
}

String _hexOf(List<int> h) =>
    h.map((v) => v.toRadixString(16).padLeft(8, '0')).join();

/// The SHA-256 of [bytes] as 64 lowercase hex characters.
String sha256Hex(List<int> bytes) {
  final h = _initialState();
  // Padding: message || 0x80 || zeros || 64-bit big-endian bit length.
  final bitLen = bytes.length * 8;
  final padded = <int>[...bytes, 0x80];
  while (padded.length % 64 != 56) {
    padded.add(0);
  }
  for (var i = 7; i >= 0; i--) {
    padded.add((bitLen >> (8 * i)) & 0xff);
  }
  for (var block = 0; block < padded.length; block += 64) {
    _compress(h, padded, block);
  }
  return _hexOf(h);
}

/// Streaming SHA-256 (build 2116): the same compression as
/// [sha256Hex], fed in chunks — for hashing a body while it
/// downloads (the updater's feed-digest verification), where
/// holding the whole file in memory is not an option.
class Sha256 {
  final List<int> _h = _initialState();
  final List<int> _pending = <int>[];
  int _length = 0;
  bool _done = false;

  void add(List<int> chunk) {
    if (_done) throw StateError('Sha256 already finalized');
    _length += chunk.length;
    var data = chunk;
    if (_pending.isNotEmpty) {
      data = <int>[..._pending, ...chunk];
      _pending.clear();
    }
    var offset = 0;
    while (data.length - offset >= 64) {
      _compress(_h, data, offset);
      offset += 64;
    }
    if (offset < data.length) _pending.addAll(data.sublist(offset));
  }

  /// The digest as 64 lowercase hex characters. Finalizes
  /// the hash — no further [add] calls.
  String hex() {
    if (_done) throw StateError('Sha256 already finalized');
    _done = true;
    final bitLen = _length * 8;
    final tail = <int>[..._pending, 0x80];
    while (tail.length % 64 != 56) {
      tail.add(0);
    }
    for (var i = 7; i >= 0; i--) {
      tail.add((bitLen >> (8 * i)) & 0xff);
    }
    for (var block = 0; block < tail.length; block += 64) {
      _compress(_h, tail, block);
    }
    return _hexOf(_h);
  }
}
