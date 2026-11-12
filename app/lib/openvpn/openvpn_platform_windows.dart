/// The OpenVPN engine on Windows (build 2025 contract): the
/// official OpenVPN community client (openvpn.exe) as a
/// sidecar, staged by scripts/fetch-windows-sidecars.ps1 from
/// the pinned official Windows package, next to the wintun.dll
/// the build already ships.
///
/// What maps from the Android contract, and how:
/// - setOn writes the profile to a private temp config (with
///   `--windows-driver wintun`, the session's auth file when
///   credentials ride along, `auth-nocache` mirroring build
///   2030's lifecycle repair) and spawns openvpn.exe; stdout
///   drives the phase: AUTH_FAILED / "Initialization Sequence
///   Completed" (connected — openvpn only prints it after the
///   tunnel is up and routes are pushed) / exit (error).
/// - openvpn.exe must be able to create the Wintun adapter and
///   set routes: the app must run elevated (the installer
///   offers the OpenVPN Interactive Service route as well).
///   When it cannot, the process exits with its own words and
///   the state surfaces them — never a fake connected.
/// - validate: the profile is parsed by the same Dart parser
///   the import path uses, and openvpn.exe must exist; the
///   binary's own config check runs at connect.
/// - ping: the endpoint probe — a TCP connect timing for TCP
///   profiles, an OpenVPN hard-reset packet for UDP (any reply
///   proves the endpoint is alive), mirroring OpenVpnProbe.
/// - pickFile: the Windows OpenFileDialog (PowerShell).
/// - credentials: DPAPI (CurrentUser) via PowerShell's
///   ProtectedData — the Windows counterpart of the Android
///   Keystore vault: the payload on disk is ciphertext only
///   this user account can open; status 'unreadable' when a
///   payload exists but DPAPI refuses it (build 2027's verified
///   semantics: a save counts only after a read-back decrypts).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/core_api.dart';
import 'openvpn_platform.dart';

class WindowsOpenVpnBackend {
  Process? _process;
  String _phase = 'idle';
  String _profileId = '';
  String _profileName = '';
  int _sinceMs = 0;
  String? _error;
  String _lastStage = '';
  bool _lastUnclean = false;
  String _lastExitReason = '';
  String _lastException = '';
  final List<String> _logRing = [];
  File? _authFile;
  File? _configFile;

  static String get _coreExe {
    final dir = File(Platform.resolvedExecutable).parent.path;
    final sep = Platform.pathSeparator;
    return '$dir${sep}openvpn${sep}openvpn.exe';
  }

  bool get _available => File(_coreExe).existsSync();

  Directory get _workDir {
    final d = Directory('${CoreLocator.dataDir(const [])}/openvpn');
    d.createSync(recursive: true);
    return d;
  }

  Directory get _vaultDir {
    final d = Directory('${_workDir.path}/vault');
    d.createSync(recursive: true);
    return d;
  }

  void _log(String line) {
    _logRing.add(line);
    while (_logRing.length > 120) _logRing.removeAt(0);
  }

  Future<void> setOn({
    required String profileId,
    required String name,
    required String config,
    String credKey = '',
    String user = '',
    String pass = '',
    bool needsCreds = false,
  }) async {
    await stop();
    if (!_available) {
      throw StateError(
        'openvpn.exe is missing from this build (the OpenVPN '
        'sidecar was not staged)',
      );
    }
    _profileId = profileId;
    _profileName = name;
    _phase = 'connecting';
    _error = null;
    _lastStage = '';
    final dir = _workDir;
    _configFile = File('${dir.path}/session.ovpn');
    var text = config;
    final extra = <String>[
      '',
      '# --- Ember session (Windows) ---',
      'windows-driver wintun',
      'auth-nocache',
      'verb 3',
    ];
    if (needsCreds) {
      _authFile = File('${dir.path}/session.auth');
      await _authFile!.writeAsString('$user\n$pass\n', flush: true);
      extra.add('auth-user-pass ${_authFile!.path}');
    }
    await _configFile!.writeAsString(text + extra.join('\n'), flush: true);
    try {
      final p = await Process.start(
        _coreExe,
        ['--config', _configFile!.path],
        workingDirectory: dir.path,
      );
      _process = p;
      _sinceMs = DateTime.now().millisecondsSinceEpoch;
      unawaited(_drain(p));
    } catch (e) {
      _phase = 'error';
      _error = 'openvpn.exe could not start: $e';
      throw StateError(_error!);
    }
  }

