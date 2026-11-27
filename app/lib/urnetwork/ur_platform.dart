import 'package:flutter/services.dart';

/// The URnetwork engine's published state (build 2156):
/// the :urnetwork process's snapshot, read through
/// MainActivity's urState case — the same shape discipline
/// as LanternState. "connected" is the SDK device's own
/// verdict (its connected-provider list is non-empty),
/// never a local guess.
class UrState {
  const UrState({
    this.available = false,
    this.running = false,
    this.connected = false,
    this.killSwitchHeld = false,
    this.stage = 'idle',
    this.exitCity = '',
    this.exitCountry = '',
    this.exitCode = '',
    this.exitRegion = '',
    this.providers = 0,
    this.reqName = '',
    this.reqCode = '',
    this.sinceMs = 0,
    this.upBytes = 0,
    this.downBytes = 0,
    this.countersReported = false,
    this.error,
  });

  factory UrState.fromMap(Map<dynamic, dynamic> m) => UrState(
    available: m['available'] == true,
    running: m['running'] == true,
    connected: m['connected'] == true,
    killSwitchHeld: m['killSwitchHeld'] == true,
    stage: (m['stage'] as String?) ?? 'idle',
    exitCity: (m['exitCity'] as String?) ?? '',
    exitCountry: (m['exitCountry'] as String?) ?? '',
    exitCode: (m['exitCode'] as String?) ?? '',
    exitRegion: (m['exitRegion'] as String?) ?? '',
    providers: (m['providers'] as num?)?.toInt() ?? 0,
    reqName: (m['reqName'] as String?) ?? '',
    reqCode: (m['reqCode'] as String?) ?? '',
    sinceMs: (m['sinceMs'] as num?)?.toInt() ?? 0,
    upBytes: (m['up'] as num?)?.toInt() ?? 0,
    downBytes: (m['down'] as num?)?.toInt() ?? 0,
    countersReported: m['up'] is num && m['down'] is num,
    error: m['error'] as String?,
  );

  /// False on builds without the shaded SDK library.
  final bool available;

  /// A session was started and has not been stopped.
  final bool running;

  /// The SDK device reports at least one connected
  /// provider — the tunnel's own connected verdict.
  final bool connected;

  /// The kill-switch hold is in place: the session died
  /// unexpectedly and its TUN is held as a blackhole.
  final bool killSwitchHeld;

  /// idle | starting | up | error
  final String stage;

  /// The connected exit, from the SDK's
  /// ConnectedProviderLocation readback.
  final String exitCity;
  final String exitCountry;

  /// The exit's ISO country code (US, DE, …), for the map pin.
  final String exitCode;
  final String exitRegion;

  /// Providers in the device's connected window.
  final int providers;

  /// The location this session was asked for ('' name =
  /// Best Available), echoed by the service for display.
  final String reqName;
  final String reqCode;

  final int sinceMs;
  final int upBytes;
  final int downBytes;

  /// False when the state carried no counter keys at all —
  /// the zeros above are then placeholders, not measurements.
  final bool countersReported;

  /// The last startup/core failure, verbatim from the platform.
  final String? error;

  bool get starting => running && !connected;

  /// Short human line for the stage, for the home page and bar.
  String get stageLabel => switch (stage) {
    'starting' => 'Starting the core…',
    'up' => 'Connected',
    'error' => 'Failed',
    _ => running ? 'Connecting…' : 'Not connected',
  };

  /// "City, Country" when the device has named its exit.
  String get exitLine {
    if (exitCity.isNotEmpty && exitCountry.isNotEmpty) {
      return '$exitCity, $exitCountry';
    }
    return exitCountry;
  }
}

/// The platform-channel surface of the URnetwork engine
/// (MainActivity's ur* cases; the work happens in the
/// :urnetwork process, state returns through its snapshot).
class UrPlatform {
  static const _channel = MethodChannel('app/android');

  /// Starts (or stops) the engine. [jwt] is the account's
  /// cached client JWT from the auth-client exchange — a
  /// credential: it crosses only as this start argument
  /// and is held by the service in memory, never written
  /// to disk there. [locationId] is a provider-locations
  /// country id; '' means Best Available.
  static Future<void> setOn({
    required bool on,
    String jwt = '',
    String locationId = '',
    String locationName = '',
    String locationCode = '',
    required int mtu,
    bool killSwitch = false,
  }) => _channel.invokeMethod<void>('urSetOn', {
    'on': on,
    'jwt': jwt,
    'locationId': locationId,
    'locationName': locationName,
    'locationCode': locationCode,
    'mtu': mtu,
    'killSwitch': killSwitch,
  });

  static Future<void> stop() => _channel.invokeMethod<void>('urStop');

  static Future<UrState> state() async {
    // Build 2116 (AB-11) pattern: catch→stopped — a thrown
    // state read must never freeze the card on its last state.
    try {
      final m = await _channel.invokeMapMethod<dynamic, dynamic>('urState');
      return m == null ? const UrState() : UrState.fromMap(m);
    } catch (_) {
      return const UrState();
    }
  }
}
