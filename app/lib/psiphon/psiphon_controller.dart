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
import '../net/geo_country.dart';
import '../net/probe.dart';
import '../xray/exit_info.dart';
import 'psiphon_platform.dart';
import 'psiphon_strategy.dart';
import 'psiphon_watchdog.dart';

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

  /// Bridge policy for the Auto ladder (build 2075, feature
  /// item 10): 'auto' (fronted and plain rungs alternate as
  /// the ladder falls through), 'on' (bridges only — the
  /// plain direct rung never runs), 'off' (no bridges — the
  /// fronted rungs never run). A pinned method ignores it.
  String bridgeMode = 'auto';

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
  /// Build 2125 (audit A25-26 / F-05): the default flips
  /// to OFF under the owner's defaults law (every
  /// Ember-added feature ships OFF; the owner enables what
  /// he wants) — it shipped default-ON, a dial-override
  /// egress change nobody chose. Stored values move once
  /// via the defaultsReset2125 migration in fromJson.
  bool cdnFronting = false;

  /// Disable core timeouts (NetworkLatencyMultiplierLambda=0.1 —
  /// Shir's Disable-Timeouts option). Default off.
  bool disableTimeouts = false;

  /// Build 2129 (Leg 2): the Shiro bootstrap — the public
  /// Shirokhorshid (GPL-3.0-or-later) partner bootstrap as
  /// ONE set: its identity, its 2,434-entry embedded server
  /// list and its fronting overrides replace the MLM set on
  /// the next start. Default OFF: off, the engine runs the
  /// 2128 MLM identity + 493-entry list exactly as before.
  bool shiroBootstrap = false;

  /// Build 2129 (Leg 2): strong mode — AggressiveEstablishment
  /// in the core config (LML's Shiro "strong" option).
  /// Default OFF, in both bootstrap modes.
  bool strongMode = false;

  /// The CDN edge list: built-ins (merged in at load) plus the
  /// owner's custom entries, each carrying its last probe result.
  List<CdnEdge> cdnEdges = [];

  /// Feed the fastest reachable edges to the core automatically.
  /// Build 2125 (audit A25-26 / F-05): default OFF, like
  /// [cdnFronting] above — an automatic egress change is
  /// the owner's to enable.
  bool edgeAutoUse = false;

  /// Build 2125 (audit A25-26 / F-05): the one-time
  /// defaults-reset marker, the 2114/2116 pattern — the
  /// two fields above were written on every save, so a
  /// stored ON cannot be told apart from the shipped
  /// default; both move to OFF exactly once, and a value
  /// set afterwards is kept.
  bool defaultsReset2125 = false;

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
        'bridgeMode': bridgeMode,
        'lastMethodByNetwork': lastMethodByNetwork,
        'lastMethod': lastMethod,
        'compartmentId': compartmentId,
        'compartmentName': compartmentName,
        'cdnFronting': cdnFronting,
        'disableTimeouts': disableTimeouts,
        'shiroBootstrap': shiroBootstrap,
        'strongMode': strongMode,
        'cdnEdges': cdnEdges.map((e) => e.toJson()).toList(),
        'edgeAutoUse': edgeAutoUse,
        'defaultsReset2125': defaultsReset2125,
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
    // Build 2075: the bridge policy — an unknown stored value
    // reads as 'auto', never as a broken ladder.
    final bridge = str(j['bridgeMode']);
    s.bridgeMode = const {'auto', 'on', 'off'}.contains(bridge)
        ? bridge
        : 'auto';
    final winners = j['lastMethodByNetwork'];
    s.lastMethodByNetwork = (winners is Map ? winners : const {}).map(
      (k, v) => MapEntry(k.toString(), v.toString()),
    );
    s.lastMethod = str(j['lastMethod']);
    s.compartmentId = str(j['compartmentId']);
    s.compartmentName = str(j['compartmentName']);
    // Build 2125 (audit A25-26 / F-05): the fallbacks are
    // the new OFF defaults; a pre-2125 store's values are
    // then moved OFF once by the reset below.
    s.cdnFronting = flag(j['cdnFronting'], false);
    s.disableTimeouts = flag(j['disableTimeouts'], false);
    // Build 2129 (Leg 2): absent in older stores = OFF.
    s.shiroBootstrap = flag(j['shiroBootstrap'], false);
    s.strongMode = flag(j['strongMode'], false);
    s.cdnEdges = listOf(j['cdnEdges'])
        .whereType<Map>()
        .map((e) => CdnEdge.fromJson(e.cast<String, dynamic>()))
        .where((e) => e.address.isNotEmpty)
        .toList();
    s.edgeAutoUse = flag(j['edgeAutoUse'], false);
    // Build 2125 (audit A25-26 / F-05) defaults reset, the
    // 2114/2116 pattern: cdnFronting and edgeAutoUse
    // shipped default-ON and are written on every save, so
    // a stored ON is the shipped default, not a
    // discernible choice — both move to OFF exactly once.
    // A value set afterwards is kept.
    s.defaultsReset2125 = j['defaultsReset2125'] == true;
    if (!s.defaultsReset2125) {
      s.cdnFronting = false;
      s.edgeAutoUse = false;
      s.defaultsReset2125 = true;
    }
    s.pinnedEdgeId = str(j['pinnedEdgeId']);
    final testedAt = j['edgesTestedAtMs'];
    s.edgesTestedAtMs = testedAt is num ? testedAt.toInt() : 0;
    return s;
  }
}

