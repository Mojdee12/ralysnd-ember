/// Provider DNS (build 2105): resolving a subscription's server
/// hostnames through the subscription provider's own DNS
/// (Subscription.dns), extending build 2103's hostname handling.
///
/// Why: 2103 aligned the tunnel's DNS with v2rayNG — the server
/// name is kept and resolved by the config's DNS section. But on
/// a network whose local resolver poisons the provider's names,
/// the first resolution of all — the server's own — is the one
/// that must not come from the local resolver. When the feature
/// is on (XraySettings.providerDnsEnabled, default OFF) and the
/// subscription carries a DNS, a connect resolves the profile's
/// server hostname HERE, before the tunnel exists, and pins the
/// answer into the generated config's hosts map (the same map
/// the user's custom DNS hosts ride). The name stays in the
/// outbound (2103's D6: hostname kept — SNI, certificates and
/// the server's own view are unchanged); only its resolution is
/// pinned.
///
/// Failure doctrine: every failure — timeout, refusal, garbage
/// answer — returns an empty list and the connect proceeds
/// without the pin, exactly as today. Provider DNS can improve
/// a connect; it can never break one.
///
/// The resolver speaks plain DNS wire format itself (the tree
/// has no DNS client): UDP to a resolver address, or DoH
/// (RFC 8484, application/dns-message) to an https:// URL. Both
/// families are asked; the caller pins what comes back.
///
/// Trust, stated plainly (the whole point is a poisoned local
/// network): UDP answers are believed only from the resolver's
/// own address and port, with a cryptographic-random query ID,
/// the response bit set and the question matching what was
/// asked — anything else is ignored while the query waits. DoH
/// rides TLS to the named host. One limit remains: a resolver
/// given as a bare HOSTNAME is itself looked up through the
/// system resolver, so only an IP or a DoH URL fully avoids the
/// local resolver for the bootstrap.

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// Build 2139 (A34-02 re-fix): whether [host] names a literal
/// IP server, in the forms a stored profile address actually
/// takes: a bare IPv4/IPv6 literal, a bracketed IPv6 literal,
/// or either with a trailing `:port` (some imports and
/// hand-edited profiles keep the whole endpoint in the
/// address field). A literal needs no resolution and no pin,
/// and the "carries no DNS" warning must never fire for one —
/// build 2135's bare `InternetAddress.tryParse` check missed
/// the bracketed and host:port forms, so the warning still
/// fired for literal-IP profiles (the owner's 2026-11-22
/// journal: "Senpai 194.36.55.96:443", twice per connect).
bool isLiteralServerHost(String host) {
  final h = host.trim();
  if (h.isEmpty) return false;
  if (InternetAddress.tryParse(h) != null) return true;
  // Bracketed IPv6, with or without a port: [::1], [::1]:443.
  if (h.startsWith('[')) {
    final close = h.indexOf(']');
    if (close <= 1) return false;
    final rest = h.substring(close + 1);
    if (rest.isNotEmpty && !rest.startsWith(':')) return false;
    return InternetAddress.tryParse(h.substring(1, close)) != null;
  }
  // host:port with a literal host. An unbracketed value with
  // several colons is IPv6-shaped; if it did not parse bare
  // above it is not a literal this helper claims.
  final colon = h.lastIndexOf(':');
  if (colon > 0 && !h.substring(0, colon).contains(':')) {
    final port = h.substring(colon + 1);
    if (port.isNotEmpty &&
        port.codeUnits.every((c) => c >= 0x30 && c <= 0x39)) {
      return InternetAddress.tryParse(h.substring(0, colon)) != null;
    }
  }
  return false;
}

/// Resolves [host] through the provider DNS [dns] (a DoH URL or
/// a resolver address) and returns the A/AAAA answers as address
/// strings. Empty on any failure — see the file comment.
Future<List<String>> resolveViaProviderDns(
  String host,
  String dns, {
  Duration timeout = const Duration(seconds: 3),
  // Build 2116 (B13-5, 2106-L5): an accounting note for
  // the caller's journal — today it reports a bootstrap
  // target that consumed its whole share of the deadline
  // in silence, which used to pass unrecorded.
  void Function(String note)? onNote,
}) async {
  var name = host.trim().toLowerCase();
  // A trailing-dot FQDN is the same name; the wire form drops
  // the dot, so the comparison form must too (else a correct
  // answer is rejected and the query waits out its deadline).
  if (name.endsWith('.')) name = name.substring(0, name.length - 1);
  if (name.isEmpty || InternetAddress.tryParse(name) != null) {
    return const []; // a literal needs no resolution
  }
  // Names this minimal wire writer cannot encode — a label over
  // 63 octets, or non-ASCII that would need punycode — fail
  // closed to no pin rather than emitting a malformed question.
  for (final label in name.split('.')) {
    if (label.length > 63 || label.codeUnits.any((c) => c > 0x7F)) {
      return const [];
    }
  }
  final resolver = dns.trim();
  if (resolver.isEmpty) return const [];
  // One deadline for the WHOLE resolution: the timeout is not
  // re-armed per stage or per family, so a slow endpoint can
  // hold a connect for about [timeout], never a multiple of it.
  final deadline = DateTime.now().add(timeout);
  Duration left() {
    final d = deadline.difference(DateTime.now());
    return d.isNegative ? Duration.zero : d;
  }

  try {
    if (resolver.startsWith('https://')) {
      return await _resolveDoH(name, resolver, left);
    }
    return await _resolveUdp(name, resolver, left, onNote: onNote);
  } catch (_) {
    // Catch-ALL, Errors included: a malformed resolver value
    // (an out-of-range port is an ArgumentError, not an
    // Exception) must still land here — provider DNS can never
    // break a connect.
    return const [];
  }
}

