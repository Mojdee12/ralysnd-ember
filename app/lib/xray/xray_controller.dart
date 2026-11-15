/// The V2Ray engine's brain: the user's profiles and subscriptions,
/// their persistence, and the tunnel's on/off state — everything the
/// Ember UI binds to.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../atomic_json_store.dart';
import '../core/android_core.dart';
import '../core/poll_policy.dart';
import '../psiphon/psiphon_platform.dart';
import 'awg_uapi.dart';
import 'config_builder.dart';
import 'diagnostics.dart';
import 'dnstt_args.dart';
import 'dnstt_platform.dart';
import 'exit_info.dart';
import 'fallback_groups.dart';
import 'lantern_import.dart';
import 'link_parser.dart';
import 'profile_codec.dart';
import 'reconnect_policy.dart';
import 'sandbox_test.dart';
import 'scan_probes.dart';
import 'shape_cache.dart';
import 'shapes.dart';
import 'sub_fetcher.dart';
import 'warp_args.dart';
import 'warp_platform.dart';
import 'wg_conf.dart';
import 'wstunnel_args.dart';
import 'wstunnel_platform.dart';
import 'xray_models.dart';
import 'xray_platform.dart';

/// The adaptive-failover probe interval in 2 s poll ticks (build
/// 2057, audit B-M2): the probe asks the tunnel for one real
/// proxied request, so probing an idle tunnel every ~16 s keeps
/// the modem warm for nothing. After consecutive successes on
/// an idle tunnel the interval stretches — 60 s after 3, 120 s
/// after 10 — and any traffic (or any failure) resets it to the
/// base 16 s, so failover latency on a USED tunnel is unchanged.
/// Pure, so the schedule is unit-testable without a tunnel.
int adaptiveProbeEveryTicks({
  required int successStreak,
  required bool trafficActive,
}) {
  if (trafficActive) return 8;
  if (successStreak >= 10) return 60;
  if (successStreak >= 3) return 30;
  return 8;
}

class XrayController extends ChangeNotifier {
  List<Profile> profiles = [];
  List<Subscription> subscriptions = [];
  XraySettings settings = XraySettings();

  /// LAN sharing (build 2062, feature queue #2): the SOCKS
  /// credentials the app's own probes present to the live
  /// tunnel — the stored user/pass only when sharing auth is
  /// ready, '' otherwise (noauth). A warp session's port
  /// belongs to a core with no auth, so its call sites pass
  /// '' explicitly instead of these.
  String get _lanUser =>
      settings.lanShareAuthReady ? settings.lanShareUser : '';
  String get _lanPass =>
      settings.lanShareAuthReady ? settings.lanSharePass : '';

  /// The subscription fetch this controller runs (build 2050,
  /// audit F-M20): the real fetcher in the app; tests inject a
  /// fake to drive the add/refresh flows without a network.
  SubscriptionFetcher subscriptionFetcher = fetchSubscription;

  /// The EmberWarp connection profile (build 2030): one WARP
  /// profile for the whole app — the standalone card and the
  /// Warp underlay both run it.
  WarpProfile warpProfile = WarpProfile();

  /// The EmberWarp core's last known state (build 2030),
  /// refreshed by [refreshWarpState] and the session flows.
  WarpCoreState warpState = const WarpCoreState();

  /// True while a standalone WARP session is the live tunnel
  /// (the Xray service runs in warp mode: no Xray process, the
  /// tunlink bridge feeds the warp core's SOCKS directly).
  bool warpSession = false;

  /// True while an AmneziaWG session is the live tunnel (build
  /// 2040, queue 2h): the Xray service runs in AWG mode — no
  /// Xray process, no SOCKS port — and the userspace device in
  /// libwg-go.so carries the traffic with the obfuscation the
  /// profile carried. Refreshed by [refreshState] from the
  /// service's own flag, like [warpSession].
  bool awgSession = false;

  /// The device's last reported transfer counters (build 2040):
  /// per-config accounting for AWG sessions reads these
  /// deltas, since there is no Xray stats API to ask. -1 =
  /// no AWG sample yet this session.
  int _lastAwgRx = -1;
  int _lastAwgTx = -1;

  /// The session name a standalone WARP tunnel reports under.
  // Build 2071 (review §1.5): the EmberWarp session's name —
  // 'EmberWarp', not 'WARP': the shell's standalone Aether
  // engine (cfwarp slot) is the app's 'WARP', and the two
  // engines sharing one label made sessions, notifications and
  // settings name the wrong core.
  static const warpSessionName = 'EmberWarp';
  String selectedProfileId = '';

  XrayState state = XrayState.stopped;
  bool connecting = false;
  int upRate = 0;
  int downRate = 0;

  /// The store's complaint, when it has one (build 2071,
  /// review §5.4): set when a save fails or the saved file
  /// was damaged at load, cleared by the next successful
  /// save. [lastError] reports it whenever no fresher
  /// connect error exists, so a failing disk is visible
  /// instead of every change being lost silently, forever.
  String? storeError;

  String? _lastError;

  /// The last connect error — or, while there is none, the
  /// store's complaint ([storeError]).
  String? get lastError => _lastError ?? storeError;
  set lastError(String? v) => _lastError = v;

  /// The running tunnel's exit IP/country, looked up best-effort
  /// through the tunnel once it is up; null while unknown, after a
  /// failed lookup, and whenever the tunnel is down.
  ExitInfo? exitInfo;
  bool _exitFetching = false;

  /// Set by the shell: stops the Mozilla engine so only one tunnel is
  /// ever up. Returns when that engine is off.
  Future<void> Function()? stopOtherEngine;

  bool _loaded = false;
  bool get loaded => _loaded;

  Timer? _poll;
  XrayState? _lastSample;
  DateTime? _lastSampleAt;
  final Set<String> _testing = {};

  // ---- Test All funnel (build 2026, Stage A) -------------------

  /// True while a Test All funnel run is going.
  bool scanRunning = false;

  /// The funnel stage in progress: 'tcp', 'tls' or 'real'
  /// ('' when idle). The servers page renders it as progress.
  String scanPhase = '';
  int scanDone = 0;
  int scanTotal = 0;

  /// Stage-3 results that answered, so far.
  int scanAlive = 0;
  bool _scanCancel = false;

  // ---- Adaptive failover (build 2026, Stage A) -----------------

  /// The last adaptive switch (or give-up), shown on the V2Ray
  /// home card. Empty when nothing has happened this session.
  String adaptiveNotice = '';

  /// The last seamless server switch, shown on the V2Ray home
  /// card next to [adaptiveNotice]. Empty when nothing has
  /// switched this session. (Build 2039, queue 2g.)
  String switchNotice = '';

  /// The profile a seamless switch is moving to right now
  /// (null when idle): the servers page shows its row busy.
  /// (Build 2039, queue 2g.)
  String? switchingProfileId;

  bool _switchBusy = false;

  /// Bumped by [disconnect] and at the start of
  /// [_connectSelected]: a switch in flight must not fall back
  /// to a full connect after the user (or a new connect)
  /// superseded it. (Build 2039.)
  int _tunnelGen = 0;

  /// Bumped when the exit line is invalidated by a switch, so a
  /// lookup started before the switch cannot land stale exit
  /// data afterwards. (Build 2039.)
  int _exitGen = 0;

  /// App-foreground state for the poll cadence (build 2050,
  /// audit §3): the shell forwards lifecycle changes here, and
  /// the session poller runs its live 2 s cadence only while
  /// foregrounded — a 30 s heartbeat otherwise.
  bool _foreground = true;

  /// Exit-lookup failure backoff (build 2050, audit B-H3):
  /// consecutive failures and the earliest next attempt.
  int _exitFailures = 0;
  DateTime? _exitNextTryAt;

  /// The session start the exit backoff belongs to: a new
  /// session (a different state.sinceMs) resets the schedule.
  int _exitSessionStart = -1;

  /// Stats-save debounce (build 2050, audit B-M1): totals are
  /// attributed in memory every read, but the whole-store write
  /// happens at most every 30 s (and at session end), not on
  /// every 2 s poll that saw traffic.
  int _lastStatsSaveMs = 0;
  bool _statsSavePending = false;

  int _adaptiveFails = 0;
  int _adaptiveSwitches = 0;
  bool _adaptiveBusy = false;

  /// The failover probe's stretch state (build 2057, audit
  /// B-M2): consecutive successful probes on an idle tunnel,
  /// the current interval in ticks, and ticks since the last
  /// probe. Reset on traffic, failure, or a new manual session.
  int _adaptiveProbeStreak = 0;
  int _adaptiveProbeEveryTicks = 8;
  int _adaptiveProbeTicks = 0;

  // ---- Auto-reconnect (build 2042) -----------------------------

  /// The last reconnect wait or give-up, shown on the home card.
  /// Empty when nothing is pending and nothing gave up.
  String reconnectNotice = '';

  /// True while a session is up that nobody disconnected: the
  /// poll's "tunnel down" then means an unexpected drop, not a
  /// manual stop, and the auto-reconnect may fire. Set when a
  /// connect succeeds (or when a live session is re-read at
  /// startup); cleared by [disconnect] and when the policy
  /// gives up. A manual disconnect therefore never resurrects
  /// — the flag, not the setting, decides that.
  bool _expectRunning = false;

  /// Which engine the live session runs on, so a retry re-enters
  /// through the same entry point the user connected with:
  /// 'xray' (V2Ray profiles, including plain WireGuard through
  /// the core), 'warp' (standalone WARP), 'wireguard' (the WG
  /// fallback path, including AmneziaWG).
  String _reconnectKind = 'xray';

  /// The profile the dropped session ran on ('' for standalone
  /// WARP, which has no profile): the retry reconnects it, not
  /// whatever happens to be selected now.
  String _reconnectProfileId = '';

  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  int _reconnectCountdown = 0;

  /// Profile attempts the most recent [_connectWithFallbackGroup]
  /// call consumed — 1 plus the fallback-group members it tried
  /// (build 2057, audit F-M3): a retry's connect walks the
  /// group, so the episode budget counts every member tried, not
  /// just the one the UI counted. Reset to 1 at the start of
  /// every [_attemptReconnect], so a WARP retry (no group walk)
  /// charges exactly one attempt.

  int _lastConnectTries = 1;

  /// Fallback groups (build 2035): when each profile last failed
  /// a fallback attempt. A member that failed is skipped for
  /// [fallbackCooldown] so the group does not flap straight back
  /// onto the config that just died. In-memory only: a process
  /// restart clears the cooldowns, and a member that recovered
  /// meanwhile rejoins the group on its own.
  final Map<String, DateTime> _fallbackFailedAt = {};

  /// Build 2060: the in-memory cooldowns are hydrated from the
  /// persisted [XraySettings.fallbackFailedAtMs] — merged on every
  /// use, not just once, so a settings reload after construction
  /// still lands. Expired entries are pruned from the persisted
  /// map (and saved) instead of being resurrected.
  void _hydrateCooldowns() {
    final now = DateTime.now();
    var changed = false;
    for (final e in settings.fallbackFailedAtMs.entries) {
      final at = DateTime.fromMillisecondsSinceEpoch(e.value);
      if (now.difference(at) >= fallbackCooldown) {
        changed = true;
        continue;
      }
      _fallbackFailedAt.putIfAbsent(e.key, () => at);
    }
    if (changed) {
      settings.fallbackFailedAtMs.removeWhere(
        (id, ms) =>
            now.difference(DateTime.fromMillisecondsSinceEpoch(ms)) >=
            fallbackCooldown,
      );
      unawaited(save());
    }
  }

  /// True while [profileId]'s last fallback failure is still
  /// inside the cooldown window.
  bool isCoolingDown(String profileId) {
    _hydrateCooldowns();
    final at = _fallbackFailedAt[profileId];
    if (at == null) return false;
    if (DateTime.now().difference(at) >= fallbackCooldown) {
      _fallbackFailedAt.remove(profileId);
      settings.fallbackFailedAtMs.remove(profileId);
      return false;
    }
    return true;
  }

  /// The ids currently inside their cooldown window (expired
  /// entries are dropped as a side effect).
  Set<String> get _coolingDownIds {
    _hydrateCooldowns();
    final now = DateTime.now();
    _fallbackFailedAt.removeWhere(
      (id, at) => now.difference(at) >= fallbackCooldown,
    );
    settings.fallbackFailedAtMs.removeWhere(
      (id, ms) =>
          now.difference(DateTime.fromMillisecondsSinceEpoch(ms)) >=
          fallbackCooldown,
    );
    return _fallbackFailedAt.keys.toSet();
  }

  /// Records a fallback failure for [profileId] (the clock
  /// starts now) and notifies listeners so the servers page's
  /// fallback card shows the cooldown at once.
  void markFallbackFailed(String profileId) {
    _hydrateCooldowns();
    final now = DateTime.now();
    _fallbackFailedAt[profileId] = now;
    // Build 2060: the cooldown survives a restart — the epoch
    // goes into the persisted settings alongside the memory map.
    settings.fallbackFailedAtMs[profileId] = now.millisecondsSinceEpoch;
    unawaited(save());
    notifyListeners();
  }

  /// The members of [p]'s fallback group, in failover order
  /// (see fallback_groups.dart).
  List<Profile> fallbackGroupMembers(Profile p) =>
      fallbackGroupMembersOf(profiles, p);

  /// Ordered failover candidates for [p]: its group first, then
  /// the rest of the list. Used by the failover watcher and by
  /// the connect-time fallback in [connect].
  List<Profile> fallbackCandidates(Profile p) =>
      fallbackOrder(all: profiles, current: p, coolingDownIds: _coolingDownIds);

  /// Cloudflare edge IPs the in-app scanner found answering on
  /// this network; they are probed first on the next scan.
  List<String> cfGoodIps = [];

  // ---- Diagnostics, shapes, chain (build 2029A) --------------

  /// The diagnostics journal: the guided check's stages and
  /// every later feature's steps (watchdog, chain, connect
  /// fast-paths) land here in plain language.
  final DiagnosticsJournal diagnostics = DiagnosticsJournal();

  /// Winning shapes per (profile, network) — see shape_cache.
  WinningShapeCache shapeCache = WinningShapeCache();

  /// This network's fingerprint ('' = unknown: the cache does
  /// not engage and nothing is keyed on a guess).
  String networkFp = '';

  /// The guided check's latest stages, for the home card.
  List<CheckStage> lastCheck = [];
  bool checking = false;

  /// The ChainSupervisor's last word, mirrored for the home
  /// card (the native state carries it; this keeps it visible
  /// after the session ends too).
  String chainNotice = '';
  String _lastChainProblem = '';

  /// Build 2050 (audit C-1): when an AmneziaWG profile ends up
  /// running as PLAIN WireGuard because the obfuscated engine
  /// could not start or its peer never answered, this says so —
  /// the session must never silently present itself as
  /// obfuscated when it is not. Set by
  /// [connectWireGuardWithFallback], cleared on disconnect and
  /// on a real AmneziaWG start.
  String awgFallbackNotice = '';

  /// Set by the shell: the Psiphon engine's current settings,
  /// which a chained session starts its underlay with.
  ({String region, String upstream, List<String> protocols}) Function()?
  underlayParams;

  // Watchdog shape escalation state (build 2029A).
  String _wdShape = shapeStock;
  int? _wdBaseUp;
  int? _wdBaseDown;
  int _wdStallSinceMs = 0;
  int _wdProbeFails = 0;
  bool _wdBusy = false;

  /// The profile the running tunnel was started with: the core's
  /// traffic deltas are attributed to it. Set by [connect]; when the
  /// service outlived the page it falls back to the persisted
  /// selection (the only profile connect() ever starts).
  String _connectedProfileId = '';

  /// The local wstunnel forward port of the live session
  /// (build 2072): 0 unless this session's WireGuard profile
  /// runs over WebSocket. Config rotations must keep pointing
  /// the peer at the forwarder, so the value lives for the
  /// session's life and clears in _stopTunnel.
  int _sessionWgWstunnelPort = 0;
  bool _statsBusy = false;

  bool isTesting(String id) => _testing.contains(id);

