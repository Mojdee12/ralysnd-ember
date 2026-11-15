/// The Psiphon engine's brain: its settings (mode, exit region,
/// upstream proxy, transport limits), their persistence, and the
/// tunnel's on/off state — everything the Ember UI binds to. Mirrors
/// the Xray controller's shape so the shell arbitrates all three
/// engines the same way.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../atomic_json_store.dart';
import '../core/android_core.dart';
import '../core/poll_policy.dart';
import '../net/probe.dart';
import '../xray/exit_info.dart';
import 'psiphon_platform.dart';
import 'psiphon_strategy.dart';

/// One selectable tunnel transport: the friendly name the UI shows
/// and the protocol value the core's LimitTunnelProtocols takes.
class PsiphonTransport {
  final String label;
  final String value;
  const PsiphonTransport(this.label, this.value);
}

/// The transports the core can be limited to (protocol.go). An empty
/// selection means the core's own automatic choice — its default and
/// the recommended setting.
const psiphonTransports = <PsiphonTransport>[
  PsiphonTransport('SSH', 'SSH'),
  PsiphonTransport('Obfuscated SSH', 'OSSH'),
  PsiphonTransport('TLS Obfuscated SSH', 'TLS-OSSH'),
  PsiphonTransport('Shadowsocks SSH', 'SHADOWSOCKS-OSSH'),
  PsiphonTransport('QUIC', 'QUIC-OSSH'),
  PsiphonTransport('Meek (fronted)', 'FRONTED-MEEK-OSSH'),
  PsiphonTransport('Meek (fronted HTTP)', 'FRONTED-MEEK-HTTP-OSSH'),
  PsiphonTransport('Meek (fronted QUIC)', 'FRONTED-MEEK-QUIC-OSSH'),
  PsiphonTransport('Meek (unfronted)', 'UNFRONTED-MEEK-OSSH'),
  PsiphonTransport('Meek (unfronted HTTPS)', 'UNFRONTED-MEEK-HTTPS-OSSH'),
  PsiphonTransport(
    'Meek (unfronted, session ticket)',
    'UNFRONTED-MEEK-SESSION-TICKET-OSSH',
  ),
  PsiphonTransport('Conjure', 'CONJURE-OSSH'),
];

/// The egress regions the core announced in this app's VM smoke test
/// (AvailableEgressRegions notice, tunnel-core v2.0.42); the live list
/// from the running core replaces it whenever the engine has run.
const psiphonFallbackRegions = <String>[
  'AT', 'AU', 'BE', 'BR', 'CA', 'CH', 'CZ', 'DE', 'DK', 'ES', 'FI',
  'FR', 'GB', 'IE', 'IN', 'IT', 'JP', 'LT', 'NL', 'NO', 'PL', 'RO',
  'RS', 'SE', 'SG', 'US',
];

class PsiphonSettings {
  /// True: the whole device through the TUN bridge. False: the core
  /// only serves its local proxies (proxy-only).
  bool vpnMode = true;

  /// The egress region code ('' = automatic: the core picks).
  String region = '';

  /// An upstream proxy URL (http://[user:pass@]host:port or
  /// socks5://...) Psiphon itself connects through; '' = direct.
  String upstream = '';

  /// LimitTunnelProtocols values; empty = automatic.
  Set<String> protocols = {};

  // ---- Build 2065: the strategy pack ----------------------------

  /// The picked connection method: '' = Auto ladder, else a rung
  /// letter (A/E/D/C/P/X — see psiphon_strategy.dart).
  String method = '';

  /// Winner memory, keyed by network identity (build 2065, item
  /// 4): network key -> the rung that last connected there. The
  /// pre-2065 single 'lastMethod' value migrates into every key's
  /// fallback (see [winnerFor]).
  Map<String, String> lastMethodByNetwork = {};
  String lastMethod = '';

  /// The paired personal Conduit station (rung P), from a
  /// psiphon://pair/ link. Empty = none paired.
  String compartmentId = '';
  String compartmentName = '';