/// Whether [dns] is a value the provider-DNS path can use at
/// all: a DoH URL, an IP, or a plain hostname, with an in-range
/// port when one is written. (The resolver itself stays
/// failure-tolerant regardless — an unusable value resolves to
/// no pin, never to a failed connect.)
bool providerDnsUsable(String dns) {
  final v = dns.trim();
  if (v.isEmpty) return false;
  if (v.startsWith('https://')) {
    final u = Uri.tryParse(v);
    if (u == null || u.host.isEmpty) return false;
    return !u.hasPort || (u.port > 0 && u.port <= 65535);
  }
  if (v.contains(' ') || v.contains('/')) return false;
  final (_, port) = _splitResolverAddress(v);
  return port > 0 && port <= 65535;
}

/// Splits a resolver address into (server, port): `host`,
/// `host:port`, a bare IPv6 address, or `[v6]:port`. (Splitting
/// on the last colon alone mangled every IPv6 form.)
(String, int) _splitResolverAddress(String dns) {
  var server = dns;
  var port = 53;
  if (dns.startsWith('[')) {
    final close = dns.indexOf(']');
    if (close > 0) {
      server = dns.substring(1, close);
      final rest = dns.substring(close + 1);
      if (rest.startsWith(':')) {
        port = int.tryParse(rest.substring(1)) ?? 53;
      }
    }
    return (server, port);
  }
  if (dns.indexOf(':') == dns.lastIndexOf(':') && dns.contains(':')) {
    final colon = dns.lastIndexOf(':');
    final p = int.tryParse(dns.substring(colon + 1));
    if (p != null) {
      server = dns.substring(0, colon);
      port = p;
    }
  }
  return (server, port);
}

Future<List<String>> _resolveUdp(
  String host,
  String dns,
  Duration Function() left, {
  void Function(String note)? onNote,
}) async {
  final (server, port) = _splitResolverAddress(dns);
  if (port <= 0 || port > 65535) return const [];
  final addresses = await InternetAddress.lookup(server).timeout(left());
  // Build 2106 (journey audit F-04): EVERY resolved address
  // is tried in turn under the one deadline — builds ≤2105
  // used only addresses.first, so a resolver hostname whose
  // first address was dead (or a dead family listed first)
  // silently lost the pin even when a later address would
  // have answered. The first target that answers anything
  // ends the walk; the deadline is never re-armed.
  // Build 2116 (B13-5, 2106-L5): "in turn" used to mean a
  // SILENT first target waited out the whole shared
  // deadline and the later targets never got a turn at
  // all. Each target now owns a share — the remaining
  // budget divided by the targets still to try (the last
  // target keeps the full remainder) — and a target that
  // spends its whole share in silence is accounted in the
  // caller's journal through onNote.
  for (var i = 0; i < addresses.length; i++) {
    if (left() == Duration.zero) break;
    final target = addresses[i];
    final remaining = addresses.length - i;
    final before = left();
    // This target's own deadline: its share of what is
    // left, never past the walk's deadline.
    final share = remaining <= 1 ? before : before ~/ remaining;
    final targetDeadline = DateTime.now().add(share);
    Duration shareLeft() {
      final d = targetDeadline.difference(DateTime.now());
      final l = left();
      if (d.isNegative) return Duration.zero;
      return d < l ? d : l;
    }

    final answers = await _queryUdpTarget(
      host,
      target,
      port,
      remaining <= 1 ? left : shareLeft,
    );
    if (answers.isNotEmpty) return answers;
    // A target that burned (nearly) its entire share
    // without an answer is worth a journal line — silently
    // eating the deadline was the L5 defect. A target that
    // merely answered empty quickly is not news.
    final consumed = before - left();
    if (remaining > 1 && consumed >= share * 0.9) {
      onNote?.call(
        'Provider DNS bootstrap target ${target.address} '
        'stayed silent for its share of the lookup budget; '
        'trying the next address.',
      );
    }
  }
  return const [];
}

