/// Launcher shortcuts for one-tap connect (build 2093, feature-watch
/// 2026-11-16, FlClash 0.9.x): long-press the app icon to connect
/// straight to a starred config. The platform side (Kotlin,
/// LauncherShortcuts) owns the ShortcutManager calls; this file owns
/// the Dart-side contract — which profiles become shortcuts, the
/// outbound publish/clear calls, and the inbound intent parsing.
/// Nothing here ever calls setMethodCallHandler: NetworkInfoService
/// owns the single handler on 'app/android', and a second one would
/// replace it (networkChanged / notificationRotate / openOvpnFile
/// would stop arriving). Outbound invokeMethod calls are safe.

import 'package:flutter/services.dart';

/// One shortcut: the profile id the tap connects to, and the label
/// the launcher shows.
class ShortcutTarget {
  const ShortcutTarget({required this.id, required this.name});

  final String id;
  final String name;
}

/// Android shows at most 5 dynamic shortcuts; Ember publishes 4 and
/// leaves the fifth slot to the system.
const maxLauncherShortcuts = 4;

/// The launcher's short label is short by design — a long config
/// name is cut here so the label the platform receives is already
/// the label the user sees.
const maxShortcutLabelLength = 25;

/// The starred profiles, in list order, reduced to publishable
/// shortcuts: blank ids/names never publish (a shortcut that
/// cannot connect is worse than no shortcut), a repeated id keeps
/// its first occurrence, and the list stops at [maxLauncherShortcuts].
List<ShortcutTarget> buildShortcutTargets(List<ShortcutTarget> starred) {
  final seen = <String>{};
  final out = <ShortcutTarget>[];
  for (final t in starred) {
    if (out.length >= maxLauncherShortcuts) break;
    if (t.id.isEmpty || t.name.isEmpty) continue;
    if (!seen.add(t.id)) continue;
    final name = t.name.length > maxShortcutLabelLength
        ? t.name.substring(0, maxShortcutLabelLength)
        : t.name;
    out.add(ShortcutTarget(id: t.id, name: name));
  }
  return out;
}

/// The profile id a launcher-shortcut tap carries, or null when the
/// intent carried none (a stale shortcut, or a tap the platform
/// could not attribute — both are ignored, never connected to the
/// wrong profile).
String? parseShortcutConnectArgs(Object? args) {
  if (args is! Map) return null;
  final id = args['profileId'];
  if (id is! String || id.isEmpty) return null;
  return id;
}

class LauncherShortcuts {
  static const _channel = MethodChannel('app/android');

  /// Publishes the starred profiles as launcher shortcuts when
  /// [enabled], and removes every Ember dynamic shortcut when it
  /// is not. Best-effort by design: a launcher that refuses the
  /// publish (old Android, a rate limit, a missing channel in a
  /// host test) must never break starring or connecting — the
  /// call returns false and the app carries on.
  static Future<bool> sync({
    required bool enabled,
    required List<ShortcutTarget> targets,
  }) async {
    try {
      if (!enabled) {
        await _channel.invokeMethod('clearShortcuts');
      } else {
        await _channel.invokeMethod('publishShortcuts', {
          'shortcuts': [
            for (final t in targets) {'id': t.id, 'name': t.name},
          ],
        });
      }
      return true;
    } catch (_) {
      return false;
    }
  }
}
