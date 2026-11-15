/// Guided connection diagnostics (build 2029A — the
/// ship-first item of this build): a staged check with
/// plain-language findings, plus the journal every other
/// feature of the build writes its steps into (watchdog
/// escalations, chain lifecycle, connect fast-paths).
///
/// The check walks the same stages a connection does:
///
/// 1. the entry point answers a plain connection,
/// 2. the entry point answers a TLS handshake with the
///    profile's own SNI,
/// 3. a real request crosses a throwaway core (which also
///    proves the core's in-tunnel DNS: the request is made by
///    domain name, resolved by the core, not locally),
///
/// and, for the live tunnel:
///
/// 1. the local SOCKS port is open,
/// 2. a request by domain name crosses it (in-tunnel DNS +
///    data plane together),
/// 3. the exit identifies itself.
///
/// Every stage lands in the journal with a verdict a
/// non-specialist can act on.

import 'dart:async';
import 'dart:io';

import 'scan_probes.dart';
import 'xray_models.dart';

/// One journal line: when, from which feature, what happened,
/// and (when known) whether it was good news.
class DiagEntry {
  const DiagEntry({
    required this.atMs,
    required this.source,
    required this.text,
    this.ok,
  });

  final int atMs;

  /// 'check' | 'watchdog' | 'chain' | 'connect' | 'scan'
  final String source;
  final String text;
  final bool? ok;

  String get line {
    final t = DateTime.fromMillisecondsSinceEpoch(atMs);
    String two(int v) => v.toString().padLeft(2, '0');
    final mark = ok == null ? '·' : (ok! ? '✓' : '✗');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)} '
        '$mark [$source] $text';
  }
}

/// The diagnostics journal: an in-memory ring the UI renders,
/// mirrored line-by-line to a sink (the controller appends it
/// to diagnostics.log in the engine's workdir, so the record
/// survives the page and the process).
class DiagnosticsJournal {
  DiagnosticsJournal({this.sink});

  void Function(String line)? sink;
  final List<DiagEntry> _entries = [];
  static const int capacity = 300;

  List<DiagEntry> get entries => List.unmodifiable(_entries);

  void add(String source, String text, {bool? ok}) {
    final entry = DiagEntry(
      atMs: DateTime.now().millisecondsSinceEpoch,
      source: source,
      text: text,
      ok: ok,
    );
    _entries.add(entry);
    while (_entries.length > capacity) {
      _entries.removeAt(0);
    }
    try {
      sink?.call(entry.line);
    } catch (_) {
      // The journal is evidence, never a reason to fail.
    }
  }
}

/// One stage of a connection check, as the UI renders it.
class CheckStage {
  const CheckStage({
    required this.title,
    required this.ok,
    required this.detail,
  });

  final String title;
  final bool ok;
  final String detail;
}

/// Whether the local SOCKS port on [port] answers a SOCKS5
/// greeting: the first thing a dead tunnel fails.
Future<bool> socksPortAnswers(int port) async {
  Socket? socket;
  try {
    socket = await Socket.connect(
      '127.0.0.1',
      port,
      timeout: const Duration(seconds: 2),
    );
    socket.add(const [5, 1, 0]);
    final reply = await socket
        .timeout(const Duration(seconds: 2))
        .firstWhere((data) => data.length >= 2);
    return reply[0] == 5;
  } catch (_) {
    return false;
  } finally {
    socket?.destroy();
  }
}