/// One UDP resolver target: both families asked at once over
/// one listen, answers believed only from [target]:[port].
/// Empty when the target stays silent for the remaining
/// budget — the caller then tries the next address.
Future<List<String>> _queryUdpTarget(
  String host,
  InternetAddress target,
  int port,
  Duration Function() left,
) async {
  final socket = await RawDatagramSocket.bind(
    target.type == InternetAddressType.IPv6
        ? InternetAddress.anyIPv6
        : InternetAddress.anyIPv4,
    0,
  );
  try {
    // Both families are asked at once, over ONE listen:
    // RawDatagramSocket is a single-subscription stream — it
    // can be listened to exactly once, ever — so a per-family
    // listen (the shape this replaces) threw on the second
    // family and UDP pins never landed at all.
    final budget = left();
    if (budget == Duration.zero) return const [];
    // The deadline is ABSOLUTE, checked on every datagram:
    // Stream.timeout alone is a per-event-GAP timer that a
    // spray of junk datagrams (all discarded below) would keep
    // resetting — on the poisoned network this feature exists
    // for, that spray would hold the connect open indefinitely.
    final deadline = DateTime.now().add(budget);
    final idForType = <int, int>{};
    for (final qtype in const [1, 28]) {
      var id = Random.secure().nextInt(0x10000);
      while (idForType.containsKey(id)) {
        id = Random.secure().nextInt(0x10000);
      }
      idForType[id] = qtype;
      socket.send(buildDnsQuery(id, host, qtype), target, port);
    }
    final out = <String>[];
    final answered = <int>{};
    try {
      await for (final event in socket.timeout(budget)) {
        if (DateTime.now().isAfter(deadline)) break;
        if (event != RawSocketEvent.read) continue;
        final dg = socket.receive();
        if (dg == null) continue;
        // Only the resolver we asked may answer: on the
        // networks this feature exists for, anyone can race a
        // forged datagram at our ephemeral port.
        if (dg.address != target || dg.port != port) continue;
        if (dg.data.length < 2) continue;
        final id = (dg.data[0] << 8) | dg.data[1];
        final qtype = idForType[id];
        if (qtype == null) continue; // not an answer to us
        if (answered.contains(qtype)) continue; // a retransmit
        final parsed = parseDnsAnswers(dg.data, id, host: host, qtype: qtype);
        if (parsed != null) {
          // One family's silence never discards the other's
          // answers: what arrived is kept, whatever happens
          // to the rest.
          out.addAll(parsed);
          answered.add(qtype);
          if (answered.length == idForType.length) break;
        }
      }
    } on Exception {
      // The wait timed out (or the socket failed) with what it
      // had: the answers already collected stand.
    }
    return out;
  } finally {
    socket.close();
  }
}

Future<List<String>> _resolveDoH(
  String host,
  String url,
  Duration Function() left,
) async {
  final client = HttpClient()..connectionTimeout = left();
  try {
    final out = <String>[];
    for (final qtype in const [1, 28]) {
      if (left() == Duration.zero) break;
      // Per-family isolation, as on the UDP path: a family
      // that times out must not discard the other's answers.
      try {
        final id = Random.secure().nextInt(0x10000);
        final request = await client.postUrl(Uri.parse(url)).timeout(left());
        request.headers.set('content-type', 'application/dns-message');
        request.headers.set('accept', 'application/dns-message');
        request.add(buildDnsQuery(id, host, qtype));
        final response = await request.close().timeout(left());
        if (response.statusCode != 200) {
          // Drain the refused response so its connection is
          // released now, not at the client's force-close.
          try {
            await response.drain<void>().timeout(left());
          } catch (_) {
            // Bounded by the force-close in the finally.
          }
          continue;
        }
        // The body is size-capped as it accumulates: a DNS
        // message has a natural 64 KiB scale, and a hostile or
        // broken endpoint must not stream a connect-time
        // allocation out of the time bound alone.
        final bytes = await response
            .fold<List<int>>([], (all, chunk) {
              if (all.length > 131072) {
                throw const FormatException('provider DNS answer too large');
              }
              return all..addAll(chunk);
            })
            .timeout(left());
        final parsed = parseDnsAnswers(
          Uint8List.fromList(bytes),
          id,
          host: host,
          qtype: qtype,
        );
        if (parsed != null) out.addAll(parsed);
      } catch (_) {
        // Keep the answers already in hand. Catch-all, not
        // just Exception: an Error here (a malformed URL's
        // ArgumentError) must stay inside its family too.
      }
    }
    return out;
  } finally {
    client.close(force: true);
  }
}