  Profile? get selected {
    for (final p in profiles) {
      if (p.id == selectedProfileId) return p;
    }
    return profiles.isEmpty ? null : profiles.first;
  }

  Subscription? subscriptionOf(Profile p) {
    for (final s in subscriptions) {
      if (s.id == p.subscriptionId) return s;
    }
    return null;
  }

  List<Profile> profilesOf(Subscription s) =>
      profiles.where((p) => p.subscriptionId == s.id).toList();

  List<Profile> get looseProfiles =>
      profiles.where((p) => p.subscriptionId.isEmpty).toList();

  // ---- persistence ----------------------------------------------------

  Future<File> _stateFile() async {
    final coreDir = await AndroidCore.dataDir();
    final filesDir = File(coreDir).parent;
    return File('${filesDir.path}/xray/state.json');
  }

  Future<Directory> workDir() async {
    final coreDir = await AndroidCore.dataDir();
    return Directory('${File(coreDir).parent.path}/xray');
  }

  Future<void> load() async {
    try {
      final file = await _stateFile();
      if (await file.exists()) {
        // Build 2071 (review §5.4): the document decode gets
        // its own try — a file that is there but unreadable
        // as a document is damage, not a first run, and the
        // error surface says so (the store still starts
        // empty, exactly as before).
        Map<String, dynamic>? decoded;
        try {
          decoded =
              jsonDecode(await file.readAsString())
                  as Map<String, dynamic>;
        } catch (_) {
          storeError =
              'The saved data was damaged and could not be '
              'read, so this section started fresh.';
        }
        if (decoded != null) {
          final doc = decoded;
          // Per-entry decode (build 2033): one damaged profile
          // or subscription entry is skipped on its own — it
          // must never take the whole store down with it. (The
          // pre-2033 single map() lost EVERY profile, WireGuard
          // ones included, when any one entry failed to decode:
          // a "sometimes no servers load" failure that depended
          // entirely on which entry was damaged.)
          profiles = _decodeList(doc['profiles'], (j) => Profile.fromJson(j));
          subscriptions = _decodeList(
            doc['subscriptions'],
            (j) => Subscription.fromJson(j),
          );
          if (doc['settings'] is Map) {
            settings = XraySettings.fromJson(
              (doc['settings'] as Map).cast<String, dynamic>(),
            );
          }
          selectedProfileId = doc['selectedProfileId'] as String? ?? '';
          if (doc['warpProfile'] is Map) {
            warpProfile = WarpProfile.fromJson(
              (doc['warpProfile'] as Map).cast<String, dynamic>(),
            );
          }
          cfGoodIps = ((doc['cfGoodIps'] as List?) ?? [])
              .map((e) => e.toString())
              .toList();
          // Corrupt entries are dropped by the reader itself —
          // a damaged cache must never take the tab down with it
          // (the device-state rule).
          shapeCache = WinningShapeCache.fromJson(doc['shapeCache']);
        }
      }
    } catch (_) {
      // A damaged store starts empty rather than crashing the tab.
    }
    // Build 2070 (review §4 row 7): the one-time fingerprint
    // migration — clear the 'chrome' the old link parser
    // manufactured on stored VLESS tls/reality profiles, so the
    // shipped uTLS rotation can finally apply to them (scope and
    // the honest edge: clearParserDefaultFingerprints). Runs
    // over whatever the store yielded — a fresh or damaged store
    // simply has nothing to clear — and the result is persisted
    // immediately below, so the flag and the cleared profiles
    // land in one write and a 'chrome' the owner sets later is
    // never re-cleared.
    var fingerprintMigrated = false;
    if (!settings.fingerprintDefaultMigrated) {
      clearParserDefaultFingerprints(profiles);
      settings.fingerprintDefaultMigrated = true;
      fingerprintMigrated = true;
    }
    _loaded = true;
    if (fingerprintMigrated) await _save();
    // Publish the decoded store immediately (build 2033,
    // WireGuard audit): the geo install and platform probes
    // below can take seconds, and pages must not sit on a
    // false "empty" state for that whole window.
    notifyListeners();
    _wireDiagnosticsSink();
    unawaited(refreshNetworkFingerprint());
    await _installGeoFiles();
    await refreshState();
    // EmberWarp housekeeping (build 2030): finish any renewal
    // settle an interrupted run left staged, and learn the
    // core's state for the card.
    unawaited(WarpPlatform.settle());
    unawaited(refreshWarpState());
    notifyListeners();
    if (settings.subUpdateOnLaunch) unawaited(_autoUpdateStale());
  }

  /// Mirrors the diagnostics journal to diagnostics.log in the
  /// workdir, so the record survives the page and the process;
  /// the file is rotated by deletion past half a megabyte.
  Future<void> _wireDiagnosticsSink() async {
    try {
      final dir = await workDir();
      await dir.create(recursive: true);
      final file = File('${dir.path}/diagnostics.log');
      if (await file.exists() && await file.length() > 512 * 1024) {
        await file.delete();
      }
      diagnostics.sink = (line) {
        try {
          file.writeAsStringSync('$line\n', mode: FileMode.append);
        } catch (_) {
          // Evidence, never a failure.
        }
      };
    } catch (_) {
      // The journal still works in memory.
    }
  }

  /// Refreshes [networkFp] from the platform. Best-effort: an
  /// answer of '' simply means the shape cache sits this
  /// network out.
  Future<void> refreshNetworkFingerprint() async {
    networkFp = networkFingerprintOf(await XrayPlatform.networkFingerprint());
  }

  /// The geo data files' exact asset lengths in the APK
  /// (build 2054, audit F-M19): a kill mid-write used to
  /// leave a truncated file that still passed the old
  /// "> 1 MB" check forever, so geo presets failed with no
  /// self-heal. Update these when the geo assets change —
  /// they are the lengths of the assets bundled in this APK.
  static const _geoExpectedBytes = {
    'geoip.dat': 16549675,
    'geosite.dat': 11309380,
  };

  /// The routing presets name geoip:/geosite: categories, so the core
  /// needs its data files beside the config it runs from.
  Future<void> _installGeoFiles() async {
    try {
      final dir = await workDir();
      await dir.create(recursive: true);
      for (final entry in _geoExpectedBytes.entries) {
        final target = File('${dir.path}/${entry.key}');
        if (await target.exists() && await target.length() == entry.value) {
          continue;
        }
        final data = await rootBundle.load('assets/geo/${entry.key}');
        // tmp + flush + rename: a kill mid-write leaves the
        // previous file (or nothing), never a torn one that
        // passes the length check.
        await AtomicJsonStore.writeBytes(target, data.buffer.asUint8List());
      }
    } catch (_) {
      // Without them only the geo presets fail, and the core says so.
    }
  }

  /// Decodes a stored JSON list entry by entry: an element
  /// that is not a map, or whose decoder throws, is skipped
  /// instead of failing the whole list (build 2033).
  static List<T> _decodeList<T>(
    dynamic raw,
    T Function(Map<String, dynamic>) decode,
  ) {
    final out = <T>[];
    if (raw is List) {
      for (final e in raw) {
        if (e is! Map) continue;
        try {
          out.add(decode(e.cast<String, dynamic>()));
        } catch (_) {
          // One damaged entry is dropped, never the store.
        }
      }
    }
    return out;
  }

  /// Saves are serialized through this chain and land
  /// atomically (build 2033): the store is written to a
  /// sibling temp file and renamed over state.json, so a
  /// reader can never meet a half-written document, and two
  /// saves fired in the same moment (a delay test finishing
  /// while a stats read saves, an import landing during a
  /// subscription refresh) queue instead of interleaving
  /// bytes into a torn file — the pre-2033 store's
  /// "sometimes nothing loads on the next start" failure.
  Future<void> _saveChain = Future<void>.value();

  Future<void> _save() {
    _saveChain = _saveChain.then((_) => _writeStore());
    return _saveChain;
  }

  Future<void> _writeStore() async {
    // Never persist before the store has loaded (build 2033,
    // WireGuard audit): during startup the in-memory lists are
    // still empty, and a save fired that early would overwrite
    // the on-disk store with nothing. The write is whole-state,
    // so skipping it loses nothing — the next save carries
    // everything.
    if (!_loaded) return;
    try {
      final file = await _stateFile();
      await file.parent.create(recursive: true);
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(
        jsonEncode({
          'profiles': profiles.map((p) => p.toJson()).toList(),
          'subscriptions': subscriptions.map((s) => s.toJson()).toList(),
          'settings': settings.toJson(),
          'warpProfile': warpProfile.toJson(),
          'selectedProfileId': selectedProfileId,
          'cfGoodIps': cfGoodIps,
          'shapeCache': shapeCache.toJson(),
        }),
        flush: true,
      );
      await tmp.rename(file.path);
      // Build 2071 (review §5.4): a save that lands clears
      // a save-failure complaint. A damaged-at-load
      // complaint is NOT cleared here — it clears on the
      // next clean load, so the notice survives the session
      // that started fresh (the fingerprint migration's
      // save right after a damaged load must not erase it
      // before anyone saw it).
      if (storeError == storeSaveFailedMessage) {
        storeError = null;
        notifyListeners();
      }
    } catch (_) {
      // Persistence failure must not take the UI down — but
      // since build 2071 it is surfaced, not just swallowed:
      // the error surface keeps saying the store is failing
      // until a save succeeds again.
      if (storeError != storeSaveFailedMessage) {
        storeError = storeSaveFailedMessage;
        notifyListeners();
      }
    }
  }

  Future<void> save() => _save();

  /// Rebuilds UI listening to this controller (the settings
  /// page's conditional rows, build 2042): save() alone does
  /// not notify, and a settings toggle that shows or hides rows
  /// needs the rebuild at once. Deliberately separate from
  /// save() — the 2 s stats poll also saves, and notifying on
  /// every one of those would rebuild listeners constantly.
  void notifySettingsChanged() => notifyListeners();

  /// Persists the CF scanner's answering edges: the newest scan
  /// leads, older finds follow, capped so the list stays a
  /// useful head start rather than an archive.
  Future<void> saveCfGoodIps(List<String> ips) async {
    final merged = <String>[...ips];
    for (final ip in cfGoodIps) {
      if (!merged.contains(ip)) merged.add(ip);
    }
    cfGoodIps = merged.take(32).toList();
    await _save();
    notifyListeners();
  }

  // ---- imports ----------------------------------------------------------

  /// Parses pasted links; returns how many were added.
  int importLinks(String text, {String subscriptionId = ''}) {
    final parsed = parseLinks(text);
    for (final p in parsed) {
      p.subscriptionId = subscriptionId;
      profiles.add(p);
      if (selectedProfileId.isEmpty) selectedProfileId = p.id;
    }
    if (parsed.isNotEmpty) unawaited(_save());
    notifyListeners();
    return parsed.length;
  }

  /// Like [importLinks], but also resolves Lantern private-server
  /// links: each one is fetched from its server manager (direct,
  /// ~15 s) and becomes an ordinary Shadowsocks profile. Returns
  /// how many profiles were added and the user-facing error of
  /// every Lantern link that failed, in order.
  Future<({int added, List<String> errors})> importLinksAsync(
    String text,
  ) async {
    final lanternLinks = <LanternPrivateServerLink>[];
    final seen = <String>{};
    final rest = <String>[];
    for (final rawLine in text.split(RegExp(r'[\r\n]'))) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      final lantern = findLanternPrivateServerLink(line);
      if (lantern != null) {
        final key = '${lantern.ip}:${lantern.port}:${lantern.token}';
        if (seen.add(key)) lanternLinks.add(lantern);
        continue;
      }
      rest.add(line);
    }

    var added = 0;
    final errors = <String>[];
    for (final link in lanternLinks) {
      try {
        final profile = await fetchLanternPrivateServerProfile(link);
        profiles.add(profile);
        if (selectedProfileId.isEmpty) selectedProfileId = profile.id;
        added++;
      } on LanternImportException catch (e) {
        errors.add(e.message);
      } catch (e) {
        errors.add('Lantern import failed: $e');
      }
    }

