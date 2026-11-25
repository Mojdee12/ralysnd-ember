import 'dart:convert';

import 'package:flutter/services.dart';

/// One server on Lantern's list, as the gomobile core reports
/// it through Mobile.getAvailableServers() (build 2129): the
/// bridge maps each entry to its tag and location. A [tag] is
/// what connectToServer pins. Build 2131: the list carries
/// private servers too — the core stores them with
/// isLantern=false — and the picker marks them.
class LanternServer {
  const LanternServer({
    required this.tag,
    this.city = '',
    this.country = '',
    this.countryCode = '',
    this.isLantern = true,
  });

  factory LanternServer.fromMap(Map<dynamic, dynamic> m) => LanternServer(
    tag: (m['tag'] as String?) ?? '',
    city: (m['city'] as String?) ?? '',
    country: (m['country'] as String?) ?? '',
    countryCode: (m['countryCode'] as String?) ?? '',
    // Payloads from before build 2131 carry no isLantern
    // key; those lists held Lantern entries only.
    isLantern: m['isLantern'] != false,
  );

  final String tag;
  final String city;
  final String country;
  final String countryCode;

  /// False for a private server (the owner's own, registered
  /// through the private-server API); true for Lantern's
  /// public fleet.
  final bool isLantern;

  /// "Country · City" for the picker (the LML label shape).
  String get label {
    if (country.isNotEmpty && city.isNotEmpty) return '$country · $city';
    if (country.isNotEmpty) return country;
    if (city.isNotEmpty) return city;
    return tag;
  }
}

/// Parses the bridge's server-list JSON (a string field of the
/// published state) into servers. Malformed input reads as an
/// empty list — the picker then offers Automatic only.
List<LanternServer> parseLanternServers(String json) {
  try {
    final decoded = jsonDecode(json);
    if (decoded is! List) return const [];
    return [
      for (final entry in decoded)
        if (entry is Map && (entry['tag'] as String? ?? '').isNotEmpty)
          LanternServer.fromMap(entry),
    ];
  } catch (_) {
    return const [];
  }
}

/// The Lantern engine's state, as the :lantern process's
/// LanternVpnService publishes it (build 2129). Connected is
/// the core's own verdict (Mobile.isVPNConnected, polled by
/// the service) — never a local guess: the honesty rule.
class LanternState {
  const LanternState({
    this.available = false,
    this.running = false,
    this.coreRunning = false,
    this.connected = false,
    this.killSwitchHeld = false,
    this.stage = 'idle',
    this.exitCity = '',
    this.exitCountry = '',
    this.exitCode = '',
    this.selectedTag = '',
    this.servers = -1,
    this.serversJson = '[]',
    this.smartRouting = false,
    this.privateResult = '',
    this.sinceMs = 0,
    this.upBytes = 0,
    this.countersReported = false,
    this.downBytes = 0,
    this.error,
  });

  factory LanternState.fromMap(Map<dynamic, dynamic> m) => LanternState(
    available: m['available'] == true,
    running: m['running'] == true,
    coreRunning: m['coreRunning'] == true,
    connected: m['connected'] == true,
    // Build 2125 (audit A25-04): the kill-switch hold flag.
    killSwitchHeld: m['killSwitchHeld'] == true,
    stage: (m['stage'] as String?) ?? 'idle',
    exitCity: (m['exitCity'] as String?) ?? '',
    exitCountry: (m['exitCountry'] as String?) ?? '',
    exitCode: (m['exitCode'] as String?) ?? '',
    selectedTag: (m['selectedTag'] as String?) ?? '',
    servers: (m['servers'] as num?)?.toInt() ?? -1,
    serversJson: (m['serversJson'] as String?) ?? '[]',
    // Build 2129: smart routing through the real API —
    // DEFAULT OFF, forced off at every core init; this is
    // the core's own readback of the setting.
    smartRouting: m['smartRouting'] == true,
    privateResult: (m['privateResult'] as String?) ?? '',
    sinceMs: (m['sinceMs'] as num?)?.toInt() ?? 0,
    upBytes: (m['up'] as num?)?.toInt() ?? 0,
    downBytes: (m['down'] as num?)?.toInt() ?? 0,
    countersReported: m['up'] is num && m['down'] is num,
    error: m['error'] as String?,
  );

  /// False on builds without the gomobile library (non-arm64).
  final bool available;

  /// A session was started and has not been stopped.
  final bool running;

  /// Kept for the shell's engine arbitration: with the
  /// gomobile core there is no separate process to probe, so
  /// this mirrors [running] (the platform fills it in).
  final bool coreRunning;

  /// The core itself reports the VPN connected.
  final bool connected;

  /// Build 2125 (audit A25-04): the kill-switch hold is in
  /// place — the session died unexpectedly and its TUN is
  /// held as a blackhole until the user disconnects or
  /// reconnects.
  final bool killSwitchHeld;

  /// idle | starting | up | error
  final String stage;
  final String exitCity;
  final String exitCountry;

  /// The exit's ISO country code (NL, DE, …), for the map pin.
  final String exitCode;