/// One DNS query packet (RD set, one question, IN class).
Uint8List buildDnsQuery(int id, String host, int qtype) {
  final labels = host.split('.').where((l) => l.isNotEmpty).toList();
  var size = 12 + 1 + 4;
  for (final l in labels) {
    size += 1 + l.length;
  }
  final out = Uint8List(size);
  final view = ByteData.view(out.buffer);
  view.setUint16(0, id);
  view.setUint16(2, 0x0100); // RD
  view.setUint16(4, 1); // QDCOUNT
  var at = 12;
  for (final l in labels) {
    out[at++] = l.length;
    out.setRange(at, at + l.length, l.codeUnits);
    at += l.length;
  }
  out[at++] = 0;
  view.setUint16(at, qtype);
  view.setUint16(at + 2, 1); // IN
  return out;
}

/// The A/AAAA answers of a response packet, as address strings;
/// null when the packet is not the answer to [id] (a stray or
/// spoofed datagram), so the caller keeps waiting. When [host]
/// and [qtype] are given, the packet's question must match them
/// and the packet must be a response (QR set); an error RCODE
/// is an answer (to our question) with no records, not a stray.
/// Compression pointers in names are followed defensively; a
/// malformed packet yields an empty list, never a throw.
List<String>? parseDnsAnswers(
  Uint8List packet,
  int id, {
  String? host,
  int? qtype,
}) {
  try {
    if (packet.length < 12) return null;
    final view = ByteData.view(packet.buffer, packet.offsetInBytes);
    if (view.getUint16(0) != id) return null;
    final flags = view.getUint16(2);
    if (flags & 0x8000 == 0) return null; // not a response
    final qd = view.getUint16(4);
    // A packet with no question cannot be shown to answer ours.
    if (host != null && qd == 0) return null;
    final an = view.getUint16(6);
    var at = 12;
    for (var i = 0; i < qd; i++) {
      if (i == 0 && host != null) {
        final (name, past) = _readName(packet, at);
        if (name == null || name.toLowerCase() != host.toLowerCase()) {
          return null;
        }
        if (qtype != null &&
            (past + 2 > packet.length || view.getUint16(past) != qtype)) {
          return null;
        }
        at = past;
      } else {
        at = _skipName(packet, at);
      }
      at += 4;
    }
    if (flags & 0x000F != 0) return const []; // RCODE: no records
    final out = <String>[];
    for (var i = 0; i < an; i++) {
      at = _skipName(packet, at);
      if (at + 10 > packet.length) return out;
      final type = view.getUint16(at);
      final rdLength = view.getUint16(at + 8);
      at += 10;
      if (at + rdLength > packet.length) return out;
      if (type == 1 && rdLength == 4) {
        out.add(packet.sublist(at, at + 4).join('.'));
      } else if (type == 28 && rdLength == 16) {
        out.add(formatIpv6Address(packet.sublist(at, at + 16)));
      }
      at += rdLength;
    }
    return out;
  } on Exception {
    return const [];
  }
}

/// A 16-byte IPv6 address in full (uncompressed) text form.
String formatIpv6Address(Uint8List bytes) {
  return [
    for (var i = 0; i < 16; i += 2)
      ((bytes[i] << 8) | bytes[i + 1]).toRadixString(16),
  ].join(':');
}

/// Reads the name at [at] (following one compression pointer);
/// returns its dotted text and the offset just past it in the
/// original stream, or (null, at) when malformed.
(String?, int) _readName(Uint8List packet, int at) {
  final labels = <String>[];
  var guard = 0;
  var cur = at;
  int? past;
  while (cur < packet.length && guard++ < 128) {
    final len = packet[cur];
    if (len == 0) {
      past ??= cur + 1;
      return (labels.join('.'), past);
    }
    if (len & 0xC0 == 0xC0) {
      if (cur + 1 >= packet.length) return (null, at);
      past ??= cur + 2;
      cur = ((len & 0x3F) << 8) | packet[cur + 1];
      continue;
    }
    if (len > 63 || cur + 1 + len > packet.length) return (null, at);
    labels.add(String.fromCharCodes(packet.sublist(cur + 1, cur + 1 + len)));
    cur += 1 + len;
  }
  return (null, at);
}

/// Skips a (possibly compressed) DNS name at [at]; returns the
/// offset just past it in the original stream.
int _skipName(Uint8List packet, int at) {
  var guard = 0;
  while (at < packet.length && guard++ < 128) {
    final len = packet[at];
    if (len == 0) return at + 1;
    if (len & 0xC0 == 0xC0) return at + 2; // pointer: name ends here
    at += 1 + len;
  }
  return at;
}
