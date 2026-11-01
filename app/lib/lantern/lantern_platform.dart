/// The Dart side of the Lantern engine's platform calls (the same
/// 'app/android' channel MainActivity serves).

import 'dart:convert';

import 'package:flutter/services.dart';

class LanternState {
  final bool running;

  /// The core reported a working tunnel (Mobile.isVPNConnected).
  final bool connected;

  /// The service's start sequence failed; [failure] says why.
  final bool failed;
  final String failure;
  final int sinceMs;

  /// The server the core selected, as the core reports it
  /// (radiance's servers.Server JSON): tag + location. All fields
  /// best-effort — the free plan auto-selects and the core only
  /// knows the server once its config has loaded.
  final String serverTag;
  final String serverCity;
  final String serverCountry;
  final String serverCountryCode;

  /// The free plan's data cap, when the core reports one:
  /// bytes allotted / used over the cap window. Null when the core
  /// reports no cap info.
  final int? capAllotted;
  final int? capUsed;

  const LanternState({
    required this.running,
    required this.connected,
    required this.failed,
    required this.failure,
    required this.sinceMs,
    required this.serverTag,
    required this.serverCity,
    required this.serverCountry,
    required this.serverCountryCode,
    required this.capAllotted,
    required this.capUsed,
  });

  static const stopped = LanternState(
    running: false,
    connected: false,
    failed: false,
    failure: '',
    sinceMs: 0,
    serverTag: '',
    serverCity: '',
    serverCountry: '',
    serverCountryCode: '',
    capAllotted: null,
    capUsed: null,
  );

  factory LanternState.fromMap(Map<String, dynamic> m) {
    var tag = '';
    var city = '';
    var country = '';
    var countryCode = '';
    final serverJson = m['server'] as String? ?? '';
    if (serverJson.isNotEmpty) {
      try {
        final doc = jsonDecode(serverJson);
        if (doc is Map) {
          tag = doc['tag']?.toString() ?? '';
          final loc = doc['location'];
          if (loc is Map) {
            city = loc['city']?.toString() ?? '';
            country = loc['country']?.toString() ?? '';
            countryCode = loc['country_code']?.toString() ??
                loc['countryCode']?.toString() ??
                '';
          }
        }
      } catch (_) {
        // A shape we do not know: show nothing rather than guess.
      }
    }
    int? allotted;
    int? used;
    final capJson = m['dataCap'] as String? ?? '';
    if (capJson.isNotEmpty) {
      try {
        final doc = jsonDecode(capJson);
        if (doc is Map && doc['enabled'] == true) {
          final usage = doc['usage'];
          if (usage is Map) {
            allotted = int.tryParse(usage['bytesAllotted']?.toString() ?? '');
            used = int.tryParse(usage['bytesUsed']?.toString() ?? '');
          }
        }
      } catch (_) {
        // As above.
      }
    }
    return LanternState(
      running: m['running'] as bool? ?? false,
      connected: m['connected'] as bool? ?? false,
      failed: m['failed'] as bool? ?? false,
      failure: m['failure'] as String? ?? '',
      sinceMs: (m['sinceMs'] as num?)?.toInt() ?? 0,
      serverTag: tag,
      serverCity: city,
      serverCountry: country,
      serverCountryCode: countryCode,
      capAllotted: allotted,
      capUsed: used,
    );
  }

  /// "City, Country" / "Country" / "" for display.
  String get serverLine {
    if (serverCity.isNotEmpty && serverCountry.isNotEmpty) {
      return '$serverCity, $serverCountry';
    }
    if (serverCountry.isNotEmpty) return serverCountry;
    return serverCity;
  }
}

class LanternPlatform {
  static const _channel = MethodChannel('app/android');

  /// The novpn core's fixed local proxy port (radiance
  /// boxoptions_novpn.go: the mixed SOCKS/HTTP inbound).
  static const socksPort = 1080;

  static Future<void> setOn({required String dns}) =>
      _channel.invokeMethod('lanternSetOn', {'on': true, 'dns': dns});

  static Future<void> stop() => _channel.invokeMethod('lanternStop');

  static Future<LanternState> state() async {
    final m = await _channel.invokeMapMethod<String, dynamic>('lanternState');
    if (m == null) return LanternState.stopped;
    return LanternState.fromMap(m);
  }

  /// The exit IP/country of the running Lantern tunnel, asked
  /// through its own SOCKS proxy. Best-effort: null on any failure.
  static Future<Map<String, String>?> exitInfo() async {
    try {
      final m =
          await _channel.invokeMapMethod<String, dynamic>('lanternExitInfo');
      if (m == null) return null;
      return m.map((k, v) => MapEntry(k, v.toString()));
    } catch (_) {
      return null;
    }
  }
}
