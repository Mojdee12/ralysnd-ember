/// Parsing and modelling of .ovpn profiles for the OpenVPN
/// engine (build 2025). The core takes the profile text almost
/// verbatim; this layer reads out what the UI and the connect
/// flow need (remotes, protocol, credential and control-channel
/// requirements), normalizes the one directive the core would
/// otherwise misread, and surfaces the directives a phone
/// cannot honour instead of silently dropping them.

/// One remote endpoint of a profile.
class OvpnRemote {
  const OvpnRemote({required this.host, required this.port, this.proto});

  final String host;
  final int port;

  /// udp | tcp (from the remote line or the profile's proto).
  final String? proto;
}

/// A parsed .ovpn profile.
class OvpnProfile {
  const OvpnProfile({
    required this.id,
    required this.name,
    required this.config,
    required this.remotes,
    required this.proto,
    required this.needsAuth,
    required this.hasInlineCredentials,
    required this.authenticatedControl,
    required this.unsupported,
    this.credKey = '',
  });

  /// Store id: a generated id for the user's own imports.
  /// (Build 2028 removed the bundled TunnelBear pack — the
  /// engine is a generic client for imported profiles only,
  /// by the owner's ruling.)
  final String id;
  final String name;

  /// The profile text as the core receives it.
  final String config;
  final List<OvpnRemote> remotes;

  /// udp | tcp — the first remote's protocol, else the proto line.
  final String proto;

  /// The profile asks for username/password authentication.
  final bool needsAuth;

  /// Username/password ride inside the profile text itself
  /// (an `<auth-user-pass>` block). Such profiles are used
  /// as-is and never need the vault.
  final bool hasInlineCredentials;

  /// tls-auth / tls-crypt present: the control channel is
  /// authenticated, so a bare UDP probe cannot measure latency
  /// (the platform probe reports that honestly).
  final bool authenticatedControl;

  /// Directives a phone cannot honour (scripts, plugins,
  /// external files, …), named for the UI. The core would
  /// reject or ignore them; they are shown, never hidden.
  final List<String> unsupported;

  /// Vault key holding this profile's saved credentials —
  /// the profile's own id (build 2028: credentials are
  /// per-profile only; there is no shared account entry).
  /// Empty = ask at connect time, never save.
  final String credKey;

  OvpnRemote? get firstRemote => remotes.isEmpty ? null : remotes.first;

  /// Parses [text] into a profile. Never throws: a profile the
  /// parser cannot make sense of still imports, and the core's
  /// own evaluation (validate on connect) gives the verdict.
  factory OvpnProfile.parse({
    required String id,
    required String name,
    required String text,
    String credKey = '',
  }) {
    final remotes = <OvpnRemote>[];
    String? protoLine;
    var needsAuth = false;
    var hasInlineCredentials = false;
    var authenticatedControl = false;
    final unsupported = <String>[];
    var inAuthBlock = false;

    for (final raw in text.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      if (inAuthBlock) {
        if (line == '</auth-user-pass>') inAuthBlock = false;
        continue;
      }
      if (line.startsWith('#') || line.startsWith(';')) continue;
      final parts = line.split(RegExp(r'\s+'));
      final head = parts.first.toLowerCase();
      switch (head) {
        case '<auth-user-pass>':
          inAuthBlock = true;
          hasInlineCredentials = true;
          needsAuth = true;
        case 'remote':
          if (parts.length >= 2) {
            remotes.add(
              OvpnRemote(
                host: parts[1],
                port: parts.length >= 3 ? int.tryParse(parts[2]) ?? 1194 : 1194,
                proto: parts.length >= 4 ? parts[3].toLowerCase() : null,
              ),
            );
          }
        case 'proto':
          if (parts.length >= 2) protoLine = parts[1].toLowerCase();
        case 'auth-user-pass':
          needsAuth = true;
          // "auth-user-pass <file>" names an external file the
          // import cannot carry; a bare one is the normal prompt.
          if (parts.length >= 2) {
            unsupported.add('auth-user-pass file (${parts[1]})');
          }
        case 'tls-auth':
        case 'tls-crypt':
        case 'tls-crypt-v2':
          authenticatedControl = true;
        case '<tls-auth>':
        case '<tls-crypt>':
        case '<tls-crypt-v2>':
          authenticatedControl = true;
      }
      // Directives that cannot work on a phone, named honestly.
      // External key/cert file references only count when they
      // are not inlined as <tag> blocks (checked after the loop).
      if (_externalFileDirectives.contains(head) && parts.length >= 2) {
        unsupported.add('$head file (${parts[1]})');
      } else if (_unsupportedDirectives.contains(head)) {
        unsupported.add(head);
      }
    }

    // An external reference whose material IS inlined is fine.
    for (final tag in ['ca', 'cert', 'key', 'tls-auth', 'tls-crypt']) {
      if (text.contains('<$tag>')) {
        unsupported.removeWhere((u) => u.startsWith('$tag file'));
      }
    }
    // Inline credentials make the external auth file moot too.
    if (hasInlineCredentials) {
      unsupported.removeWhere((u) => u.startsWith('auth-user-pass file'));
    }

    final proto = _normalizeProto(
      (remotes.isEmpty ? null : remotes.first.proto) ?? protoLine ?? 'udp',
    );
    return OvpnProfile(
      id: id,
      name: name,
      config: normalizeConfig(text),
      remotes: remotes,
      proto: proto,
      needsAuth: needsAuth,
      hasInlineCredentials: hasInlineCredentials,
      authenticatedControl: authenticatedControl,
      unsupported: unsupported,
      credKey: credKey,
    );
  }

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'config': config};

  /// A stored user profile (its parse is recomputed from text).
  factory OvpnProfile.fromJson(Map<dynamic, dynamic> j) => OvpnProfile.parse(
    id: (j['id'] as String?) ?? '',
    name: (j['name'] as String?) ?? 'Profile',
    text: (j['config'] as String?) ?? '',
    credKey: (j['id'] as String?) ?? '',
  );
}

