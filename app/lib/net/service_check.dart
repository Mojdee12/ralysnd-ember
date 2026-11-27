/// Proxied service reachability checks (build 2091, feature-watch
/// 2026-11-16, FlClash 0.9.x): does a config actually open the
/// services that matter, not just answer a ping? The delay test
/// proves a 204 through the node and the sandbox test proves
/// delay + hold + exit — but a node can ping fine while every
/// service is blocked at its exit. This check asks six well-known
/// services for a real HTTPS HEAD through the same isolated
/// throwaway core the sandbox test uses, so the live tunnel is
/// never touched.
///
/// Grading is deliberately narrow and honest: any HTTP status
/// line (200, 301, 403 — even a block page's status) proves the
/// service answered through the node; only "no answer" counts
/// as unreachable. The sheet says "Reachable" / "No answer",
/// never "loads", because a HEAD answer is reachability, not a
/// full page load.

/// One service the check asks: the host probed and the label
/// the sheet shows for it.
class ServiceCheckTarget {
  final String host;
  final String label;
  const ServiceCheckTarget(this.host, this.label);
}

/// The fixed service set. Six hosts, all HTTPS, all answered
/// by a HEAD on `/`. The delay-test host
/// (connectivitycheck.gstatic.com) is deliberately NOT here —
/// the sandbox delay is the control; these six are the question.
const serviceCheckTargets = <ServiceCheckTarget>[
  ServiceCheckTarget('www.google.com', 'Google'),
  ServiceCheckTarget('www.youtube.com', 'YouTube'),
  ServiceCheckTarget('www.instagram.com', 'Instagram'),
  ServiceCheckTarget('www.telegram.org', 'Telegram'),
  ServiceCheckTarget('github.com', 'GitHub'),
  ServiceCheckTarget('x.com', 'X'),
];

/// One service's verdict inside a check run.
class ServiceCheckEntry {
  final String host;
  final String label;

  /// True when the service answered with any HTTP status line
  /// through the node.
  final bool reachable;

  /// Round-trip ms of the HEAD request, when [reachable].
  final int ms;

  /// The HTTP status the service answered with, 0 when it
  /// never answered.
  final int status;

  const ServiceCheckEntry({
    required this.host,
    required this.label,
    required this.reachable,
    required this.ms,
    required this.status,
  });

  /// A failed entry: the service never answered.
  factory ServiceCheckEntry.failed(ServiceCheckTarget target) =>
      ServiceCheckEntry(
        host: target.host,
        label: target.label,
        reachable: false,
        ms: -1,
        status: 0,
      );
}

/// The result of one service check run: one entry per target,
/// in [serviceCheckTargets] order, plus the failing stage in
/// plain words when the check never ran.
class ServiceCheckResult {
  /// The check ran (the throwaway core started and the probes
  /// were attempted). False only when the run itself failed —
  /// no engine serves the protocol, no free port, the core
  /// did not start, or the channel did not answer.
  final bool ok;
  final List<ServiceCheckEntry> entries;

  /// The failing stage in plain words ('' when the check ran).
  final String error;

  const ServiceCheckResult({
    required this.ok,
    required this.entries,
    required this.error,
  });

  /// A failed result that never reached the core: every
  /// service reads as unanswered, and [error] names why.
  factory ServiceCheckResult.failed(String error) => ServiceCheckResult(
    ok: false,
    entries: [
      for (final t in serviceCheckTargets) ServiceCheckEntry.failed(t),
    ],
    error: error,
  );

  /// Parses the native side's map tolerantly: a wrong-typed or
  /// missing value degrades that service to "no answer", never
  /// throws, and never invents a reachable verdict. The native
  /// map is `{'ok': 1/0, 'error': '', 'results': {host:
  /// {'ms': n, 'status': code}}}`.
  factory ServiceCheckResult.fromMap(
    Map<dynamic, dynamic> m, [
    List<ServiceCheckTarget> targets = serviceCheckTargets,
  ]) {
    int asInt(Object? v, [int fallback = -1]) =>
        v is num ? v.toInt() : fallback;
    String asStr(Object? v) => v is String ? v : '';
    final ok = asInt(m['ok'], 0) == 1;
    final error = asStr(m['error']);
    final raw = m['results'];
    final results = raw is Map ? raw : const {};
    return ServiceCheckResult(
      ok: ok,
      entries: [
        for (final t in targets)
          if (results[t.host] is Map)
            _entryFromMap(t, results[t.host] as Map)
          else
            ServiceCheckEntry.failed(t),
      ],
      error: error,
    );
  }

  static ServiceCheckEntry _entryFromMap(
    ServiceCheckTarget target,
    Map<dynamic, dynamic> m,
  ) {
    int asInt(Object? v, [int fallback = -1]) =>
        v is num ? v.toInt() : fallback;
    final status = asInt(m['status'], 0);
    final ms = asInt(m['ms'], -1);
    // Reachable = the service answered with any HTTP status
    // line. A status of 0 (or a negative ms) means no answer
    // at all, whatever else the map claims.
    final reachable = status >= 100 && ms >= 0;
    return ServiceCheckEntry(
      host: target.host,
      label: target.label,
      reachable: reachable,
      ms: reachable ? ms : -1,
      status: reachable ? status : 0,
    );
  }

  /// How many services answered through the node.
  int get reachableCount => entries.where((e) => e.reachable).length;

  /// Every service answered.
  bool get allReachable =>
      entries.isNotEmpty && reachableCount == entries.length;

  /// No service answered.
  bool get noneReachable => reachableCount == 0;

  /// The plain-words summary line for the sheet.
  String get summary {
    if (!ok) {
      return error.isEmpty
          ? 'The check did not run.'
          : error;
    }
    if (allReachable) {
      return 'All ${entries.length} services answered through this node.';
    }
    if (noneReachable) {
      return 'No service answered — the node may be dead, or '
          'its exit blocks these sites.';
    }
    return '$reachableCount of ${entries.length} services answered '
        'through this node.';
  }
}