/// A real HTTP request through the SOCKS proxy on [port],
/// addressed by DOMAIN name (so the proxy's own DNS resolves
/// it — this is the in-tunnel DNS proof), expecting the
/// generate_204 answer. The round trip in ms, or -1.
///
/// [user]/[pass] (build 2062, feature queue #2, LAN sharing):
/// when both are non-empty the greeting offers username/
/// password auth (method 2) and the subnegotiation runs before
/// CONNECT. Empty credentials take the byte-identical noauth
/// path of every earlier build.
Future<int> socksDomainRequestMs(
  int port, {
  String host = 'connectivitycheck.gstatic.com',
  Duration timeout = const Duration(seconds: 8),
  String user = '',
  String pass = '',
}) async {
  final sw = Stopwatch()..start();
  Socket? socket;
  try {
    socket = await Socket.connect('127.0.0.1', port, timeout: timeout);
    final s = socket;
    final responses = StreamQueue(s.timeout(timeout));
    final authed = user.isNotEmpty && pass.isNotEmpty;
    s.add(authed ? const [5, 2, 0, 2] : const [5, 1, 0]);
    var reply = await responses.next;
    if (reply.length < 2 || reply[0] != 5) return -1;
    if (authed) {
      if (reply[1] != 2) return -1;
      // RFC 1929 username/password subnegotiation: version 1,
      // one-byte lengths, then the credentials.
      final userBytes = user.codeUnits;
      final passBytes = pass.codeUnits;
      if (userBytes.length > 255 || passBytes.length > 255) return -1;
      s.add([
        1,
        userBytes.length,
        ...userBytes,
        passBytes.length,
        ...passBytes,
      ]);
      reply = await responses.next;
      if (reply.length < 2 || reply[0] != 1 || reply[1] != 0) return -1;
    }
    final hostBytes = host.codeUnits;
    s.add([
      5, 1, 0, 3, hostBytes.length, ...hostBytes, 0, 80, // port 80
    ]);
    reply = await responses.next;
    if (reply.length < 2 || reply[0] != 5 || reply[1] != 0) return -1;
    s.add(
      'HEAD /generate_204 HTTP/1.1\r\nHost: $host\r\n'
              'Connection: close\r\n\r\n'
          .codeUnits,
    );
    final head = String.fromCharCodes(await responses.next);
    if (!head.startsWith('HTTP/')) return -1;
    final code = int.tryParse(head.split(' ').elementAt(1)) ?? -1;
    return (code == 204 || code == 200) ? sw.elapsedMilliseconds : -1;
  } catch (_) {
    return -1;
  } finally {
    socket?.destroy();
  }
}

/// Minimal stream queue for the SOCKS handshake above (the
/// `async` package is not a dependency of this app).
class StreamQueue<T> {
  StreamQueue(Stream<T> source) : _source = source;

  final Stream<T> _source;
  final List<T> _buffer = [];
  final List<Completer<T>> _waiters = [];
  StreamSubscription<T>? _sub;

  Future<T> get next {
    if (_buffer.isNotEmpty) return Future.value(_buffer.removeAt(0));
    final completer = Completer<T>();
    _waiters.add(completer);
    _sub ??= _source.listen(
      (event) {
        if (_waiters.isNotEmpty) {
          _waiters.removeAt(0).complete(event);
        } else {
          _buffer.add(event);
        }
      },
      onError: (Object e) {
        for (final w in _waiters) {
          w.completeError(e);
        }
        _waiters.clear();
      },
    );
    return completer.future;
  }
}

/// The staged checker. Every probe is injectable so the
/// staging and the wording are unit-testable without sockets
/// or a core.
class ConnectionChecker {
  ConnectionChecker({
    Future<int> Function(String host, int port)? tcp,
    Future<bool> Function(String host, int port, String sni)? tls,
    Future<int> Function(Profile p)? delay,
    Future<bool> Function(int port)? socksOpen,
    Future<int> Function(int port)? socksDomain,
    Future<Map<String, String>?> Function(int port)? exit,
    // LAN sharing (build 2062): the SOCKS credentials for the
    // default domain probe only — injected lambdas keep their
    // (int) signature and are untouched by these.
    String socksUser = '',
    String socksPass = '',
  }) : _tcp = tcp ?? ((h, p) => tcpProbe(h, p)),
       _tls = tls ?? ((h, p, s) => tlsSniAnswers(h, p, s)),
       _delay = delay,
       _socksOpen = socksOpen ?? socksPortAnswers,
       _socksDomain =
           socksDomain ??
           ((p) => socksDomainRequestMs(p, user: socksUser, pass: socksPass)),
       _exit = exit;