/// Directives backed by external files; fine when inlined.
const _externalFileDirectives = {'ca', 'cert', 'key', 'tls-auth', 'tls-crypt'};

/// Directives the phone build cannot honour at all.
const _unsupportedDirectives = {
  // Build 2119 (audit F-07): compression. Ember applies
  // neither comp-lzo nor compress itself — up to 2118 a
  // profile carrying them rode verbatim to the native
  // core, unapplied by app code, unstripped, and never
  // flagged. They are flagged now, like the rest of this
  // set (the native library's own negotiated-compression
  // behaviour is its own property, not an app feature).
  'comp-lzo',
  'compress',
  'up',
  'down',
  'route-up',
  'route-pre-down',
  'ipchange',
  'learn-address',
  'client-connect',
  'client-disconnect',
  'auth-user-pass-verify',
  'plugin',
  'script-security',
  'management',
  'dh',
  'pkcs12',
  'crl-verify',
  'secret',
  'ifconfig-pool-persist',
  'status',
  'log',
  'log-append',
  'daemon',
  'writepid',
  'chroot',
  'setenv',
};

String _normalizeProto(String p) {
  if (p.startsWith('tcp')) return 'tcp';
  return 'udp';
}

/// The normalizations the core needs, applied to the profile
/// text at import (and re-applied on every store load, since
/// [OvpnProfile.parse] runs it):
///
/// 1. openvpn3 ignores "data-ciphers" and falls back to a
///    cipher it then refuses (BF-CBC), so when a profile
///    declares data-ciphers without a plain cipher line, the
///    first data cipher becomes the cipher line.
/// 2. The legacy `ns-cert-type server|client` directive
///    (build 2029A; device-proven 2026-11-04): modern servers
///    no longer carry the nsCertType extension in their leaf
///    certificates, so the core's verify fails with "bad
///    ns-cert-type in leaf certificate" (CERT_VERIFY_FAIL).
///    The modern equivalent is `remote-cert-tls`, which checks
///    the key-usage/EKU extensions those servers DO carry —
///    the owner's one-line hand edit of exactly this shape
///    connected. A config that already has a remote-cert-tls
///    line keeps it; the legacy line is dropped, not
///    duplicated.
///
/// Everything else passes through untouched.
String normalizeConfig(String text) {
  var hasCipher = false;
  String? firstDataCipher;
  var hasRemoteCertTls = false;
  for (final raw in text.split('\n')) {
    final line = raw.trim();
    final parts = line.split(RegExp(r'\s+'));
    if (parts.first.toLowerCase() == 'cipher') hasCipher = true;
    if (parts.first.toLowerCase() == 'data-ciphers' && parts.length >= 2) {
      firstDataCipher = parts[1].split(':').first;
    }
    if (parts.first.toLowerCase() == 'remote-cert-tls') {
      hasRemoteCertTls = true;
    }
  }
  final outLines = <String>[];
  var changed = false;
  for (final raw in text.split('\n')) {
    final line = raw.trim();
    final parts = line.split(RegExp(r'\s+'));
    if (parts.first.toLowerCase() == 'ns-cert-type' && parts.length >= 2) {
      changed = true;
      final kind = parts[1].toLowerCase();
      if (!hasRemoteCertTls && (kind == 'server' || kind == 'client')) {
        outLines.add('remote-cert-tls $kind');
        hasRemoteCertTls = true;
      }
      continue; // The legacy line never survives.
    }
    outLines.add(raw);
  }
  var result = changed ? outLines.join('\n') : text;
  if (!hasCipher && firstDataCipher != null) {
    final sep = result.endsWith('\n') ? '' : '\n';
    result = '$result${sep}cipher $firstDataCipher\n';
  }
  return result;
}

