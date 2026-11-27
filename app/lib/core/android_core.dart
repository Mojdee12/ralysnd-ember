import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'core_api.dart';

/// An app installed on the phone.
@immutable
class InstalledApp {
  const InstalledApp(this.package, this.label, {this.launcher = true});

  final String package;
  final String label;

  /// It has a launcher icon; the others are mostly the system's.
  final bool launcher;
}

/// Which apps use the VPN (CoreService.kt), in v2rayN's words: bypass the
/// selected apps ([bypass]), or proxy only the selected apps ([only]).
class AppRouting {
  AppRouting({
    required this.onlyChosen,
    required this.bypass,
    required this.only,
    required this.suggested,
    Set<String>? declined,
  }) : declined = declined ?? {};

  /// Proxy selected apps; otherwise bypass them.
  bool onlyChosen;

  /// Bypass selected apps: these connect directly.
  final Set<String> bypass;

  /// Proxy selected apps: only these use the VPN.
  final Set<String> only;

  /// The routing region's apps (from the core), suggested for bypassing:
  /// the installed ones are checked by themselves (CoreService.suggest),
  /// unless the user unchecked them ([declined]).
  final Set<String> suggested;

  /// The suggested apps the user unchecked: never checked again by
  /// themselves, only by the user or "Suggested apps".
  final Set<String> declined;

  Set<String> get _chosen => onlyChosen ? only : bypass;

  /// Whether [package] is checked in the current mode.
  bool checked(String package) => _chosen.contains(package);

  void toggle(String package, bool on) {
    on ? _chosen.add(package) : _chosen.remove(package);
    if (!onlyChosen && suggested.contains(package)) {
      on ? declined.remove(package) : declined.add(package);
    }
  }

  /// Checks the suggested apps that are installed, also those unchecked
  /// before; returns how many were not checked yet.
  int checkSuggested(Iterable<String> installed) {
    final mine = installed.where(suggested.contains).toSet();
    declined.removeAll(mine);
    final add = mine..removeAll(bypass);
    bypass.addAll(add);
    return add.length;
  }

  /// A key that changes with the choice, to know whether to apply it.
  String get key => [
    onlyChosen,
    ...[bypass, only].map((s) => (s.toList()..sort()).join(',')),
  ].join('|');
}

/// The user did not allow the app to set up a VPN.
class VpnNotAllowed implements Exception {
  const VpnNotAllowed();
}

/// The core on Android: it runs in this app's process. It starts with the
/// proxy off while the UI is open, so settings and accounts work; turned
/// on, a foreground service (android/.../CoreService.kt) keeps it running
/// for other apps while the UI is closed. The UI talks to it through the
/// same HTTP API.
/// Build 2116 (E-7): single-value secrets in the Android
/// Keystore-backed vault (OpenVpnVault's generic entries —
/// AES-256-GCM under a Keystore key, the plaintext never
/// touches a JSON store). Every call is best-effort: a
/// platform without the vault (desktop, tests) answers
/// false/null and the caller keeps its previous behaviour.
/// Build 2116 (B7-1, AB-08): the native VPN-slot claim's
/// Dart face. Every engine start claims the slot natively
/// (EngineClaim.kt); the shell reads the owner when the app
/// returns to the foreground and re-arbitrates — adopting a
/// natively-started engine's mode, or clearing a marker
/// whose engine is no longer live. Best-effort throughout:
/// a missing channel (desktop, tests) reads as no claim.
abstract final class EngineClaimChannel {
  static const _channel = MethodChannel('app/android');

  static Future<String?> owner() async {
    try {
      return await _channel.invokeMethod<String>('engineClaimOwner');
    } catch (_) {
      return null;
    }
  }

  static Future<void> clear() async {
    try {
      await _channel.invokeMethod<bool>('engineClaimClear');
    } catch (_) {
      // Best effort — the next claim overwrites the marker.
    }
  }

  /// Build 2125 (audit A25-17 / P-24): corrects the marker
  /// to name [name] — the engine the shell's own live-state
  /// evidence says is actually running — WITHOUT stopping
  /// anything. Used when the marker names a different,
  /// no-longer-live engine: later native readers (the WG
  /// stand-down, the next claim's displacement) must act on
  /// the true owner, not the stale name.
  static Future<void> setOwner(String name) async {
    try {
      await _channel.invokeMethod<bool>('engineClaimRewrite', {'name': name});
    } catch (_) {
      // Best effort — the next claim overwrites the marker.
    }
  }
}

class SecretStore {
  static const _channel = MethodChannel('app/android');