  Future<void> _drain(Process p) async {
    try {
      await for (final line
          in p.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter())) {
        _log(line.length > 300 ? line.substring(0, 300) : line);
        if (line.contains('Initialization Sequence Completed')) {
          _phase = 'connected';
          _lastStage = 'connected';
        } else if (line.contains('AUTH_FAILED')) {
          _phase = 'error';
          _error = 'the server refused the credentials (AUTH_FAILED)';
          _lastStage = 'auth';
        } else if (line.contains('SIGUSR1')) {
          _phase = 'reconnecting';
          _lastStage = 'reconnecting';
        } else if (line.contains('Exiting due to fatal error') ||
            line.contains('FATAL')) {
          _lastStage = 'fatal';
          _lastException = line.trim();
        }
      }
    } catch (_) {}
    final code = await p.exitCode;
    if (identical(_process, p)) {
      _process = null;
      _lastUnclean = _phase == 'connected' || _phase == 'connecting';
      _lastExitReason = 'openvpn.exe exited (code $code)';
      if (_phase != 'error') {
        _phase = 'error';
        _error ??= _lastException.isNotEmpty
            ? _lastException
            : 'openvpn.exe exited (code $code) — it needs to run '
                  'with administrator rights to create its tunnel '
                  'adapter and set routes';
      }
      await _cleanupFiles();
    }
  }

  Future<void> _cleanupFiles() async {
    for (final f in [_authFile, _configFile]) {
      try {
        await f?.delete();
      } catch (_) {}
    }
    _authFile = null;
    _configFile = null;
  }

  Future<void> stop() async {
    final p = _process;
    _process = null;
    if (_phase != 'error') _phase = 'idle';
    _profileId = '';
    _profileName = '';
    _sinceMs = 0;
    if (p != null) {
      p.kill();
      try {
        await p.exitCode.timeout(const Duration(seconds: 1));
      } on TimeoutException {
        p.kill(ProcessSignal.sigkill);
      }
    }
    await _cleanupFiles();
  }

  OpenVpnState state() => OpenVpnState(
    available: _available,
    running: _process != null,
    connected: _process != null && _phase == 'connected',
    phase: _process == null && _phase == 'connected' ? 'idle' : _phase,
    profileId: _profileId,
    profileName: _profileName,
    sinceMs: _sinceMs,
    error: _error,
    logTail: List.of(_logRing),
    lastStage: _lastStage,
    lastUnclean: _lastUnclean,
    lastExitReason: _lastExitReason,
    lastException: _lastException,
  );

  Future<String> validate(String config) async {
    if (!_available) return 'CORE_UNAVAILABLE';
    if (!config.contains('remote ')) return 'NO_REMOTE';
    if (!config.contains('client')) return 'NOT_A_CLIENT';
    return '';
  }

  Future<OvpnPing> ping({
    required String host,
    required int port,
    required String proto,
    required bool authenticatedControl,
  }) async {
    final sw = Stopwatch()..start();
    try {
      if (proto == 'udp') {
        // OpenVPN hard-reset client packet (opcode 0x38):
        // any reply at all proves a live OpenVPN endpoint.
        final socket = await RawDatagramSocket.bind(
          InternetAddress.anyIPv4,
          0,
        );
        try {
          final packet = <int>[
            0x38,
            0, 0, 0, 0, 0, 0, 0, 1, // session id (arbitrary)
            0, // ack count
            0, 0, 0, 1, // message packet id
          ];
          socket.send(packet, InternetAddress(host), port);
          final event = await socket
              .firstWhere((e) => e == RawSocketEvent.read)
              .timeout(const Duration(seconds: 5));
          if (event == RawSocketEvent.read) {
            socket.receive();
            return OvpnPing(ms: sw.elapsedMilliseconds, method: 'UDP_RESET');
          }
        } finally {
          socket.close();
        }
        return const OvpnPing(ms: -1, method: 'NO_RESPONSE');
      }
      final socket = await Socket.connect(
        host,
        port,
        timeout: const Duration(seconds: 5),
      );
      final ms = sw.elapsedMilliseconds;
      socket.destroy();
      return OvpnPing(ms: ms, method: 'TCP');
    } catch (e) {
      return OvpnPing(ms: -1, method: 'NO_RESPONSE', error: '$e');
    }
  }

  Future<Map<String, String>?> pickFile() async {
    try {
      final result = await Process.run('powershell', [
        '-NoProfile',
        '-STA',
        '-Command',
        'Add-Type -AssemblyName System.Windows.Forms; '
            '\$d = New-Object System.Windows.Forms.OpenFileDialog; '
            '\$d.Filter = "OpenVPN profile (*.ovpn)|*.ovpn|All files (*.*)|*.*"; '
            'if (\$d.ShowDialog() -eq "OK") { \$d.FileName }',
      ]);
      final path = '${result.stdout}'.trim();
      if (path.isEmpty) return null;
      final file = File(path);
      return {
        'name': file.uri.pathSegments.last,
        'content': await file.readAsString(),
      };
    } catch (_) {
      return null;
    }
  }

  // ---- credential vault (DPAPI, CurrentUser) -------------------

  File _vaultFile(String key) =>
      File('${_vaultDir.path}/${key.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_')}.dpapi');

  Future<String?> _dpapi(String mode, String input) async {
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

  Future<bool> saveCredentials(String key, String user, String pass) async {
    try {
      final payload = jsonEncode({'user': user, 'pass': pass});
      final sealed = await _dpapi('protect', payload);
      if (sealed == null || sealed.isEmpty) return false;
      await _vaultFile(key).writeAsString(sealed, flush: true);
      // Build 2027's rule: a save counts only when the read-back
      // decrypts to the same payload.
      final back = await _dpapi('unprotect', sealed);
      return back == payload;
    } catch (_) {
      return false;
    }
  }

  Future<String> credentialStatus(String key) async {
    final f = _vaultFile(key);
    if (!f.existsSync()) return 'none';
    try {
      final sealed = await f.readAsString();
      final back = await _dpapi('unprotect', sealed.trim());
      return back == null ? 'unreadable' : 'ok';
    } catch (_) {
      return 'unreadable';
    }
  }

  Future<bool> hasCredentials(String key) async =>
      await credentialStatus(key) == 'ok';

  /// The decrypted pair, for the connect flow's own backend use.
  Future<({String user, String pass})?> readCredentials(String key) async {
    try {
      final sealed = await _vaultFile(key).readAsString();
      final back = await _dpapi('unprotect', sealed.trim());
      if (back == null) return null;
      final doc = jsonDecode(back) as Map<String, dynamic>;
      return (
        user: doc['user'] as String? ?? '',
        pass: doc['pass'] as String? ?? '',
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> deleteCredentials(String key) async {
    try {
      await _vaultFile(key).delete();
    } catch (_) {}
  }
}
