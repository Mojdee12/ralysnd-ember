/// The Mieru client's config for one profile (build 2075).
/// sing-box has no Mieru outbound (verified against
/// sing-box 1.14.4 by config check: "unknown outbound type:
/// mieru"), so Mieru rides its own upstream client binary
/// (libmieru.so, MieruCore.kt). The JSON below follows the
/// upstream client-config protobuf schema
/// (pkg/appctl/proto/clientcfg.proto) and was validated
/// against the real v3.39.0 binary during development:
/// `replace config` accepted it, the daemon started, and
/// its SOCKS port opened.
///
/// The management RPC port is pinned high (28964) so it
/// cannot collide with a separately installed Mieru app's
/// default, and the client's self update check is off.

import 'xray_models.dart';

/// The client daemon's local SOCKS5 port (mirrored in
/// Kotlin: MieruCore.PORT).
const mieruListenPort = 20863;

/// The management RPC port written into the config.
const mieruRpcPort = 28964;

/// Plain-language reason this profile cannot be served by
/// the Mieru client, or null when the config can be built.
String? mieruConfigError(Profile p) {
  if (p.protocol != Protocol.mieru) return 'Not a Mieru config.';
  if (p.address.isEmpty) return 'This Mieru config has no server.';
  if (p.username.isEmpty) return 'This Mieru config has no username.';
  if (p.uuidOrPassword.isEmpty) return 'This Mieru config has no password.';
  return null;
}

/// The Mieru logging level for the app's log-level
/// setting (build 2119, audit F-08): the setting speaks
/// the Xray vocabulary (debug/info/warning/error/none);
/// Mieru wants upper-case names and has no off switch —
/// 'none' maps to its quietest, ERROR. Anything
/// unrecognised keeps the long-standing behaviour, INFO.
/// Mirrors singBoxLogLevel's contract for sing-box.
String mieruLogLevel(String setting) => switch (setting.trim().toLowerCase()) {
  'debug' => 'DEBUG',
  'info' => 'INFO',
  'warn' || 'warning' => 'WARN',
  'error' || 'none' => 'ERROR',
  _ => 'INFO',
};

/// The full client config JSON for [p] (see the file
/// header). The server address goes to domainName when it
/// is not an IP literal (the schema ignores ipAddress when
/// a domain is set, and resolves the domain itself).
/// [logLevel] is the app's log-level setting (build 2119,
/// F-08): the client's log verbosity follows it, mapped by
/// [mieruLogLevel]; the default preserves the hard-coded
/// 'INFO' this builder shipped with up to 2118.
Map<String, dynamic> buildMieruConfig(Profile p, {String logLevel = 'info'}) {
  final isIp = RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(p.address) ||
      p.address.contains(':');
  final transport = p.network.toLowerCase() == 'udp' ? 'UDP' : 'TCP';
  return {
    'profiles': [
      {
        'profileName': 'default',
        'user': {'name': p.username, 'password': p.uuidOrPassword},
        'servers': [
          {
            if (isIp) 'ipAddress': p.address else 'domainName': p.address,
            'portBindings': [
              {'port': p.port, 'protocol': transport},
            ],
          },
        ],
        // No 'mtu' key: the Profile model's mtu defaults to
        // 1420 (a WireGuard-shaped default), which is not a
        // Mieru choice the user made — the client keeps its
        // own default instead of inheriting ours.
      },
    ],
    'activeProfile': 'default',
    'rpcPort': mieruRpcPort,
    'socks5Port': mieruListenPort,
    'loggingLevel': mieruLogLevel(logLevel),
    'advancedSettings': {'noCheckUpdate': true},
  };
}