  static Future<bool> store(String key, String value) async {
    if (Platform.isWindows) return _WindowsVault.store(key, value);
    try {
      return await _channel.invokeMethod<bool>('secretStore', {
            'key': key,
            'value': value,
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }

  static Future<String?> load(String key) async {
    if (Platform.isWindows) return _WindowsVault.load(key);
    try {
      return await _channel.invokeMethod<String>('secretLoad', {'key': key});
    } catch (_) {
      return null;
    }
  }

  static Future<void> delete(String key) async {
    if (Platform.isWindows) return _WindowsVault.delete(key);
    try {
      await _channel.invokeMethod<void>('secretDelete', {'key': key});
    } catch (_) {}
  }
}

/// The Windows SecretStore (W3, full-parity build): the
/// Android Keystore's counterpart is DPAPI (CurrentUser) —
/// the same construction the OpenVPN credential vault proved
/// (openvpn_platform_windows.dart): the sealed payload is a
/// base64 blob in `<dataDir>/vault/<sanitized key>.dpapi`,
/// and a save counts only when the read-back decrypts to the
/// same value. Nothing secret ever lands in settings/state
/// JSON on Windows either.
abstract final class _WindowsVault {
  static Directory get _dir =>
      Directory('${CoreLocator.dataDir(const [])}/vault');

  static File _file(String key) => File(
    '${_dir.path}/${key.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_')}.dpapi',
  );

  static Future<String?> _dpapi(String mode, String input) async {
    final script =
        '''
\$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security
\$in = [Console]::In.ReadToEnd()
if ('$mode' -eq 'protect') {
  \$bytes = [Text.Encoding]::UTF8.GetBytes(\$in)
  \$out = [Security.Cryptography.ProtectedData]::Protect(\$bytes, \$null, 'CurrentUser')
  [Console]::Out.Write([Convert]::ToBase64String(\$out))
} else {
  \$bytes = [Convert]::FromBase64String(\$in)
  \$out = [Security.Cryptography.ProtectedData]::Unprotect(\$bytes, \$null, 'CurrentUser')
  [Console]::Out.Write([Text.Encoding]::UTF8.GetString(\$out))
}
''';
    final p = await Process.start('powershell', [
      '-NoProfile',
      '-Command',
      script,
    ]);
    p.stdin.write(input);
    await p.stdin.close();
    final out = await p.stdout.transform(utf8.decoder).join();
    final code = await p.exitCode;
    if (code != 0) return null;
    return out;
  }

  static Future<bool> store(String key, String value) async {
    try {
      final sealed = await _dpapi('protect', value);
      if (sealed == null || sealed.isEmpty) return false;
      await _dir.create(recursive: true);
      await _file(key).writeAsString(sealed, flush: true);
      final back = await _dpapi('unprotect', sealed);
      return back == value;
    } catch (_) {
      return false;
    }
  }

  static Future<String?> load(String key) async {
    try {
      final f = _file(key);
      if (!await f.exists()) return null;
      return await _dpapi('unprotect', (await f.readAsString()).trim());
    } catch (_) {
      return null;
    }
  }

  static Future<void> delete(String key) async {
    try {
      await _file(key).delete();
    } catch (_) {}
  }
}

class AndroidCore {
  static const _channel = MethodChannel('app/android');

  /// The core's data folder inside the app's private storage.
  ///
  /// Android: the 'app/android' channel — filesDir/core, and the
  /// synced controllers root their per-engine folders at its
  /// parent (filesDir). Desktop has no such channel (the call
  /// threw MissingPluginException, so synced controllers could
  /// not persist state across restarts); it answers with the
  /// same shape instead: the app data folder's own `core`
  /// child, so every caller's parent-based math lands in the
  /// app data folder exactly as on Android.
  static Future<String> dataDir() async {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      return '${CoreLocator.dataDir(const [])}'
          '${Platform.pathSeparator}core';
    }
    return await _channel.invokeMethod<String>('dataDir') ?? '';
  }

  AndroidCore(this._dataDir);

  final String _dataDir;

  /// Opens a client of the core, starting the core (off) when it does not
  /// run; it throws [CoreUnavailable] until the core answers.
  Future<CoreApi> connect() async {
    if (await _channel.invokeMethod<bool>('isRunning') != true) {
      try {
        await _channel.invokeMethod<void>('startCore');
      } on PlatformException catch (e) {
        // Build 2095 (third-pass audit 3-4): the native
        // start failure IS the core problem — the core will
        // never answer, so "starting" would spin forever.
        throw CoreUnavailable(
          CoreProblem.exited,
          e.message ?? 'the core did not start',
        );
      }
      throw const CoreUnavailable(CoreProblem.starting);
    }
    try {
      final api = CoreApi(await CoreLocator.locate(_dataDir));
      try {
        await api.status();
        return api;
      } on Exception {
        api.close();
        rethrow;
      }
    } on CoreUnavailable {
      // Started, and its API is still coming up.
      throw const CoreUnavailable(CoreProblem.starting);
    }
  }

