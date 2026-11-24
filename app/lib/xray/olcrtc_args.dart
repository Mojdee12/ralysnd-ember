// The OLCRTC client's config (build 2134), built from the
// Xray settings. Pure and testable; the native side
// (OlcrtcCore.kt) only spawns what it is given.
//
// olcrtc (openlibrecommunity/olcrtc, vendored in
// ~/workspace/ember-app/engines/olcrtc) carries TCP over
// WebRTC data/video channels disguised as a video call on
// an SFU service (Jitsi, Telemost, WBStream). The binary
// takes exactly one argument — a YAML config file — and
// in client mode (`mode: cnc`) exposes a local SOCKS5
// listener; Ember runs it as the V2Ray chain underlay and
// the Xray outbound is a SOCKS outbound aimed at that
// listener. The server end is the same binary in
// `mode: srv` with the same room and key, run by the user
// on their own host.
//
// The YAML below is upstream's real schema
// (docs/configuration.md): strict — an unknown key is a
// load error — so only documented fields are emitted, and
// the optional transport blocks ride along only when the
// user set a value (empty = upstream default).

import 'xray_models.dart';

/// The fixed local listen port (mirrored in Kotlin:
/// OlcrtcCore.PORT). 20866 verified free against every
/// staged helper: 20850–20854 EmberWarp, 20860 DNSTT,
/// 20861 wstunnel, 20862 sing-box, 20863 Mieru, 20864
/// Zapret, 20865 sudokubox, 20870 cfwarp.
const olcrtcListenPort = 20866;

/// The providers upstream ships (docs/settings.md).
const kOlcrtcProviders = {'jitsi', 'telemost', 'wbstream'};

/// The transports upstream ships (docs/settings.md).
const kOlcrtcTransports = {
  'datachannel',
  'vp8channel',
  'seichannel',
  'videochannel',
};

/// An olcrtc shared key is 32 bytes as 64 hex digits — the
/// client's own requirement (it refuses to start without
/// one).
bool isOlcrtcKey(String v) {
  final t = v.trim();
  if (t.length != 64) return false;
  return RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(t);
}

/// True when the OLCRTC fields are complete enough to
/// spawn: a known provider and transport, a room, and a
/// 64-hex-digit key.
bool olcrtcConfigured(XraySettings s) {
  if (!kOlcrtcProviders.contains(s.olcrtcProvider)) return false;
  if (!kOlcrtcTransports.contains(s.olcrtcTransport)) return false;
  if (s.olcrtcRoom.trim().isEmpty) return false;
  return isOlcrtcKey(s.olcrtcKey);
}

/// A YAML double-quoted scalar: the config loader is
/// strict, and room URLs / tokens may carry characters a
/// plain scalar cannot.
String _q(String v) {
  final b = StringBuffer('"');
  for (final rune in v.runes) {
    switch (rune) {
      case 0x22:
        b.write(r'\"');
      case 0x5C:
        b.write(r'\\');
      case 0x0A:
        b.write(r'\n');
      case 0x0D:
        b.write(r'\r');
      case 0x09:
        b.write(r'\t');
      default:
        if (rune < 0x20) {
          b.write('\\x${rune.toRadixString(16).padLeft(2, '0')}');
        } else {
          b.writeCharCode(rune);
        }
    }
  }
  b.write('"');
  return b.toString();
}

/// Appends one `  name: value` line to [b] when the stored
/// string parses as an integer — a crafted or corrupt
/// stored value is omitted (upstream default) rather than
/// breaking the strict config load.
void _intField(StringBuffer b, String name, String raw) {
  final v = int.tryParse(raw.trim());
  if (v == null) return;
  b.writeln('  $name: $v');
}

