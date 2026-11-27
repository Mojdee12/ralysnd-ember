/// The wstunnel client's command line (build 2072), built
/// per WireGuard session. Pure and testable; the native side
/// (WstunnelCore.kt) only spawns what it is given.
///
/// wstunnel (erebe/wstunnel v11.1.0, vendored in
/// ~/workspace/ember-app/engines/wstunnel):
///   wstunnel client -L udp://LISTEN:TARGET?timeout_sec=0 WSURL
///
/// The -L target (the real WireGuard endpoint) is dialed by
/// the wstunnel SERVER, so hostname endpoints work unchanged.
/// timeout_sec=0 disables the default 30 s UDP idle timeout —
/// WireGuard keepalive gaps exceed it (the upstream README's
/// own WireGuard example uses it).

/// The fixed local UDP forward port (mirrored in Kotlin:
/// WstunnelCore.PORT).
const wstunnelListenPort = 20861;

/// The client command line forwarding the WireGuard peer at
/// [host]:[port] through the wstunnel server at [url]
/// (ws:// or wss://).
List<String> buildWstunnelArgs({
  required String url,
  required String host,
  required int port,
}) {
  final target = host.contains(':') && !host.startsWith('[')
      ? '[$host]:$port'
      : '$host:$port';
  return [
    'client',
    '-L',
    'udp://127.0.0.1:$wstunnelListenPort:$target?timeout_sec=0',
    url.trim(),
  ];
}

/// True when [url] is a plausible wstunnel server URL.
bool isWstunnelUrl(String url) {
  final t = url.trim();
  return t.startsWith('ws://') || t.startsWith('wss://');
}
