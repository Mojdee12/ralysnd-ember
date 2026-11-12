import 'xray_models.dart';

/// A WireGuard `.conf` parser (build 2032): the standalone
/// WireGuard section's import. A `.conf` carries ONE interface
/// (private key, addresses) and one or more peers; Ember's
/// profile model carries one peer per profile (the Xray
/// WireGuard outbound is built per profile), so each peer
/// becomes its own profile sharing the interface fields. The
/// group key ([wgGroupKey]) keeps the peers of one config
/// together — that group is what the peer-fallback connect
/// walks when an endpoint does not answer.
///
/// AmneziaWG configs parse too, but their obfuscation fields
/// (Jc/Jmin/Jmax/S1/S2/H1–H4) have no Xray equivalent: the
/// result flags them so the page can say plainly that the
/// profile will run as plain WireGuard, never silently.
class WgConfResult {
  const WgConfResult({
    required this.profiles,
    required this.amnezia,
    required this.error,
  });

  final List<Profile> profiles;

  /// The source carried AmneziaWG obfuscation parameters.
  final bool amnezia;

  /// Why parsing failed ('' when it did not).
  final String error;

  bool get ok => error.isEmpty && profiles.isNotEmpty;
}

/// The peer-group key: peers imported from one .conf share the
/// interface private key and addresses.
String wgGroupKey(Profile p) => '${p.secretKey}|${p.localAddress}';

/// The identity key of a profile for store-wide dedupe (the
/// v2go fold-in): two profiles are the same server when the
/// protocol, the credentials and the endpoint all match — the
/// name is presentation, not identity.
String profileIdentityKey(Profile p) {
  final cred = p.protocol == Protocol.wireguard
      // The pre-shared key and the tunnel address are part of a
      // WireGuard profile's identity: two configs that differ
      // only in them are different configs, and dedupe must not
      // silently drop one (audit, build 2033).
      ? '${p.secretKey}|${p.peerPublicKey}|${p.preSharedKey}|${p.localAddress}'
      : p.protocol == Protocol.shadowsocks
      ? '${p.method}|${p.uuidOrPassword}'
      : p.protocol == Protocol.socks
      ? '${p.username}|${p.uuidOrPassword}'
      : p.uuidOrPassword;
  return '${p.protocol.name}|$cred|${p.address.toLowerCase()}|${p.port}';
}

const _amneziaKeys = {'jc', 'jmin', 'jmax', 's1', 's2', 'h1', 'h2', 'h3', 'h4'};