/// The client YAML for the settings (upstream schema; see
/// the file header). The `net.dns` value is the olcrtc
/// process's OWN resolver for reaching the SFU service —
/// an upstream-required field of ITS config format, not
/// Ember's DNS stack (which this file never touches).
String buildOlcrtcYaml(XraySettings s) {
  final b = StringBuffer()
    ..writeln('mode: cnc')
    ..writeln('auth:')
    ..writeln('  provider: ${s.olcrtcProvider}');
  if (s.olcrtcToken.trim().isNotEmpty) {
    b.writeln('  token: ${_q(s.olcrtcToken.trim())}');
  }
  b
    ..writeln('room:')
    ..writeln('  id: ${_q(s.olcrtcRoom.trim())}')
    ..writeln('crypto:')
    ..writeln('  key: ${_q(s.olcrtcKey.trim())}')
    ..writeln('net:')
    ..writeln('  transport: ${s.olcrtcTransport}')
    ..writeln('  dns: ${_q(s.olcrtcDns.trim())}');
  switch (s.olcrtcTransport) {
    case 'vp8channel':
      final body = StringBuffer();
      _intField(body, 'fps', s.olcrtcVp8Fps);
      _intField(body, 'batch_size', s.olcrtcVp8Batch);
      if (body.isNotEmpty) b.write('vp8:\n$body');
    case 'seichannel':
      final body = StringBuffer();
      _intField(body, 'fps', s.olcrtcSeiFps);
      _intField(body, 'batch_size', s.olcrtcSeiBatch);
      _intField(body, 'fragment_size', s.olcrtcSeiFrag);
      _intField(body, 'ack_timeout_ms', s.olcrtcSeiAckMs);
      if (body.isNotEmpty) b.write('sei:\n$body');
    case 'videochannel':
      final body = StringBuffer();
      _intField(body, 'width', s.olcrtcVideoWidth);
      _intField(body, 'height', s.olcrtcVideoHeight);
      _intField(body, 'fps', s.olcrtcVideoFps);
      final codec = s.olcrtcVideoCodec.trim();
      if (codec == 'qrcode' || codec == 'tile') {
        body.writeln('  codec: $codec');
      }
      _intField(body, 'qr_size', s.olcrtcVideoQrSize);
      final recovery = s.olcrtcVideoQrRecovery.trim();
      if (const {'low', 'medium', 'high', 'highest'}.contains(recovery)) {
        body.writeln('  qr_recovery: $recovery');
      }
      _intField(body, 'tile_module', s.olcrtcVideoTileModule);
      _intField(body, 'tile_rs', s.olcrtcVideoTileRs);
      if (body.isNotEmpty) b.write('video:\n$body');
  }
  b
    ..writeln('socks:')
    ..writeln('  host: "127.0.0.1"')
    ..writeln('  port: $olcrtcListenPort');
  return b.toString();
}

/// A parsed `olcrtc://` share link (upstream's client
/// convention, docs/uri.md — olcrtc itself does not parse
/// the URI; clients do):
///   `olcrtc://<Provider>?<Transport><k=v&...>@<RoomID>#<Key>$<comment>`
/// The payload block `<...>` is present only when the
/// transport carries non-default parameters.
class OlcrtcLink {
  final String provider;
  final String transport;

  /// Transport parameters by their URI key (e.g. 'vp8-fps').
  final Map<String, String> params;
  final String room;
  final String key;

  /// The free-form comment after '$' (UI metadata only).
  final String comment;

  const OlcrtcLink({
    required this.provider,
    required this.transport,
    this.params = const {},
    required this.room,
    required this.key,
    this.comment = '',
  });
}

String _decode(String v) {
  if (!v.contains('%')) return v;
  try {
    return Uri.decodeComponent(v);
  } catch (_) {
    return v;
  }
}

/// Parses an `olcrtc://` link; null when the shape is not
/// one (wrong scheme, missing separators, an unknown
/// provider/transport, or a key that is not 64 hex).
OlcrtcLink? parseOlcrtcLink(String raw) {
  final text = raw.trim();
  const scheme = 'olcrtc://';
  if (!text.toLowerCase().startsWith(scheme)) return null;
  var rest = text.substring(scheme.length);
  final q = rest.indexOf('?');
  if (q <= 0) return null;
  final provider = rest.substring(0, q).trim().toLowerCase();
  if (!kOlcrtcProviders.contains(provider)) return null;
  rest = rest.substring(q + 1);
  // Transport name runs to '<' (payload) or '@' (room).
  var i = 0;
  while (i < rest.length && rest[i] != '<' && rest[i] != '@') {
    i++;
  }
  if (i == rest.length) return null;
  final transport = rest.substring(0, i).trim().toLowerCase();
  if (!kOlcrtcTransports.contains(transport)) return null;
  rest = rest.substring(i);
  final params = <String, String>{};
  if (rest.startsWith('<')) {
    final close = rest.indexOf('>');
    if (close < 0) return null;
    final payload = rest.substring(1, close);
    for (final pair in payload.split('&')) {
      final eq = pair.indexOf('=');
      if (eq <= 0) continue;
      params[pair.substring(0, eq).trim()] = pair.substring(eq + 1).trim();
    }
    rest = rest.substring(close + 1);
  }
  if (!rest.startsWith('@')) return null;
  rest = rest.substring(1);
  final hash = rest.indexOf('#');
  if (hash < 0) return null;
  final room = _decode(rest.substring(0, hash).trim());
  rest = rest.substring(hash + 1);
  var comment = '';
  final dollar = rest.indexOf(r'$');
  if (dollar >= 0) {
    comment = _decode(rest.substring(dollar + 1).trim());
    rest = rest.substring(0, dollar);
  }
  final key = rest.trim();
  if (room.isEmpty || !isOlcrtcKey(key)) return null;
  return OlcrtcLink(
    provider: provider,
    transport: transport,
    params: params,
    room: room,
    key: key,
    comment: comment,
  );
}