/// Build 2095 (third-pass audit 2.1): a disconnect during
/// connect()'s pre-start window bumps [_connectGen]; the
/// attempt checks it and unwinds quietly instead of
/// raising the tunnel the user just cancelled.
class _PsiphonConnectCancelled implements Exception {
  const _PsiphonConnectCancelled();
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

  /// Set by the shell: the Settings kill switch (build
  /// 2125, audit A25-04 / plan S-4) — read at connect time
  /// and passed to the TUN start; with it on, an
  /// unexpectedly dead standalone session's TUN is held
  /// as a blackhole instead of being closed to direct
  /// traffic. Defaults to false when unwired.
  bool Function() killSwitchEnabled = () => false;

  Timer? _poll;
  PsiphonState? _lastSample;
  DateTime? _lastSampleAt;

  /// Build 2088: the external watchdog (psiphon_watchdog.dart)
  /// — armed by every connect() for its attempt, fed by the
  /// connect path's own state samples, and settled when the
  /// attempt resolves. Its firing is the native side's: find
  /// the wedged :psiphon process, dump it, kill it, publish
  /// the failure this controller already fails fast on.
  final PsiphonWatchdog _watchdog = PsiphonWatchdog();

  /// Build 2095 (audit 2.1): the connect generation.
  int _connectGen = 0;

  /// Build 2095 (audit 1.4): the on-disk store belongs to
  /// a newer build; saves are refused.
  bool _storeFromNewerVersion = false;

  /// Build 2097 (post-2096 audit C-L7/C-L12): the on-disk
  /// document is not safely ours to overwrite — it was
  /// unreadable at load (intact) or valid JSON of the
  /// wrong shape (foreign). Saves are refused while it
  /// exists; if the file disappears, saves resume.
  bool _storeProtected = false;

  /// The tail timer for an attempt whose start call is still
  /// inside the library when connect() returns (build 2088):
  /// connect() now waits for a tunnel in BOTH modes (build
  /// 2091), so a return with the call still inside is the
  /// wedge frontier only — the deadline keeps ticking on this
  /// one-shot timer until it can be settled.
  Timer? _watchdogTail;