/// Parses [text] as a WireGuard `.conf`. [baseName] names the
/// profiles ("<baseName>" for one peer, "<baseName> · 1/N" for
/// several). [idFor] mints profile ids (the controller passes
/// its own generator; tests pass a counter).
WgConfResult parseWgConf(
  String text, {
  required String baseName,
  required String Function() idFor,
}) {
  final sections = <String, Map<String, String>>{};
  final peers = <Map<String, String>>[];
  Map<String, String>? current;
  var amnezia = false;

  // A byte-order mark (build 2033) must not hide the first
  // section header: files saved by Windows editors often
  // carry one, and the pre-2033 parser then reported
  // "no [Interface] section" for a perfectly good config —
  // one of the shapes of "the WireGuard config won't load".
  final body = text.startsWith('\uFEFF') ? text.substring(1) : text;

  for (final raw in body.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#') || line.startsWith(';')) {
      continue;
    }
    if (line.startsWith('[') && line.endsWith(']')) {
      final name = line.substring(1, line.length - 1).trim().toLowerCase();
      current = <String, String>{};
      if (name == 'peer') {
        peers.add(current);
      } else {
        sections[name] = current;
      }
      continue;
    }
    final eq = line.indexOf('=');
    if (eq <= 0 || current == null) continue;
    final key = line.substring(0, eq).trim().toLowerCase();
    // A trailing " # …" / " ; …" comment is cut (build 2033):
    // exported configs annotate values ("Endpoint = …:51820
    // # frankfurt"), and an uncut comment made the port parse
    // fail, which silently dropped the whole peer. None of
    // the values this parser reads (keys, endpoints, address
    // lists) can contain a space followed by # or ;, so the
    // cut is safe.
    final value = line
        .substring(eq + 1)
        .split(' #')
        .first
        .split(' ;')
        .first
        .trim();
    if (_amneziaKeys.contains(key)) amnezia = true;
    current[key] = value;
  }

  final iface = sections['interface'];
  if (iface == null) {
    return const WgConfResult(
      profiles: [],
      amnezia: false,
      error: 'no [Interface] section',
    );
  }
  final privateKey = iface['privatekey'] ?? '';
  if (privateKey.isEmpty) {
    return const WgConfResult(
      profiles: [],
      amnezia: false,
      error: 'the [Interface] section has no PrivateKey',
    );
  }
  if (peers.isEmpty) {
    return const WgConfResult(
      profiles: [],
      amnezia: false,
      error: 'no [Peer] section',
    );
  }
  final addresses = (iface['address'] ?? '')
      .split(',')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .join(',');
  final mtu = int.tryParse(iface['mtu'] ?? '') ?? 1280;

  // AmneziaWG parameters (build 2033): they live in the
  // [Interface] section in the standard layout (a few
  // generators repeat them per [Peer]). They are stored on
  // every profile the file produces — import no longer drops
  // them — even though the carrier runs the profile as plain
  // WireGuard (see the class comment above).
  String awgOf(Map<String, String> peer, String key) =>
      iface[key] ?? peer[key] ?? '';

  final out = <Profile>[];
  for (var i = 0; i < peers.length; i++) {
    final peer = peers[i];
    final publicKey = peer['publickey'] ?? '';
    final endpoint = peer['endpoint'] ?? '';
    if (publicKey.isEmpty || endpoint.isEmpty) continue;
    final (host, port) = _splitEndpoint(endpoint);
    if (host.isEmpty || port <= 0) continue;
    out.add(
      Profile(
        id: idFor(),
        name: peers.length == 1 ? baseName : '$baseName · ${i + 1}/${peers.length}',
        protocol: Protocol.wireguard,
        address: host,
        port: port,
        secretKey: privateKey,
        peerPublicKey: publicKey,
        preSharedKey: peer['presharedkey'] ?? '',
        localAddress: addresses,
        mtu: mtu,
        keepAlive: int.tryParse(peer['persistentkeepalive'] ?? '') ?? 0,
        awgJc: awgOf(peer, 'jc'),
        awgJmin: awgOf(peer, 'jmin'),
        awgJmax: awgOf(peer, 'jmax'),
        awgS1: awgOf(peer, 's1'),
        awgS2: awgOf(peer, 's2'),
        awgH1: awgOf(peer, 'h1'),
        awgH2: awgOf(peer, 'h2'),
        awgH3: awgOf(peer, 'h3'),
        awgH4: awgOf(peer, 'h4'),
      ),
    );
  }
  if (out.isEmpty) {
    return WgConfResult(
      profiles: [],
      amnezia: amnezia,
      error: 'no usable [Peer] (each needs PublicKey and Endpoint)',
    );
  }
  return WgConfResult(profiles: out, amnezia: amnezia, error: '');
}

/// Splits "host:port" and "[v6]:port" endpoints.
(String, int) _splitEndpoint(String endpoint) {
  final e = endpoint.trim();
  if (e.startsWith('[')) {
    final close = e.indexOf(']');
    if (close < 0) return ('', 0);
    final host = e.substring(1, close);
    final rest = e.substring(close + 1);
    if (!rest.startsWith(':')) return ('', 0);
    return (host, int.tryParse(rest.substring(1)) ?? 0);
  }
  final lastColon = e.lastIndexOf(':');
  if (lastColon <= 0) return ('', 0);
  return (
    e.substring(0, lastColon),
    int.tryParse(e.substring(lastColon + 1)) ?? 0,
  );
}