/// Applies a parsed link's transport parameters to the
/// settings' per-transport fields (the URI keys are
/// upstream's, docs/uri.md). Fields the link does not
/// carry are left as they are.
void applyOlcrtcLinkParams(XraySettings s, OlcrtcLink link) {
  final p = link.params;
  String take(String key) => p[key] ?? '';
  switch (link.transport) {
    case 'vp8channel':
      if (p.containsKey('vp8-fps')) s.olcrtcVp8Fps = take('vp8-fps');
      if (p.containsKey('vp8-batch')) s.olcrtcVp8Batch = take('vp8-batch');
    case 'seichannel':
      if (p.containsKey('fps')) s.olcrtcSeiFps = take('fps');
      if (p.containsKey('batch')) s.olcrtcSeiBatch = take('batch');
      if (p.containsKey('frag')) s.olcrtcSeiFrag = take('frag');
      if (p.containsKey('ack-ms')) s.olcrtcSeiAckMs = take('ack-ms');
    case 'videochannel':
      if (p.containsKey('video-w')) s.olcrtcVideoWidth = take('video-w');
      if (p.containsKey('video-h')) s.olcrtcVideoHeight = take('video-h');
      if (p.containsKey('video-fps')) s.olcrtcVideoFps = take('video-fps');
      if (p.containsKey('video-codec')) {
        s.olcrtcVideoCodec = take('video-codec');
      }
      if (p.containsKey('video-qr-size')) {
        s.olcrtcVideoQrSize = take('video-qr-size');
      }
      if (p.containsKey('video-qr-recovery')) {
        s.olcrtcVideoQrRecovery = take('video-qr-recovery');
      }
      if (p.containsKey('video-tile-module')) {
        s.olcrtcVideoTileModule = take('video-tile-module');
      }
      if (p.containsKey('video-tile-rs')) {
        s.olcrtcVideoTileRs = take('video-tile-rs');
      }
  }
}

/// The share link for the current settings (the inverse
/// of [parseOlcrtcLink]), for copy-out from the settings
/// page. Only parameters that differ from upstream
/// defaults (non-empty stored values) are carried.
String buildOlcrtcLink(XraySettings s, {String comment = ''}) {
  final params = <String>[];
  void add(String key, String raw) {
    if (raw.trim().isNotEmpty) params.add('$key=${raw.trim()}');
  }

  switch (s.olcrtcTransport) {
    case 'vp8channel':
      add('vp8-fps', s.olcrtcVp8Fps);
      add('vp8-batch', s.olcrtcVp8Batch);
    case 'seichannel':
      add('fps', s.olcrtcSeiFps);
      add('batch', s.olcrtcSeiBatch);
      add('frag', s.olcrtcSeiFrag);
      add('ack-ms', s.olcrtcSeiAckMs);
    case 'videochannel':
      add('video-w', s.olcrtcVideoWidth);
      add('video-h', s.olcrtcVideoHeight);
      add('video-fps', s.olcrtcVideoFps);
      add('video-codec', s.olcrtcVideoCodec);
      add('video-qr-size', s.olcrtcVideoQrSize);
      add('video-qr-recovery', s.olcrtcVideoQrRecovery);
      add('video-tile-module', s.olcrtcVideoTileModule);
      add('video-tile-rs', s.olcrtcVideoTileRs);
  }
  final payload = params.isEmpty ? '' : '<${params.join('&')}>';
  final suffix = comment.trim().isEmpty ? '' : '\$${comment.trim()}';
  return 'olcrtc://${s.olcrtcProvider}?${s.olcrtcTransport}$payload'
      '@${s.olcrtcRoom.trim()}#${s.olcrtcKey.trim()}$suffix';
}