  /// The tag of the server the core selected, from its own
  /// getSelectedServerJSON readback.
  final String selectedTag;

  /// Servers in the core's current list; -1 until the first
  /// list lands.
  final int servers;

  /// The list itself, verbatim JSON from the bridge.
  final String serversJson;

  /// The core's smart-routing setting (real API readback).
  final bool smartRouting;

  /// The last private-server registration outcome from the
  /// service: "", `ok|<tag>` or `error|<words>`.
  final String privateResult;

  final int sinceMs;
  final int upBytes;
  final int downBytes;

  /// False when the state carried no counter keys at all —
  /// the zeros above are then placeholders, not measurements.
  final bool countersReported;

  /// The last startup/core failure, verbatim from the platform.
  final String? error;

  /// The parsed server list (picker entries after Automatic).
  List<LanternServer> get serverList => parseLanternServers(serversJson);

  bool get starting => running && !connected;

  /// Short human line for the stage, for the home page and bar.
  String get stageLabel => switch (stage) {
    'starting' => 'Starting the core…',
    'up' => 'Connected',
    'error' => 'Failed',
    _ => running ? 'Connecting…' : 'Not connected',
  };

  /// "City, Country" when the core has named its exit.
  String get exitLine {
    if (exitCity.isNotEmpty && exitCountry.isNotEmpty) {
      return '$exitCity, $exitCountry';
    }
    return exitCountry;
  }
}

/// The platform-channel surface of the Lantern engine
/// (MainActivity's lantern* cases; the work happens in the
/// :lantern process, state returns through its snapshot).
class LanternPlatform {
  static const _channel = MethodChannel('app/android');

  static Future<void> setOn({
    required bool on,
    bool ipv6 = true,
    required int mtu,
    String dns = '1.1.1.1',
    // Build 2125 (audit A25-04): the kill switch.
    bool killSwitch = false,
    // Build 2129: the picked server's tag; "" = automatic
    // (Mobile.startVPN), a tag pins (Mobile.connectToServer).
    String tag = '',
    // Build 2149 (audit A43-09): the pinned PRIVATE
    // server's stored identity (country + code), so the
    // service's exit-identity lookup can synthesize the
    // pinned entry when the core's list has no row for it.
    // '' for a public pin or automatic.
    String pinCountry = '',
    String pinCode = '',
    // Build 2149 (audit A43-27): the stored smart-routing
    // choice; the service applies it after core init.
    bool smartOn = false,
  }) => _channel.invokeMethod<void>('lanternSetOn', {
    'on': on,
    'ipv6': ipv6,
    'mtu': mtu,
    'dns': dns,
    'killSwitch': killSwitch,
    'tag': tag,
    'pinCountry': pinCountry,
    'pinCode': pinCode,
    'smartOn': smartOn,
  });

  static Future<void> stop() => _channel.invokeMethod<void>('lanternStop');

  static Future<LanternState> state() async {
    // Build 2116 (AB-11): catch→stopped, like the rest of
    // the platform family — a thrown state read froze the
    // Lantern card on its last state.
    try {
      final m = await _channel.invokeMapMethod<dynamic, dynamic>(
        'lanternState',
      );
      return m == null ? const LanternState() : LanternState.fromMap(m);
    } catch (_) {
      return const LanternState();
    }
  }

  /// Asks the :lantern process to initialize the core and
  /// publish its server list; the list arrives through
  /// [state] (the service publishes it when the fetch lands).
  static Future<void> fetchServers() =>
      _channel.invokeMethod<void>('lanternFetchServers');

  /// The real smart-routing API (Mobile.setSmartRoutingEnabled).
  static Future<void> setSmartRouting(bool on) =>
      _channel.invokeMethod<void>('lanternSetSmartRouting', {'on': on});

  /// Registers a private server through
  /// Mobile.addServerManagerInstance (build 2129, replacing
  /// the 2127 H8 servers.json merge). The outcome arrives in
  /// the state's privateResult.
  static Future<void> addPrivateServer({
    required String ip,
    required int port,
    required String token,
    required String tag,
  }) => _channel.invokeMethod<void>('lanternAddPrivateServer', {
    'ip': ip,
    'port': port,
    'token': token,
    'tag': tag,
  });

  /// Removes a private server by its tag
  /// (Mobile.deletePrivateServerByName).
  static Future<void> removePrivateServer(String tag) =>
      _channel.invokeMethod<void>('lanternRemovePrivateServer', {
        'tag': tag,
      });

  /// Build 2131: switches a RUNNING session to [tag]
  /// ("" = automatic) inside the live tunnel — the service
  /// re-runs the bridge connect, and the core switches via
  /// SelectServer without a TUN rebuild. Build 2149 (audit
  /// A43-09): the pin identity rides along, as on [setOn].
  static Future<void> switchServer(
    String tag, {
    String pinCountry = '',
    String pinCode = '',
  }) => _channel.invokeMethod<void>('lanternSwitch', {
    'tag': tag,
    'pinCountry': pinCountry,
    'pinCode': pinCode,
  });
}