  /// Build 2069: Beast Mode is WITHDRAWN. It was the one
  /// feature that needed the rebuilt fork core (the
  /// AggressiveEstablishment config field is that core's
  /// patch, not a stock field); 2069 transplants ralysnd's
  /// complete stock Psiphon stack (v2.0.39 wrapper +
  /// libpgjni.so) in place of the rebuilt core, so the
  /// setting, its toggle, and the config emission are all
  /// removed rather than left as a dead control. A stored
  /// 'beastMode' key from an older build is now simply an
  /// unknown key — fromJson ignores it by design. Beast
  /// returns only on a device-proven core.

  /// CDN fronting (scanned + dial-override edges) on the
  /// fronted rung: config-level, stock-core supported.
  /// Default on.
  bool cdnFronting = true;

  /// Disable core timeouts (NetworkLatencyMultiplierLambda=0.1 —
  /// Shir's Disable-Timeouts option). Default off.
  bool disableTimeouts = false;

  /// The CDN edge list: built-ins (merged in at load) plus the
  /// owner's custom entries, each carrying its last probe result.
  List<CdnEdge> cdnEdges = [];

  /// Feed the fastest reachable edges to the core automatically.
  bool edgeAutoUse = true;

  /// The manually pinned edge id (used when [edgeAutoUse] is off).
  String pinnedEdgeId = '';

  /// When the edge list was last fully tested (epoch ms).
  int edgesTestedAtMs = 0;

  /// The network key the settings were last used on (the shell
  /// updates it; the winner memory is keyed by it).
  String networkKey = '';

  String winnerFor(String key) =>
      lastMethodByNetwork[key] ?? lastMethod;

  Map<String, dynamic> toJson() => {
        'vpnMode': vpnMode,
        'region': region,
        'upstream': upstream,
        'protocols': protocols.toList(),
        'method': method,
        'lastMethodByNetwork': lastMethodByNetwork,
        'lastMethod': lastMethod,
        'compartmentId': compartmentId,
        'compartmentName': compartmentName,
        'cdnFronting': cdnFronting,
        'disableTimeouts': disableTimeouts,
        'cdnEdges': cdnEdges.map((e) => e.toJson()).toList(),
        'edgeAutoUse': edgeAutoUse,
        'pinnedEdgeId': pinnedEdgeId,
        'edgesTestedAtMs': edgesTestedAtMs,
      };

  static PsiphonSettings fromJson(Map<String, dynamic> j) {
    // Build 2066 (device-state gate): every field coerces
    // defensively. The old `as bool?` / `as String?` casts threw
    // on a single wrong-typed value in a carried-over or damaged
    // store, and load()'s catch then discarded EVERY setting —
    // survivable, but needlessly total. Now a bad field degrades
    // to its own default and the rest survive. An unknown
    // connection method (written by another build, or corrupt)
    // falls back to Auto: a bogus pinned rung would otherwise
    // make every connect fail with nothing visibly wrong.
    String str(Object? v) => v is String ? v : '';
    bool flag(Object? v, bool d) => v is bool ? v : d;
    List<Object?> listOf(Object? v) =>
        v is List ? v.cast<Object?>() : const [];
    final s = PsiphonSettings();
    s.vpnMode = flag(j['vpnMode'], true);
    s.region = str(j['region']);
    s.upstream = str(j['upstream']);
    s.protocols = listOf(j['protocols'])
        .map((e) => e.toString())
        .where((v) => psiphonTransports.any((t) => t.value == v))
        .toSet();
    final method = str(j['method']);
    s.method = psiphonMethods.containsKey(method) ? method : '';
    final winners = j['lastMethodByNetwork'];
    s.lastMethodByNetwork = (winners is Map ? winners : const {}).map(
      (k, v) => MapEntry(k.toString(), v.toString()),
    );
    s.lastMethod = str(j['lastMethod']);
    s.compartmentId = str(j['compartmentId']);
    s.compartmentName = str(j['compartmentName']);
    s.cdnFronting = flag(j['cdnFronting'], true);
    s.disableTimeouts = flag(j['disableTimeouts'], false);
    s.cdnEdges = listOf(j['cdnEdges'])
        .whereType<Map>()
        .map((e) => CdnEdge.fromJson(e.cast<String, dynamic>()))
        .where((e) => e.address.isNotEmpty)
        .toList();
    s.edgeAutoUse = flag(j['edgeAutoUse'], true);
    s.pinnedEdgeId = str(j['pinnedEdgeId']);
    final testedAt = j['edgesTestedAtMs'];
    s.edgesTestedAtMs = testedAt is num ? testedAt.toInt() : 0;
    return s;
  }
}