/// The credential pair inside an `<auth-user-pass>` block
/// (first two non-empty lines), or null when the profile has
/// no such block (or the block is empty). The core never reads
/// credentials from the profile text — openvpn3 takes them
/// only through its API — so a block left in place is a pair
/// the session will never see: the server asks, the core has
/// nothing, and the attempt dies with NEED_CREDS (build
/// 2029A; the owner's second-remote fall-through attempt died
/// exactly this way). The importer therefore lifts the pair
/// into the encrypted vault and strips the block.
({String user, String pass})? inlineCredentialsOf(String text) {
  var inBlock = false;
  final lines = <String>[];
  for (final raw in text.split('\n')) {
    final line = raw.trim();
    if (!inBlock && line.toLowerCase() == '<auth-user-pass>') {
      inBlock = true;
      continue;
    }
    if (inBlock) {
      if (line.toLowerCase() == '</auth-user-pass>') break;
      if (line.isNotEmpty) lines.add(line);
    }
  }
  if (!inBlock && lines.isEmpty) return null;
  if (lines.isEmpty) return null;
  return (user: lines.first, pass: lines.length >= 2 ? lines[1] : '');
}

/// [text] with any `<auth-user-pass>` block replaced by the
/// bare `auth-user-pass` directive, so the stored profile
/// text carries no plaintext credentials (they live in the
/// vault instead — see [inlineCredentialsOf]).
String stripInlineCredentials(String text) {
  final out = StringBuffer();
  var inBlock = false;
  var replaced = false;
  for (final raw in text.split('\n')) {
    final line = raw.trim().toLowerCase();
    if (!inBlock && line == '<auth-user-pass>') {
      inBlock = true;
      if (!replaced) {
        out.writeln('auth-user-pass');
        replaced = true;
      }
      continue;
    }
    if (inBlock) {
      if (line == '</auth-user-pass>') inBlock = false;
      continue;
    }
    out.writeln(raw);
  }
  return out.toString();
}

/// A stable, content-derived id for an imported profile
/// (build 2029A): FNV-1a 64 over the normalized config text.
/// Re-importing the same profile content — the natural way to
/// apply a hand edit, which is how the owner's ns-cert-type
/// fix reached the app — must land on the SAME profile, not a
/// fresh `user-<timestamp>` id: saved credentials are keyed by
/// profile id, so a new id orphans the vault entry and the
/// next connect reaches the server with no credentials at all
/// (NEED_CREDS). Content addressing makes import idempotent.
String ovpnContentId(String normalizedConfig) {
  var hash = 0xcbf29ce484222325;
  for (final byte in normalizedConfig.codeUnits) {
    hash ^= byte & 0xff;
    hash = (hash * 0x100000001b3) & 0xffffffffffffffff;
    if (byte > 0xff) {
      hash ^= (byte >> 8) & 0xff;
      hash = (hash * 0x100000001b3) & 0xffffffffffffffff;
    }
  }
  return 'user-${hash.toRadixString(16).padLeft(16, '0')}';
}
