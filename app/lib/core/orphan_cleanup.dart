/// Reaping sidecar processes orphaned by a hard-killed app run
/// (Windows only in practice: neither Dart nor a killed Flutter
/// process can take its children with it, and a leftover xray.exe /
/// psiphon-core.exe keeps holding the engine's loopback ports, so
/// the next run's core dies on "address already in use").
///
/// The match is the executable's full path, compared
/// case-insensitively: only THIS app's bundled sidecar is ever
/// killed — a same-named core from any other install (the user's
/// own v2rayN, say) is a different path and is left alone.
library;

import 'dart:convert';
import 'dart:io';

/// Kills every running [processName] process whose executable path
/// is exactly [exePath] (this app's sidecar). Returns the killed
/// PIDs. Best-effort: enumeration or kill failures yield an empty
/// or partial result, never an exception.
Future<List<int>> killOrphanedSidecars({
  required String exePath,
  required String processName,
}) async {
  if (!Platform.isWindows) return const [];
  try {
    final result = await Process.run('powershell', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      "Get-CimInstance Win32_Process -Filter \"Name='$processName'\" "
          '| Select-Object ProcessId, ExecutablePath '
          '| ConvertTo-Json -Compress',
    ]).timeout(const Duration(seconds: 15));
    final out = (result.stdout as String).trim();
    if (out.isEmpty) return const [];
    final decoded = jsonDecode(out);
    final entries = decoded is List ? decoded : [decoded];
    String norm(String p) => p.replaceAll('/', r'\').toLowerCase();
    final wanted = norm(exePath);
    final killed = <int>[];
    for (final entry in entries) {
      if (entry is! Map) continue;
      final path = entry['ExecutablePath'] as String?;
      final pid = (entry['ProcessId'] as num?)?.toInt();
      if (path == null || pid == null) continue;
      if (norm(path) != wanted) continue;
      try {
        final kill = await Process.run('taskkill', [
          '/PID',
          '$pid',
          '/F',
        ]).timeout(const Duration(seconds: 10));
        if (kill.exitCode == 0) killed.add(pid);
      } catch (_) {
        // Best-effort: a process that refuses to die is reported
        // by the port probe that follows as a busy port.
      }
    }
    return killed;
  } catch (_) {
    return const [];
  }
}
