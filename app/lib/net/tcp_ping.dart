/// Per-config TCP connect ping (build 2075, feature item
/// 14): how long a bare TCP connection to a profile's
/// endpoint takes, measured with the existing probe
/// machinery (lib/net/probe.dart — the same code the CF
/// scanner and the filtering probe use). This is a
/// reachability signal only: it proves the endpoint
/// answers TCP, nothing about the protocol handshake or
/// the exit. The UI labels it exactly that way, and it is
/// stored on the profile next to the real delay test's
/// result (Profile.tcpPingMs / tcpPingFailed), never mixed
/// with it.

import 'dart:async';

import '../xray/xray_models.dart';
import 'probe.dart';

/// Probes [p]'s endpoint once. Returns the connect time in
/// milliseconds, or -1 when the endpoint did not answer
/// within [timeout]. The probe machinery resolves the
/// hostname itself (first answer wins, as everywhere else
/// in the app).
Future<int> probeProfileTcp(
  Profile p, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  if (p.address.isEmpty || p.port <= 0) return -1;
  final result = await tcpProbe(p.address, p.port, timeout: timeout);
  return result.ok ? (result.ms ?? -1) : -1;
}

/// Races [candidates]' endpoints in parallel (build 2075,
/// feature item 5 — smart dial racing): every candidate is
/// probed at once and the first that answers wins. Returns
/// the winning profile, or null when none answered within
/// [timeout]. Every outcome is reported through [onResult]
/// so the caller can learn it into the profiles' TCP ping
/// fields and the winner memory.
Future<Profile?> raceProfileTcp(
  List<Profile> candidates, {
  Duration timeout = const Duration(seconds: 3),
  void Function(Profile p, int ms)? onResult,
}) async {
  if (candidates.isEmpty) return null;
  final winner = Completer<Profile?>();
  var pending = candidates.length;
  for (final p in candidates) {
    unawaited(
      probeProfileTcp(p, timeout: timeout).then((ms) {
        onResult?.call(p, ms);
        if (ms >= 0 && !winner.isCompleted) winner.complete(p);
        if (--pending == 0 && !winner.isCompleted) winner.complete(null);
      }),
    );
  }
  return winner.future;
}