  /// The tunnel MTU (build 2038, Iran-priority queue 2f): the
  /// XraySettings value, mirrored here so the Mozilla connect path
  /// can send it — CoreController's turnOn takes only (bool), and
  /// the shell owns the Xray settings, so the shell and the
  /// settings page keep this in sync (see EmberShell initState
  /// and the MTU chips). Default 1500, the unchanged behaviour.
  static final tunnelMtu = ValueNotifier<int>(1500);

  /// The kill switch for the Mozilla engine (build 2127,
  /// H4): the XraySettings value, mirrored here like
  /// [tunnelMtu] — the shell and the settings page keep it
  /// in sync, and CoreService reads it from prefs when the
  /// core dies. Default false, the unchanged behaviour.
  static final killSwitch = ValueNotifier<bool>(false);

  /// Turns the VPN on (asking the user for the VPN permission the first
  /// time) or off. It throws [VpnNotAllowed] when the user refuses.
  static Future<void> setOn(bool on) async {
    try {
      await _channel.invokeMethod<void>('setOn', {
        'on': on,
        'mtu': tunnelMtu.value,
        'killSwitch': killSwitch.value,
      });
    } on PlatformException catch (e) {
      if (e.code == 'vpn_denied') throw const VpnNotAllowed();
      throw CoreApiException(0, e.message ?? e.code);
    }
  }

  /// The connection mode: 'vpn' (every app on the phone) or 'proxy' (only
  /// apps set up to use the local proxy). Read at start ([loadMode]).
  static final mode = ValueNotifier<String>('vpn');

  static Future<void> loadMode() async {
    mode.value = await _channel.invokeMethod<String>('connectionMode') ?? 'vpn';
    showSpeed.value = await _channel.invokeMethod<bool>('showSpeed') ?? false;
  }

  /// Whether the notification shows the speed (CoreService.kt reads it).
  static final showSpeed = ValueNotifier<bool>(false);

  /// Build 2095 (feature 5): keeps the home widget's
  /// lock marker in step with the app-lock setting.
  static Future<void> setWidgetLock(bool on) async {
    try {
      await _channel.invokeMethod<void>('setWidgetLock', {'on': on});
    } catch (_) {
      // The widget falls back to its last marker.
    }
  }

  static Future<void> setShowSpeed(bool on) async {
    await _channel.invokeMethod<void>('setShowSpeed', {'on': on});
    showSpeed.value = on;
  }

  /// Keeps the mode; a running proxy switches at once. Switching to the
  /// VPN the first time turns it off and on again, so Android asks for the
  /// VPN permission; it throws [VpnNotAllowed] when the user refuses.
  static Future<void> setMode(String value) async {
    try {
      await _channel.invokeMethod<void>('setConnectionMode', {'mode': value});
      mode.value = value;
    } on PlatformException catch (e) {
      if (e.code != 'vpn_denied') rethrow;
      await setOn(false);
      await _channel.invokeMethod<void>('setConnectionMode', {'mode': value});
      mode.value = value;
      await setOn(true);
    }
  }

  /// The installed apps but this one, the system's too.
  static Future<List<InstalledApp>> installedApps() async {
    final list = await _channel.invokeListMethod<Map<Object?, Object?>>(
      'installedApps',
    );
    return [
      for (final m in list ?? const <Map<Object?, Object?>>[])
        InstalledApp(
          '${m['package']}',
          '${m['label']}',
          launcher: m['launcher'] != false,
        ),
    ];
  }

  /// An app's icon as PNG.
  static Future<Uint8List?> appIcon(String package) =>
      _channel.invokeMethod<Uint8List>('appIcon', {'package': package});

  /// Which apps use the VPN.
  static Future<AppRouting> appRouting() async {
    final m =
        await _channel.invokeMapMethod<String, Object?>('appRouting') ??
        const {};
    Set<String> set(String key) => {
      for (final p in (m[key] as List<Object?>? ?? const [])) '$p',
    };
    return AppRouting(
      onlyChosen: m['mode'] == 'include',
      bypass: set('bypass'),
      only: set('only'),
      suggested: set('region'),
      declined: set('declined'),
    );
  }

  /// Keeps which apps use the VPN; [apply] sets a running VPN up again.
  static Future<void> setAppRouting(AppRouting r, {required bool apply}) =>
      _channel.invokeMethod<void>('setAppRouting', {
        'mode': r.onlyChosen ? 'include' : 'exclude',
        'bypass': r.bypass.toList(),
        'only': r.only.toList(),
        'declined': r.declined.toList(),
        'apply': apply,
      });

