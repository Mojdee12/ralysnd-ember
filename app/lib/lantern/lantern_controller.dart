/// The Lantern engine's brain: the tunnel's on/off state, polled
/// from the service, and the core's logs. Mirrors the Psiphon
/// controller's shape so the shell arbitrates all four engines the
/// same way.
///
/// Lantern's free plan has no user settings to persist: no account,
/// no server choice (the core auto-selects), no config. The one
/// honest gap vs the other engines: the core exposes no session
/// byte counters to the mobile bindings, so this controller reports
/// no rates or totals rather than inventing them — the home shows
/// status and session duration only, plus the free plan's data-cap
/// usage when the core reports it.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/android_core.dart';
import '../xray/exit_info.dart';
import 'lantern_platform.dart';

class LanternController extends ChangeNotifier {
  LanternState state = LanternState.stopped;
  bool connecting = false;
  String? lastError;

  /// The running tunnel's exit IP/country, looked up best-effort
  /// through the tunnel once it is up.
  ExitInfo? exitInfo;
  bool _exitFetching = false;

  /// Set by the shell: stops the other engines so only one tunnel is
  /// ever up. Returns when they are off.
  Future<void> Function()? stopOtherEngine;

  Timer? _poll;

  Future<Directory> workDir() async {
    final coreDir = await AndroidCore.dataDir();
    return Directory('${File(coreDir).parent.path}/lantern');
  }

  Future<void> load() async {
    await refreshState();
    notifyListeners();
  }

  // ---- state ------------------------------------------------------------

  Future<void> refreshState() async {
    state = await LanternPlatform.state();
    if (state.running) {
      _startPolling();
      if (state.connected) _fetchExitInfo();
    }
    notifyListeners();
  }

  void _startPolling() {
    _poll ??= Timer.periodic(const Duration(seconds: 2), (_) async {
      final sample = await LanternPlatform.state();
      state = sample;
      if (sample.running && sample.connected) _fetchExitInfo();
      if (!sample.running) {
        _poll?.cancel();
        _poll = null;
        exitInfo = null;
      }
      notifyListeners();
    });
  }

  void _fetchExitInfo() {
    if (_exitFetching || exitInfo != null) return;
    _exitFetching = true;
    LanternPlatform.exitInfo().then((m) {
      _exitFetching = false;
      if (m != null && m['ip'] != null && m['ip']!.isNotEmpty) {
        exitInfo = ExitInfo.fromMap(m);
        notifyListeners();
      }
    });
  }

  // ---- connect / disconnect ----------------------------------------------

  Future<void> connect() async {
    connecting = true;
    lastError = null;
    exitInfo = null;
    notifyListeners();
    try {
      // One tunnel at a time: the other engines go off first.
      await stopOtherEngine?.call();
      if (state.running) await disconnect();
      await LanternPlatform.setOn(dns: '1.1.1.1');
      // The service reports itself once its start sequence is under
      // way; the core's bootstrap on a censored network can take a
      // while, and a tunnel to a Lantern server longer still
      // (state.connected follows separately).
      for (var i = 0; i < 120; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        state = await LanternPlatform.state();
        if (state.failed) {
          throw StateError(
            state.failure.isNotEmpty ? state.failure : 'start-failed',
          );
        }
        if (state.running) break;
      }
      if (!state.running) throw StateError('start-failed');
      _startPolling();
    } catch (e) {
      lastError = e.toString();
      // Refresh once more so the home's failed-start card renders
      // the service's own failure state (Kotlin statics), not just
      // the transient snackbar.
      try {
        state = await LanternPlatform.state();
      } catch (_) {
        // The channel is gone (process restarted); keep the sample.
      }
      rethrow;
    } finally {
      connecting = false;
      notifyListeners();
    }
  }

  Future<void> disconnect() async {
    await LanternPlatform.stop();
    for (var i = 0; i < 20; i++) {
      state = await LanternPlatform.state();
      if (!state.running) break;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    state = await LanternPlatform.state();
    exitInfo = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  // ---- logs ----------------------------------------------------------------

  /// The tails of the Lantern logs, newest content last.
  /// lantern-crash.log is the core's Go crash output (radiance
  /// points debug.SetCrashOutput at it): a panic in a core goroutine
  /// lands there and nowhere else, so it belongs in this viewer —
  /// the 2011 build never showed it, which hid exactly that class
  /// of failure.
  Future<String> readLogs() async {
    final dir = await workDir();
    final out = StringBuffer();
    for (final name in [
      'lantern.log',
      'lantern-service.log',
      'lantern-crash.log',
      'tunlink.log',
    ]) {
      final file = File('${dir.path}/$name');
      out.writeln('—— $name ——');
      try {
        if (await file.exists()) {
          final bytes = await file.readAsBytes();
          final tail = bytes.length > 64 * 1024
              ? bytes.sublist(bytes.length - 64 * 1024)
              : bytes;
          out.writeln(utf8.decode(tail, allowMalformed: true));
        } else {
          out.writeln('(empty)');
        }
      } catch (e) {
        out.writeln('($e)');
      }
    }
    return out.toString();
  }

  Future<void> clearLogs() async {
    final dir = await workDir();
    for (final name in [
      'lantern.log',
      'lantern-service.log',
      'lantern-crash.log',
      'tunlink.log',
    ]) {
      try {
        await File('${dir.path}/$name').writeAsString('');
      } catch (_) {
        // Not there yet.
      }
    }
  }
}