class PsiphonController extends ChangeNotifier {
  PsiphonSettings settings = PsiphonSettings();
  PsiphonState state = PsiphonState.stopped;
  bool connecting = false;
  int upRate = 0;
  int downRate = 0;

  /// The store's complaint, when it has one (build 2071,
  /// review §5.4): set when a save fails or the saved file
  /// was damaged at load, cleared by the next successful
  /// save. It rides the existing error surface — [lastError]
  /// reports it whenever no fresher connect error exists —
  /// instead of the failure being swallowed forever.
  String? storeError;

  String? _lastError;

  /// The last connect error — or, while there is none, the
  /// store's complaint ([storeError]).
  String? get lastError => _lastError ?? storeError;
  set lastError(String? v) => _lastError = v;

  /// The running tunnel's exit IP/country, looked up best-effort
  /// through the tunnel once it is up.
  ExitInfo? exitInfo;
  bool _exitFetching = false;

  /// Set by the shell: stops the other engines so only one tunnel is
  /// ever up. Returns when they are off.
  Future<void> Function()? stopOtherEngine;

  /// Set by the shell: the global tunnel MTU (build 2038, queue 2f) —
  /// the Xray settings value, read at connect time so a change in
  /// Settings applies to the next connect without an app restart.
  /// Defaults to 1500 (the unchanged behaviour) when unwired.
  int Function() tunnelMtu = () => 1500;

  /// Set by the shell: the tunnel's DNS (build 2057, audit §6
  /// engine low) — the Xray settings localDns, read at connect
  /// time. The old code hardcoded '1.1.1.1' here while Settings
  /// offered a DNS the Psiphon tunnel silently ignored.
  /// Defaults to 1.1.1.1 (the unchanged behaviour) when unwired.
  String Function() localDns = () => '1.1.1.1';

  /// Set by the shell: capture IPv6 in the TUN (build 2057, audit
  /// F-M4) — the Xray settings ipv6Route, read at connect time.
  /// Defaults to true (the unchanged behaviour) when unwired.
  bool Function() tunnelIpv6 = () => true;

  Timer? _poll;
  PsiphonState? _lastSample;
  DateTime? _lastSampleAt;

  /// The regions to offer: the core's own list once known, else the
  /// fallback captured from the core.
  List<String> get regionChoices =>
      state.regions.isNotEmpty ? state.regions : psiphonFallbackRegions;

  // ---- persistence ----------------------------------------------------

  Future<File> _stateFile() async {
    final coreDir = await AndroidCore.dataDir();
    final filesDir = File(coreDir).parent;
    return File('${filesDir.path}/psiphon/state.json');
  }

  Future<Directory> workDir() async {
    final coreDir = await AndroidCore.dataDir();
    return Directory('${File(coreDir).parent.path}/psiphon');
  }

  /// The shared atomic store for this file (build 2054, audit
  /// F-H8), cached so every write for this file goes through
  /// one serialization chain.
  AtomicJsonStore? _store;

  Future<AtomicJsonStore> _atomicStore() async {
    return _store ??= AtomicJsonStore(await _stateFile());
  }

  /// True once the store has loaded (build 2054, audit F-H8):
  /// a save before load would persist default settings over
  /// the user's. Set even when the file is torn or missing.
  bool _loaded = false;