    final parsed = parseLinks(rest.join('\n'));
    // Build 2032 (the v2go fold-in): store-wide identity dedupe
    // on manual import — the same server (protocol + credentials
    // + endpoint) arriving again, under any name, is not added
    // twice; duplicates within the batch itself collapse too.
    final known = profiles.map(profileIdentityKey).toSet();
    var skippedDupes = 0;
    for (final p in parsed) {
      if (!known.add(profileIdentityKey(p))) {
        skippedDupes++;
        continue;
      }
      profiles.add(p);
      if (selectedProfileId.isEmpty) selectedProfileId = p.id;
      added++;
    }
    if (skippedDupes > 0) {
      errors.add(
        skippedDupes == 1
            ? '1 duplicate was skipped (already in the list)'
            : '$skippedDupes duplicates were skipped (already in the list)',
      );
    }
    if (added > 0) {
      unawaited(_save());
      notifyListeners();
    }
    return (added: added, errors: errors);
  }

  /// Removes every profile whose last delay test FAILED (build
  /// 2032, the v2go fold-in's "keep only working" cleanup).
  /// Profiles never tested are kept — untested is not dead.
  /// Returns how many were removed. The running profile is
  /// never removed.
  Future<int> keepOnlyWorking() async {
    final before = profiles.length;
    profiles.removeWhere(
      (p) =>
          p.delayFailed &&
          p.id != selectedProfileId &&
          // WireGuard profiles are managed on their own page;
          // their delay tests ride the Xray core and fail for
          // UDP-filtered endpoints, so this V2Ray-page cleanup
          // must not silently shrink the WireGuard list
          // (audit, build 2033).
          p.protocol != Protocol.wireguard,
    );
    final removed = before - profiles.length;
    if (removed > 0) {
      await _save();
      notifyListeners();
    }
    return removed;
  }

  /// The victims of a "keep only the fastest N" prune of
  /// [sub] (build 2033), computed without changing anything
  /// so the confirm dialog can state the exact count first.
  /// Policy: among the subscription's profiles that have a
  /// successful delay result, the [n] smallest delays stay;
  /// slower tested ones go, profiles whose last test FAILED
  /// go, profiles never tested STAY (untested is not slow —
  /// the same rule [keepOnlyWorking] keeps), and the
  /// selected / currently connected profile always stays.
  List<Profile> fastestPruneVictims(Subscription sub, int n) {
    final members = profilesOf(sub);
    final good = members.where((p) => p.delayMs >= 0).toList()
      ..sort((a, b) => a.delayMs.compareTo(b.delayMs));
    final keep = good.take(n < 0 ? 0 : n).map((p) => p.id).toSet();
    return members.where((p) {
      if (p.id == selectedProfileId || p.id == _connectedProfileId) {
        return false;
      }
      if (p.delayMs >= 0) return !keep.contains(p.id);
      return p.delayFailed;
    }).toList();
  }

  /// Applies the prune [fastestPruneVictims] describes.
  /// Returns how many profiles were removed.
  Future<int> keepFastestInSubscription(Subscription sub, int n) async {
    final victims = fastestPruneVictims(sub, n);
    if (victims.isEmpty) return 0;
    final ids = victims.map((p) => p.id).toSet();
    profiles.removeWhere((p) => ids.contains(p.id));
    await _save();
    notifyListeners();
    return victims.length;
  }

  /// Adds a subscription by URL and fetches it. [certPin] pins
  /// the one server certificate this subscription may trust
  /// (build 2050, audit C-3); [hwid] and [fallbackUrl] ride
  /// along to every later refresh. [customHeaders] (build
  /// 2051, F-H13 remainder) rides along too — every fetch
  /// and refresh sends them.
  Future<Subscription> addSubscription(
    String url, {
    String name = '',
    String certPin = '',
    String hwid = '',
    String fallbackUrl = '',
    Map<String, String> customHeaders = const {},
  }) async {
    final sub = Subscription(
      id: 's${DateTime.now().millisecondsSinceEpoch}',
      name: name,
      url: url,
      certPin: certPin,
      hwid: hwid,
      fallbackUrl: fallbackUrl,
      customHeaders: customHeaders,
    );
    subscriptions.add(sub);
    try {
      await updateSubscription(sub);
    } catch (_) {
      subscriptions.remove(sub);
      await _save();
      notifyListeners();
      rethrow;
    }
    return sub;
  }

  Future<void> updateSubscription(Subscription sub) async {
    final SubResult result;
    try {
      result = await subscriptionFetcher(
        sub.url,
        certPin: sub.certPin,
        hwid: sub.hwid,
        headers: sub.customHeaders,
        fallbackUrl: sub.fallbackUrl,
        hosts: settings.customDnsHosts,
      );
    } catch (e) {
      // Build 2050 (audit C-2): the real failure is journaled
      // here, once, and the typed exception propagates so the
      // call site can show its own specific words — the era of
      // every failure collapsing into "Update failed" with the
      // cause discarded is over.
      diagnostics.add(
        'subscription',
        'Fetch of ${sub.url} failed: '
            '${e is SubFetchException ? e.message : e}',
        ok: false,
      );
      rethrow;
    }
    if (result.usedFallback) {
      diagnostics.add(
        'subscription',
        'The primary URL of ${sub.name.isEmpty ? sub.url : sub.name} '
            'failed; the fallback URL served it.',
        ok: true,
      );
    }
    // Traffic totals survive the refresh: profiles are recreated with
    // fresh ids, so carry the totals over by profile identity — the
    // share link without its display name (build 2047: without a
    // user-added certificate pin either — see profileIdentityLink).
    String identityOf(Profile p) => profileIdentityLink(p);
    final prevSelected = selected;
    // Build 2057 (audit F-M21): two old profiles can share one
    // identity link (duplicates in a subscription). A single map
    // entry collapsed them, so the second lost its totals, star,
    // label and pin. Keep a queue per identity and spend one old
    // profile per new profile — each old id's carry is used at
    // most once, which is what the id-reuse guard relied on.
    final carried = <String, List<Profile>>{};
    for (final old in profiles.where((p) => p.subscriptionId == sub.id)) {
      (carried[identityOf(old)] ??= []).add(old);
    }
    profiles.removeWhere((p) => p.subscriptionId == sub.id);
    final usedIds = <String>{};
    for (final p in result.profiles) {
      p.subscriptionId = sub.id;
      Profile? old;
      final candidates = carried[identityOf(p)];
      if (candidates != null) {
        for (final candidate in candidates) {
          if (usedIds.add(candidate.id)) {
            old = candidate;
            break;
          }
        }
      }
      if (old != null) {
        p.totalDownBytes = old.totalDownBytes;
        p.totalUpBytes = old.totalUpBytes;
        p.statsUpdatedMs = old.statsUpdatedMs;
        // Build 2044: the star is the user's, not the
        // provider's — a starred subscription profile stays
        // starred after refresh (same carry as the totals).
        p.starred = old.starred;
        // Build 2045: the user's label is theirs too — a
        // renamed subscription profile keeps its label after
        // refresh (same carry as the star).
        p.localName = old.localName;
        // Build 2047: a user-added certificate pin is theirs
        // too — a pinned subscription profile keeps its pin
        // after refresh (same carry as the label).
        p.tlsCertPin = old.tlsCertPin;
        // Build 2033 (WireGuard audit): keep the OLD id and
        // the last test results for a profile that is still
        // the same server. Before this, every refresh minted
        // fresh ids — a launch-time auto-update could make
        // stored profiles (WireGuard ones included) vanish
        // from under the selection, which then silently
        // jumped elsewhere.
        p.id = old.id;
        p.delayMs = old.delayMs;
        p.delayFailed = old.delayFailed;
        p.exitIp = old.exitIp;
        p.exitCountryCode = old.exitCountryCode;
      }
      profiles.add(p);
    }
    sub
      ..uploadBytes = result.uploadBytes
      ..downloadBytes = result.downloadBytes
      ..totalBytes = result.totalBytes
      ..expireEpochSec = result.expireEpochSec
      ..lastUpdatedMs = DateTime.now().millisecondsSinceEpoch
      ..profileCount = result.profiles.length;
    if (sub.name.isEmpty && result.suggestedName != null) {
      sub.name = result.suggestedName!;
    }
    if (sub.name.isEmpty) {
      sub.name = Uri.tryParse(sub.url)?.host ?? sub.url;
    }
    if (profiles.isNotEmpty &&
        !profiles.any((p) => p.id == selectedProfileId)) {
      // Prefer a profile of the same protocol as the lost
      // selection — mode pages key off the selection's
      // protocol, and a cross-protocol jump reads as "my
      // servers did not load" (audit, build 2033).
      final sameProtocol = profiles.where(
        (p) => p.protocol == prevSelected?.protocol,
      );
      selectedProfileId =
          (sameProtocol.isNotEmpty ? sameProtocol.first : profiles.first).id;
    }
    await _save();
    notifyListeners();
  }

  Future<void> updateAllSubscriptions() async {
    for (final sub in List.of(subscriptions)) {
      try {
        await updateSubscription(sub);
      } catch (_) {
        // One bad subscription must not stop the others.
      }
    }
  }

  Future<void> _autoUpdateStale() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final periodMs = settings.subAutoUpdateHours * 3600 * 1000;
    for (final sub in List.of(subscriptions)) {
      if (!sub.autoUpdate) continue;
      if (periodMs > 0 && now - sub.lastUpdatedMs < periodMs) continue;
      try {
        await updateSubscription(sub);
      } catch (_) {
        // Silent: auto-update errors surface only on manual refresh.
      }
    }
  }

  Future<void> deleteSubscription(Subscription sub) async {
    profiles.removeWhere((p) => p.subscriptionId == sub.id);
    subscriptions.removeWhere((s) => s.id == sub.id);
    if (!profiles.any((p) => p.id == selectedProfileId)) {
      selectedProfileId = profiles.isEmpty ? '' : profiles.first.id;
    }
    await _save();
    notifyListeners();
  }

  Future<void> addProfile(Profile p) async {
    profiles.add(p);
    if (selectedProfileId.isEmpty) selectedProfileId = p.id;
    await _save();
    notifyListeners();
  }

  Future<void> updateProfile(Profile p) async {
    final i = profiles.indexWhere((e) => e.id == p.id);
    if (i >= 0) profiles[i] = p;
    await _save();
    notifyListeners();
  }

  Future<void> deleteProfile(Profile p) async {
    if (state.running && selectedProfileId == p.id) await disconnect();
    profiles.removeWhere((e) => e.id == p.id);
    if (selectedProfileId == p.id) {
      selectedProfileId = profiles.isEmpty ? '' : profiles.first.id;
    }
    await _save();
    notifyListeners();
  }

  /// The starred profiles, in list order (build 2044): the
  /// Favorites section at the top of the server list.
  List<Profile> get starredProfiles =>
      profiles.where((p) => p.starred).toList();

  /// Flips the star on one profile (build 2044) and persists it.
  /// Starring is display state only — it changes nothing about
  /// the connection, the core config or the share link.
  Future<void> toggleStarred(Profile p) async {
    p.starred = !p.starred;
    await _save();
    notifyListeners();
  }

  Future<void> duplicateProfile(Profile p) async {
    final copy = p.copy()
      ..id = newProfileId()
      // Build 2045: the copy is a new hand-added config, so it
      // takes the name the user sees (label included) as its own
      // name and is born with no label — the original keeps its.
      ..name = '${p.displayName} (2)'
      ..localName = ''
      ..subscriptionId = ''
      ..starred = false
      ..totalDownBytes = 0
      ..totalUpBytes = 0
      ..statsUpdatedMs = 0;
    profiles.add(copy);
    await _save();
    notifyListeners();
  }

  /// Zeroes one profile's cumulative traffic totals.
  Future<void> resetProfileStats(Profile p) async {
    p.totalDownBytes = 0;
    p.totalUpBytes = 0;
    p.statsUpdatedMs = 0;
    await _save();
    notifyListeners();
  }

  void select(Profile p) {
    selectedProfileId = p.id;
    unawaited(_save());
    notifyListeners();
    // Tapping another server while the tunnel is up switches to
    // it (seamlessly when the session can rotate, otherwise a
    // full reconnect); tapping the connected one only selects.
    // (Build 2039, queue 2g.)
    if (state.running &&
        !connecting &&
        _connectedProfileId.isNotEmpty &&
        p.id != _connectedProfileId) {
      unawaited(_switchOrConnect(p));
    }
  }

  void sortProfilesByDelay() {
    profiles.sort((a, b) {
      final ad = a.delayMs < 0 ? 1 << 30 : a.delayMs;
      final bd = b.delayMs < 0 ? 1 << 30 : b.delayMs;
      return ad.compareTo(bd);
    });
    unawaited(_save());
    notifyListeners();
  }

  void sortProfilesByName() {
    // Build 2045: sort by the name the user sees — their label
    // when one is set — so a renamed config sorts where it shows.
    profiles.sort((a, b) => a.displayName.compareTo(b.displayName));
    unawaited(_save());
    notifyListeners();
  }

  // ---- backup / restore -------------------------------------------------

  /// The backup document's schema version (build 2054, audit
  /// F-H9): a restore refuses a document newer than the app
  /// understands, and accepts a missing version (backups
  /// written before the key existed).
  static const backupSchemaVersion = 1;

  Future<String> exportBackup() async {
    Map<String, dynamic>? doc;
    final file = await _stateFile();
    if (await file.exists()) {
      try {
        final raw = jsonDecode(await file.readAsString());
        if (raw is Map<String, dynamic>) doc = raw;
      } catch (_) {
        // A torn store file exports from memory instead.
        doc = null;
      }
    }
    doc ??= {
      'profiles': profiles.map((p) => p.toJson()).toList(),
      'subscriptions': subscriptions.map((s) => s.toJson()).toList(),
      'settings': settings.toJson(),
      'warpProfile': warpProfile.toJson(),
      'selectedProfileId': selectedProfileId,
      'cfGoodIps': cfGoodIps,
      'shapeCache': shapeCache.toJson(),
    };
    // The schema key rides every export (build 2054): a
    // future build that changes the document shape can refuse
    // a backup it cannot read, instead of half-restoring it.
    doc['schemaVersion'] = backupSchemaVersion;
    return jsonEncode(doc);
  }

  /// Restores a backup document; returns false when it is not
  /// one. Transactional (build 2054, audit F-H9): EVERYTHING
  /// is decoded into locals first — profiles and subscriptions
  /// per-entry (one damaged entry is skipped, never fatal),
  /// settings, warp profile, CF IPs and shape cache — and only
  /// when all of it validates does the live state swap, the
  /// tunnel disconnect (a malformed backup must never kill a
  /// live tunnel before failing), and one save persist the
  /// result. A failure anywhere before the swap leaves the
  /// in-memory AND on-disk state exactly as it was.
  Future<bool> importBackup(String text) async {
    Map<String, dynamic> doc;
    try {
      final raw = jsonDecode(text);
      if (raw is! Map<String, dynamic>) return false;
      doc = raw;
    } catch (_) {
      return false;
    }
    final version = doc['schemaVersion'];
    if (version is int && version > backupSchemaVersion) return false;
    if (doc['profiles'] is! List) return false;
    late final List<Profile> newProfiles;
    late final List<Subscription> newSubscriptions;
    late final XraySettings newSettings;
    late final WarpProfile newWarpProfile;
    late final List<String> newCfGoodIps;
    late final WinningShapeCache newShapeCache;
    late String newSelectedId;
    try {
      // Per-entry decode (build 2033): one damaged entry is
      // skipped, never the whole restore.
      newProfiles = _decodeList(doc['profiles'], (j) => Profile.fromJson(j));
      newSubscriptions = _decodeList(
        doc['subscriptions'],
        (j) => Subscription.fromJson(j),
      );
      newSettings = doc['settings'] is Map
          ? XraySettings.fromJson(
              (doc['settings'] as Map).cast<String, dynamic>(),
            )
          : XraySettings();
      // Build 2054 (audit F-H9/F-M14): the fields the old
      // import silently dropped — a restore used to keep the
      // TARGET's warp profile and CF IPs and re-persist them.
      newWarpProfile = doc['warpProfile'] is Map
          ? WarpProfile.fromJson(
              (doc['warpProfile'] as Map).cast<String, dynamic>(),
            )
          : WarpProfile();
      newCfGoodIps = ((doc['cfGoodIps'] as List?) ?? [])
          .map((e) => e.toString())
          .toList();
      newShapeCache = WinningShapeCache.fromJson(doc['shapeCache']);
      newSelectedId = doc['selectedProfileId'] is String
          ? doc['selectedProfileId'] as String
          : '';
      if (!newProfiles.any((p) => p.id == newSelectedId)) {
        newSelectedId = newProfiles.isEmpty ? '' : newProfiles.first.id;
      }
    } catch (_) {
      // Any decode failure: false, state untouched.
      return false;
    }
    // Validation passed — only now may the live tunnel go.
    if (state.running) await disconnect();
    profiles = newProfiles;
    subscriptions = newSubscriptions;
    settings = newSettings;
    warpProfile = newWarpProfile;
    cfGoodIps = newCfGoodIps;
    shapeCache = newShapeCache;
    selectedProfileId = newSelectedId;
    await _save();
    notifyListeners();
    return true;
  }

  // ---- tunnel -----------------------------------------------------------

  Future<void> refreshState() async {
    state = await XrayPlatform.state();
    // A standalone WARP session reports under its own name
    // (build 2030): the card's state follows the service, not
    // a local flag, so an app restart mid-session reads true.
    warpSession = state.running && state.name == warpSessionName;
    // An AmneziaWG session reports its own flag (build 2040).
    awgSession = state.running && state.awg;
    if (state.running) {
      // A live session re-read at startup is still a session
      // nobody disconnected (build 2042): if it later dies
      // unexpectedly, the auto-reconnect may fire for it.
      _expectRunning = true;
      _reconnectKind = state.awg
          ? 'wireguard'
          : warpSession
          ? 'warp'
          : 'xray';
      if (_connectedProfileId.isEmpty) {
        _connectedProfileId = selectedProfileId;
      }
      _startPolling();
      _fetchExitInfo();
    } else {
      _expectRunning = false;
      _connectedProfileId = '';
      exitInfo = null;
      _lastAwgRx = -1;
      _lastAwgTx = -1;
    }
    notifyListeners();
  }

  /// Reads the core's traffic deltas for the "proxy" outbound and
  /// adds them to the connected profile's cumulative totals. The
  /// native query resets the counters, so each call accounts exactly
  /// the bytes since the previous one; a call that fails loses
  /// nothing (the counters keep counting until a read succeeds).
  Future<void> _pollStats() async {
    if (_statsBusy || !state.running) return;
    _statsBusy = true;
    try {
      // The byte source depends on the engine (build 2040): an
      // AmneziaWG session has no Xray stats API, so its deltas
      // come from the device's own transfer counters in the
      // polled state; an Xray session reads the core's API as
      // before. Either way the attribution below is the same.
      int up;
      int down;
      if (awgSession) {
        final rx = state.awgRxBytes;
        final tx = state.awgTxBytes;
        if (_lastAwgRx < 0 || _lastAwgTx < 0) {
          _lastAwgRx = rx;
          _lastAwgTx = tx;
          return;
        }
        down = (rx - _lastAwgRx).clamp(0, 1 << 62);
        up = (tx - _lastAwgTx).clamp(0, 1 << 62);
        _lastAwgRx = rx;
        _lastAwgTx = tx;
      } else {
        final delta = await XrayPlatform.trafficStats(statsApiPort(settings));
        if (delta == null) return;
        up = delta['up'] ?? 0;
        down = delta['down'] ?? 0;
      }
      if (up <= 0 && down <= 0) return;
      final id = _connectedProfileId.isNotEmpty
          ? _connectedProfileId
          : selectedProfileId;
      for (final p in profiles) {
        if (p.id != id) continue;
        p.totalUpBytes += up;
        p.totalDownBytes += down;
        p.statsUpdatedMs = DateTime.now().millisecondsSinceEpoch;
        // Build 2050 (audit B-M1): the write is debounced —
        // display reads memory, so nothing visible waits on
        // disk; _flushStatsSave lands the rest at session end.
        _statsSavePending = true;
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        if (nowMs - _lastStatsSaveMs >= 30000) {
          _lastStatsSaveMs = nowMs;
          _statsSavePending = false;
          await _save();
        }
        notifyListeners();
        break;
      }
    } finally {
      _statsBusy = false;
    }
  }

  /// Persists stats totals a debounced poll left pending
  /// (build 2050): called at session end, so a disconnect never
  /// loses the tail of the session's traffic.
  Future<void> _flushStatsSave() async {
    if (!_statsSavePending) return;
    _statsSavePending = false;
    _lastStatsSaveMs = DateTime.now().millisecondsSinceEpoch;
    await _save();
  }

  /// The shell's background hook (build 2055, audit B-M1):
  /// when the app leaves the foreground, land any debounced
  /// stats totals at once — Android may kill a backgrounded
  /// app before the next 30 s write, and the disconnect flush
  /// never runs for a killed process. A no-op when nothing is
  /// pending, so it costs no I/O on an idle tunnel.
  Future<void> flushStatsOnBackground() => _flushStatsSave();

  /// Fires the exit-IP lookup (once at a time, never awaited by the
  /// connection path): fills [exitInfo] when the tunnel answers and
  /// silently leaves it null when it does not.
  void _fetchExitInfo() {
    if (_exitFetching || exitInfo != null || !state.running) return;
    // A new session starts with a clean backoff schedule.
    if (_exitSessionStart != state.sinceMs) {
      _exitSessionStart = state.sinceMs;
      _exitFailures = 0;
      _exitNextTryAt = null;
    }
    // Build 2050 (audit B-H3): a failed lookup backs off
    // (5 s → 15 s → 45 s → 2 min) instead of retrying at the
    // full poll cadence forever.
    final nextTry = _exitNextTryAt;
    if (nextTry != null && DateTime.now().isBefore(nextTry)) return;
    _exitFetching = true;
    // A lookup started before a server switch must not land
    // the OLD exit afterwards (build 2039).
    final gen = _exitGen;
    () async {
      try {
        // A standalone WARP session's proxy is the warp core's
        // port, not the Xray SOCKS port (build 2030) — and that
        // core has no auth, so it gets no credentials (build
        // 2062, LAN sharing: creds ride only the Xray port).
        final m = await XrayPlatform.exitInfo(
          warpSession ? warpSessionPort : settings.socksPort,
          socksUser: warpSession ? '' : _lanUser,
          socksPass: warpSession ? '' : _lanPass,
        );
        if (m != null && state.running && gen == _exitGen) {
          exitInfo = ExitInfo.fromMap(m);
          _exitFailures = 0;
          _exitNextTryAt = null;
          notifyListeners();
        } else if (m == null && state.running && gen == _exitGen) {
          _exitFailures++;
          _exitNextTryAt = DateTime.now().add(exitRetryDelay(_exitFailures));
        }
      } finally {
        _exitFetching = false;
      }
    }();
  }

  /// The shell's lifecycle feed (build 2050): the session
  /// poller keeps its live 2 s cadence only while the app is
  /// foregrounded; backgrounded it drops to the 30 s heartbeat
  /// from poll_policy. Drop detection, the watchdogs, and the
  /// stats reads all ride the same tick — they slow down
  /// together, and the traffic counters keep accumulating in
  /// the core meanwhile, so nothing is lost.
  void setForeground(bool fg) {
    if (fg == _foreground) return;
    _foreground = fg;
    // Build 2057 (audit B-M5): the reconnect countdown text is
    // kept current in memory but only rebuilt while foregrounded
    // — coming back to the foreground re-renders it at once so
    // the home card never shows a stale number.
    if (fg && _reconnectTimer != null) notifyListeners();
    if (_poll != null) {
      _poll!.cancel();
      _poll = null;
      _startPolling();
    }
  }

  void _startPolling() {
    // Build 2050: the cadence comes from poll_policy — 2 s
    // foregrounded, a 30 s heartbeat backgrounded. setForeground
    // recreates the timer when the lifecycle flips.
    _poll ??= Timer.periodic(
      enginePollPeriod(foreground: _foreground),
      (_) => unawaited(_pollTick()),
    );
  }

  Future<void> _pollTick() async {
    final sample = await XrayPlatform.state();
    final now = DateTime.now();
    final last = _lastSample;
    final lastAt = _lastSampleAt;
    if (last != null && lastAt != null && sample.running) {
      final dt = now.difference(lastAt).inMilliseconds / 1000.0;
      if (dt > 0) {
        upRate = ((sample.upBytes - last.upBytes) / dt).round().clamp(
          0,
          1 << 62,
        );
        downRate = ((sample.downBytes - last.downBytes) / dt).round().clamp(
          0,
          1 << 62,
        );
      }
    }
    _lastSample = sample;
    _lastSampleAt = now;
    state = sample;
    if (sample.chainProblem.isNotEmpty &&
        sample.chainProblem != _lastChainProblem) {
      _lastChainProblem = sample.chainProblem;
      chainNotice = sample.chainProblem;
      diagnostics.add('chain', sample.chainProblem, ok: false);
    }
    if (sample.running) {
      // A tunnel that came up outside connect() (e.g. the service
      // outlived the page) still gets its exit line.
      _fetchExitInfo();
      // Build 2050 (audit B-H1): the stats query spawns native
      // processes, so it runs only when the tunnel's own byte
      // counters MOVED since the previous sample. A completely
      // idle tunnel skips it entirely; a busy one loses
      // nothing — the core's counters keep accumulating until
      // the next read, reset-on-read as always.
      if (last == null ||
          sample.upBytes != last.upBytes ||
          sample.downBytes != last.downBytes) {
        unawaited(_pollStats());
      }
      unawaited(_watchdogTick(sample));
    }
    if (!sample.running) {
      // An unexpected drop (build 2042): the poll only ever
      // sees this while a session was up, so capture the
      // profile before the state below is cleared — the
      // retry reconnects it, not whatever is selected now.
      final droppedId = _connectedProfileId.isNotEmpty
          ? _connectedProfileId
          : selectedProfileId;
      final wasExpected = _expectRunning;
      _poll?.cancel();
      _poll = null;
      upRate = 0;
      downRate = 0;
      _lastSample = null;
      _lastSampleAt = null;
      _connectedProfileId = '';
      exitInfo = null;
      unawaited(_flushStatsSave());
      if (wasExpected) _onUnexpectedDrop(droppedId);
    }
    unawaited(_adaptiveTick());
    notifyListeners();
  }

  /// The adaptive failover watcher (build 2026, Stage A),
  /// driven from the 2 s state poll: every ~16 s of tunnel-up
  /// time it asks the tunnel for one real proxied request.
  /// Three consecutive silences mean the tunnel is dead in
  /// practice (the 2025 watchdog covers a wedged CORE; this
  /// covers a live core whose exit path died). It then switches
  /// — seamlessly when the session can rotate (build 2039),
  /// otherwise through the normal connect path — to the next
  /// member of the dead profile's fallback group (build 2035: same
  /// subscription first, tested by delay then untested, a
  /// member that just failed cooling down for 10 minutes), and
  /// says so in [adaptiveNotice]. At most 3 switches per manual
  /// session, then it gives up — and hands the session to the
  /// auto-reconnect episode when the policy allows it (build
  /// 2049), so a dead tunnel is retried instead of left up with
  /// only a notice — rather than flapping forever. With the
  /// setting OFF this returns immediately: nothing watches,
  /// nothing switches, 2025 behaviour exactly.
  /// An AmneziaWG session is OUT of scope for this watcher
  /// (build 2040, v1 limit): its health probe is the SOCKS
  /// request a device with no SOCKS port cannot answer, and
  /// an idle WireGuard peer's stale handshake is not a death —
  /// so a tunnelCheck here would flap a healthy quiet session
  /// to another server. The peer-fallback at connect time and
  /// the handshake age on the home card are the AWG session's
  /// resilience signals for now.
  Future<void> _adaptiveTick({bool force = false}) async {
    // Build 2054 (audit F-H1): the two 2 s ticks cross-check
    // each other's busy flag — the watchdog escalation and the
    // adaptive switch both rotate the core, and the old guards
    // (each tick watching only its own flag) let them fire
    // rotateConfig concurrently. The checks and the flag sets
    // below are synchronous up to the first await, so on Dart's
    // single-threaded event loop the exclusion is airtight;
    // the native coreLock is the backstop.
    if (!settings.adaptiveFailover ||
        !state.running ||
        awgSession ||
        connecting ||
        _switchBusy ||
        _wdBusy ||
        _adaptiveBusy) {
      return;
    }
    if (!force) {
      // Build 2057 (audit B-M2): the probe interval stretches
      // after consecutive successes on an idle tunnel (see
      // adaptiveProbeEveryTicks) — a counter, not a modulo, so a
      // stretched interval never skews the phase.
      if (++_adaptiveProbeTicks < _adaptiveProbeEveryTicks) return;
      _adaptiveProbeTicks = 0;
    }
    _adaptiveBusy = true;
    try {
      final ms = await XrayPlatform.tunnelCheck(
        settings.socksPort,
        socksUser: _lanUser,
        socksPass: _lanPass,
      );
      if (ms >= 0) {
        _adaptiveFails = 0;
        // Build 2057 (audit B-M2): a successful probe extends
        // the streak; traffic since the last probe resets it —
        // failover latency on a USED tunnel is preserved.
        final trafficActive = downRate + upRate > 0;
        _adaptiveProbeStreak = trafficActive ? 0 : _adaptiveProbeStreak + 1;
        _adaptiveProbeEveryTicks = adaptiveProbeEveryTicks(
          successStreak: _adaptiveProbeStreak,
          trafficActive: trafficActive,
        );
        // The tunnel answered again while a failover-handover
        // retry was counting down (build 2049): stand the retry
        // down instead of flapping a healed tunnel. The
        // give-up notice goes too — the tunnel is answering.
        if (_reconnectTimer != null) {
          _cancelReconnectTimer();
          adaptiveNotice = '';
          diagnostics.add(
            'failover',
            'The tunnel answered again — auto-reconnect stood down.',
          );
          notifyListeners();
        }
        return;
      }
      if (!state.running) return; // Stopped by hand meanwhile.
      _adaptiveFails++;
      // Build 2057 (audit B-M2): a failed probe resets the
      // stretch — a dying tunnel is watched at the base cadence.
      _adaptiveProbeStreak = 0;
      _adaptiveProbeEveryTicks = 8;
      if (_adaptiveFails < 3) return;
      _adaptiveFails = 0;
      // A retry is already counting down (build 2049): the
      // handover owns the recovery now — neither switch under
      // it nor schedule a second countdown.
      if (_reconnectTimer != null) return;
      if (_adaptiveSwitches >= 3) {
        // Build 2049: the give-up hands the session to the
        // auto-reconnect episode when the policy allows it,
        // instead of leaving a dead tunnel with only a notice.
        _handOverToReconnect(
          _connectedProfileId.isNotEmpty
              ? _connectedProfileId
              : selectedProfileId,
          'Adaptive failover gave up after 3 switches — the '
          'tunnel is still not answering.',
        );
        return;
      }
      final currentId = _connectedProfileId.isNotEmpty
          ? _connectedProfileId
          : selectedProfileId;
      final current = _profileById(currentId) ?? selected;
      if (current == null) {
        adaptiveNotice =
            'Fallback group: the tunnel stopped answering and '
            'no profile is available to switch to.';
        notifyListeners();
        return;
      }
      // The dead member cools down (build 2035): the group must
      // not flap straight back onto the config that just died.
      markFallbackFailed(current.id);
      final candidates = fallbackCandidates(current);
      if (candidates.isEmpty) {
        // Build 2049: no member to switch to, so the retry
        // re-enters on the same profile — the server may have
        // come back, and the attempt budget bounds the tries.
        _handOverToReconnect(
          current.id,
          'Fallback group: the tunnel stopped answering and '
          'no other member in its group — or anywhere else — '
          'is available to switch to.',
        );
        return;
      }
      final best = candidates.first;
      _adaptiveSwitches++;
      selectedProfileId = best.id;
      final gen = _tunnelGen;
      try {
        // The seamless path first (build 2039): the VPN stays
        // up and only the core is respawned; the full connect
        // is the fallback when the session cannot rotate.
        if (!await switchServer(best)) {
          // Stopped by hand meanwhile: never resurrect.
          if (_tunnelGen != gen) return;
          await _connectSelected();
        }
        adaptiveNotice =
            'Fallback group: switched to ${best.name} '
            '(${best.subscriptionId == current.subscriptionId ? 'same group' : 'another group'}).';
      } catch (_) {
        markFallbackFailed(best.id);
        adaptiveNotice = 'Fallback group: switching to ${best.name} failed.';
      }
      notifyListeners();
    } finally {
      _adaptiveBusy = false;
    }
  }

  /// Adaptive failover gave up on a live-but-silent tunnel
  /// (build 2049): hand the session to the auto-reconnect
  /// episode when the policy allows it, so the dead tunnel is
  /// retried instead of left up with only a notice. The retry
  /// re-enters through the same entry point the session used
  /// ([_reconnectKind]) on the profile that died; the home card
  /// keeps the give-up line above the retry countdown. When the
  /// policy says no the give-up stays a notice and is posted
  /// once, not re-notified on every later judgement — so a user
  /// who turns the setting on later still gets the handover
  /// at the next judgement.
  void _handOverToReconnect(String profileId, String giveUpNotice) {
    final decision = failoverHandover(
      retryPending: _reconnectTimer != null,
      sessionExpected: _expectRunning,
      enabled: settings.autoReconnect,
      attemptsMade: _reconnectAttempts,
      maxAttempts: settings.reconnectMaxAttempts,
    );
    switch (decision) {
      case FailoverHandover.handOver:
        adaptiveNotice = giveUpNotice;
        _reconnectProfileId = profileId;
        diagnostics.add(
          'failover',
          'Adaptive failover gave up — handing over to '
              'auto-reconnect.',
        );
        _scheduleReconnect();
      case FailoverHandover.noticeOnly:
        if (adaptiveNotice != giveUpNotice) {
          adaptiveNotice = giveUpNotice;
          notifyListeners();
        }
      case FailoverHandover.retryAlreadyPending:
        break;
    }
  }

  // ---- Auto-reconnect (build 2042) ---------------------------

  /// Cancels a pending retry countdown and clears its notice.
  /// A fresh connect supersedes a pending retry; the attempt
  /// count is deliberately NOT reset here — a retry's own
  /// connect runs through this path, and resetting would let
  /// the budget never be spent.
  void _cancelReconnectTimer() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    reconnectNotice = '';
  }

  /// Fully ends the auto-reconnect episode (manual disconnect):
  /// countdown, notice and attempt count all go.
  void _cancelReconnect() {
    _cancelReconnectTimer();
    _reconnectAttempts = 0;
  }

  /// The poll saw the tunnel down while a session was expected:
  /// an unexpected drop, not a manual stop. Schedules the first
  /// retry unless a connect is already in flight (its own
  /// outcome decides), there is nothing to reconnect to, or the
  /// policy says no. Called with the profile the dead session
  /// ran on, captured before the poll cleared the state.
  void _onUnexpectedDrop(String droppedProfileId) {
    if (connecting || _switchBusy) return;
    if (_reconnectKind != 'warp' && droppedProfileId.isEmpty) {
      _expectRunning = false;
      return;
    }
    if (!shouldAutoReconnect(
      sessionExpected: _expectRunning,
      enabled: settings.autoReconnect,
      attemptsMade: _reconnectAttempts,
      maxAttempts: settings.reconnectMaxAttempts,
    )) {
      _expectRunning = false;
      return;
    }
    _reconnectProfileId = droppedProfileId;
    _scheduleReconnect();
  }

  /// Starts (or restarts) the countdown to the next retry. The
  /// generation is captured here: a manual connect or disconnect
  /// bumps [_tunnelGen] and the pending retry must then abort
  /// instead of resurrecting a session the user ended.
  void _scheduleReconnect() {
    final gen = _tunnelGen;
    final attempt = _reconnectAttempts + 1;
    // Build 2057 (audit B-M5): the wait doubles per attempt
    // (10→20→40→80 s) instead of a fixed 10 s every time.
    _reconnectCountdown = reconnectDelayForAttempt(
      baseSeconds: settings.reconnectDelaySeconds,
      attempt: attempt,
    );
    reconnectNotice = reconnectWaitingText(
      attempt: attempt,
      maxAttempts: settings.reconnectMaxAttempts,
      secondsLeft: _reconnectCountdown,
      blocked: state.killSwitchHeld,
    );
    notifyListeners();
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (gen != _tunnelGen || !_expectRunning) {
        t.cancel();
        _reconnectTimer = null;
        return;
      }
      _reconnectCountdown--;
      if (_reconnectCountdown <= 0) {
        t.cancel();
        _reconnectTimer = null;
        unawaited(_attemptReconnect(gen));
      } else {
        // Build 2057 (audit B-M5): the countdown text is
        // refreshed every second, but the rebuild only fires
        // while the app is foregrounded — a backgrounded retry
        // must not rebuild the home card once a second. The
        // text stays current in memory, so the next foreground
        // poll shows the right number.
        reconnectNotice = reconnectWaitingText(
          attempt: attempt,
          maxAttempts: settings.reconnectMaxAttempts,
          secondsLeft: _reconnectCountdown,
          blocked: state.killSwitchHeld,
        );
        if (_foreground) notifyListeners();
      }
    });
  }

  /// One retry: re-enters through the same entry point the dead
  /// session used, reconnecting the profile that died (not
  /// whatever is selected now). On success the episode ends;
  /// on failure the next retry is scheduled until the budget is
  /// spent, then the app gives up loudly and waits for the user.
  Future<void> _attemptReconnect(int gen) async {
    if (gen != _tunnelGen || !_expectRunning || connecting || _switchBusy) {
      return;
    }
    _reconnectAttempts++;
    // Build 2057 (audit F-M3): the retry's connect may walk the
    // fallback group — [_connectWithFallbackGroup] counts every
    // member it tries into [_lastConnectTries], and the failure
    // path below charges them all. A WARP retry never walks a
    // group, so it starts at exactly one try.
    _lastConnectTries = 1;
    final kind = _reconnectKind;
    final profileId = _reconnectProfileId;
    if (kind != 'warp' && profileId.isNotEmpty) {
      selectedProfileId = profileId;
    }
    try {
      switch (kind) {
        case 'warp':
          await connectWarp();
        case 'wireguard':
          final p = _profileById(profileId);
          if (p == null) throw StateError('no-profile');
          await connectWireGuardWithFallback(p);
        default:
          await connect();
      }
      // Success: the connect path set the expectation and the
      // kind again; the episode ends.
      _reconnectAttempts = 0;
      reconnectNotice = '';
      notifyListeners();
    } catch (_) {
      // A manual disconnect meanwhile, or a superseding
      // connect, ends the episode silently.
      if (!_expectRunning || gen != _tunnelGen) return;
      _noteRetryFailed();
    }
  }

  /// Charges a failed retry against the episode budget (build
  /// 2057, audit F-M3): the retry's connect may have walked the
  /// fallback group, so every member it tried counts — the
  /// `++` in [_attemptReconnect] counted only the first try,
  /// and the extras land here. Gives up loudly when the budget
  /// is spent, otherwise schedules the next retry.
  void _noteRetryFailed() {
    _reconnectAttempts += _lastConnectTries - 1;
    if (_reconnectAttempts >= settings.reconnectMaxAttempts) {
      reconnectNotice = reconnectGaveUpText(
        maxAttempts: settings.reconnectMaxAttempts,
        blocked: state.killSwitchHeld,
      );
      _expectRunning = false;
      _reconnectAttempts = 0;
      notifyListeners();
      return;
    }
    _scheduleReconnect();
  }

  // ---- Test seams (build 2057, audit F-M3) -------------------
  // The watchdog and the retry episode are driven by timers and
  // platform channels on a device; these seams let host tests
  // drive the same code paths with synthetic samples.

  /// Starts a handover countdown that never fires, so a test
  /// can observe the watchdog while a retry is pending.
  @visibleForTesting
  void testBeginHandoverCountdown() {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer.periodic(const Duration(hours: 1), (_) {});
  }

  /// Cancels a test handover countdown (or a retry a test
  /// scheduled) so no timer outlives the test.
  @visibleForTesting
  void testEndHandoverCountdown() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
  }

  /// Drives one stall-watchdog tick with a synthetic sample.
  @visibleForTesting
  Future<void> testWatchdogTick(XrayState sample) => _watchdogTick(sample);

  /// Simulates one failed auto-reconnect retry that consumed
  /// [triesConsumed] profile attempts (the first try plus the
  /// fallback-group members its connect walked), then charges
  /// them all against the episode budget exactly as
  /// [_attemptReconnect]'s failure path does.
  @visibleForTesting
  void testNoteFailedRetry({required int triesConsumed}) {
    _reconnectAttempts++;
    _lastConnectTries = triesConsumed;
    _noteRetryFailed();
  }

  /// Attempts spent in the current auto-reconnect episode.
  @visibleForTesting
  int get testReconnectAttempts => _reconnectAttempts;

  /// True while a handover/retry countdown is pending.
  @visibleForTesting
  bool get testHasPendingRetry => _reconnectTimer != null;

  // ---- Watchdog shape escalation (build 2029A) --------------

  /// The stall watchdog, driven from the 2 s state poll. It
  /// acts ONLY on the freeze signature — bytes still going UP
  /// (the device keeps sending into the tunnel) while NO bytes
  /// come back for over 6 s. While anything at all is flowing
  /// back it never probes: a slow, busy tunnel (bufferbloat)
  /// is not a frozen one, and probing it would only add noise.
  /// Two failed probes escalate to the next shape.
  ///
  /// Disabled whenever a dialerProxy underlay is chained under
  /// the session: with Psiphon below, rotating Xray's own
  /// shapes treats the wrong layer — the ChainSupervisor owns
  /// that failure mode.
  Future<void> _watchdogTick(XrayState sample) async {
    // Build 2054 (audit F-H1): cross-check the adaptive
    // tick's busy flag (see _adaptiveTick) — a watchdog
    // escalation must never rotate while a failover switch
    // is mid-rotate, and vice versa.
    if (_wdBusy || _adaptiveBusy || connecting || _switchBusy || scanRunning) {
      return;
    }
    // Build 2057 (audit F-M3): a handover countdown owns the
    // recovery now — the tunnel still runs while it counts down,
    // and the stall watchdog must not rotate or restart under
    // it. (The adaptive tick already stands down on the same
    // condition; the watchdog had no such check.)
    if (_reconnectTimer != null) return;
    if (settings.underlay != 'none') return;
    // A standalone WARP session has no Xray core to rotate
    // shapes on (build 2030): its supervisor is native.
    if (warpSession) return;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (nowMs - sample.sinceMs < 10000) return; // Let it settle.
    if (_wdBaseUp == null || _wdBaseDown == null) {
      _wdBaseUp = sample.upBytes;
      _wdBaseDown = sample.downBytes;
      _wdStallSinceMs = nowMs;
      return;
    }
    if (sample.downBytes > _wdBaseDown!) {
      // Downlink is flowing: by definition not stalled.
      _wdBaseUp = sample.upBytes;
      _wdBaseDown = sample.downBytes;
      _wdStallSinceMs = nowMs;
      _wdProbeFails = 0;
      return;
    }
    if (sample.upBytes <= _wdBaseUp!) {
      // Nothing is being sent either: an idle tunnel is not a
      // stalled one. Keep the bases; restart the stall clock.
      _wdStallSinceMs = nowMs;
      return;
    }
    // Uplink advancing, downlink flat: the freeze signature.
    if (nowMs - _wdStallSinceMs < 6000) return;
    _wdBusy = true;
    try {
      final ms = await XrayPlatform.tunnelCheck(
        settings.socksPort,
        socksUser: _lanUser,
        socksPass: _lanPass,
      );
      if (ms >= 0) {
        diagnostics.add(
          'watchdog',
          'Traffic stalled for 6 s, but a probe through the '
              'tunnel answered in $ms ms — no action taken.',
          ok: true,
        );
        _wdProbeFails = 0;
        _wdBaseUp = sample.upBytes;
        _wdBaseDown = sample.downBytes;
        _wdStallSinceMs = DateTime.now().millisecondsSinceEpoch;
        return;
      }
      _wdProbeFails++;
      diagnostics.add(
        'watchdog',
        'Traffic is going up but nothing comes back, and probe '
            '$_wdProbeFails of 2 through the tunnel failed.',
        ok: false,
      );
      if (_wdProbeFails < 2) return;
      _wdProbeFails = 0;
      await _escalateShape();
    } finally {
      _wdBusy = false;
    }
  }

  /// One escalation step: rotate the core (TUN untouched) to
  /// the next shape, prove it with the endurance pair
  /// (0 / +2.5 s), and persist the winner. When the shapes run
  /// out: core restart, then the existing adaptive failover.
  Future<void> _escalateShape() async {
    final p = _profileById(_connectedProfileId) ?? selected;
    if (p == null) return;
    final shapes = shapesFor(p);
    final idx = shapes.indexOf(_wdShape);
    if (idx < 0 || idx >= shapes.length - 1) {
      diagnostics.add(
        'watchdog',
        'Every connection shape failed for ${p.name}. '
            'Restarting the core; adaptive failover takes it '
            'from here.',
        ok: false,
      );
      await XrayPlatform.rotateConfig(
        buildTunnelConfig(
          p,
          settings,
          psiphonUnderlay: settings.underlay == 'psiphon',
          warpUnderlay: settings.underlay == 'warp',
          warp: warpProfile,
          dnsttUnderlay: settings.underlay == 'dnstt',
          wgWstunnelPort: _sessionWgWstunnelPort,
        ),
      );
      _wdShape = shapeStock;
      _resetWatchdogBases();
      // Let the failover judge the restarted core at once
      // rather than at its next scheduled tick.
      _adaptiveFails = 2;
      unawaited(_adaptiveTick(force: true));
      return;
    }
    final next = shapes[idx + 1];
    diagnostics.add(
      'watchdog',
      'Switching ${p.name} to the ${shapeLabel(next)} shape.',
    );
    final rotated = await XrayPlatform.rotateConfig(
      buildTunnelConfig(
        profileWithShape(p, next),
        settings,
        psiphonUnderlay: settings.underlay == 'psiphon',
        warpUnderlay: settings.underlay == 'warp',
        warp: warpProfile,
        dnsttUnderlay: settings.underlay == 'dnstt',
        wgWstunnelPort: _sessionWgWstunnelPort,
      ),
    );
    if (!rotated) {
      diagnostics.add(
        'watchdog',
        'The core would not take the rotated config; the '
            'session keeps its current shape.',
        ok: false,
      );
      return;
    }
    _wdShape = next;
    // The shape must HOLD, not just answer once (the
    // endurance rule, shortened for a live rotation).
    final first = await XrayPlatform.tunnelCheck(
      settings.socksPort,
      socksUser: _lanUser,
      socksPass: _lanPass,
    );
    await Future<void>.delayed(const Duration(milliseconds: 2500));
    final second = await XrayPlatform.tunnelCheck(
      settings.socksPort,
      socksUser: _lanUser,
      socksPass: _lanPass,
    );
    if (first >= 0 && second >= 0) {
      diagnostics.add(
        'watchdog',
        'The ${shapeLabel(next)} shape held (probes $first ms '
            'and $second ms). Remembered for this network.',
        ok: true,
      );
      shapeCache.record(p.id, networkFp, next, first);
      unawaited(_save());
      _resetWatchdogBases();
    } else {
      diagnostics.add(
        'watchdog',
        'The ${shapeLabel(next)} shape answered but did not '
            'hold. Escalating further.',
        ok: false,
      );
      await _escalateShape();
    }
  }

  void _resetWatchdogBases() {
    _wdBaseUp = null;
    _wdBaseDown = null;
    _wdStallSinceMs = 0;
    _wdProbeFails = 0;
  }

  Profile? _profileById(String id) {
    for (final p in profiles) {
      if (p.id == id) return p;
    }
    return null;
  }

  // ---- Guided diagnostics (build 2029A) -----------------------

  /// Runs the staged connection check — against the live
  /// tunnel when one is up, against the selected profile when
  /// not — and journals every stage.
  Future<List<CheckStage>> runConnectionCheck() async {
    if (checking) return lastCheck;
    checking = true;
    notifyListeners();
    try {
      final checker = ConnectionChecker(
        delay: (p) => testDelay(p),
        exit: (port) => XrayPlatform.exitInfo(
          port,
          socksUser: _lanUser,
          socksPass: _lanPass,
        ),
        socksUser: _lanUser,
        socksPass: _lanPass,
      );
      final List<CheckStage> stages;
      if (state.running) {
        diagnostics.add('check', 'Checking the running tunnel…');
        stages = await checker.checkLive(
          socksPort: settings.socksPort,
          listenHost: settings.lanShareEnabled ? '0.0.0.0' : '127.0.0.1',
        );
      } else if (selected != null) {
        diagnostics.add('check', 'Checking ${selected!.name}…');
        stages = await checker.checkProfile(selected!);
      } else {
        stages = const [];
      }
      for (final stage in stages) {
        diagnostics.add(
          'check',
          '${stage.title} — ${stage.detail}',
          ok: stage.ok,
        );
      }
      lastCheck = stages;
      return stages;
    } finally {
      checking = false;
      notifyListeners();
    }
  }

  /// Sets the chain underlay ('none' | 'psiphon' | 'warp' |
  /// 'dnstt').
  /// Applies to the NEXT V2Ray session: a running session
  /// keeps the shape it started with.
  Future<void> setUnderlay(String value) async {
    settings.underlay = switch (value) {
      'psiphon' => 'psiphon',
      'warp' => 'warp',
      'dnstt' => 'dnstt',
      _ => 'none',
    };
    diagnostics.add('chain', switch (settings.underlay) {
      'psiphon' =>
        'Underlay set to Psiphon: the next V2Ray session '
            'will run over a Psiphon tunnel.',
      'warp' =>
        'Underlay set to Warp: the next V2Ray session '
            'will run over the EmberWarp core.',
      'dnstt' =>
        'Underlay set to DNSTT: the next V2Ray session '
            'will run over the DNS tunnel.',
      _ =>
        'Underlay off: the next V2Ray session connects '
            'directly.',
    });
    await _save();
    notifyListeners();
  }

  /// Persists the DNSTT underlay fields (build 2072).
  Future<void> saveDnsttSettings({
    required String resolverType,
    required String resolver,
    required String domain,
    required String pubkey,
  }) async {
    settings.dnsttResolverType = resolverType;
    settings.dnsttResolver = resolver.trim();
    settings.dnsttDomain = domain.trim();
    settings.dnsttPubkey = pubkey.trim();
    await _save();
    notifyListeners();
  }

  /// The WireGuard-over-WebSocket switch (build 2072).
  Future<void> setWgWstunnel(bool on) async {
    settings.wgWstunnel = on;
    await _save();
    notifyListeners();
  }

  /// The wstunnel server URL for WireGuard sessions
  /// (build 2072).
  Future<void> setWgWstunnelUrl(String url) async {
    settings.wgWstunnelUrl = url.trim();
    await _save();
    notifyListeners();
  }

  // ---- EmberWarp (build 2030) ------------------------------------------

  /// Refreshes the warp core's known state (identity, refusal,
  /// readiness) for the card and the settings sheet.
  Future<void> refreshWarpState() async {
    warpState = await WarpPlatform.state();
    notifyListeners();
  }

  /// Persists an edited warp profile.
  Future<void> saveWarpProfile() async {
    await _save();
    notifyListeners();
  }

  /// Starts the EmberWarp core with [args] (unless it already
  /// runs) and waits for its data-plane readiness — the core
  /// answers its SOCKS greeting only after a gateway carried
  /// a real check, so a ready answer IS the proof. False on
  /// timeout, process death, or a refused identity; the
  /// journal says which.
  Future<bool> _awaitWarpReady(List<String> args, {int port = 20850}) async {
    final before = await WarpPlatform.state();
    if (!(before.running && before.ready)) {
      diagnostics.add('warp', 'Starting the EmberWarp core…');
      final spawned = await WarpPlatform.start(args, port: port);
      if (!spawned) {
        diagnostics.add(
          'warp',
          'The EmberWarp core could not start.',
          ok: false,
        );
        return false;
      }
    }
    final deadline = DateTime.now().add(const Duration(seconds: 90));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final s = await WarpPlatform.state();
      warpState = s;
      if (s.running && s.ready) {
        diagnostics.add('warp', 'The EmberWarp core is up.', ok: true);
        return true;
      }
      if (s.renewNeeded || s.stage == 'refused') {
        diagnostics.add(
          'warp',
          'Cloudflare refused the saved WARP identity. Renew '
              'the WARP key from the WARP card to reconnect.',
          ok: false,
        );
        return false;
      }
      if (!s.running || s.stage == 'error') break;
    }
    diagnostics.add(
      'warp',
      'The EmberWarp core did not become ready in time.',
      ok: false,
    );
    return false;
  }

  /// The standalone WARP session (the WARP MASQUE card):
  /// the core first, readiness-proven, then the TUN service
  /// in warp mode — no Xray process anywhere in the path.
  Future<void> connectWarp() async {
    connecting = true;
    lastError = null;
    exitInfo = null;
    // A fresh connect supersedes a pending retry (build 2042).
    _cancelReconnectTimer();
    notifyListeners();
    try {
      await stopOtherEngine?.call();
      if (state.running) await _stopTunnel();
      final args = buildWarpArgs(warpProfile);
      if (!await _awaitWarpReady(args)) {
        throw StateError('warp-failed');
      }
      await XrayPlatform.setOnWarp(
        name: warpSessionName,
        dns: settings.localDns,
        ipv6: settings.ipv6Route,
        mtu: settings.tunnelMtu,
        warpArgs: args,
        killSwitch: settings.killSwitch,
      );
      for (var i = 0; i < 40; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        state = await XrayPlatform.state();
        if (state.running) break;
      }
      if (!state.running) throw StateError('start-failed');
      warpSession = true;
      // The session is up and nobody disconnected it (build
      // 2042): a later unexpected drop may auto-reconnect it.
      _expectRunning = true;
      _reconnectKind = 'warp';
      _connectedProfileId = '';
      _lastSample = state;
      _lastSampleAt = DateTime.now();
      _startPolling();
      _fetchExitInfo();
    } catch (e) {
      if (!state.running) unawaited(WarpPlatform.stop());
      lastError = e.toString();
      rethrow;
    } finally {
      connecting = false;
      notifyListeners();
    }
  }

  /// The explicit identity renewal (dossier Q1): the ONLY
  /// path that registers a fresh WARP identity. True when a
  /// new identity landed and settled.
  Future<bool> renewWarpIdentity() async {
    diagnostics.add('warp', 'Renewing the WARP identity…');
    final ok = await WarpPlatform.renew(warpRegisterKind(warpProfile));
    diagnostics.add(
      'warp',
      ok
          ? 'A fresh WARP identity is registered and saved.'
          : 'The renewal did not complete — check the '
                'connection and try again.',
      ok: ok,
    );
    await refreshWarpState();
    return ok;
  }

  /// Explicit identity wipe (the settings sheet's danger
  /// action): the next connect registers fresh.
  Future<void> resetWarpIdentity() async {
    await WarpPlatform.resetIdentity();
    diagnostics.add(
      'warp',
      'The saved WARP identity was deleted; the next connect '
          'registers a fresh one.',
    );
    await refreshWarpState();
  }

  /// Starts the Psiphon underlay proxy-only and waits until
  /// its tunnel handshake passes (build 2029A chain sequence,
  /// step 1–2). Throws StateError('underlay-failed') after
  /// stopping the underlay again — a chained session must
  /// never start against a dead underlay.
  Future<({String region, String upstream, List<String> protocols})>
  _startUnderlay() async {
    final params =
        underlayParams?.call() ??
        (region: '', upstream: '', protocols: <String>[]);
    diagnostics.add('chain', 'Starting the Psiphon underlay…');
    final before = await PsiphonPlatform.state();
    if (before.running && !before.vpnMode) {
      // A standalone proxy-only session is already up: adopt
      // it as-is (it is the same core the chain would start).
      if (before.connected) {
        diagnostics.add('chain', 'The Psiphon proxy is already up.', ok: true);
        return params;
      }
      // Build 2054 (audit F-M5): running-but-not-connected
      // proxy-only Psiphon — the old code called setOn again
      // without stopping it at all, the same async-stop race
      // as the native respawn. Stop, wait for the death to be
      // observable, then start.
      diagnostics.add(
        'chain',
        'The Psiphon proxy is up but not connected; stopping it first.',
      );
      await _stopPsiphonUnderlay();
    } else if (before.running) {
      // A VPN-mode Psiphon is up: same stop-then-wait before
      // the chain restarts it proxy-only (the old code stopped
      // and immediately setOn again).
      await _stopPsiphonUnderlay();
    }
    await PsiphonPlatform.setOn(
      vpnMode: false,
      region: params.region,
      upstream: params.upstream,
      protocols: params.protocols,
      dns: settings.localDns,
      mtu: settings.tunnelMtu,
    );
    final deadline = DateTime.now().add(const Duration(seconds: 90));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final s = await PsiphonPlatform.state();
      if (s.running && s.connected) {
        diagnostics.add(
          'chain',
          'The Psiphon underlay is up (exit region '
              '${s.region.isEmpty ? 'auto' : s.region}).',
          ok: true,
        );
        return params;
      }
      if (!s.running) break;
    }
    diagnostics.add(
      'chain',
      'The Psiphon underlay did not connect in time; the '
          'chained session was not started.',
      ok: false,
    );
    await PsiphonPlatform.stop();
    throw StateError('underlay-failed');
  }

  /// Stops the Psiphon service and waits, bounded (~4 s), for
  /// the stop to be observable (build 2054, audit F-M5):
  /// psiphonStop is an async service intent, so stop-then-start
  /// without a wait can leave two gomobile cores on 11808.
  /// Throws StateError('underlay-failed') when the old core
  /// will not go — starting a second core on the same port is
  /// worse than not starting the chain.
  Future<void> _stopPsiphonUnderlay() async {
    await PsiphonPlatform.stop();
    final deadline = DateTime.now().add(const Duration(seconds: 4));
    while (DateTime.now().isBefore(deadline)) {
      PsiphonState s;
      try {
        s = await PsiphonPlatform.state();
      } catch (_) {
        throw StateError('underlay-failed');
      }
      if (!s.running) return;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    diagnostics.add(
      'chain',
      'The Psiphon underlay did not stop in time; the chained '
          'session was not started.',
      ok: false,
    );
    throw StateError('underlay-failed');
  }

  /// Starts the DNSTT underlay client and waits until its
  /// local listener accepts (build 2072). The client is a
  /// port forward through a DNS tunnel: readiness proves the
  /// listener, and the tunnel itself forms per stream — the
  /// native ChainSupervisor owns its health for the session's
  /// life. Throws StateError('dnstt-not-configured') when the
  /// fields are incomplete, and StateError('underlay-failed')
  /// after stopping the client again when it will not start —
  /// a chained session must never start against a dead
  /// underlay.
  Future<List<String>> _startDnsttUnderlay() async {
    if (!dnsttConfigured(settings)) {
      diagnostics.add(
        'chain',
        'DNSTT is the selected underlay but its settings are '
            'incomplete — a resolver, the tunnel domain and '
            'the server public key (64 hex digits) are all '
            'required. Open DNSTT settings on the home card.',
        ok: false,
      );
      throw StateError('dnstt-not-configured');
    }
    final args = buildDnsttArgs(settings);
    diagnostics.add(
      'chain',
      'Starting the DNSTT underlay (${settings.dnsttDomain} '
          'via ${settings.dnsttResolver})…',
    );
    if (!await DnsttPlatform.start(args)) {
      final st = await DnsttPlatform.state();
      diagnostics.add(
        'chain',
        'The DNSTT client would not start'
            '${st.error.isEmpty ? '' : ': ${st.error}'}',
        ok: false,
      );
      throw StateError('underlay-failed');
    }
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      final st = await DnsttPlatform.state();
      if (st.ready) {
        diagnostics.add(
          'chain',
          'The DNSTT client is listening on '
              '127.0.0.1:$dnsttListenPort.',
          ok: true,
        );
        return args;
      }
      if (!st.running || st.stage == 'error') {
        diagnostics.add(
          'chain',
          'The DNSTT client stopped during start'
              '${st.error.isEmpty ? '' : ': ${st.error}'}',
          ok: false,
        );
        throw StateError('underlay-failed');
      }
    }
    diagnostics.add(
      'chain',
      'The DNSTT client did not open its listener in time; '
          'the chained session was not started.',
      ok: false,
    );
    await DnsttPlatform.stop();
    throw StateError('underlay-failed');
  }

  /// Starts the wstunnel forwarder for a WireGuard session
  /// (build 2072) and waits for its startup window to pass.
  /// A UDP forwarder has no handshake to probe — readiness is
  /// the process alive with its listener bound; the
  /// WireGuard handshake above it is the end-to-end proof,
  /// and the native supervisor owns its health for the
  /// session's life. Throws StateError('wstunnel-failed')
  /// after stopping the forwarder again when it will not
  /// start.
  Future<void> _startWstunnel(List<String> args) async {
    diagnostics.add(
      'wstunnel',
      'Starting the wstunnel forwarder for this WireGuard '
          'session…',
    );
    if (!await WstunnelPlatform.start(args)) {
      final st = await WstunnelPlatform.state();
      diagnostics.add(
        'wstunnel',
        'The wstunnel client would not start'
            '${st.error.isEmpty ? '' : ': ${st.error}'}',
        ok: false,
      );
      throw StateError('wstunnel-failed');
    }
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      final st = await WstunnelPlatform.state();
      if (st.ready) {
        diagnostics.add(
          'wstunnel',
          'The wstunnel forwarder is up on UDP '
              '127.0.0.1:$wstunnelListenPort.',
          ok: true,
        );
        return;
      }
      if (!st.running || st.stage == 'error') {
        diagnostics.add(
          'wstunnel',
          'The wstunnel client stopped during start'
              '${st.error.isEmpty ? '' : ': ${st.error}'}',
          ok: false,
        );
        throw StateError('wstunnel-failed');
      }
    }
    diagnostics.add(
      'wstunnel',
      'The wstunnel client did not come up in time; the '
          'session was not started.',
      ok: false,
    );
    await WstunnelPlatform.stop();
    throw StateError('wstunnel-failed');
  }

  /// Connects a WireGuard profile with peer fallback (build
  /// 2032, the ENG1 behaviour on Ember's carrier): the chosen
  /// peer is tried first; when its tunnel carries nothing —
  /// judged by a real request through the live tunnel, never
  /// by the TUN merely being up — the next peer of the same
  /// imported config (same interface keys) is tried, in order.
  /// Throws StateError('wg-all-peers-failed') when no peer of
  /// the group carries traffic.
  ///
  /// A peer that carries AmneziaWG parameters is tried on the
  /// obfuscated engine FIRST (build 2040, queue 2h); only a
  /// peer the AWG engine cannot reach falls through to the
  /// plain-WireGuard Xray path below — never a silent plain
  /// run, and never a dead end.
  Future<void> connectWireGuardWithFallback(Profile first) async {
    // A fresh connect supersedes a pending retry (build 2042).
    _cancelReconnectTimer();
    awgFallbackNotice = '';
    final group = profiles
        .where(
          (p) =>
              p.protocol == Protocol.wireguard &&
              wgGroupKey(p) == wgGroupKey(first),
        )
        .toList();
    final ordered = [first, ...group.where((p) => p.id != first.id)];
    Object? lastFailure;
    // Build 2050 (audit C-1): the name of a candidate whose
    // AmneziaWG attempt failed, so a plain-WireGuard success
    // below can say — visibly, not only in the journal — that
    // the session is NOT obfuscated.
    String? awgFailedFor;
    for (final candidate in ordered) {
      selectedProfileId = candidate.id;
      notifyListeners();
      if (candidate.hasAmneziaParams) {
        if (await _connectAwg(candidate)) {
          // AmneziaWG is up and nobody disconnected it (build
          // 2042): a later unexpected drop may auto-reconnect it
          // through this same fallback path.
          _expectRunning = true;
          _reconnectKind = 'wireguard';
          await _save();
          return;
        }
        awgFailedFor = candidate.name;
        diagnostics.add(
          'awg',
          'AmneziaWG did not answer for ${candidate.name}; '
              'falling back to plain WireGuard.',
          ok: false,
        );
      }
      // The plain WireGuard leg (build 2057, audit F-M10): the
      // fallback-group walk directly, NOT connect() — connect()
      // routes WireGuard back into this function, and calling it
      // here would recurse.
      try {
        await _connectWithFallbackGroup();
      } catch (e) {
        lastFailure = e;
        continue;
      }
      // The TUN is up; WireGuard is connectionless, so only a
      // carried request proves the peer. The exit lookup rides
      // the same path; a tunnel-check request is the verdict.
      final deadline = DateTime.now().add(const Duration(seconds: 12));
      var carries = false;
      while (DateTime.now().isBefore(deadline)) {
        await refreshState();
        if (!state.running) break;
        if (exitInfo != null) {
          carries = true;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 800));
      }
      if (!carries && state.running) {
        final ms = await XrayPlatform.tunnelCheck(
          settings.socksPort,
          socksUser: _lanUser,
          socksPass: _lanPass,
        );
        carries = ms >= 0;
      }
      if (carries) {
        // Plain WireGuard through the core is up and nobody
        // disconnected it (build 2042): a later unexpected drop
        // may auto-reconnect it through this same fallback path.
        _expectRunning = true;
        _reconnectKind = 'wireguard';
        if (awgFailedFor != null) {
          // Build 2050 (audit C-1): say it where the user can
          // see it — this session runs WITHOUT the AmneziaWG
          // obfuscation the profile carries.
          awgFallbackNotice =
              'AmneziaWG could not start for $awgFailedFor — '
              'this session runs as plain WireGuard, without '
              'obfuscation.';
        }
        await _save();
        return;
      }
      lastFailure = StateError('peer-silent');
      await disconnect();
    }
    throw StateError(
      lastFailure is StateError && lastFailure.message == 'no-profile'
          ? 'no-profile'
          : 'wg-all-peers-failed',
    );
  }

  /// Connects [p] on the AmneziaWG userspace engine (build
  /// 2040, queue 2h): the service brings the TUN up and hands
  /// its fd to the device in libwg-go.so, which runs the
  /// profile's obfuscation parameters for real. Returns true
  /// only once the device reports a completed handshake —
  /// which only happens when the peer answers with the right
  /// keys AND the right obfuscation values — so a peer that
  /// never answers (wrong values, or DPI eating the handshake)
  /// returns false and the caller falls back to plain
  /// WireGuard. Never throws; a session left running by a
  /// failed attempt is stopped by the plain path's connect
  /// (or by the next disconnect), never left behind.
  Future<bool> _connectAwg(Profile p) async {
    _tunnelGen++;
    connecting = true;
    lastError = null;
    exitInfo = null;
    notifyListeners();
    try {
      // One tunnel at a time: the Mozilla engine goes off first.
      await stopOtherEngine?.call();
      if (state.running) await _stopTunnel();
      if (networkFp.isEmpty) await refreshNetworkFingerprint();
      await XrayPlatform.setOnAwg(
        settings: buildAwgUapi(p),
        name: p.name,
        addresses: p.localAddress,
        dns: settings.localDns,
        ipv6: settings.ipv6Route,
        // Build 2059 (audit §6 WG-conf divergence): the AWG TUN
        // MTU comes from Settings like every other engine — the
        // profile's p.mtu is the peer MTU, not the tunnel MTU.
        mtu: settings.tunnelMtu,
      );
      // The service reports itself once the tunnel is really up.
      for (var i = 0; i < 40; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        state = await XrayPlatform.state();
        if (state.running) break;
      }
      if (!state.running) {
        diagnostics.add(
          'awg',
          'AmneziaWG did not start for ${p.name}.',
          ok: false,
        );
        return false;
      }
      final deadline = DateTime.now().add(const Duration(seconds: 12));
      while (DateTime.now().isBefore(deadline)) {
        state = await XrayPlatform.state();
        if (!state.running) return false;
        if (state.awgHandshakeAgeSec >= 0) {
          _connectedProfileId = p.id;
          _lastSample = state;
          _lastSampleAt = DateTime.now();
          _startPolling();
          diagnostics.add(
            'awg',
            'AmneziaWG handshake with ${p.name} '
                '(${state.awgHandshakeAgeSec}s ago) — the '
                'obfuscated tunnel carries traffic.',
            ok: true,
          );
          return true;
        }
        await Future<void>.delayed(const Duration(milliseconds: 800));
      }
      diagnostics.add(
        'awg',
        'AmneziaWG peer ${p.name} never answered the handshake.',
        ok: false,
      );
      return false;
    } catch (e) {
      lastError = e.toString();
      diagnostics.add('awg', 'AmneziaWG failed for ${p.name}: $e', ok: false);
      return false;
    } finally {
      connecting = false;
      notifyListeners();
    }
  }

  /// Connects the selected profile (a manual connect: the
  /// adaptive failover's session counters start over). Throws a
  /// short message on failure. With fallback groups on (build
  /// 2035), a failed connect walks the selected profile's
  /// fallback group — up to 3 further members, each failure
  /// starting that member's cooldown — and only throws when
  /// every tried member failed.
  // ---- Seamless server switch (build 2039, queue 2g) ----------

  /// Whether a live session can change servers WITHOUT dropping
  /// the VPN: the tunnel must be a plain Xray session. A
  /// standalone WARP session runs no Xray core to rotate, and a
  /// chained session (Psiphon/Warp underlay) needs its chain
  /// parameters re-supplied — the controller does not keep them,
  /// so those sessions take the full reconnect path instead. An
  /// AmneziaWG session (build 2040) likewise has no core to
  /// respawn: its device would need a fresh UAPI peer, which
  /// the rotate path cannot supply.
  static bool seamlessSwitchAllowed({
    required bool running,
    required bool warpSession,
    required String underlay,
    bool awgSession = false,
    // Build 2072: a wstunnel session's forwarder is bound to
    // the CURRENT peer — a rotated config would point at the
    // new peer directly while the forwarder still serves the
    // old one, so those sessions take the full reconnect path
    // too (the forwarder restarts with the new endpoint).
    bool wstunnelSession = false,
  }) =>
      running &&
      !warpSession &&
      !awgSession &&
      !wstunnelSession &&
      underlay == 'none';

  /// Switches the live tunnel to [next] WITHOUT dropping the
  /// VPN: only the Xray core subprocess is respawned with the
  /// new profile's config (the rotate path the watchdog's shape
  /// rotation has used since 2029A); the TUN interface and its
  /// bridge stay up, and new flows recover on the new server by
  /// themselves. Returns true only once a real request through
  /// the NEW exit has answered. Returns false when the session
  /// cannot rotate, the rotation was refused, the session died,
  /// or the new exit never answered — the caller falls back to
  /// the full connect path. Never throws.
  Future<bool> switchServer(Profile next) async {
    if (_switchBusy || connecting) return false;
    if (!next.protocol.supportedByCore) return false;
    if (_connectedProfileId.isEmpty || _connectedProfileId == next.id) {
      return false;
    }
    if (!seamlessSwitchAllowed(
      running: state.running,
      warpSession: warpSession,
      underlay: settings.underlay,
      awgSession: awgSession,
      wstunnelSession: _sessionWgWstunnelPort != 0,
    )) {
      return false;
    }
    final gen = _tunnelGen;
    _switchBusy = true;
    switchingProfileId = next.id;
    switchNotice = '';
    notifyListeners();
    try {
      if (networkFp.isEmpty) await refreshNetworkFingerprint();
      // The same shape fast-path connect() uses: a shape that
      // already proved itself on this network is dialed directly.
      final win = shapeCache.lookup(next.id, networkFp);
      final dialProfile = win == null
          ? next
          : profileWithShape(next, win.shapeId);
      final config = buildTunnelConfig(dialProfile, settings);
      // Count the old exit's tail into its own totals before
      // the core is replaced (the new core's counters start at 0).
      await _pollStats();
      final rotated = await XrayPlatform.rotateConfig(config);
      if (!rotated) return false;
      // The rotated config is live from here: new bytes belong
      // to the new profile.
      selectedProfileId = next.id;
      _connectedProfileId = next.id;
      _wdShape = win?.shapeId ?? shapeStock;
      _resetWatchdogBases();
      _adaptiveFails = 0;
      await _save();
      // Prove the new exit answers a real request (the probe
      // the watchdog shape rotation uses). Each check can take
      // seconds when the exit is dead, so the loop is bounded by
      // a wall-clock deadline, not by attempts.
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (DateTime.now().isBefore(deadline)) {
        // Stopped by hand (or superseded by a full connect)
        // meanwhile: never resurrect the tunnel.
        if (_tunnelGen != gen) return false;
        try {
          state = await XrayPlatform.state();
        } catch (_) {
          return false;
        }
        if (!state.running) return false;
        final ms = await XrayPlatform.tunnelCheck(
          settings.socksPort,
          socksUser: _lanUser,
          socksPass: _lanPass,
        );
        if (ms >= 0) {
          _exitGen++;
          exitInfo = null;
          // Build 2050: a fresh exit gets a fresh backoff too.
          _exitFailures = 0;
          _exitNextTryAt = null;
          _fetchExitInfo();
          switchNotice = 'Switched to ${next.name} — connection kept.';
          diagnostics.add(
            'switch',
            'Seamless switch to ${next.name} ($ms ms) — the '
                'VPN stayed up.',
            ok: true,
          );
          notifyListeners();
          return true;
        }
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      diagnostics.add(
        'switch',
        'Switched to ${next.name} but the new exit never '
            'answered; falling back to a full reconnect.',
        ok: false,
      );
      return false;
    } catch (e) {
      diagnostics.add(
        'switch',
        'Switch to ${next.name} failed ($e); falling back to a '
            'full reconnect.',
        ok: false,
      );
      return false;
    } finally {
      _switchBusy = false;
      switchingProfileId = null;
      notifyListeners();
    }
  }

  /// Tries the seamless switch; when it is impossible or the
  /// new exit never answered, the full connect path (with its
  /// group fallback) takes over.
  Future<void> _switchOrConnect(Profile next) async {
    final gen = _tunnelGen;
    selectedProfileId = next.id;
    unawaited(_save());
    // A connect already in flight wins; the tap only selects.
    if (connecting) return;
    if (await switchServer(next)) return;
    // A disconnect (or a superseding connect) during the switch
    // must not resurrect the tunnel.
    if (_tunnelGen != gen || connecting) return;
    await connect();
  }

  /// The generic connect path (build 2057, audit F-M10): a
  /// WireGuard selection routes through the peer-fallback path,
  /// which tries the AmneziaWG engine first for a profile that
  /// carries obfuscation parameters — the old code called the
  /// plain Xray path directly, so the main home toggle built the
  /// plain WireGuard outbound and silently ignored all nine AWG
  /// fields, contradicting the editor's "runs on its AmneziaWG
  /// engine" claim. Every other protocol keeps the fallback-group
  /// walk below. Callers that already route (the WireGuard tab,
  /// the editor's test-connect, the Mozilla bootstrap) are
  /// unaffected: they call connectWireGuardWithFallback directly.
  Future<void> connect() async {
    // Build 2065 (item 13): advance the TLS fingerprint rotation
    // cursor once per user connect, before any config is built.
    // Only profiles without their own fingerprint consume a step.
    final sel = selected;
    if (settings.rotateTlsFingerprint &&
        sel != null &&
        sel.fingerprint.isEmpty) {
      settings.tlsFingerprintIndex =
          (settings.tlsFingerprintIndex + 1) %
          tlsFingerprintRotationSet.length;
      unawaited(_save());
    }
    final p = selected;
    if (p != null && p.protocol == Protocol.wireguard) {
      await connectWireGuardWithFallback(p);
      return;
    }
    await _connectWithFallbackGroup();
  }

  /// Per-network winner memory (build 2065, item 4): record the
  /// selected profile as the winner for [networkKey] — called by
  /// the shell only after the tunnel is up AND carried traffic.
  Future<void> rememberWinnerForNetwork(String networkKey) async {
    final p = selected;
    if (p == null || networkKey.isEmpty) return;
    if (settings.lastProfileByNetwork[networkKey] == p.id) return;
    settings.lastProfileByNetwork[networkKey] = p.id;
    await _save();
  }

  /// Preselect the remembered winner for [networkKey], if the
  /// profile still exists. Returns true when a preselect happened.
  bool preselectForNetwork(String networkKey) {
    final id = settings.lastProfileByNetwork[networkKey];
    if (id == null || id.isEmpty) return false;
    if (selectedProfileId == id) return false;
    for (final p in profiles) {
      if (p.id == id) {
        select(p);
        return true;
      }
    }
    return false;
  }

  // Keep-fastest-N per subscription (item 12's prune half)
  // already exists above as [keepFastestInSubscription] with its
  // Accounts-page UI (feature queue #6 landed in an earlier
  // build); build 2065 adds only the scheduled half below and a
  // second entry point for the same action on the servers page.

  /// Scheduled subscription health (build 2065, item 12): when the
  /// owner enabled it and the interval has elapsed, re-test every
  /// profile with the real funnel. Never runs while a tunnel is
  /// up or a scan already runs. Returns true when a run started.
  Future<bool> maybeRunScheduledHealth() async {
    if (!settings.subHealthEnabled) return false;
    if (state.running || scanRunning) return false;
    final now = DateTime.now().millisecondsSinceEpoch;
    final due =
        settings.lastSubHealthAtMs +
        settings.subHealthIntervalHours * 3600 * 1000;
    if (now < due) return false;
    settings.lastSubHealthAtMs = now;
    await _save();
    unawaited(testAllDelays());
    return true;
  }

  /// Connects the selected profile (a manual connect: the
  /// adaptive failover's session counters start over). Throws a
  /// short message on failure. With fallback groups on (build
  /// 2035), a failed connect walks the selected profile's
  /// fallback group — up to 3 further members, each failure
  /// starting that member's cooldown — and only throws when
  /// every tried member failed.
  Future<void> _connectWithFallbackGroup() async {
    _adaptiveFails = 0;
    _adaptiveSwitches = 0;
    // Build 2057 (audit F-M3): every profile this call tries
    // counts against the auto-reconnect episode budget (see
    // [_noteRetryFailed]) — the first try plus each group
    // member below.
    _lastConnectTries = 1;
    // Build 2057 (audit B-M2): a new manual session restarts
    // the probe stretch from the base cadence.
    _adaptiveProbeStreak = 0;
    _adaptiveProbeEveryTicks = 8;
    _adaptiveProbeTicks = 0;
    adaptiveNotice = '';
    try {
      await _connectSelected();
      return;
    } catch (e) {
      if (!settings.adaptiveFailover) rethrow;
      final first = selected;
      if (first == null) rethrow;
      markFallbackFailed(first.id);
      Object? lastError = e;
      var attempts = 0;
      for (final next in fallbackCandidates(first)) {
        if (attempts >= 3) break;
        attempts++;
        _lastConnectTries = 1 + attempts;
        selectedProfileId = next.id;
        try {
          await _connectSelected();
          adaptiveNotice =
              'Fallback group: ${first.name} failed, connected via '
              '${next.name}.';
          notifyListeners();
          return;
        } catch (err) {
          lastError = err;
          markFallbackFailed(next.id);
        }
      }
      adaptiveNotice =
          'Fallback group: ${first.name} failed and no other member '
          'in its group connected.';
      notifyListeners();
      throw lastError ?? e;
    }
  }

  Future<void> _connectSelected() async {
    final p = selected;
    if (p == null) throw StateError('no-profile');
    if (!p.protocol.supportedByCore) throw StateError('unsupported');
    // A Shadowsocks plugin is stored but never applied (build
    // 2057, audit F-M11): the core has no plugin support, so say
    // so in the diagnostics at connect time — the home card
    // badges the profile too, and neither leaves the handshake
    // failure unexplained.
    if (p.hasUnsupportedPlugin) {
      diagnostics.add(
        'ss',
        'Plugin "${p.plugin}" is not applied — the core has no '
            'plugin support; this session connects without it.',
        ok: false,
      );
    }
    // A fresh connect supersedes a pending retry (build 2042).
    _cancelReconnectTimer();
    // A full connect supersedes any switch in flight (build 2039).
    _tunnelGen++;
    connecting = true;
    lastError = null;
    exitInfo = null;
    notifyListeners();
    try {
      // One tunnel at a time: the Mozilla engine goes off first.
      await stopOtherEngine?.call();
      if (state.running) await _stopTunnel();
      if (networkFp.isEmpty) await refreshNetworkFingerprint();
      // Fast path (build 2029A): a shape that already proved
      // itself on THIS network is dialed directly, without
      // re-running any funnel.
      final win = shapeCache.lookup(p.id, networkFp);
      final dialProfile = win == null ? p : profileWithShape(p, win.shapeId);
      _wdShape = win?.shapeId ?? shapeStock;
      _resetWatchdogBases();
      if (win != null && win.shapeId != shapeStock) {
        diagnostics.add(
          'connect',
          'Fast path: the ${shapeLabel(win.shapeId)} shape won '
              'on this network before (${win.rttMs} ms) — dialing '
              'it directly.',
          ok: true,
        );
      }
      // The chain (build 2029A): the Psiphon underlay comes up
      // FIRST and must prove its handshake before Xray starts;
      // the native ChainSupervisor then owns its health for
      // the session's life.
      final chained = settings.underlay == 'psiphon';
      final warpChained = settings.underlay == 'warp';
      final dnsttChained = settings.underlay == 'dnstt';
      ({String region, String upstream, List<String> protocols})? chainParams;
      if (chained) {
        chainNotice = '';
        _lastChainProblem = '';
        chainParams = await _startUnderlay();
      }
      // The Warp chain (build 2030) starts in the opposite
      // order: the warp core's egress must ride Xray's
      // exit-node, so Xray (with its secondary inbound) starts
      // FIRST, and the core is spawned against it right after;
      // its readiness — a gateway proven through the exit —
      // completes the connect below.
      var warpArgs = const <String>[];
      if (warpChained) {
        chainNotice = '';
        _lastChainProblem = '';
        warpArgs = buildWarpArgs(
          warpProfile,
          upstream: 'socks5://127.0.0.1:$warpExitPort',
        );
        diagnostics.add(
          'chain',
          'Chaining over EmberWarp: the warp core’s egress '
              'will ride this session’s exit-node.',
        );
      }
      // The DNSTT chain (build 2072): like Psiphon, the
      // client comes up FIRST and must open its listener
      // before Xray starts; the native ChainSupervisor then
      // owns its health for the session's life.
      var dnsttArgs = const <String>[];
      if (dnsttChained) {
        chainNotice = '';
        _lastChainProblem = '';
        dnsttArgs = await _startDnsttUnderlay();
      }
      // WireGuard over WebSocket (build 2072): the forwarder
      // comes up before the config is built, because the
      // built config points the peer at it. An unusable URL
      // is called out in the diagnostics and the session
      // connects directly rather than into a dead port.
      var wgWstunnelOn = false;
      var wstunnelArgs = const <String>[];
      _sessionWgWstunnelPort = 0;
      if (p.protocol == Protocol.wireguard && settings.wgWstunnel) {
        if (!isWstunnelUrl(settings.wgWstunnelUrl)) {
          diagnostics.add(
            'wstunnel',
            'WireGuard over WebSocket is on but the wstunnel '
                'URL is not a ws:// or wss:// address — this '
                'session connects directly.',
            ok: false,
          );
        } else {
          wstunnelArgs = buildWstunnelArgs(
            url: settings.wgWstunnelUrl,
            host: p.address,
            port: p.port,
          );
          await _startWstunnel(wstunnelArgs);
          wgWstunnelOn = true;
          _sessionWgWstunnelPort = wstunnelListenPort;
        }
      }
      final config = buildTunnelConfig(
        dialProfile,
        settings,
        psiphonUnderlay: chained,
        warpUnderlay: warpChained,
        warp: warpProfile,
        dnsttUnderlay: dnsttChained,
        wgWstunnelPort: _sessionWgWstunnelPort,
      );
      await XrayPlatform.setOn(
        config: config,
        name: p.name,
        socksPort: settings.socksPort,
        dns: settings.localDns,
        ipv6: settings.ipv6Route,
        mtu: settings.tunnelMtu,
        socksUser: _lanUser,
        socksPass: _lanPass,
        killSwitch: settings.killSwitch,
        underlay: chained
            ? 'psiphon'
            : warpChained
            ? 'warp'
            : dnsttChained
            ? 'dnstt'
            : 'none',
        underlayRegion: chainParams?.region ?? '',
        underlayUpstream: chainParams?.upstream ?? '',
        underlayProtocols: chainParams?.protocols ?? const [],
        warpArgs: warpArgs,
        dnsttArgs: dnsttArgs,
        wgWstunnel: wgWstunnelOn,
        wstunnelArgs: wstunnelArgs,
      );
      // The service reports itself once the tunnel is really up.
      for (var i = 0; i < 40; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        state = await XrayPlatform.state();
        if (state.running) break;
      }
      if (!state.running) throw StateError('start-failed');
      if (warpChained && !await _awaitWarpReady(warpArgs)) {
        // Xray is up but the underlay never proved itself:
        // tear the whole session down rather than showing a
        // chained "Connected" over a dead warp core.
        await _stopTunnel();
        throw StateError('underlay-failed');
      }
      _connectedProfileId = p.id;
      // The session is up and nobody disconnected it (build
      // 2042): a later unexpected drop may auto-reconnect it.
      _expectRunning = true;
      _reconnectKind = 'xray';
      _lastSample = state;
      _lastSampleAt = DateTime.now();
      _startPolling();
      _fetchExitInfo();
    } catch (e) {
      // A chained start that failed must not leave the
      // underlay running with nothing above it (build 2029A):
      // reap it here; a live Xray session reaps it natively.
      if (settings.underlay == 'psiphon' && !state.running) {
        unawaited(PsiphonPlatform.stop());
      }
      if (settings.underlay == 'warp' && !state.running) {
        unawaited(WarpPlatform.stop());
      }
      if (settings.underlay == 'dnstt' && !state.running) {
        unawaited(DnsttPlatform.stop());
      }
      if (!state.running) {
        unawaited(WstunnelPlatform.stop());
      }
      lastError = e.toString();
      rethrow;
    } finally {
      connecting = false;
      notifyListeners();
    }
  }

  /// A manual disconnect also ends the adaptive failover's
  /// session: counters and notice reset.
  Future<void> disconnect() async {
    // A manual disconnect ends the auto-reconnect episode too
    // (build 2042): the expectation flag clears first, so a
    // poll tick landing mid-stop can never schedule a retry.
    _expectRunning = false;
    _cancelReconnect();
    _adaptiveFails = 0;
    _adaptiveSwitches = 0;
    adaptiveNotice = '';
    awgFallbackNotice = '';
    // A switch in flight must not resurrect the tunnel after a
    // manual disconnect (build 2039).
    _tunnelGen++;
    switchNotice = '';
    switchingProfileId = null;
    await _stopTunnel();
  }

  Future<void> _stopTunnel() async {
    // Count the tail of the session while the core is still up.
    if (state.running) await _pollStats();
    await XrayPlatform.stop();
    for (var i = 0; i < 20; i++) {
      state = await XrayPlatform.state();
      if (!state.running) break;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    state = await XrayPlatform.state();
    _connectedProfileId = '';
    _sessionWgWstunnelPort = 0;
    exitInfo = null;
    // Build 2050: the session's final totals reach disk even
    // when the last debounced write is still pending.
    await _flushStatsSave();
    notifyListeners();
  }

  // ---- tests --------------------------------------------------------------

  /// The real delay of one profile, run through a throwaway core.
  /// Build 2032: the same test also captures the exit identity
  /// through the test core (the v2go fold-in) and stores it on
  /// the profile, so the list shows where a config exits
  /// without connecting to it.
  Future<int> testDelay(Profile p) async {
    if (!p.protocol.supportedByCore) return -1;
    _testing.add(p.id);
    notifyListeners();
    try {
      final r = await XrayPlatform.measureDelayEx(buildTestConfig(p, settings));
      final ms = (r['ms'] as num?)?.toInt() ?? -1;
      p.delayMs = ms;
      p.delayFailed = ms < 0;
      if (ms >= 0) {
        final ip = (r['ip'] as String?) ?? '';
        final cc = (r['countryCode'] as String?) ?? '';
        if (ip.isNotEmpty) p.exitIp = ip;
        if (cc.isNotEmpty) p.exitCountryCode = cc;
      }
      await _save();
      return ms;
    } catch (_) {
      p.delayMs = -1;
      p.delayFailed = true;
      await _save();
      return -1;
    } finally {
      _testing.remove(p.id);
      notifyListeners();
    }
  }

  /// Asks the running Test All funnel to stop: stages finish
  /// the item in flight and take no new ones. Profiles the
  /// funnel never reached keep their previous results.
  void stopTestAll() {
    _scanCancel = true;
  }

  Future<void> _markScanFailed(Profile p) async {
    p.delayMs = -1;
    p.delayFailed = true;
    await _save();
    notifyListeners();
  }

  /// Test All, as a funnel (build 2026, Stage A — MLM's
  /// measurement order): cheap TCP probes first, a TLS-SNI
  /// pre-check second, then the real proxied-request tests
  /// through throwaway cores, fed fastest-stage-1-answer first.
  /// The ranking afterwards is by the REAL test alone (the
  /// servers page sorts by delayMs, as before). Cancellable via
  /// [stopTestAll]. The funnel's cheap-stage verdicts follow
  /// scan_probes.dart's rules: an IP-literal stage-1 failure and
  /// any stage-2 failure are final; a domain-address stage-1
  /// failure falls through to the real test (the system resolver
  /// behind the probe may be the poisoned one); UDP-only
  /// protocols skip the cheap stages entirely.
  /// Runs the funnel over [only] when given (build 2033:
  /// the servers page passes the profiles its current
  /// search/filter actually shows, so a filtered view tests
  /// what the user sees — before, Test All always ran the
  /// whole store and overwrote results the user had filtered
  /// away). Returns true when the run was cancelled.
  Future<bool> testAllDelays({List<Profile>? only}) async {
    if (scanRunning) return _scanCancel;
    final seenIds = <String>{};
    final all = (only ?? profiles)
        .where((p) => p.protocol.supportedByCore && seenIds.add(p.id))
        .toList();
    _scanCancel = false;
    scanRunning = true;
    scanPhase = 'tcp';
    scanTotal = all.length;
    scanDone = 0;
    scanAlive = 0;
    notifyListeners();
    try {
      final tcpMs = <String, int>{};
      final survivors = <Profile>[];
      final realtime = <Profile>[];
      final fallThrough = <Profile>[];

      // Stage 1 — TCP probes, wide and cheap (32 at a time).
      final stage1 = <Profile>[];
      for (final p in all) {
        if (funnelSkipsCheapStages(p)) {
          realtime.add(p);
          scanDone++;
        } else {
          stage1.add(p);
        }
      }
      notifyListeners();
      await _funnelPool(stage1, 32, (p) async {
        final ms = await tcpProbe(p.address, p.port);
        scanDone++;
        if (ms >= 0) {
          tcpMs[p.id] = ms;
          survivors.add(p);
        } else if (!isIpLiteralAddress(p.address)) {
          fallThrough.add(p);
        } else {
          await _markScanFailed(p);
        }
        notifyListeners();
      });

      // Stage 2 — TLS-SNI pre-check on the TLS survivors
      // (REALITY and plain streams pass through untouched:
      // there is no SNI handshake of that shape to pre-check).
      if (!_scanCancel) {
        scanPhase = 'tls';
        scanDone = 0;
        scanTotal = survivors.length;
        notifyListeners();
        final tlsChecked = <Profile>[];
        await _funnelPool(survivors, 16, (p) async {
          scanDone++;
          if (p.security != 'tls') {
            tlsChecked.add(p);
          } else if (await tlsSniAnswers(p.address, p.port, funnelSniOf(p))) {
            tlsChecked.add(p);
          } else {
            await _markScanFailed(p);
          }
          notifyListeners();
        });
        survivors
          ..clear()
          ..addAll(tlsChecked);
      }

      // Stage 3 — the real tests, bounded like before (4 cores
      // at a time), fed in funnel order.
      var feed = <Profile>[];
      if (!_scanCancel) {
        scanPhase = 'real';
        scanDone = 0;
        scanAlive = 0;
        feed = funnelStage3Order(
          survivors: survivors,
          tcpMs: tcpMs,
          realtime: realtime,
          fallThrough: fallThrough,
        );
        scanTotal = feed.length;
        notifyListeners();
        await _funnelPool(feed, settings.testAllConcurrency.clamp(1, 8), (
          p,
        ) async {
          final ms = await testDelay(p);
          scanDone++;
          if (ms >= 0) scanAlive++;
          notifyListeners();
        });
      }

      // Stage 4 — endurance qualification (build 2029A): the
      // top-3 survivors of the real test must HOLD a session,
      // not just answer once. Three probes at 0/+2.5/+5.4 s
      // ride ONE keep-alive connection through a fresh core;
      // a profile that freezes after the handshake fails here
      // even though stage 3 graded it alive. Winners are
      // remembered per network (the winning-shape cache), so
      // the next connect on this network starts proven.
      if (!_scanCancel && feed.isNotEmpty) {
        if (networkFp.isEmpty) await refreshNetworkFingerprint();
        final ranked = feed.where((p) => p.delayMs >= 0).toList()
          ..sort((a, b) => a.delayMs.compareTo(b.delayMs));
        final top = ranked.take(3).toList();
        if (top.isNotEmpty) {
          scanPhase = 'endurance';
          scanDone = 0;
          scanTotal = top.length;
          notifyListeners();
          await _funnelPool(top, 3, (p) async {
            final r = await XrayPlatform.endurance(
              buildTestConfig(p, settings),
            );
            scanDone++;
            if (r != null && r['held'] == 1) {
              diagnostics.add(
                'scan',
                '${p.name} held a session through 5.4 s '
                    '(probes ${r['p0']} / ${r['p1']} / ${r['p2']} ms).',
                ok: true,
              );
              shapeCache.record(
                p.id,
                networkFp,
                shapeStock,
                r['p0'] ?? p.delayMs,
              );
            } else {
              diagnostics.add(
                'scan',
                '${p.name} answered the quick test but its '
                    'session froze within seconds (probes '
                    '${r?['p0'] ?? -1} / ${r?['p1'] ?? -1} / '
                    '${r?['p2'] ?? -1} ms).',
                ok: false,
              );
            }
            notifyListeners();
          });
          await _save();
        }
      }
    } finally {
      scanRunning = false;
      scanPhase = '';
      notifyListeners();
    }
    return _scanCancel;
  }

  /// A bounded worker pool over [items]; stops taking new items
  /// once the run is cancelled.
  Future<void> _funnelPool(
    List<Profile> items,
    int width,
    Future<void> Function(Profile) job,
  ) async {
    var index = 0;
    Future<void> worker() async {
      while (index < items.length && !_scanCancel) {
        final p = items[index++];
        await job(p);
      }
    }

    await Future.wait([for (var i = 0; i < width; i++) worker()]);
  }

  /// The sandbox test of one profile (build 2061, feature queue
  /// #1): one throwaway core proves delay + hold + exit in a
  /// single run, on a free port — the live tunnel is never
  /// touched. Like [testDelay] it stores the delay/exit on the
  /// profile when the test answers, and marks the delay failed
  /// when it does not.
  Future<SandboxTestResult> sandboxTest(Profile p) async {
    if (!p.protocol.supportedByCore) {
      return SandboxTestResult.failed('protocol not supported by the core');
    }
    _testing.add(p.id);
    notifyListeners();
    try {
      final r = SandboxTestResult.fromMap(
        await XrayPlatform.sandboxTest(buildTestConfig(p, settings)),
      );
      if (r.ok) {
        p.delayMs = r.delayMs;
        p.delayFailed = false;
        if (r.exitIp.isNotEmpty) p.exitIp = r.exitIp;
        if (r.countryCode.isNotEmpty) p.exitCountryCode = r.countryCode;
      } else {
        p.delayMs = -1;
        p.delayFailed = true;
      }
      await _save();
      return r;
    } catch (_) {
      p.delayMs = -1;
      p.delayFailed = true;
      await _save();
      return SandboxTestResult.failed('the sandbox test did not answer');
    } finally {
      _testing.remove(p.id);
      notifyListeners();
    }
  }

  /// The download rate (bytes/s) through one profile's own core.
  Future<int> testSpeed(Profile p) async {
    if (!p.protocol.supportedByCore) return -1;
    _testing.add(p.id);
    notifyListeners();
    try {
      return await XrayPlatform.speedTest(buildTestConfig(p, settings));
    } catch (_) {
      return -1;
    } finally {
      _testing.remove(p.id);
      notifyListeners();
    }
  }

  // ---- logs ---------------------------------------------------------------

  /// The tails of the core logs, newest content last. The
  /// diagnostics journal's mirror (build 2029A) leads, so the
  /// plain-language record — checks, watchdog escalations,
  /// chain events — is the first thing on the page.
  Future<String> readLogs() async {
    final dir = await workDir();
    final out = StringBuffer();
    final diagFile = File('${dir.path}/diagnostics.log');
    out.writeln('—— diagnostics ——');
    try {
      if (await diagFile.exists()) {
        final lines = await diagFile.readAsLines();
        out.writeln(
          lines.skip(lines.length > 120 ? lines.length - 120 : 0).join('\n'),
        );
      } else {
        out.writeln('(none yet)');
      }
    } catch (e) {
      out.writeln('($e)');
    }
    for (final name in ['xray.log', 'tunlink.log', 'crash.log']) {
      // Build 2068: crash.log is the native crash recorder's
      // file and lives in filesDir itself, one level above
      // this engine's workDir — surfaced here too because this
      // viewer is the app's general diagnostics surface.
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
    // Build 2072: the DNSTT + wstunnel helpers' logs, in
    // their own directories beside this engine's workDir.
    // Each stream gets its own section, never merged — a
    // helper silent on stdout (both are; their diagnostics
    // ride stderr) must never read as if stderr were stdout.
    for (final name in [
      'dnstt/dnstt-stdout.log',
      'dnstt/dnstt-stderr.log',
      'wstunnel/wstunnel-stdout.log',
      'wstunnel/wstunnel-stderr.log',
    ]) {
      final file = File('${dir.parent.path}/$name');
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

  /// Build 2070 (review §3.4): Clear means ALL of it — every
  /// file this viewer displays (diagnostics.log and the shared
  /// crash.log included; previously only xray.log + tunlink.log
  /// were emptied, so a "cleared" page still showed the journal
  /// and the crash records). crash.log is the recorder's shared
  /// file in filesDir: clearing it here empties it for every
  /// engine's viewer, which is the owner's reproduce-then-paste
  /// loop working as intended. crash.log.old — the recorder's
  /// rotation archive, never displayed — is left alone.
  Future<void> clearLogs() async {
    final dir = await workDir();
    for (final name in ['xray.log', 'tunlink.log', 'diagnostics.log']) {
      try {
        await File('${dir.path}/$name').writeAsString('');
      } catch (_) {
        // Not there yet.
      }
    }
    // Build 2072: Clear empties the helper logs this viewer
    // displays too (the 2070 rule: every displayed file).
    for (final name in [
      'dnstt/dnstt-stdout.log',
      'dnstt/dnstt-stderr.log',
      'wstunnel/wstunnel-stdout.log',
      'wstunnel/wstunnel-stderr.log',
    ]) {
      try {
        await File('${dir.parent.path}/$name').writeAsString('');
      } catch (_) {
        // Not there yet.
      }
    }
    try {
      await File('${dir.parent.path}/crash.log').writeAsString('');
    } catch (_) {
      // Not there yet.
    }
  }
}
