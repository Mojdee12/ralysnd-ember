/// The current network's identity (build 2065), shared by the
/// per-network winner memory (item 4) and the auto-connect
/// triggers (item 14). The platform exposes what it can without a
/// location permission: transport always; the Wi-Fi SSID only
/// when Android hands it out; the carrier name on mobile. The
/// [key] degrades honestly to a coarse transport key when nothing
/// finer is exposed — memory keyed 'wifi' still separates Wi-Fi
/// from the mobile carrier, which is where the DPI difference
/// that matters lives.

import 'dart:async';

import 'package:flutter/services.dart';

class NetworkIdentity {
  final String transport; // wifi | mobile | ethernet | other | none
  final String ssid;
  final String operatorName;

  const NetworkIdentity({
    required this.transport,
    this.ssid = '',
    this.operatorName = '',
  });

  static const none = NetworkIdentity(transport: 'none');

  factory NetworkIdentity.fromMap(Map<dynamic, dynamic> m) =>
      NetworkIdentity(
        transport: m['transport'] as String? ?? 'none',
        ssid: m['ssid'] as String? ?? '',
        operatorName: m['operator'] as String? ?? '',
      );

  bool get isWifi => transport == 'wifi';
  bool get isMobile => transport == 'mobile';

  /// The memory key: finest identity the platform exposed.
  String get key {
    switch (transport) {
      case 'wifi':
        return ssid.isNotEmpty ? 'wifi:$ssid' : 'wifi';
      case 'mobile':
        return operatorName.isNotEmpty ? 'mobile:$operatorName' : 'mobile';
      default:
        return transport;
    }
  }
}

class NetworkInfoService {
  static const _channel = MethodChannel('app/android');

  static final StreamController<NetworkIdentity> _changes =
      StreamController<NetworkIdentity>.broadcast();
  static bool _handlerArmed = false;

  /// Fires when Android's default network changes. This service is
  /// the only Dart-side handler on the app channel (all other
  /// platform classes only invoke outwards).
  static Stream<NetworkIdentity> get changes {
    if (!_handlerArmed) {
      _handlerArmed = true;
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'networkChanged' && call.arguments is Map) {
          _changes.add(
            NetworkIdentity.fromMap(call.arguments as Map<dynamic, dynamic>),
          );
        }
        return null;
      });
    }
    return _changes.stream;
  }

  static Future<NetworkIdentity> current() async {
    try {
      final m = await _channel.invokeMapMethod<String, dynamic>('networkInfo');
      if (m == null) return NetworkIdentity.none;
      return NetworkIdentity.fromMap(m);
    } catch (_) {
      return NetworkIdentity.none;
    }
  }

  /// Reads (and clears) the boot flag BootReceiver recorded.
  static Future<bool> consumeBootPending() async {
    try {
      return await _channel.invokeMethod<bool>('consumeBootPending') ?? false;
    } catch (_) {
      return false;
    }
  }
}