  Future<void> load() async {
    try {
      final store = await _atomicStore();
      final doc = await store.read();
      // Build 2071 (review §5.4): a store file that was there
      // but damaged starts from defaults as before — but it
      // says so on the error surface instead of silently
      // pretending nothing was ever saved.
      if (store.lastReadProblem != null) {
        storeError = storeDamagedMessage;
      }
      if (doc != null && doc['settings'] is Map) {
        settings = PsiphonSettings.fromJson(
          (doc['settings'] as Map).cast<String, dynamic>(),
        );
      }
      // Build 2065: the built-in CDN edges are code, not data —
      // merge any missing ones into the stored list so a core
      // update can add candidates without wiping results/customs.
      final known = settings.cdnEdges.map((e) => e.id).toSet();
      for (final b in builtinCdnEdges()) {
        if (!known.contains(b.id)) settings.cdnEdges.add(b);
      }
    } catch (_) {
      // A damaged store starts with defaults rather than crashing.
    } finally {
      _loaded = true;
    }
    await refreshState();
    notifyListeners();
  }

  Future<void> _save() async {
    // Build 2054 (audit F-H8): never persist before load, and
    // write atomically through the shared store — the old
    // direct write could tear the file and silently reset the
    // settings on the next launch.
    if (!_loaded) return;
    try {
      final store = await _atomicStore();
      await store.write({
        'settings': settings.toJson(),
      });
      // Build 2071 (review §5.4): the store's write never
      // throws, so read its outcome — a failure surfaces on
      // the error surface and stays until a save succeeds.
      if (store.lastWriteError != null) {
        if (storeError != storeSaveFailedMessage) {
          storeError = storeSaveFailedMessage;
          notifyListeners();
        }
      } else if (storeError == storeSaveFailedMessage) {
        // A save landed: the save-failure complaint clears.
        // A damaged-at-load complaint is NOT cleared here —
        // it clears on the next clean load, so the notice
        // survives the session that started fresh.
        storeError = null;
        notifyListeners();
      }
    } catch (_) {
      // The choice holds in memory until the next successful save.
    }
  }

  /// Stores new settings; a running tunnel keeps its start settings
  /// until the next connect (the core reads them only at start).
  Future<void> updateSettings(PsiphonSettings next) async {
    // The runtime network key is not part of the JSON round-trip
    // callers build [next] through (build 2065): carry it across
    // settings edits explicitly or every edit would forget which
    // network the winner memory belongs to.
    next.networkKey = settings.networkKey;
    settings = next;
    await _save();
    notifyListeners();
  }

  /// Picks the exit region (build 2033 — the exit-country
  /// selection the feature list asked for, completed): the
  /// choice is stored, and when a tunnel is already running
  /// it is restarted on the new region so the pick takes
  /// effect NOW. Before, picking a country while connected
  /// silently changed nothing until a manual reconnect —
  /// the picker looked broken exactly when it was used most.
  /// A failed restart surfaces through [lastError] like any
  /// connect failure; the stored region stands either way.
  Future<void> setRegion(String code) async {
    final next = PsiphonSettings.fromJson(settings.toJson());
    next.region = code;
    await updateSettings(next);
    if (state.running) {
      await disconnect();
      try {
        await connect();
      } catch (_) {
        // lastError already carries it; the region stays picked.
      }
    }
  }

  // ---- state ------------------------------------------------------------

  Future<void> refreshState() async {
    state = await PsiphonPlatform.state();
    if (state.running) {
      _lastSample = state;
      _lastSampleAt = DateTime.now();
      _startPolling();
      if (state.connected) _fetchExitInfo();
    }
    notifyListeners();
  }

  /// App-foreground state for the poll cadence (build 2050,
  /// same contract as the Xray controller's).
  bool _foreground = true;

  /// Exit-lookup failure backoff (build 2050, audit B-H3).
  int _exitFailures = 0;
  DateTime? _exitNextTryAt;

  /// The shell's lifecycle feed (build 2050): live 2 s poll
  /// only while foregrounded; a 30 s heartbeat otherwise.
  void setForeground(bool fg) {
    if (fg == _foreground) return;
    _foreground = fg;
    if (_poll != null) {
      _poll!.cancel();
      _poll = null;
      _startPolling();
    }
  }

