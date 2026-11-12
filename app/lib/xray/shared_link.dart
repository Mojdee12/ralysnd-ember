/// Password-protected, expiring share links (build 2030,
/// the plan-check's self-contained design): the profile's
/// normal share link is encrypted with AES-256-GCM under a
/// key derived from the user's password (PBKDF2-HMAC-SHA256,
/// 120k rounds, random salt), and the whole thing travels as
/// one `ember://share/` URL — no server, nothing to phone
/// home. The expiry epoch rides INSIDE the authenticated
/// payload (so it cannot be edited without the password) and
/// is duplicated in the clear as a pre-prompt hint. Expiry is
/// advisory: an expired link still imports, with a warning —
/// there is no authority to enforce it against, and pretending
/// otherwise would be theatre.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

const protectedSharePrefix = 'ember://share/';

const _iterations = 120000;
const _saltBytes = 16;
const _nonceBytes = 12;

/// True when [text] contains a protected share link (imports
/// are line-based; a protected link may share a paste with
/// plain ones).
bool containsProtectedShare(String text) => text
    .split(RegExp(r'[\r\n]'))
    .any((l) => l.trim().startsWith(protectedSharePrefix));

/// The clear-text expiry hint of a protected link (epoch
/// seconds), or null when absent/unparseable. Advisory only —
/// the authenticated copy inside decides.
int? protectedShareExpiryHint(String link) {
  try {
    final uri = Uri.parse(link.trim());
    final exp = int.tryParse(uri.queryParameters['exp'] ?? '');
    return (exp != null && exp > 0) ? exp : null;
  } catch (_) {
    return null;
  }
}

bool _expired(int epochSec, DateTime now) =>
    epochSec > 0 &&
    now.millisecondsSinceEpoch ~/ 1000 > epochSec;

Uint8List _deriveKey(String password, Uint8List salt) {
  final derivator = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
    ..init(Pbkdf2Parameters(salt, _iterations, 32));
  return derivator.process(Uint8List.fromList(utf8.encode(password)));
}

/// Wraps [innerLink] (a normal profile share link) into a
/// protected `ember://share/` URL that expires after [ttl].
String createProtectedShareLink(
  String innerLink,
  String password, {
  required Duration ttl,
  DateTime? now,
}) {
  final at = now ?? DateTime.now();
  final exp = at.millisecondsSinceEpoch ~/ 1000 + ttl.inSeconds;
  final payload = jsonEncode({'link': innerLink, 'exp': exp});
  final rnd = Random.secure();
  final salt = Uint8List.fromList(
    List.generate(_saltBytes, (_) => rnd.nextInt(256)),
  );
  final nonce = Uint8List.fromList(
    List.generate(_nonceBytes, (_) => rnd.nextInt(256)),
  );
  final cipher = GCMBlockCipher(AESEngine())
    ..init(
      true,
      AEADParameters(
        KeyParameter(_deriveKey(password, salt)),
        128,
        nonce,
        Uint8List(0),
      ),
    );
  final plain = Uint8List.fromList(utf8.encode(payload));
  final sealed = cipher.process(plain);
  final blob = Uint8List.fromList([...salt, ...nonce, ...sealed]);
  final data = base64Url.encode(blob).replaceAll('=', '');
  return '${protectedSharePrefix}v1?exp=$exp&data=$data';
}

/// Opens a protected link with [password]: the inner share
/// link + its authenticated expiry, or null when the password
/// is wrong / the link is malformed (GCM's tag makes the two
/// indistinguishable, by design).
({String link, int expiresEpochSec, bool expired})? openProtectedShareLink(
  String link,
  String password, {
  DateTime? now,
}) {
  try {
    final uri = Uri.parse(link.trim());
    var data = uri.queryParameters['data'] ?? '';
    if (data.isEmpty) return null;
    data = data.padRight((data.length + 3) ~/ 4 * 4, '=');
    final blob = base64Url.decode(data);
    if (blob.length < _saltBytes + _nonceBytes + 16) return null;
    final salt = Uint8List.sublistView(blob, 0, _saltBytes);
    final nonce = Uint8List.sublistView(
      blob,
      _saltBytes,
      _saltBytes + _nonceBytes,
    );
    final sealed = Uint8List.sublistView(blob, _saltBytes + _nonceBytes);
    final cipher = GCMBlockCipher(AESEngine())
      ..init(
        false,
        AEADParameters(
          KeyParameter(_deriveKey(password, salt)),
          128,
          nonce,
          Uint8List(0),
        ),
      );
    final plain = cipher.process(sealed);
    final payload =
        (jsonDecode(utf8.decode(plain)) as Map).cast<String, dynamic>();
    final inner = payload['link'] as String? ?? '';
    if (inner.isEmpty) return null;
    final exp = (payload['exp'] as num?)?.toInt() ?? 0;
    return (
      link: inner,
      expiresEpochSec: exp,
      expired: _expired(exp, now ?? DateTime.now()),
    );
  } catch (_) {
    return null;
  }
}

/// Replaces every protected link in [text] with its decrypted
/// inner link. Returns null when any link fails to open
/// (wrong password). [onExpired] is called once per expired
/// link — expiry is advisory, the import proceeds.
String? unlockProtectedShares(
  String text,
  String password, {
  void Function()? onExpired,
  DateTime? now,
}) {
  final out = <String>[];
  for (final raw in text.split(RegExp(r'[\r\n]'))) {
    final line = raw.trim();
    if (line.startsWith(protectedSharePrefix)) {
      final opened = openProtectedShareLink(line, password, now: now);
      if (opened == null) return null;
      if (opened.expired) onExpired?.call();
      out.add(opened.link);
    } else if (line.isNotEmpty) {
      out.add(raw);
    }
  }
  return out.join('\n');
}
