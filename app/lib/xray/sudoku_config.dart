import 'xray_models.dart';

/// The Sudoku engine's local SOCKS port (build 2127, H2).
/// 20862 is sing-box's, 20863 Mieru's, 20864 the Zapret
/// Lab proxy's, 20870 cfwarp's — this one is free.
const int sudokuListenPort = 20865;

/// Build 2127 (H2): the config for the Sudoku sidecar —
/// Hiddify's sing-box fork built with its with_sudoku tag
/// (engines/sudokubox/). Sudoku exists in NO other engine
/// in the app: the official sing-box 1.14.4 has no sudoku
/// outbound at all (its option package has no h_sudoku.go),
/// and the Xray core has never heard of it.
///
/// The shape mirrors singbox_config.dart's minimal config:
/// one mixed inbound on loopback, one sudoku outbound,
/// route final = the outbound. The outbound grammar is
/// the fork's option/h_sudoku.go SudokuOutboundOptions
/// verbatim (key required; aead_method / padding_min /
/// padding_max / table_type / enable_pure_downlink /
/// custom_table / custom_tables / multiplex / http_mask),
/// validated against the fork's own TestH_Sudoku and by
/// `sing-box check` on a host build of the same source.

/// The first reason [p] cannot run as a Sudoku profile,
/// or null when it can. Checked before the sidecar ever
/// starts, so a bad profile fails in plain words.
String? sudokuConfigError(Profile p) {
  if (p.protocol != Protocol.sudoku) return 'not a Sudoku profile';
  if (p.address.isEmpty) return 'A Sudoku profile needs a server address.';
  if (p.port < 1 || p.port > 65535) {
    return 'A Sudoku profile needs a valid server port.';
  }
  if (p.uuidOrPassword.isEmpty) {
    return 'A Sudoku profile needs its key (a password or a keypair).';
  }
  final opts = p.sudokuOpts;
  final aead = opts['aeadMethod'];
  if (aead is String &&
      aead.isNotEmpty &&
      aead != 'chacha20-poly1305' &&
      aead != 'aes-128-gcm' &&
      aead != 'none') {
    return 'Sudoku AEAD method "$aead" is not one the engine accepts '
        '(chacha20-poly1305, aes-128-gcm, none).';
  }
  final table = opts['tableType'];
  if (table is String &&
      table.isNotEmpty &&
      table != 'prefer_entropy' &&
      table != 'prefer_ascii' &&
      table != 'up_ascii_down_entropy' &&
      table != 'up_entropy_down_ascii') {
    return 'Sudoku table type "$table" is not one the engine accepts.';
  }
  final min = opts['paddingMin'];
  final max = opts['paddingMax'];
  if (min is num && max is num && min > max) {
    return 'Sudoku padding minimum is above its maximum.';
  }
  return null;
}

/// The sidecar config for [p]. Callers gate on
/// [sudokuConfigError] first; a key the core would reject
/// still produces a config here (the core's own error then
/// surfaces through the sidecar start path).
Map<String, dynamic> buildSudokuConfig(Profile p, {String logLevel = 'warn'}) {
  final opts = p.sudokuOpts;
  final outbound = <String, dynamic>{
    'type': 'sudoku',
    'tag': 'proxy',
    'server': p.address,
    'server_port': p.port,
    'key': p.uuidOrPassword,
  };
  final aead = opts['aeadMethod'];
  if (aead is String && aead.isNotEmpty) outbound['aead_method'] = aead;
  final paddingMin = opts['paddingMin'];
  if (paddingMin is num) outbound['padding_min'] = paddingMin.toInt();
  final paddingMax = opts['paddingMax'];
  if (paddingMax is num) outbound['padding_max'] = paddingMax.toInt();
  final tableType = opts['tableType'];
  if (tableType is String && tableType.isNotEmpty) {
    outbound['table_type'] = tableType;
  }
  final pureDownlink = opts['pureDownlink'];
  if (pureDownlink is bool) {
    outbound['enable_pure_downlink'] = pureDownlink;
  }
  final customTable = opts['customTable'];
  if (customTable is String && customTable.isNotEmpty) {
    outbound['custom_table'] = customTable;
  }
  final customTables = opts['customTables'];
  if (customTables is List && customTables.isNotEmpty) {
    outbound['custom_tables'] = [
      for (final t in customTables) t.toString(),
    ];
  }
  final multiplex = opts['multiplex'];
  if (multiplex is String && multiplex.isNotEmpty) {
    outbound['multiplex'] = multiplex;
  }
  if (opts['httpMask'] == true) {
    final mask = <String, dynamic>{'enabled': true};
    final mode = opts['httpMaskMode'];
    if (mode is String && mode.isNotEmpty) mask['mode'] = mode;
    final host = opts['httpMaskHost'];
    if (host is String && host.isNotEmpty) mask['host'] = host;
    final pathRoot = opts['httpMaskPathRoot'];
    if (pathRoot is String && pathRoot.isNotEmpty) {
      mask['path_root'] = pathRoot;
    }
    outbound['http_mask'] = mask;
  }
  return {
    'log': {'level': logLevel, 'timestamp': true},
    'inbounds': [
      {
        'type': 'mixed',
        'tag': 'in',
        'listen': '127.0.0.1',
        'listen_port': sudokuListenPort,
      },
    ],
    'outbounds': [outbound],
    'route': {'final': 'proxy'},
  };
}