  void _startPolling() {
    _poll ??= Timer.periodic(
      enginePollPeriod(foreground: _foreground),
      (_) async {
      final sample = await PsiphonPlatform.state();
      final now = DateTime.now();
      final last = _lastSample;
      final lastAt = _lastSampleAt;
      if (last != null && lastAt != null && sample.running) {
        final dt = now.difference(lastAt).inMilliseconds / 1000.0;
        if (dt > 0) {
          upRate =
              ((sample.upBytes - last.upBytes) / dt).round().clamp(0, 1 << 62);
          downRate = ((sample.downBytes - last.downBytes) / dt)
              .round()
              .clamp(0, 1 << 62);
        }
      }
      _lastSample = sample;
      _lastSampleAt = now;
      state = sample;
      if (sample.running && sample.connected) {
        _fetchExitInfo();
        // Proxy-only connects finish here, not in connect():
        // remember their winner too.
        unawaited(_recordWinner(sample.method));
      }
      if (!sample.running) {
        _poll?.cancel();
        _poll = null;
        upRate = 0;
        downRate = 0;
        _lastSample = null;
        _lastSampleAt = null;
        exitInfo = null;
      }
        notifyListeners();
      },
    );
  }

  void _fetchExitInfo() {
    if (_exitFetching || exitInfo != null) return;
    // Build 2050 (audit B-H3): back off after failures
    // (5 s → 15 s → 45 s → 2 min) instead of retrying at the
    // full poll cadence forever. connect() resets the schedule
    // with the session.
    final nextTry = _exitNextTryAt;
    if (nextTry != null && DateTime.now().isBefore(nextTry)) return;
    _exitFetching = true;
    PsiphonPlatform.exitInfo().then((m) {
      _exitFetching = false;
      if (m != null && m['ip'] != null && m['ip']!.isNotEmpty) {
        exitInfo = ExitInfo.fromMap(m);
        _exitFailures = 0;
        _exitNextTryAt = null;
        notifyListeners();
      } else {
        _exitFailures++;
        _exitNextTryAt = DateTime.now().add(exitRetryDelay(_exitFailures));
      }
    });
  }

  /// Persists the winning rung for the current network (build
  /// 2065 winner memory). No-op for the legacy path (no method).
  Future<void> _recordWinner(String method) async {
    if (method.isEmpty) return;
    if (settings.winnerFor(settings.networkKey) == method) return;
    settings.lastMethodByNetwork[settings.networkKey] = method;
    settings.lastMethod = method;
    await _save();
  }

  // ---- CDN edges (build 2065) ------------------------------------

  bool _edgeTesting = false;
  bool get edgeTesting => _edgeTesting;

  /// Probes every edge in the list with a real TCP+TLS handshake
  /// (the owner's "ping the CDN list" ask): per-entry latency or an
  /// honest failure, persisted with the winner. Bounded: 4 probes
  /// in flight, 4 s each.
  Future<void> testAllEdges() async {
    if (_edgeTesting) return;
    _edgeTesting = true;
    notifyListeners();
    try {
      final edges = settings.cdnEdges;
      var next = 0;
      Future<void> worker() async {
        while (next < edges.length) {
          final e = edges[next++];
          final r = await tlsProbe(
            e.address,
            e.sni,
            timeout: const Duration(seconds: 4),
          );
          e.lastOk = r.ok;
          e.lastMs = r.ms;
          e.lastTestAtMs = DateTime.now().millisecondsSinceEpoch;
          if (r.ip != null) e.testedIp = r.ip;
          notifyListeners();
        }
      }

      await Future.wait([for (var i = 0; i < 4; i++) worker()]);
      settings.edgesTestedAtMs = DateTime.now().millisecondsSinceEpoch;
      await _save();
    } finally {
      _edgeTesting = false;
      notifyListeners();
    }
  }

  /// Marks the stored edge results stale (build 2066): a network
  /// change invalidates them, because reachability measured on
  /// one network (say Wi-Fi) says nothing about another (mobile
  /// data) — yet rungs A/E feed the top results to the core at
  /// probability 1.0, so stale winners from the wrong network
  /// could pin a whole rung to dead addresses. The next connect
  /// re-probes on the current network (the pre-connect refresh
  /// below) before anything is fed.
  Future<void> invalidateEdgeResults() async {
    if (settings.edgesTestedAtMs == 0) return;
    settings.edgesTestedAtMs = 0;
    await _save();
  }