  final Future<int> Function(String, int) _tcp;
  final Future<bool> Function(String, int, String) _tls;
  final Future<int> Function(Profile p)? _delay;
  final Future<bool> Function(int) _socksOpen;
  final Future<int> Function(int) _socksDomain;
  final Future<Map<String, String>?> Function(int)? _exit;

  /// Checks a stored profile without a tunnel: entry
  /// reachability, the SNI handshake, and a real request
  /// through a throwaway core.
  Future<List<CheckStage>> checkProfile(Profile p) async {
    final stages = <CheckStage>[];
    final udpOnly = funnelSkipsCheapStages(p);
    if (!udpOnly) {
      final ms = await _tcp(p.address, p.port);
      stages.add(
        CheckStage(
          title: 'Server answers a plain connection',
          ok: ms >= 0,
          detail: ms >= 0
              ? '${p.address}:${p.port} answered in $ms ms.'
              : 'Nothing answered at ${p.address}:${p.port}. The '
                    'address may be blocked on this network, or the '
                    'server is down.',
        ),
      );
      if (p.security == 'tls') {
        final answers = await _tls(p.address, p.port, funnelSniOf(p));
        stages.add(
          CheckStage(
            title: 'TLS handshake answers',
            ok: answers,
            detail: answers
                ? 'The server completed a TLS handshake with this '
                      "profile's name."
                : 'The TLS handshake was reset or timed out — on a '
                      'filtered network this is the classic sign the '
                      "server's name is being blocked. A fragment or "
                      'ECH shape may get through.',
          ),
        );
      }
    }
    if (_delay != null) {
      final ms = await _delay(p);
      stages.add(
        CheckStage(
          title: 'A real request crosses',
          ok: ms >= 0,
          detail: ms >= 0
              ? 'A request through this profile answered in $ms ms, '
                    'resolved by the core itself.'
              : 'The entry point may answer, but no real request '
                    'came back through the profile. The server may '
                    'be full or dead, or the session is being frozen '
                    'after the handshake.',
        ),
      );
    }
    return stages;
  }

  /// Checks the tunnel that is already running: the local
  /// proxy port, a by-domain request through it (in-tunnel
  /// DNS + data plane), and the exit identity. [listenHost]
  /// (build 2062, LAN sharing) is only the address the
  /// "listening on …" detail names — the probes themselves
  /// always go to 127.0.0.1.
  Future<List<CheckStage>> checkLive({
    required int socksPort,
    String listenHost = '127.0.0.1',
  }) async {
    final stages = <CheckStage>[];
    final open = await _socksOpen(socksPort);
    stages.add(
      CheckStage(
        title: 'Local proxy port is open',
        ok: open,
        detail: open
            ? 'The tunnel core is listening on $listenHost:$socksPort.'
            : 'Nothing is listening on $listenHost:$socksPort — the '
                  'tunnel core is not running.',
      ),
    );
    if (open) {
      final ms = await _socksDomain(socksPort);
      stages.add(
        CheckStage(
          title: 'Names resolve and data crosses inside the tunnel',
          ok: ms >= 0,
          detail: ms >= 0
              ? 'A request by name answered through the tunnel in '
                    '$ms ms — DNS inside the tunnel works.'
              : 'The port is open but a request by name did not '
                    'come back: either DNS inside the tunnel is '
                    'failing or the data path is frozen.',
        ),
      );
      if (ms >= 0 && _exit != null) {
        final info = await _exit(socksPort);
        final ip = info?['ip'] ?? '';
        stages.add(
          CheckStage(
            title: 'Exit identity',
            ok: ip.isNotEmpty,
            detail: ip.isNotEmpty
                ? 'Traffic leaves through $ip'
                      '${(info?['countryCode'] ?? '').isNotEmpty ? ' (${info!['countryCode']})' : ''}.'
                : 'The tunnel carried the request, but the exit '
                      'did not identify itself.',
          ),
        );
      }
    }
    return stages;
  }
}