  /// The watchdog's clock (a test seam; production reads
  /// the wall clock).
  @visibleForTesting
  DateTime Function() nowForWatchdog = DateTime.now;

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
      if (store.lastReadProblem == 'damaged') {
        storeError = storeDamagedMessage;
      }
      // Build 2097 (post-2096 audit C-L7): an UNREADABLE
      // store (intact file, filesystem error) is not
      // damage — build 2096 set the damaged message and
      // let the first save overwrite the intact original.
      // The file is protected now (see _storeProtected).
      if (store.lastReadProblem == 'unreadable') {
        _storeProtected = true;
        storeError = storeUnreadableMessage;
      }
      // Build 2095 (third-pass audit 1.4): never
      // overwrite a newer build's store.
      if (doc != null && storeSchemaVersion(doc) > 1) {
        _storeFromNewerVersion = true;
        storeError =
            'Your saved data was written by a newer build '
            'of Ember — this build will not overwrite it.';
      }
      // Build 2097 (post-2096 audit C-L12): a 'settings'
      // value of the wrong shape (a foreign document) used
      // to be silently ignored — defaults in memory, no
      // surface, and the next save overwrote the foreign
      // file. It is damage-shaped now: surfaced, and the
      // file is protected from overwrite.
      if (doc != null && doc['settings'] != null && doc['settings'] is! Map) {
        _storeProtected = true;
        storeError = storeDamagedMessage;
      }
      // Build 2098 (post-2097 audit L10): the missing-key
      // sibling — a non-empty document with NO 'settings'
      // key at all (a foreign or misplaced file) used to
      // fall silently into defaults and be overwritten by
      // the next save. A real Psiphon store always carries
      // 'settings'; its absence is damage-shaped too.
      if (doc != null && doc.isNotEmpty && !doc.containsKey('settings')) {
        _storeProtected = true;
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
      if (_storeFromNewerVersion) return;
      // Build 2097 (post-2096 audit C-L7/C-L12): never
      // overwrite a protected document while it exists.
      if (_storeProtected) {
        if (await store.file.exists()) return;
        _storeProtected = false;
      }
      await store.write({
        'schemaVersion': 1,
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
      if (state.connected) {
        _fetchExitInfo();
      } else {
        // Build 2095 (third-pass audit 1.5): a session
        // adopted after process death had NO establishment
        // watchdog — connect() arms it, adoption did not,
        // so a running-but-never-connected session was
        // polled forever with no owner. Re-arm on adoption.
        _watchdog.arm(nowForWatchdog());
      }
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
      // Build 2123 (S-5, audit P-52): an adopted session's
      // re-armed watchdog (see refreshState) previously had
      // no evaluator — the tail timer is a connect-path
      // artifact and this poll never fed the decision, so a
      // running-but-never-connected adoption could sit at
      // "connecting" past the 25 s deadline indefinitely.
      // The poll evaluates while armed; the decision itself
      // fires at most once per attempt, so evaluating here
      // alongside the connect loop cannot double-fire.
      if (_watchdog.armed && sample.running && !sample.connected) {
        await _maybeFireWatchdog();
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
    PsiphonPlatform.exitInfo().then((m) async {
      if (m != null && m['ip'] != null && m['ip']!.isNotEmpty) {
        // Build 2129 (leg 6): online answer primary; the
        // offline range tables fill a missing country
        // only (see lib/net/geo_country.dart).
        final info = await exitInfoWithOfflineCountry(ExitInfo.fromMap(m));
        _exitFetching = false;
        exitInfo = info;
        _exitFailures = 0;
        _exitNextTryAt = null;
        notifyListeners();
      } else {
        _exitFetching = false;
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
    if (connecting) return; // Build 2095 (audit 2.2).
    connecting = true;
    lastError = null;
    exitInfo = null;
    _exitFailures = 0;
    _exitNextTryAt = null;
    notifyListeners();
    // Build 2088: set when the attempt's watchdog has been
    // settled on the success path; the finally below disarms
    // it on every other exit.
    var attemptSettled = false;
    try {
      // One tunnel at a time: the other engines go off first.
      await stopOtherEngine?.call();
      if (state.running) await disconnect();
      // Build 2095 (audit 2.1): the generation is captured
      // AFTER the prologue's own disconnect() call (which
      // bumps it) — from here on, a user disconnect cancels
      // this attempt.
      final gen = _connectGen;
      void checkAlive() {
        if (gen != _connectGen) {
          throw const _PsiphonConnectCancelled();
        }
      }

      // Build 2065: the strategy ladder. Pinned methods with a
      // missing prerequisite fail BEFORE starting anything, with
      // the reason in plain words — a ladder that silently drops
      // the user's picked method would be a dead choice.
      final method = settings.method;
      if (method == 'E') {
        await _refreshEdgesIfStale();
        checkAlive();
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
        checkAlive();
      }
      final edges = _edgesForCore();
      final rungs = psiphonRungOrder(
        method: method,
        lastWinner: settings.winnerFor(settings.networkKey),
        hasEdges: edges.akamai.isNotEmpty || edges.fastly.isNotEmpty,
        hasPairing: settings.compartmentId.isNotEmpty,
        hasUpstream: settings.upstream.trim().isNotEmpty,
        bridgeMode: settings.bridgeMode,
      );
      checkAlive();
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
        // Build 2125 (A25-04 / S-4): standalone sessions
        // only — a chain underlay's start passes
        // vpnMode=false and the service never holds those.
        killSwitch: settings.vpnMode && killSwitchEnabled(),
        // Build 2129 (Leg 2): the Shiro bootstrap + strong
        // mode, from settings (both default OFF).
        shiroBootstrap: settings.shiroBootstrap,
        strongMode: settings.strongMode,
      );
      // Build 2088: the external watchdog's deadline starts
      // with the attempt (its decision is fed by the samples
      // below; see _maybeFireWatchdog).
      _watchdog.arm(nowForWatchdog());
      // The service reports itself once the core is up; a tunnel to a
      // Psiphon server can take a while longer (state.connected).
      for (var i = 0; i < 40; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        checkAlive();
        state = await PsiphonPlatform.state();
        // Build 2087 (diagnosis F1/F3): a wedged start publishes
        // its failure and exits its process — fail here, at
        // once, never after the long waits below.
        if (state.wedged) throw StateError('start-wedged');
        await _maybeFireWatchdog();
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
      // dead core.
      //
      // Build 2091: the same bar now applies to proxy-only mode
      // (the MLM transplant's contract change, analysis §9.2/R12):
      // the AAR core's onConnected is the only success signal in
      // either mode, and the 2089/2090 sidecar's success-at-running
      // contract is closed. The old reason for the lower bar — "no
      // TUN to blackhole" — never held for the chain: Xray dials
      // the SOCKS and a running-but-not-connected core fails every
      // dial while the UI claims a session. The 90 s Xray underlay
      // wait and this 300 s ladder wait both read the same
      // published connected flag.
      var connected = false;
      // Build 2065: the ladder's worst case is the sum of its
      // rung budgets (region phase 25 s + A 60 + E 45 + D 45 +
      // C 75 = 250 s); wait past it (300 s) instead of the old
      // single-attempt 110 s. A service that gives up stops
      // running, which breaks the wait early either way.
      for (var i = 0; i < 1200; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        checkAlive();
        state = await PsiphonPlatform.state();
        if (state.connected) {
          connected = true;
          break;
        }
        // Build 2087: the wedge signal ends the wait the
        // moment it is published (~15 s into the attempt),
        // not at this loop's 300 s bound.
        if (state.wedged) throw StateError('start-wedged');
        // Build 2088: the external watchdog's tick — at
        // its deadline a start still inside the library is
        // recorded and killed from the main process, and
        // the wedge it publishes ends this wait above.
        await _maybeFireWatchdog();
        if (!state.running) break;
      }
      if (!connected) {
        // Build 2090: the timeout carries its evidence —
        // the service's session log carries the core's own
        // notices directly now (build 2091: the AAR core's
        // onDiagnosticMessage writes into psiphon.log; the
        // sidecar's appendBoxEvidence is retired with the
        // sidecar), so the error surface shows the core's
        // last words instead of the bare 'connect-timeout'
        // of 2089, whose pasted logs were two content-free
        // lines.
        final dir = await workDir();
        final sessionTail =
            await _tailLines(File('${dir.path}/psiphon.log'), 15);
        await disconnect();
        throw StateError(
          sessionTail.isEmpty
              ? 'connect-timeout'
              : 'connect-timeout — the Psiphon log tail:\n$sessionTail',
        );
      }
      // Build 2088: the attempt resolved — settle its
      // watchdog (disarm, or hand the deadline to the tail
      // timer when a proxy-only start call is still inside
      // the library).
      _settleWatchdog();
      attemptSettled = true;
      // Build 2065: winner memory — the rung the service reports
      // is remembered for this network and tried first next time.
      await _recordWinner(state.method);
      _lastSample = state;
      _lastSampleAt = DateTime.now();
      _startPolling();
    } catch (e) {
      // Build 2095 (audit 2.1): a user-cancelled attempt
      // unwinds quietly.
      if (e is _PsiphonConnectCancelled) {
        lastError = null;
        return;
      }
      // Build 2087: the wedge's code becomes a plain sentence
      // on the error surface — the raw "Bad state" form of it
      // would tell the owner nothing.
      lastError =
          e is StateError && e.message == 'start-wedged'
              ? 'Psiphon got stuck while starting and its process '
                  'was restarted. Tap Connect to try again.'
              : e.toString();
      rethrow;
    } finally {
      // Build 2088: a failed attempt leaves no deadline
      // ticking behind it.
      if (!attemptSettled) {
        _watchdog.disarm();
        _cancelWatchdogTail();
      }
      connecting = false;
      notifyListeners();
    }
  }

  /// Build 2088: feeds the current sample to the external
  /// watchdog's decision; on its firing, invokes the native
  /// firing (record + kill + publish) and re-reads the
  /// state, so the caller's next check sees the published
  /// wedge in the same iteration.
  Future<void> _maybeFireWatchdog() async {
    if (_watchdog.evaluate(
      now: nowForWatchdog(),
      running: state.running,
      connected: state.connected,
      wedged: state.wedged,
      startReturned: state.startReturned,
    )) {
      await PsiphonPlatform.externalWatchdog();
      state = await PsiphonPlatform.state();
      return;
    }
    // Build 2090: the record-only establishment branch —
    // a start that spawned fine and never tunnels gets
    // its evidence into crash.log while the attempt is
    // still running (see psiphon_watchdog.dart).
    await _maybeDumpEstablishmentEvidence();
  }

  /// Build 2090: on the watchdog's establishment decision,
  /// appends the core's own log tail to crash.log.
  /// Record-only: no kill, no state change — the service's
  /// deadlines own the teardown; this only makes sure a
  /// stalled establishment leaves the core's own words
  /// behind even if the session log is never pasted.
  /// Build 2091: the evidence source is psiphon.log itself
  /// (the AAR core's notices land there directly; the
  /// sidecar's psiphonbox logs are retired with the sidecar).
  Future<void> _maybeDumpEstablishmentEvidence() async {
    if (!_watchdog.evaluateEstablishment(
      now: nowForWatchdog(),
      running: state.running,
      connected: state.connected,
      wedged: state.wedged,
      startReturned: state.startReturned,
    )) {
      return;
    }
    try {
      final dir = await workDir();
      final sessionTail =
          await _tailLines(File('${dir.path}/psiphon.log'), 20);
      final buf = StringBuffer()
        ..writeln(
          '==== psiphon establishment evidence '
          '(${DateTime.now().toIso8601String()}) ====',
        )
        ..writeln(
          'running past ${PsiphonWatchdog.establishmentEvidenceBound.inSeconds}s '
          'with no tunnel; the session log tail follows.',
        );
      if (sessionTail.isNotEmpty) {
        buf.writeln('—— psiphon.log ——');
        buf.writeln(sessionTail);
      } else {
        buf.writeln('(the session log wrote nothing)');
      }
      await File('${dir.parent.path}/crash.log').writeAsString(
        buf.toString(),
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {
      // Evidence only; a failed dump changes nothing.
    }
  }

  /// The last [count] non-empty lines of [file] (bounded
  /// read: the last 64 KB), or '' when there is nothing.
  Future<String> _tailLines(File file, int count) async {
    try {
      if (!await file.exists()) return '';
      final bytes = await file.readAsBytes();
      final tail = bytes.length > 64 * 1024
          ? bytes.sublist(bytes.length - 64 * 1024)
          : bytes;
      final lines = utf8
          .decode(tail, allowMalformed: true)
          .split('\n')
          .map((l) => l.trimRight())
          .where((l) => l.isNotEmpty)
          .toList();
      return lines.length <= count
          ? lines.join('\n')
          : lines.sublist(lines.length - count).join('\n');
    } catch (_) {
      return '';
    }
  }

  /// Build 2088: settles a resolved attempt's watchdog.
  /// Connected — or a start call that has returned — disarms
  /// it outright. A proxy-only attempt whose start call is
  /// still inside the library keeps its deadline on the
  /// tail timer: connect() returns at "running" there, and
  /// the wedge frontier is the start call, not the wait
  /// for a tunnel that proxy-only mode never raises.
  void _settleWatchdog() {
    _cancelWatchdogTail();
    if (!_watchdog.armed) return;
    if (state.connected || state.startReturned) {
      _watchdog.disarm();
      return;
    }
    final armedAt = _watchdog.armedAt;
    if (armedAt == null) return;
    var remaining =
        PsiphonWatchdog.deadline - nowForWatchdog().difference(armedAt);
    if (remaining.isNegative) remaining = Duration.zero;
    _watchdogTail = Timer(remaining, () async {
      if (!_watchdog.armed) return;
      state = await PsiphonPlatform.state();
      await _maybeFireWatchdog();
      _watchdog.disarm();
      notifyListeners();
    });
  }

  void _cancelWatchdogTail() {
    _watchdogTail?.cancel();
    _watchdogTail = null;
  }

  Future<void> disconnect() async {
    // Build 2095 (audit 2.1): cancel any in-flight connect.
    _connectGen++;
    // Build 2088: a user stop ends any ticking deadline —
    // the attempt it belonged to is over by his hand.
    _watchdog.disarm();
    _cancelWatchdogTail();
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
    _watchdogTail?.cancel();
    super.dispose();
  }

  // ---- logs ----------------------------------------------------------------

  /// The tails of the Psiphon logs, newest content last.
  /// psiphon.log is the session log (the core's own notices
  /// land there directly in the AAR era, as they did in
  /// builds 2066–2088 — the badvpn bridge logs into it too).
  /// crash.log (build 2068) is the native crash recorder's file:
  /// every uncaught native death and every guarded start
  /// refusal, with its full stack — the evidence the 2066/2067
  /// tap-crash never left behind.
  /// Build 2091: the 2089/2090 sections are gone — tunlink.log
  /// (the libtunlink subprocess bridge) and the psiphonbox
  /// logs (the sidecar) are retired with the sidecar; the
  /// badvpn bridge of the MLM transplant logs into
  /// psiphon.log, as in the AAR era.
  Future<String> readLogs() async {
    final dir = await workDir();
    final out = StringBuffer();
    final sections = <(String, File)>[
      ('psiphon.log', File('${dir.path}/psiphon.log')),
      // crash.log lives in filesDir itself (the recorder's
      // home), one level above this engine's workDir.
      ('crash.log', File('${dir.parent.path}/crash.log')),
    ];
    for (final (name, file) in sections) {
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
    // Build 2091: tunlink.log is gone with the sidecar —
    // the bridge logs into psiphon.log now.
    for (final name in ['psiphon.log']) {
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