  /// The quick pre-connect refresh: when the last full test is
  /// stale (or never ran), probe the top candidates only, bounded
  /// to a few seconds, so a connect never dials blind and never
  /// waits for the whole list either.
  Future<void> _refreshEdgesIfStale() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final stale = settings.edgesTestedAtMs == 0 ||
        now - settings.edgesTestedAtMs > 15 * 60 * 1000;
    if (!stale) return;
    final candidates = rankCdnEdges(settings.cdnEdges).take(12).toList();
    await Future.wait([
      for (final e in candidates)
        tlsProbe(e.address, e.sni, timeout: const Duration(seconds: 3))
            .then((r) {
          e.lastOk = r.ok;
          e.lastMs = r.ms;
          e.lastTestAtMs = DateTime.now().millisecondsSinceEpoch;
          if (r.ip != null) e.testedIp = r.ip;
        }),
    ]);
    settings.edgesTestedAtMs = DateTime.now().millisecondsSinceEpoch;
    await _save();
  }

  /// The edge IPs the core gets for this connect, per provider.
  ({List<String> akamai, List<String> fastly}) _edgesForCore() =>
      cdnEdgesForCore(
        settings.cdnEdges,
        autoUse: settings.edgeAutoUse,
        pinnedId: settings.pinnedEdgeId,
      );

  bool get _hasEdges {
    final e = _edgesForCore();
    return e.akamai.isNotEmpty || e.fastly.isNotEmpty;
  }

  // Build 2069: the dial-override JSON that used to be built
  // here is gone with the fork core. On the transplanted
  // stock core (ralysnd's v2.0.39), tested edges reach the
  // core the way ralysnd feeds them: as preresolved provider
  // CIDRs (DNSResolverPreresolvedIPAddressCIDRs), built from
  // _edgesForCore() and emitted by the service on the fronted
  // and clean-IP rungs. Per-edge SNI pinning was a fork-core
  // capability and is withdrawn with that core.

  // ---- connect / disconnect ----------------------------------------------

  Future<void> connect() async {
    connecting = true;
    lastError = null;
    exitInfo = null;
    _exitFailures = 0;
    _exitNextTryAt = null;
    notifyListeners();
    try {
      // One tunnel at a time: the other engines go off first.
      await stopOtherEngine?.call();
      if (state.running) await disconnect();
      // Build 2065: the strategy ladder. Pinned methods with a
      // missing prerequisite fail BEFORE starting anything, with
      // the reason in plain words — a ladder that silently drops
      // the user's picked method would be a dead choice.
      final method = settings.method;
      if (method == 'E') {
        await _refreshEdgesIfStale();
        if (!_hasEdges) {
          throw StateError(
            'Clean IP needs at least one reachable CDN edge — '
            'open Psiphon settings → CDN edges and run Test all.',
          );
        }
      }
      if (method == 'P' && settings.compartmentId.isEmpty) {
        throw StateError(
          'Personal Conduit needs a pairing — paste a '
          'psiphon://pair/ link in Psiphon settings first.',
        );
      }
      if (method == 'X' && settings.upstream.trim().isEmpty) {
        throw StateError(
          'Proxy server method needs an upstream proxy address.',
        );
      }
      if (method.isEmpty || method == 'A') {
        // The fronted/clean-IP rungs feed on tested edges; refresh
        // a stale list first (bounded, a few seconds at most).
        await _refreshEdgesIfStale();
      }
      final edges = _edgesForCore();
      final rungs = psiphonRungOrder(
        method: method,
        lastWinner: settings.winnerFor(settings.networkKey),
        hasEdges: edges.akamai.isNotEmpty || edges.fastly.isNotEmpty,
        hasPairing: settings.compartmentId.isNotEmpty,
        hasUpstream: settings.upstream.trim().isNotEmpty,
      );
      await PsiphonPlatform.setOn(
        vpnMode: settings.vpnMode,
        region: settings.region,
        upstream: settings.upstream.trim(),
        protocols: settings.protocols.toList(),
        dns: localDns(),
        mtu: tunnelMtu(),
        ipv6: tunnelIpv6(),
        rungs: rungs,
        compartment: settings.compartmentId,
        cleanAkamai: edges.akamai,
        cleanFastly: edges.fastly,
        disableTimeouts: settings.disableTimeouts,
        cdnFront: settings.cdnFronting,
      );
      // The service reports itself once the core is up; a tunnel to a
      // Psiphon server can take a while longer (state.connected).
      for (var i = 0; i < 40; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        state = await PsiphonPlatform.state();
        if (state.running) break;
      }
      if (!state.running) throw StateError('start-failed');
      // Build 2057 (audit F-M4): in VPN mode "running" alone is not
      // a connection — the old code returned success while the core
      // had not reached a server, leaving a TUN-up blackhole that
      // showed a running session with connected=false. Wait for the
      // core's own onConnected (the chain-underlay path already waits
      // for exactly this, 90 s); a core that never connects is
      // stopped, so a retry starts clean instead of stacking on a
      // dead core. Proxy-only mode keeps the old bar: there is no
      // TUN to blackhole, and the SOCKS proxy serves whenever the
      // core answers it.
      if (settings.vpnMode) {
        var connected = false;
        // Build 2065: the ladder's worst case is the sum of its
        // rung budgets (region phase 25 s + A 60 + E 45 + D 45 +
        // C 75 = 250 s); wait past it (300 s) instead of the old
        // single-attempt 110 s. A service that gives up stops
        // running, which breaks the wait early either way.
        for (var i = 0; i < 1200; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 250));
          state = await PsiphonPlatform.state();
          if (state.connected) {
            connected = true;
            break;
          }
          if (!state.running) break;
        }
        if (!connected) {
          await disconnect();
          throw StateError('connect-timeout');
        }
      }
      // Build 2065: winner memory — the rung the service reports
      // is remembered for this network and tried first next time.
      await _recordWinner(state.method);
      _lastSample = state;
      _lastSampleAt = DateTime.now();
      _startPolling();
    } catch (e) {
      lastError = e.toString();
      rethrow;
    } finally {
      connecting = false;
      notifyListeners();
    }
  }

  Future<void> disconnect() async {
    await PsiphonPlatform.stop();
    for (var i = 0; i < 20; i++) {
      state = await PsiphonPlatform.state();
      if (!state.running) break;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    state = await PsiphonPlatform.state();
    exitInfo = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  // ---- logs ----------------------------------------------------------------

  /// The tails of the Psiphon logs, newest content last.
  /// tunlink.log is the pre-2066 bridge's file: since build 2066
  /// the bridge logs into psiphon.log, and this stays readable
  /// only so an upgraded phone's old file is not orphaned.
  /// crash.log (build 2068) is the native crash recorder's file:
  /// every uncaught native death and every guarded start
  /// refusal, with its full stack — the evidence the 2066/2067
  /// tap-crash never left behind.
  Future<String> readLogs() async {
    final dir = await workDir();
    final out = StringBuffer();
    for (final name in ['psiphon.log', 'tunlink.log', 'crash.log']) {
      // crash.log lives in filesDir itself (the recorder's
      // home), one level above this engine's workDir.
      final file = name == 'crash.log'
          ? File('${dir.parent.path}/$name')
          : File('${dir.path}/$name');
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
    for (final name in ['psiphon.log', 'tunlink.log']) {
      try {
        await File('${dir.path}/$name').writeAsString('');
      } catch (_) {
        // Not there yet.
      }
    }
    // Build 2070 (review §3.4): Clear means all of it — the
    // crash.log section this viewer displays is emptied too
    // (the shared recorder file in filesDir; see the Xray
    // controller's clearLogs for the shared-file semantics).
    try {
      await File('${dir.parent.path}/crash.log').writeAsString('');
    } catch (_) {
      // Not there yet.
    }
  }
}
