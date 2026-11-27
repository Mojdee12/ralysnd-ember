/// The verdict of one sandbox config test (build 2061, feature
/// queue #1): a config tested in an isolated temporary core
/// instance on a free port, without touching the live tunnel.
enum SandboxVerdict { works, unstable, failed }

/// The result of one sandbox config test: delay, the three
/// hold probes, and the exit identity observed through the
/// throwaway core — plus the failing stage in plain words when
/// the test did not complete. Pure data: the native side hands
/// back a map, this parses it tolerantly, and the sheet grades
/// it.
class SandboxTestResult {
  /// The core answered at least one delay probe.
  final bool ok;
  final int delayMs;

  /// The three hold probes at t=0, +2.5 s and +5.4 s on one
  /// keep-alive connection (-1 when a probe failed).
  final int p0;
  final int p1;
  final int p2;

  /// All three hold probes answered.
  final bool held;
  final String exitIp;
  final String countryCode;
  final String country;

  /// The failing stage in plain words ('' when the test ran).
  final String error;

  const SandboxTestResult({
    required this.ok,
    required this.delayMs,
    required this.p0,
    required this.p1,
    required this.p2,
    required this.held,
    required this.exitIp,
    required this.countryCode,
    required this.country,
    required this.error,
  });

  /// A failed result that never reached the core (unsupported
  /// protocol, no free port, channel error).
  factory SandboxTestResult.failed(String error) => SandboxTestResult(
    ok: false,
    delayMs: -1,
    p0: -1,
    p1: -1,
    p2: -1,
    held: false,
    exitIp: '',
    countryCode: '',
    country: '',
    error: error,
  );

  factory SandboxTestResult.fromMap(Map<dynamic, dynamic> m) {
    int asInt(Object? v, [int fallback = -1]) =>
        v is num ? v.toInt() : fallback;
    String asStr(Object? v) => v is String ? v : '';
    return SandboxTestResult(
      ok: asInt(m['ok'], 0) == 1,
      delayMs: asInt(m['ms']),
      p0: asInt(m['p0']),
      p1: asInt(m['p1']),
      p2: asInt(m['p2']),
      held: asInt(m['held'], 0) == 1,
      exitIp: asStr(m['ip']),
      countryCode: asStr(m['countryCode']),
      country: asStr(m['country']),
      error: asStr(m['error']),
    );
  }

  /// Works: answered and held. Unstable: answered but the
  /// connection did not hold for 5 seconds — the filtered-network
  /// failure the hold check exists to catch. Failed: the test
  /// never got an answer, or never ran.
  SandboxVerdict get verdict {
    if (!ok) return SandboxVerdict.failed;
    if (!held) return SandboxVerdict.unstable;
    return SandboxVerdict.works;
  }

  /// How many of the three hold probes answered.
  int get heldProbes => [p0, p1, p2].where((probe) => probe >= 0).length;

  String get title => switch (verdict) {
    SandboxVerdict.works => 'Sandbox test passed',
    SandboxVerdict.unstable => 'Unstable connection',
    SandboxVerdict.failed => 'Sandbox test failed',
  };

  String get detail => switch (verdict) {
    SandboxVerdict.failed =>
      error.isEmpty ? 'The config did not answer.' : error,
    SandboxVerdict.unstable =>
      'The config answered, but the connection did not hold '
          'for 5 seconds — it may drop under filtering.',
    SandboxVerdict.works =>
      'Delay, hold and exit all checked out in the isolated test.',
  };
}