  /// The phone's main processor type, such as arm64-v8a.
  static Future<String> abi() async =>
      await _channel.invokeMethod<String>('abi') ?? '';

  /// Opens [url] in the app that handles it (such as a tg:// link).
  static Future<bool> openUrl(String url) async =>
      await _channel.invokeMethod<bool>('openUrl', {'url': url}) ?? false;

  /// Build 2075 (in-app updater): whether Android currently
  /// allows this app to install packages (the per-app "install
  /// unknown apps" grant on Android 8+; always true below).
  static Future<bool> canInstallPackages() async =>
      await _channel.invokeMethod<bool>('canInstallPackages') ?? false;

  /// Opens Android's per-app "install unknown apps" settings
  /// page, where the user can grant the install permission.
  static Future<bool> openInstallSettings() async =>
      await _channel.invokeMethod<bool>('openInstallSettings') ?? false;

  /// Hands the APK at [path] (inside the app's own files) to
  /// the system installer. Throws a [PlatformException] with a
  /// plain code ('apk_missing' / 'install_failed') on failure.
  static Future<bool> installApk(String path) async =>
      await _channel.invokeMethod<bool>('installApk', {'path': path}) ?? false;

  /// Build 2129 (leg 6): the SHA-256 (lowercase hex) of the
  /// first signing certificate of the APK file at [path],
  /// read by the platform WITHOUT installing it — the
  /// updater compares it against [ownSigningCertSha256]
  /// before a downloaded update is ever offered for
  /// install. Null when the platform cannot read it (no
  /// handler, unparseable file): callers treat null as
  /// "cannot verify", never as a match.
  static Future<String?> apkSigningCertSha256(String path) async {
    try {
      return await _channel.invokeMethod<String>('apkSigningCertSha256', {
        'path': path,
      });
    } catch (_) {
      return null;
    }
  }

  /// Build 2129 (leg 6): the running app's own signing-cert
  /// SHA-256, canonicalised exactly as
  /// [apkSigningCertSha256] (SHA-256 over the first signer's
  /// DER bytes, lowercase hex — see MainActivity). Null when
  /// the platform cannot answer.
  static Future<String?> ownSigningCertSha256() async {
    try {
      return await _channel.invokeMethod<String>('ownSigningCertSha256');
    } catch (_) {
      return null;
    }
  }

  /// Build 2098 (Item C): the installed package's own
  /// versionCode, read from the PackageManager — the one
  /// build number that cannot silently go stale the way the
  /// APP_BUILD dart-define's fallback could. Null when the
  /// platform side cannot answer (tests, older builds) —
  /// since build 2106 (journey audit F-09) callers treat
  /// that null as UNKNOWN and offer nothing, never as the
  /// define's stale value.
  static Future<int?> appBuildNumber() async {
    try {
      return await _channel.invokeMethod<int>('appBuildNumber');
    } catch (_) {
      return null;
    }
  }

  /// Build 2077 (feature queue #7, biometric half): whether
  /// the device has a strong biometric enrolled (fingerprint
  /// or face; Android 9+ with an enrolled credential). False
  /// on anything older, on a device with nothing enrolled, or
  /// when the platform side has no such call — the PIN pad is
  /// the fallback either way, so false never locks anyone out.
  static Future<bool> biometricsAvailable() async {
    try {
      return await _channel.invokeMethod<bool>('biometricsAvailable') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Shows the system biometric prompt ("Unlock Ralysnd
  /// Ember"). True only when the biometric matches; false on
  /// cancel, mismatch, lockout, or any platform error — the
  /// caller falls back to the PIN pad and never treats a
  /// false as a lockout.
  static Future<bool> authenticateBiometric() async {
    try {
      return await _channel.invokeMethod<bool>('biometricAuthenticate') ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Overlay-attack protection (build 2075, feature item
  /// 30): while [on], the app window refuses to be obscured
  /// by another app's overlay (Android 12+; a no-op below).
  /// Sensitive screens — config view, QR show/scan, account
  /// pages — turn it on for their lifetime.
  /// Build 2095 (whole-app journey audit #45, second half):
  /// FLAG_SECURE for the window — recents thumbnails and
  /// screenshots show a blank while it is set. Driven by the
  /// same sensitive-surface lifecycle as the overlay guard
  /// (the lock page included, via OverlayGuard).
  static Future<void> setSecureFlag(bool on) async {
    try {
      await _channel.invokeMethod('setSecureFlag', {'on': on});
    } catch (_) {
      // Not Android, or no engine yet: nothing to protect.
    }
  }

  static Future<void> setOverlayGuard(bool on) async {
    try {
      await _channel.invokeMethod('setOverlayGuard', {'on': on});
    } catch (_) {
      // A platform without the call must never break a page.
    }
  }
}
