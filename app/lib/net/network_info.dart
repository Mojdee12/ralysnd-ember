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

import 'launcher_shortcuts.dart';

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

/// One .ovpn file opened with / shared to Ember (build 2085,
/// audit F-H15): the file's [name] and [content], or [error]
/// ('file-too-large' | 'unreadable') when the platform could not
/// hand the file over. The shape is the picker's {name, content},
/// so the import path treats both alike.
class OvpnIntentFile {
  const OvpnIntentFile({
    required this.name,
    required this.content,
    this.error,
  });

  final String name;
  final String content;
  final String? error;

  bool get isError => error != null;

  factory OvpnIntentFile.fromMap(Map<dynamic, dynamic> m) =>
      OvpnIntentFile(
        name: (m['name'] as String?) ?? 'profile.ovpn',
        content: (m['content'] as String?) ?? '',
        error: m['error'] as String?,
      );
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
    _armHandler();
    return _changes.stream;
  }

  static final StreamController<void> _rotateRequests =
      StreamController<void>.broadcast();

  /// The V2Ray notification's Switch-server taps (build
  /// 2075, feature item 12), forwarded by MainActivity.
  static Stream<void> get rotateRequests {
    _armHandler();
    return _rotateRequests.stream;
  }

  static final StreamController<OvpnIntentFile> _openOvpnFiles =
      StreamController<OvpnIntentFile>.broadcast();

  /// .ovpn files opened with / shared to Ember (build 2085,
  /// audit F-H15), forwarded by MainActivity.
  static Stream<OvpnIntentFile> get openOvpnFiles {
    _armHandler();
    return _openOvpnFiles.stream;
  }

  static final StreamController<String> _deepLinks =
      StreamController<String>.broadcast();

  /// Config links opened from other apps (build 2095,
  /// whole-app journey audit #38), forwarded by MainActivity.
  static Stream<String> get deepLinks {
    _armHandler();
    return _deepLinks.stream;
  }

  static final StreamController<void> _screenOffRequests =
      StreamController<void>.broadcast();

  /// Screen-off broadcasts (build 2136, item 1): forwarded
  /// by MainActivity's ACTION_SCREEN_OFF receiver. The
  /// shell acts on them only when the stop-on-sleep
  /// setting is on.
  static Stream<void> get screenOffRequests {
    _armHandler();
    return _screenOffRequests.stream;
  }

  static final StreamController<String> _shortcutConnectRequests =
      StreamController<String>.broadcast();

  /// Launcher-shortcut taps (build 2093): the profile id to
  /// connect straight to, forwarded by MainActivity.
  static Stream<String> get shortcutConnectRequests {
    _armHandler();
    return _shortcutConnectRequests.stream;
  }

  static void _armHandler() {
    if (_handlerArmed) return;
    _handlerArmed = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'networkChanged' && call.arguments is Map) {
        _changes.add(
          NetworkIdentity.fromMap(call.arguments as Map<dynamic, dynamic>),
        );
      } else if (call.method == 'notificationRotate') {
        _rotateRequests.add(null);
      } else if (call.method == 'screenOff') {
        _screenOffRequests.add(null);
      } else if (call.method == 'openOvpnFile' && call.arguments is Map) {
        _openOvpnFiles.add(
          OvpnIntentFile.fromMap(call.arguments as Map<dynamic, dynamic>),
        );
      } else if (call.method == 'deepLink') {
        final link = parseDeepLinkArgs(call.arguments);
        if (link != null) _deepLinks.add(link);
      } else if (call.method == 'shortcutConnect') {
        final id = parseShortcutConnectArgs(call.arguments);
        if (id != null) _shortcutConnectRequests.add(id);
      }
      return null;
    });
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

/// The deep-link argument of a `deepLink` channel call
/// (build 2095, whole-app journey audit #38): the link
/// string, or null for any other shape. Pure, so the intake
/// contract is testable without a channel.
String? parseDeepLinkArgs(Object? args) {
  if (args is Map) {
    final link = args['link'];
    if (link is String && link.isNotEmpty) return link;
  }
  return null;
}
