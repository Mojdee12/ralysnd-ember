/// The V2Ray engine's brain: the user's profiles and subscriptions,
/// their persistence, and the tunnel's on/off state — everything the
/// Ember UI binds to.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../atomic_json_store.dart';
import '../core/android_core.dart';
import '../core/poll_policy.dart';
import '../net/geo_country.dart';
import '../net/launcher_shortcuts.dart';
import '../net/network_info.dart';
import '../net/service_check.dart';
import '../net/tcp_ping.dart';
import '../psiphon/psiphon_platform.dart';
import 'config_builder.dart';
import 'diagnostics.dart';
import 'dnscrypt_config.dart';
import 'dnstt_args.dart';
import 'dnstt_platform.dart';
import 'olcrtc_args.dart';
import 'olcrtc_platform.dart';
import 'exit_info.dart';
import 'fallback_groups.dart';
import 'lantern_import.dart';
import 'clash_import.dart';
import 'dpi_lab.dart';
import 'dpi_remote.dart';
import 'link_parser.dart';
import 'mieru_config.dart';
import 'profile_codec.dart';
import 'provider_dns.dart';
import 'reconnect_policy.dart';
import 'sandbox_test.dart';
import 'scan_probes.dart';
import 'shape_cache.dart';
import 'shapes.dart';
import 'sidecar_platform.dart';
import 'singbox_config.dart';
import 'sudoku_config.dart';
import 'hwid.dart';
import '../regionhop/regionhop_client.dart';
import 'iran_features_2147.dart';
import 'sub_fetcher.dart';
import 'traffic_history.dart';
import 'warp_args.dart';
import 'warp_platform.dart';
import 'wg_conf.dart';
import 'wstunnel_args.dart';
import 'wstunnel_platform.dart';
import 'xray_models.dart';
import 'zapret_args.dart';
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

/// The state of a "keep only the fastest N" prune plan
/// (build 2076, feature queue #6).
enum FastestPruneState {
  /// A real ranking exists: more than [n] measured configs,
  /// so the fastest N are a measurement, not a guess.
  ready,

  /// No profile in scope carries a delay result at all — the
  /// sheet offers to run Test All first instead of pruning blind.
  noResults,

  /// There are results, but no more than [n] of them are
  /// eligible — the fastest N cannot be picked from
  /// measurements alone without deleting configs that were
  /// never measured.
  nothingToPrune,
}

/// The plan for one "keep only the fastest N" prune (build
/// 2076, feature queue #6): computed pure from the scope, so
/// the confirmation sheet can state exact counts before
/// anything is deleted, and so tests can drive it without a
/// controller. [keep] + [remove] always partition the scope
/// in the ready state; in the other states [remove] is empty
/// and [keep] is the whole scope.
class FastestPrunePlan {
  const FastestPrunePlan({
    required this.state,
    required this.n,
    required this.scopeTotal,
    required this.testedCount,
    required this.eligibleCount,
    required this.keep,
    required this.remove,
    required this.activeKeptOutsideN,
  });

  final FastestPruneState state;

  /// The N the plan was computed for.
  final int n;

  /// Profiles in the pruned scope, tested or not.
  final int scopeTotal;

  /// Profiles in scope carrying a delay result (delayMs >= 0),
  /// whether or not their exit country is excluded.
  final int testedCount;

  /// Tested profiles that may be kept: measured and not
  /// country-excluded.
  final int eligibleCount;

  /// The profiles that survive the prune, fastest first.
  final List<Profile> keep;

  /// The profiles the prune deletes.
  final List<Profile> remove;

  /// The active (selected / connected) profile, when it fell
  /// outside the fastest N and was kept anyway — it counts
  /// outside N, and the sheet says so.
  final Profile? activeKeptOutsideN;

  /// How many of the removed profiles were never measured
  /// (no delay result): they sort last, so they are the
  /// first to go once a real ranking exists.
  int get untestedRemoved => remove.where((p) => p.delayMs < 0).length;

  bool get hasRemovals => remove.isNotEmpty;
}

/// Plans a "keep only the fastest N" prune of [scope]
/// (build 2076, feature queue #6). Pure: no store, no I/O.
///
/// Policy — the feature's owner-approved shape, replacing
/// the 2033 rule under which untested profiles always stayed:
/// profiles rank by stored delayMs ascending, untested
/// profiles (no delay) sort LAST, the N fastest are kept and
/// the rest are deleted. A profile whose observed exit
/// country is in [excludedCountries] is never one of the kept
/// fastest (the 2075 item-16 rule: automatic selection skips
/// excluded exits — preserved here, not silently dropped).
/// The active profile ([activeId], the connected one, or
/// [selectedId], the selected one) is NEVER deleted: when it
/// falls outside the fastest N it is kept anyway, outside N,
/// and reported in [FastestPrunePlan.activeKeptOutsideN].
/// The prune only runs on a real ranking: it needs more than
/// N eligible (measured, non-excluded) profiles — with N or
/// fewer, [FastestPruneState.nothingToPrune] says so instead
/// of deleting configs that were never measured.
FastestPrunePlan planFastestPrune(
  List<Profile> scope,
  int n, {
  String activeId = '',
  String selectedId = '',
  Set<String> excludedCountries = const {},
}) {
  final count = n < 0 ? 0 : n;
  final testedCount = scope.where((p) => p.delayMs >= 0).length;
  bool countryExcluded(Profile p) =>
      p.exitCountryCode.isNotEmpty &&
      excludedCountries.contains(p.exitCountryCode.toUpperCase());
  final ranked =
      scope.where((p) => p.delayMs >= 0 && !countryExcluded(p)).toList()..sort((
        a,
        b,
      ) {
        final byDelay = a.delayMs.compareTo(b.delayMs);
        return byDelay != 0 ? byDelay : a.displayName.compareTo(b.displayName);
      });
  FastestPrunePlan plan(
    FastestPruneState state,
    List<Profile> keep,
    List<Profile> remove,
    Profile? activeKeptOutsideN,
  ) => FastestPrunePlan(
    state: state,
    n: count,
    scopeTotal: scope.length,
    testedCount: testedCount,
    eligibleCount: ranked.length,
    keep: keep,
    remove: remove,
    activeKeptOutsideN: activeKeptOutsideN,
  );
  if (testedCount == 0) {
    return plan(FastestPruneState.noResults, List.of(scope), const [], null);
  }
  if (ranked.length <= count) {
    return plan(
      FastestPruneState.nothingToPrune,
      List.of(scope),
      const [],
      null,
    );
  }
  final keepIds = ranked.take(count).map((p) => p.id).toSet();
  final keep = ranked.take(count).toList();
  // Build 2098 (post-2097 audit M14): BOTH the connected and
  // the selected profile are rescued. The pre-2098 loop broke
  // after the FIRST rescue, so when the connected profile was
  // rescued, a selected profile outside the top-N was pruned —
  // and, since build 2097, tombstoned — leaving a dangling
  // persisted selectedProfileId despite this planner's
  // never-deleted contract for both. activeKeptOutsideN keeps
  // naming the first rescue for the sheet's notice.
  Profile? activeKeptOutsideN;
  for (final id in [activeId, selectedId]) {
    if (id.isEmpty || keepIds.contains(id)) continue;
    for (final p in scope) {
      if (p.id == id) {
        keep.add(p);
        keepIds.add(p.id);
        activeKeptOutsideN ??= p;
        break;
      }
    }
  }
  final remove = scope.where((p) => !keepIds.contains(p.id)).toList();
  return plan(FastestPruneState.ready, keep, remove, activeKeptOutsideN);
}

/// Build 2129 (recycle bin): one entry of the servers
/// page's Recently deleted list — a subscription plus one
/// of its tombstone keys. The display fields are parsed
/// out of the key itself ([parseTombstoneKey]): the
/// tombstone retains no profile name, so an entry is
/// identified by its endpoint, never by a name it does
/// not have.
class DeletedProfileEntry {
  const DeletedProfileEntry({required this.subscription, required this.key});

  final Subscription subscription;
  final String key;

  /// 'vless · node.example.com:443' — or the bare protocol
  /// when the key predates the tombstone shape and its
  /// endpoint cannot be parsed out of it.
  String get label {
    final parsed = parseTombstoneKey(key);
    if (parsed == null) return key.split('|').first;
    return '${parsed.protocol} · ${parsed.address}:${parsed.port}';
  }
}

/// Build 2095 (V2Ray journey audit #10): what a backup
/// restore actually did — the restored counts AND the
/// damaged entries that were skipped, so a restore can no
/// longer report plain success while configs vanish.
class BackupRestoreResult {
  const BackupRestoreResult({
    required this.profiles,
    required this.skippedProfiles,
    required this.subscriptions,
    required this.skippedSubscriptions,
    this.appSettingsJson,
    this.engineSections,
    this.notes = const [],
  });

  final int profiles;
  final int skippedProfiles;
  final int subscriptions;
  final int skippedSubscriptions;

  /// Build 2095 (V2Ray journey audit #15): the backup's
  /// app-settings document, secrets already stripped, for
  /// the caller to apply to the live AppSettings; null when
  /// the backup carries none.
  final Map<String, Object?>? appSettingsJson;

  /// Build 2116 (AB-05): the backup's other-engine
  /// sections (OpenVPN profiles, Psiphon settings, Aether
  /// options), for the caller to apply to those engines'
  /// controllers — the same division of labour as
  /// [appSettingsJson]. Null when the backup carries none.
  final Map<String, Object?>? engineSections;

  /// Build 2095 (third-pass audit 4a-3): bounded transform
  /// notes — values the restore had to change (unknown
  /// protocols read as VLESS, a port pair reset, an MTU
  /// clamped), named instead of applied silently.
  final List<String> notes;

  int get skipped => skippedProfiles + skippedSubscriptions;
}

/// App-settings keys that NEVER ride a backup (build 2095,
/// audit #15): the sync token is a live GitHub credential,
/// and the lock PIN hash would transplant the app lock to
/// another device. Stripped on export AND on import (a
/// backup written by anything else gets the same rule).
const backupSecretSettingsKeys = {'sync_github_token', 'app_lock_pin_hash'};

Map<String, Object?> stripBackupSecrets(Map<String, Object?> doc) =>
    Map<String, Object?>.of(doc)
      ..removeWhere((k, _) => backupSecretSettingsKeys.contains(k));

/// Build 2095 (third-pass audit 2.1): thrown inside a
/// connect when a disconnect (or a newer connect) has
/// superseded it — the attempt unwinds quietly instead of
/// raising the tunnel the user just cancelled.
class _ConnectCancelled implements Exception {
  const _ConnectCancelled();
}

/// Build 2125 (audit A25-22): the store document's decode,
/// top-level so it can run on a background isolate via
/// compute() for large documents (see load()).
Map<String, dynamic> _decodeStoreDocument(String raw) =>
    jsonDecode(raw) as Map<String, dynamic>;

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

  /// Disambiguates subscription ids minted in the same
  /// millisecond (build 2094): the id was the raw timestamp,
  /// so two adds completing within one millisecond — a batch
  /// paste of two subscription URLs against a fast local
  /// panel — shared one id, and the second add's refresh then
  /// removed the first subscription's profiles as its own.
  static int _subIdCounter = 0;

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
  /// 2040, queue 2h): no Xray process, no SOCKS port — the
  /// AmneziaWG device carries the traffic with the
  /// obfuscation the profile carried (build 2104: WG
  /// Tunnel's backend device; builds 2040–2103: the
  /// userspace device in libwg-go.so). Refreshed by
  /// [refreshState] from the platform state, like
  /// [warpSession].
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

  /// Whether the user has explicitly chosen a profile this
  /// session (build 2087, owner report on 2084): set by every
  /// [select] call — server-row taps, the editor's
  /// test-connect, the notification's Switch-server action.
  /// While true, the per-network winner memory
  /// ([preselectForNetwork]) must not override the choice:
  /// an explicit single-config selection is authoritative
  /// until the user changes it. In-memory only — a cold start
  /// may preselect as designed (build 2065, item 4).
  bool _userChoseSelection = false;

  XrayState state = XrayState.stopped;
  bool connecting = false;

  /// The profile an in-flight connect is actually starting
  /// (build 2097, post-2096 audit C-L9): captured by the
  /// attempt itself, because the selection can drift while
  /// it runs (a tap on another server re-points
  /// [selectedProfileId] and [sessionProfile]'s fallback) —
  /// the delete guard below must judge by the attempt's
  /// target, not by wherever the selection sits now.
  String _connectingProfileId = '';
  int upRate = 0;
  int downRate = 0;

  /// The store's complaint, when it has one (build 2071,
  /// review §5.4): set when a save fails or the saved file
  /// was damaged at load, cleared by the next successful
  /// save. [lastError] reports it whenever no fresher
  /// connect error exists, so a failing disk is visible
  /// instead of every change being lost silently, forever.
  String? storeError;

  /// Build 2095 (third-pass audit 1.4): the on-disk store
  /// belongs to a newer build — saves are refused so its
  /// fields survive until the app is updated.
  bool _storeFromNewerVersion = false;

  /// Build 2097 (post-2096 audit C-L7): the store file was
  /// there but UNREADABLE at load (a filesystem error, not
  /// torn bytes) — saves are refused so the intact original
  /// is never overwritten by the in-memory defaults, the
  /// M14 rule the other stores got in 2096. Cleared at
  /// save time if the file has since disappeared.
  bool _storeUnreadable = false;

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

  /// Build 2116 (audit WGX): the live WireGuard session's
  /// exit could not be verified — the one-shot measurement
  /// after adoption failed or returned nothing. The WG
  /// surface shows "Exit: unverified" instead of leaving
  /// the question unasked (up to 2115 the WG leg never
  /// measured its exit at all, so a session exiting in
  /// Iran wore a plain "Connected"). Set only by
  /// [_verifyWgExit]; cleared when a WG attempt starts and
  /// when the tunnel stops. Never a gate: a failed
  /// measurement changes this flag and nothing else.
  bool wgExitUnverified = false;

  /// Set by the shell: stops the Mozilla engine so only one tunnel is
  /// ever up. Returns when that engine is off.
  Future<void> Function()? stopOtherEngine;

  /// Set by the shell: whether launcher shortcuts are on (build
  /// 2093) — the switch lives in AppSettings, which this
  /// controller does not own, so the shell mirrors it the same way
  /// it mirrors the tunnel MTU and the local DNS. True before the
  /// shell wires it, so a starred profile publishes by default.
  bool Function() launcherShortcutsEnabled = () => true;

  /// Republishes the launcher shortcuts for the starred profiles
  /// (build 2093, FlClash 0.9.x): long-press the app icon to
  /// connect straight to a starred config. Best-effort — the
  /// platform call swallows its own failures, and a publish that
  /// cannot happen never blocks starring, saving or connecting.
  /// Called after every change that can move the starred set.
  Future<void> syncLauncherShortcuts() async {
    await LauncherShortcuts.sync(
      enabled: launcherShortcutsEnabled(),
      targets: buildShortcutTargets([
        for (final p in starredProfiles)
          ShortcutTarget(id: p.id, name: p.displayName),
      ]),
    );
  }

  bool _loaded = false;
  bool get loaded => _loaded;

  Timer? _poll;

  /// Build 2095 (V2Ray journey audit #5): the periodic
  /// subscription auto-update cadence (see load()).
  Timer? _subAutoTimer;

  /// Set by dispose(): background completion work (the
  /// geo install) checks it between steps and stops.
  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    // Build 2096 (post-2095 audit L17): the 30-minute
    // auto-update timer was never cancelled — a disposed
    // controller kept sweeping (and saving) forever.
    _subAutoTimer?.cancel();
    _poll?.cancel();
    _statsFlushTimer?.cancel();
    // Build 2125 (audit A25-30 / P-35): the reconnect
    // countdown timer was the one timer dispose() never
    // cancelled — a controller disposed mid-countdown kept
    // a 1 s periodic ticking into the disposed object.
    _reconnectTimer?.cancel();
    super.dispose();
  }
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

  /// The state.sinceMs of the session the connect path's
  /// data-plane proof verified (build 2116, audit AB-01):
  /// samples of that session are stamped
  /// [XrayState.verified] as they are read, so "Connected"
  /// for a plain Xray session means a request carried
  /// through the tunnel — not merely that the VPN service
  /// is running. 0 = no session verified (every session
  /// start has a real sinceMs).
  int _proofVerifiedSinceMs = 0;

  /// Build 2125 (audit A25-11 / P-12): when the latch was
  /// last (re-)proven, and the re-proof machinery around
  /// it. Up to 2124 the latch was for the session's whole
  /// lifetime — a server dying mid-session left the bar
  /// claiming a proof that had only ever passed at connect
  /// time. The latch now expires on a cadence: the poll
  /// re-runs the same data-plane proof, a pass refreshes
  /// the stamp, and a failure CLEARS it (the bar drops to
  /// the honest un-verified wording; nothing is torn down
  /// — the adoption proof's contract, applied mid-session).
  int _proofVerifiedAtMs = 0;
  int _reproofNextAtMs = 0;
  bool _reproofInFlight = false;
  static const int _reproofCadenceMs = 10 * 60 * 1000;

  /// The state.sinceMs the adopted-session proof in
  /// [refreshState] has already been fired for (build
  /// 2119, audit F-02): latched BEFORE the proof starts,
  /// like the adopted pin recomputes, so concurrent
  /// refreshes cannot spawn duplicates and a failed
  /// proof is not retried on every refresh.
  int _adoptionProofFor = 0;

  /// Stamps the data-plane proof flag onto a fresh sample
  /// when it belongs to the verified session.
  XrayState _stampVerified(XrayState s) =>
      s.running && s.sinceMs != 0 && s.sinceMs == _proofVerifiedSinceMs
      ? s.withVerified(true)
      : s;

  /// Build 2125 (audit A25-11 / P-12): the verified
  /// latch's re-proof, driven from the poll. Fires at most
  /// once per [_reproofCadenceMs] per session: when the
  /// latch's proof has aged past the cadence, or when a
  /// previous re-proof failure cleared the latch and the
  /// retry time has come. The WireGuard leg and the
  /// AWG / standalone-WARP sessions are exempt, exactly as
  /// at connect/adoption (their proofs are their own).
  void _maybeReproof(XrayState sample) {
    if (_reproofInFlight) return;
    if (warpSession || awgSession) return;
    if (_connectedProfileId.isEmpty) return;
    final profile = _profileById(_connectedProfileId);
    if (profile == null || profile.protocol == Protocol.wireguard) return;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final latched =
        _proofVerifiedSinceMs != 0 &&
        _proofVerifiedSinceMs == sample.sinceMs;
    if (latched) {
      if (_proofVerifiedAtMs != 0 &&
          nowMs - _proofVerifiedAtMs < _reproofCadenceMs) {
        return;
      }
    } else {
      // Unlatched mid-session: a failed re-proof — or,
      // since build 2126 (A26-07), a failed ADOPTION
      // proof — leaves a live session unlatched with a
      // retry time set; connect latches at connect.
      if (_reproofNextAtMs == 0 || nowMs < _reproofNextAtMs) return;
    }
    _reproofInFlight = true;
    _reproofNextAtMs = nowMs + _reproofCadenceMs;
    final sinceMs = sample.sinceMs;
    unawaited(
      awaitXrayCarries(() {}, freshProof: true)
          .then((carried) {
            _reproofInFlight = false;
            if (!state.running || state.sinceMs != sinceMs) return;
            if (carried) {
              _proofVerifiedSinceMs = sinceMs;
              _proofVerifiedAtMs = DateTime.now().millisecondsSinceEpoch;
              state = state.withVerified(true);
              // Build 2126 (A26-01): the displayed exit
              // data is connect-time too — drop it and
              // let the poll refetch, so the bar's exit
              // line is as fresh as the proof just run.
              exitInfo = null;
              _fetchExitInfo();
              notifyListeners();
            } else if (_proofVerifiedSinceMs == sinceMs) {
              // The proof that stamped this session no
              // longer passes: stop claiming it. The
              // session itself is untouched — the bar
              // drops to the un-verified wording and the
              // next cadence retries the proof.
              _proofVerifiedSinceMs = 0;
              _proofVerifiedAtMs = 0;
              state = state.withVerified(false);
              diagnostics.add(
                'connect',
                'A data-plane re-check no longer passes for '
                    'this session — it stays connected, but it '
                    'is no longer shown as verified.',
                ok: false,
              );
              notifyListeners();
            }
          })
          .catchError((Object _) {
            _reproofInFlight = false;
          }),
    );
  }

  /// Stats-save debounce (build 2050, audit B-M1): totals are
  /// attributed in memory every read, but the write happens
  /// at most every 30 s (and at session end), not on every
  /// 2 s poll that saw traffic. Build 2123 (audit B-02):
  /// the write is the stats SIDECAR, not the whole store —
  /// see _saveStatsSidecar.
  int _lastStatsSaveMs = 0;
  bool _statsSavePending = false;

  /// Build 2125 (audit A25-44): stats deltas consumed
  /// under a profile id no profile currently matches —
  /// held for the first later poll that matches instead
  /// of being dropped (the counters have already advanced
  /// past them). See _pollStats.
  String _heldStatsId = '';
  int _heldStatsUp = 0;
  int _heldStatsDown = 0;

  /// Build 2126 (audit A26-17): when the held delta was
  /// consumed — the traffic history books held bytes at
  /// THIS time, not the applying poll's. The hold itself
  /// is persisted in the stats sidecar (see
  /// _buildStatsDoc), so a kill while held loses nothing.
  int _heldStatsAtMs = 0;

  /// Build 2123 (audit B-01 / P-09): when the native stats
  /// query last ran. The query spawns a fresh libxray.so
  /// process per call, so _pollStats runs it on a 12 s
  /// sub-cadence inside the 2 s poll instead of on every
  /// busy tick (~1,800 spawns/hour while streaming).
  /// Lossless: since build 2125 (audit A25-06) the query
  /// no longer resets the core's counters — deltas are
  /// computed from cumulative values, so the counters
  /// accumulate between reads and the totals come out
  /// identical; the AWG path diffs cumulative counters
  /// the same way. Only the accounting granularity
  /// coarsens.
  int _lastStatsQueryMs = 0;

  /// Build 2116 (AB-14): the pending flush's timer. The
  /// in-poll 30 s save only fires when ANOTHER consume
  /// crosses the line — a burst that ends just after a
  /// save left its tail pending until session end, and a
  /// hard kill in between lost those bytes for good. The
  /// first pending consume now schedules the flush on the
  /// same 30 s cadence, traffic or no traffic.
  Timer? _statsFlushTimer;

  void _scheduleStatsFlush() {
    _statsFlushTimer ??= Timer(const Duration(seconds: 30), () {
      _statsFlushTimer = null;
      unawaited(_flushStatsSave());
    });
  }

  /// Build 2105: the traffic-history store, loaded lazily the
  /// first time a poll records into it (its toggle is on) and
  /// kept for the process. Null until then — and forever when
  /// the toggle stays off.
  TrafficHistoryStore? _trafficHistory;
  Future<TrafficHistoryStore?>? _trafficHistoryLoading;

  Future<TrafficHistoryStore?> _trafficHistoryStore() {
    final loaded = _trafficHistory;
    if (loaded != null) return Future.value(loaded);
    return _trafficHistoryLoading ??= () async {
      try {
        final dir = await workDir();
        await dir.create(recursive: true);
        final store = await TrafficHistoryStore.load(dir.path);
        // Build 2125 (audit A25-48): histories of profiles
        // deleted since the store was last written are
        // pruned at load — age-only pruning left them in
        // the chart picker for up to 90 days.
        store.pruneProfiles(profiles.map((p) => p.id).toSet());
        _trafficHistory = store;
        return store;
      } catch (_) {
        // History is a chart, not the accounting: a store that
        // cannot load must never take the poll down with it.
        // The failure is NOT cached (build 2105, verification
        // iteration 1): a transient error on the first load
        // must not disable recording for the whole process —
        // the next poll tries the load again.
        _trafficHistoryLoading = null;
        return null;
      }
    }();
  }

  /// The history store, loaded on demand — the chart page's
  /// door to the SAME instance the poll records into (a page
  /// loading its own copy would never see this session's
  /// recordings and would diverge from disk).
  Future<TrafficHistoryStore?> loadTrafficHistory() =>
      _trafficHistoryStore();

  /// The loaded history store, for the chart page — null when
  /// nothing has been recorded this process.
  TrafficHistoryStore? get trafficHistory => _trafficHistory;

  /// Build 2105: the provider-DNS pins of the live session,
  /// computed at connect (and at a seamless switch) and reused
  /// by every config rebuild of the session — a watchdog shape
  /// rotation must not silently drop them mid-session.
  Map<String, List<String>> _sessionProviderPins = const {};

  /// Build 2106 (verification iteration 1, M1): the profile
  /// id the adopted-session pin recompute in [refreshState]
  /// has already run (or is running) for. The recompute is
  /// latched per adopted session: without the latch, a
  /// FAILED recompute left the pins empty, the branch's
  /// condition stayed true, and every later refreshState
  /// re-ran a full provider-DNS lookup and — since build
  /// 2106 journals pin outcomes — appended an identical
  /// diagnostics line, for the life of the session. Reset
  /// where the session's pins are reset.
  String _providerPinsAdoptedFor = '';

  /// Build 2110 (fugui-hostname diagnosis C1): the
  /// server-name pins of the live session — the DEFAULT
  /// resolution path (v2rayNG's resolve method "1"), not a
  /// feature: computed at connect / seamless switch like
  /// the provider pins, but carried into every rotation
  /// UNCONDITIONALLY (no settings gate — there is no
  /// toggle), merged under the provider pins per name
  /// (see _mergedServerPins).
  Map<String, List<String>> _sessionServerPins = const {};

  /// Build 2110: the adopted-session recompute latch for
  /// [_sessionServerPins], mirroring [_providerPinsAdoptedFor]
  /// — an adopted session (app restarted over a live
  /// tunnel) has no pins in memory, and its first watchdog
  /// rotation must not silently rebuild the config without
  /// them.
  String _serverPinsAdoptedFor = '';

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
    // Build 2147 (feature #20): the quarantine strike count —
    // per-network handshake-failure accounting on the same
    // failure point the cooldown uses. Gate DEFAULT OFF: a
    // store that never enables it counts nothing.
    if (settings.quarantineEnabled) {
      final p = _profileById(profileId);
      if (p != null && !p.quarantined) {
        final next = nextQuarantineStrikes(p, networkFp);
        p.quarantineStrikes = next.strikes;
        p.quarantineNetwork = next.network;
        if (next.strikes >= 3) {
          p.quarantined = true;
          p.quarantineReason =
              'Failed 3 times on this network (build 2147 quarantine)';
          diagnostics.add(
            'quarantine',
            '${p.name} was quarantined after 3 failed attempts '
                'on this network. It stays in the list and can '
                'be restored from the quarantine surface.',
            ok: false,
          );
        }
      }
    }
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
  /// the connect-time fallback in [connect]. The country
  /// exclusion list (build 2075, item 16) applies here, so
  /// every automatic pick honours it.
  List<Profile> fallbackCandidates(Profile p) =>
      // Build 2147 (features #20/#21a): automatic picks never
      // land on a quarantined profile.
      fallbackOrder(
        all: profiles,
        current: p,
        coolingDownIds: _coolingDownIds,
        excludedCountryCodes: settings.excludedCountries.toSet(),
      ).where((c) => !c.quarantined).toList();

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

  /// DPI Strategy Lab wins per network (build 2107) — see
  /// dpi_lab.dart. Consulted by a connect only while
  /// XraySettings.dpiLabEnabled is on, and only where the
  /// shape cache has no win of its own for the profile.
  DpiLabMemory dpiLabMemory = DpiLabMemory();

  /// Per-config saved Lab results (build 2120) — see
  /// dpi_lab.dart's DpiLabResultBook. Evidence only: the
  /// Lab page shows it with its age; nothing here is
  /// consulted by any connect path (the per-network memory
  /// above is the connect path's record, unchanged).
  DpiLabResultBook dpiLabResults = DpiLabResultBook();

  /// The Lab sweep's unticked candidates (build 2120):
  /// candidate ids the owner has excluded from runs. Empty
  /// (the default, and every pre-2120 store) = the full
  /// sweep. Persisted in the store document beside the Lab
  /// memory.
  Set<String> dpiLabSweepExcluded = {};

  /// Remote DPI Lab strategies installed from the community
  /// feed (build 2114) — see dpi_remote.dart. DATA only:
  /// the Lab consults them exactly like the shipped
  /// candidates, and every consult path still gates on
  /// XraySettings.dpiLabEnabled.
  List<DpiRemoteStrategy> dpiRemoteStrategies = const [];

  /// When the remote strategies were last fetched from the
  /// feed (epoch ms; 0 = never). A store-loaded install
  /// keeps the time its set was fetched at.
  int dpiRemoteUpdatedMs = 0;

  /// The profile whose failed connect the Home card offers
  /// the DPI Lab for (build 2107): set on a terminal attempt
  /// failure while the Lab is on, cleared on the next
  /// attempt, on success, and on disconnect. '' = no offer.
  /// The Lab is only ever OFFERED — it never auto-runs.
  String dpiLabOfferProfileId = '';

  /// The profile the pending Lab offer names, or null when
  /// there is no offer or the profile is gone — the Home
  /// offer names the config that actually failed, not
  /// whichever config's card it happens to render under
  /// (build 2107, verification iteration 1).
  Profile? get dpiLabOfferProfile => _profileById(dpiLabOfferProfileId);

  /// The network fingerprint the most recent Lab run
  /// measured on (build 2107): a win is filed under the
  /// network it was proven on, even if the phone has moved
  /// by the time the user taps Remember.
  String _dpiLabRunFp = '';

  /// A Lab discovery run is in flight (build 2107,
  /// verification iteration 1): the controller refuses a
  /// second concurrent run — two runs would interleave the
  /// journal and race the shared [_dpiLabRunFp].
  bool _dpiLabRunning = false;

  /// The live session was dialed with a remembered Lab
  /// strategy (build 2107, verification iteration 1). The
  /// watchdog's shape escalation stands down for such a
  /// session: its shapes are computed from the STORED profile,
  /// so escalating would silently discard the Lab strategy
  /// (and an af-* candidate has no shape representation at
  /// all), and a shape win recorded from the escalation would
  /// name a config the Lab never graded. Adaptive failover —
  /// server switching, a different mechanism — still owns
  /// recovery, exactly as the AWG watchdog stand-down (build
  /// 2106, F-02) left it to.
  bool _labDialActive = false;
  String _labDialCandidateId = '';

  /// The stand-down has journaled for this session (build
  /// 2107, verification iteration 2): the journal line fires
  /// once per Lab-dialed session, not on every stall cycle.
  bool _labStandDownJournaled = false;

  /// The Lab-dial candidate restored from the store document
  /// at load (build 2107, verification iteration 2): a
  /// Lab-dialed session that survives an app restart is
  /// adopted by [refreshState], which restores the stand-down
  /// from this value — without it the adopted session was
  /// treated as a plain dial and its first stall rotated the
  /// Lab strategy away. Persisted beside connectedProfileId
  /// in the store document ('labDialCandidate').
  String _storedLabDialCandidate = '';

  /// The adoption restore has been attempted in this process
  /// (build 2107, verification iteration 3): refreshState
  /// runs routinely during live sessions, so the restore is
  /// a ONE-SHOT, toggle-gated latch that also CONSUMES the
  /// stored value — otherwise a candidate from a long-dead
  /// session could resurrect onto a later, differently
  /// dialed session (even a different profile) whose only
  /// gate was that the candidate happened to apply to it.
  bool _labAdoptionDone = false;

  /// Clears the Lab-dial session state (the live flags, the
  /// journal latch, and the not-yet-consumed stored
  /// candidate). Called from every session-end path,
  /// including the two that bypass _stopTunnel (the poll
  /// drop branch and refreshState's not-running branch).
  void _clearLabDialState() {
    _labDialActive = false;
    _labDialCandidateId = '';
    _labStandDownJournaled = false;
    _storedLabDialCandidate = '';
  }

  /// The live session's connected profile id, for surfaces
  /// that must distinguish "this config is the session" from
  /// the selection fallback chain (build 2107, verification
  /// iteration 2 — the Lab page's Connect-now reads it).
  String get connectedProfileId => _connectedProfileId;

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

  /// Build 2097 (post-2096 audit N3): a chain applied
  /// while a session is live defers its exit selection to
  /// the session's end — selecting it mid-session
  /// re-pointed the selection (and, where the session
  /// profile falls back to the selection, the session's
  /// own attribution) while the apply message claimed the
  /// running session was untouched. disconnect() consumes
  /// it; the chain page sets it instead of selecting.
  String pendingChainExitId = '';

  /// Build 2087 (analysis A1): the chain path's direct WARP
  /// identity registration already failed in this connect
  /// episode. Provisioning is not candidate-specific, so a
  /// fallback-group walk must not re-run it per member (the
  /// 2084 device log: four start/fail cycles in ~2 s, four
  /// error lines, for one missing identity). Repeat calls in
  /// the episode throw immediately; the flag clears when an
  /// identity is present and at each episode entry
  /// ([connect], [connectWireGuardWithFallback]) — an
  /// auto-reconnect episode re-enters through those, spaced
  /// by its own backoff, and gets one fresh attempt.
  bool _warpProvisionFailed = false;

  /// Build 2050 (audit C-1): when an AmneziaWG profile ends up
  /// running as PLAIN WireGuard because the obfuscated engine
  /// could not start, this says so — the session must never
  /// silently present itself as obfuscated when it is not.
  /// Set by [connectWireGuardWithFallback], cleared on
  /// disconnect and on a real AmneziaWG start. (Build 2104:
  /// a start failure was the only fallback trigger. Build
  /// 2106, journey audit F-01: a started tunnel whose peer
  /// stays silent through the walk's adoption window is a
  /// trigger again — the notice then says the peer did not
  /// answer, not that the engine could not start.)
  String awgFallbackNotice = '';

  /// Build 2106 (journey audit F-04): the one-line home-card
  /// notice for Provider DNS — set by [_providerDnsPins]
  /// when the feature was ON for a connect (or switch) but
  /// no pin landed, so the session the user believes is
  /// protected is visibly unpinned; cleared when a pin
  /// lands, when the feature is off, and on disconnect.
  /// Builds ≤2105 failed every pin silently: the connect
  /// proceeded and nothing anywhere said the protection
  /// had not engaged.
  String providerDnsNotice = '';

  /// Build 2135 (audit A34-02) capped the journaled
  /// "subscription carries no DNS" warning at once per
  /// connect for a profile with a single-slot stamp keyed
  /// on the tunnel generation. Build 2139 (A34-02 re-fix):
  /// the owner's 2026-11-22 journal still showed the line
  /// twice per connect — the single slot is evicted
  /// whenever a call for another profile interleaves
  /// (fallback walk, switch), and the generation advances
  /// on internal stops/retries INSIDE one connect episode,
  /// re-keying the stamp mid-episode. The cap is now a
  /// per-episode SET of profile ids, cleared only at the
  /// episode entries ([connect],
  /// [connectWireGuardWithFallback] — the same doctrine
  /// as [_warpProvisionFailed]); internal retries,
  /// rotations and switches within an episode can never
  /// re-journal the line for a profile.
  final Set<String> _providerDnsNoDnsWarned = <String>{};

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

  /// Build 2098 (post-2097 audit M16): the underlay the
  /// RUNNING session actually started over ('psiphon' /
  /// 'warp' / 'dnstt'; '' when the session is direct or its
  /// underlay is unknown) — captured at connect time in
  /// _connectSelected and cleared with the session in
  /// _stopTunnel. Build 2116 (B13-2): persisted beside the
  /// connected profile id, so a session adopted after a
  /// restart keeps its name too. The underlay
  /// card used to name the live session from the CURRENT
  /// settings value, so changing the chip mid-session
  /// rewrote the running session's own description (and a
  /// 'none' setting fell through to "Psiphon").
  String _sessionUnderlay = '';
  String get sessionUnderlay => _sessionUnderlay;

  /// The local wstunnel forward port of the live session
  /// (build 2072): 0 unless this session's WireGuard profile
  /// runs over WebSocket. Config rotations must keep pointing
  /// the peer at the forwarder, so the value lives for the
  /// session's life and clears in _stopTunnel.
  int _sessionWgWstunnelPort = 0;

  /// The local SOCKS port of the live session's sidecar
  /// engine (build 2075): 0 unless this session's profile is
  /// served by sing-box or the Mieru client. Config rotations
  /// must keep pointing the proxy outbound at the sidecar,
  /// and the poll supervises the sidecar's life alongside
  /// the core's. Clears in _stopTunnel.
  int _sessionSidecarPort = 0;

  /// Build 2095 (third-pass audit 2.6): a sidecar start is
  /// in flight — the port is assigned only when the start
  /// returns, so the port check alone left a window where
  /// a config test could spawn a second sidecar on the
  /// same profile.
  bool _sidecarBusy = false;

  /// Which sidecar serves the live session: '' | 'singbox' |
  /// 'mieru' (build 2075). Set beside [_sessionSidecarPort].
  String _sessionSidecarKind = '';

  /// True while the live session started the DNSCrypt proxy
  /// (build 2075): _stopTunnel reaps it with the session.
  bool _sessionDnsCrypt = false;

  /// The Zapret strategy the live session's desync proxy
  /// was started with (build 2127, H1): '' unless this
  /// session dialed through a DPI Lab zap win. The proxy's
  /// flags are per-candidate, so a seamless switch whose
  /// dial needs a different strategy (or none, or one
  /// where none runs) cannot rotate in place — the proxy
  /// must restart with the config, which only the full
  /// connect path does (see switchServer). Clears in
  /// _stopSidecars, with the proxy itself.
  String _sessionZapretStrategy = '';

  /// Poll-tick counter for the sidecar liveness check
  /// (build 2075): the sidecar's state is read every fifth
  /// tick, not every tick.
  int _sidecarTick = 0;

  /// Build 2125 (audit A25-27): consecutive sidecar
  /// supervision checks that found the process running
  /// but its listener unready — the wedged-listener
  /// debounce (see the supervision block in _pollTick).
  int _sidecarUnreadyTicks = 0;
  bool _statsBusy = false;

  bool isTesting(String id) => _testing.contains(id);

  Profile? get selected {
    for (final p in profiles) {
      if (p.id == selectedProfileId) return p;
    }
    return profiles.isEmpty ? null : profiles.first;
  }

  /// The profile the live session belongs to (build 2083): the
  /// connected profile while a session exists, the selection
  /// while a connect is in flight. The shell's engine chips
  /// read it to tell a WireGuard session from a V2Ray one —
  /// both sections ride this one core (build 2032), so the
  /// bare engine state cannot separate them.
  /// Build 2092 (UI audit item 5): a standalone EmberWarp
  /// session has NO connected profile — it returns null here
  /// instead of borrowing the selection, so neither Xray
  /// section lights or names itself for the underlay's
  /// session.
  Profile? get sessionProfile =>
      warpSession ? null : _profileById(_connectedProfileId) ?? selected;

  Subscription? subscriptionOf(Profile p) {
    for (final s in subscriptions) {
      if (s.id == p.subscriptionId) return s;
    }
    return null;
  }

  List<Profile> profilesOf(Subscription s) =>
      profiles.where((p) => p.subscriptionId == s.id).toList();

  /// Build 2105 (provider DNS): the hosts pins for [p]'s server
  /// hostname, resolved through its subscription's own DNS.
  /// Empty unless the feature is on AND the subscription
  /// carries a DNS AND the address is a hostname AND the lookup
  /// answered — every other case builds the config exactly as
  /// before (see provider_dns.dart's failure doctrine).
  ///
  /// Build 2106 (journey audit F-04): every outcome for an
  /// applicable profile is JOURNALED, and a failure also sets
  /// [providerDnsNotice] — builds ≤2105 returned {} silently
  /// on every path, so on exactly the poisoned networks the
  /// feature exists for, the user believed the server name
  /// was resolved protectively while the connect proceeded
  /// unpinned. The not-applicable cases above (feature off,
  /// sidecar/WG profiles, literal-IP hosts) stay silent:
  /// no protection was ever claimed for them.
  Future<Map<String, List<String>>> _providerDnsPins(Profile p) async {
    if (!settings.providerDnsEnabled) {
      providerDnsNotice = '';
      return const {};
    }
    // Profiles the Xray core does not dial itself never read a
    // hosts pin: sidecar-served protocols resolve their server
    // inside the sidecar, and WG-Tunnel profiles build no Xray
    // config at all. Computing one would be dead work presented
    // as protection. (Build 2106, verification L6: this
    // connect's outcome replaces any earlier pin notice —
    // a stale "did not pin" line must not ride onto a
    // session it does not describe.)
    if (servedViaSidecar(p) || p.protocol == Protocol.wireguard) {
      providerDnsNotice = '';
      return const {};
    }
    final host = p.address.trim();
    if (host.isEmpty || isLiteralServerHost(host)) {
      // A literal needs no pin (verification L6: clear, as
      // above — this connect has no pin outcome to report).
      // Build 2135 (audit A34-02): this early-out runs
      // BEFORE the no-DNS warning below — a literal-IP
      // profile is never resolved at all, so warning that
      // its server name "resolves through the tunnel DNS,
      // unpinned" was doubly wrong. Build 2139 (re-fix):
      // the test is isLiteralServerHost, which also
      // recognises the bracketed and host:port forms a
      // stored address can take — a bare tryParse missed
      // those, and the warning fired for them anyway.
      providerDnsNotice = '';
      return const {};
    }
    final dns = subscriptionOf(p)?.dns.trim() ?? '';
    if (dns.isEmpty) {
      // Build 2139 (A34-02 re-fix): the journal line is
      // capped at once per connect EPISODE for a profile
      // (see _providerDnsNoDnsWarned) — the notice field
      // below is still set on every call: it is per-connect
      // state, not journal.
      if (_providerDnsNoDnsWarned.add(p.id)) {
        diagnostics.add(
          'dns',
          'Provider DNS is on, but the subscription for '
              '${p.name} carries no DNS — its server name '
              'resolves through the tunnel DNS, unpinned.',
          ok: false,
        );
      }
      providerDnsNotice =
          'Provider DNS did not pin ${p.address} — the '
          'subscription carries no DNS.';
      return const {};
    }
    final answers = await resolveViaProviderDns(
      host,
      dns,
      // Build 2116 (B13-5): bootstrap-target accounting
      // lands in the connect journal.
      onNote: (note) => diagnostics.add('dns', note, ok: false),
    );
    if (answers.isEmpty) {
      diagnostics.add(
        'dns',
        'Provider DNS lookup for $host through $dns '
            'returned nothing — connecting without a pin; '
            'the server name resolves through the tunnel '
            'DNS.',
        ok: false,
      );
      providerDnsNotice =
          'Provider DNS did not pin $host — connected '
          'through the tunnel DNS instead.';
      return const {};
    }
    diagnostics.add(
      'dns',
      'Provider DNS pinned $host to '
          '${answers.join(', ')} via the subscription '
          'DNS ($dns).',
      ok: true,
    );
    providerDnsNotice = '';
    // The pin's key is the bare name (the resolver normalizes
    // a trailing-dot FQDN the same way): a dotted key may
    // never match the name the core looks up.
    var key = host.toLowerCase();
    if (key.endsWith('.')) key = key.substring(0, key.length - 1);
    return {key: answers};
  }

  /// Build 2110 (fugui-hostname diagnosis C1): v2rayNG's
  /// resolve method "1" — the DEFAULT resolution path, not
  /// a feature. When [p]'s server address is a domain name,
  /// resolve it HERE, app-side, through the platform
  /// resolver (the lookup v2rayNG makes with InetAddress),
  /// so the config builder can pin the answers into the
  /// config's hosts and stamp the outbound UseIP (see
  /// _stampServerNameResolve in config_builder.dart).
  /// Builds ≤2109 emitted the name as-is: the core's system
  /// dialer then resolved it through Go's pure resolver —
  /// libxray.so is CGO_ENABLED=0, so on Android that falls
  /// back to 127.0.0.1:53 and fails outright, on every
  /// carrier, which is why a hostname-form config only
  /// ever worked with the IP substituted by hand.
  ///
  /// Failure doctrine: a pin can improve a connect, never
  /// break one — an empty/failed lookup returns {} and the
  /// config is built exactly as before. Sidecar-served
  /// profiles are excluded (the core never dials their
  /// names; the sidecar resolves them itself). WireGuard
  /// profiles are NOT excluded: the plain-WG leg and the
  /// WG test configs dial the endpoint through the core.
  /// Answers are IPv4-first, v2rayNG's default family sort.
  /// [journal] is set by the session-establishing callers
  /// (connect / switch) so a Diagnostics export shows the
  /// resolution outcome; the bulk test paths stay silent.
  Future<Map<String, List<String>>> _serverNamePins(
    Profile p, {
    bool journal = false,
  }) async {
    if (servedViaSidecar(p)) return const {};
    var host = p.address.trim();
    if (host.isEmpty || InternetAddress.tryParse(host) != null) {
      return const {};
    }
    List<InternetAddress> found;
    try {
      found = await InternetAddress.lookup(
        host,
      ).timeout(const Duration(seconds: 3));
    } catch (_) {
      if (journal) {
        diagnostics.add(
          'dns',
          'On-device lookup for $host failed — connecting '
              'without a pin; the core resolves the name '
              'itself.',
          ok: false,
        );
      }
      return const {};
    }
    final answers = <String>[
      for (final a in found)
        if (a.type == InternetAddressType.IPv4) a.address,
      for (final a in found)
        if (a.type != InternetAddressType.IPv4) a.address,
    ];
    if (answers.isEmpty) {
      if (journal) {
        diagnostics.add(
          'dns',
          'On-device lookup for $host returned nothing — '
              'connecting without a pin; the core resolves '
              'the name itself.',
          ok: false,
        );
      }
      return const {};
    }
    if (journal) {
      diagnostics.add(
        'dns',
        'Server name $host resolved on-device to '
            '${answers.join(', ')} and pinned into the '
            'config.',
        ok: true,
      );
    }
    if (host.endsWith('.')) host = host.substring(0, host.length - 1);
    return {host.toLowerCase(): answers};
  }

  /// The hosts pins a config build receives: the build-2110
  /// server-name pins with the build-2105 provider-DNS pins
  /// merged over them — per name, the provider answer wins,
  /// because distrusting the local resolver for that name is
  /// the provider feature's whole purpose.
  Map<String, List<String>> _mergedServerPins(
    Map<String, List<String>> serverPins,
    Map<String, List<String>> providerPins,
  ) => {...serverPins, ...providerPins};

  /// Build 2110 (wg-start diagnosis, defect 2): the
  /// engine-switch funnel's Dart half — poll the platform
  /// state until NO engine holds anything (no running
  /// session, no AWG backend tunnel registered) before a
  /// start is issued, instead of assuming the previous
  /// engine's stop landed. `running` flips false before the
  /// AWG backend releases the VPN slot, so the merged flag
  /// alone cannot see the gap this closes. Bounded
  /// (10 × 200 ms): when the bound expires the start
  /// proceeds anyway — the Kotlin engine door now fails
  /// fast and journals a genuinely refused start rather
  /// than swallowing it. [checkAlive] runs per poll and
  /// throws the caller's cancellation.
  Future<void> _awaitPreviousEngineDown(void Function() checkAlive) async {
    for (var i = 0; i < 10; i++) {
      state = await XrayPlatform.state();
      checkAlive();
      if (!state.running && !state.awgTunnelPresent) return;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

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
    // Build 2098 (post-2097 audit M12): docPresent is set
    // when a store document exists and starts decoding;
    // docDecoded when it decodes to its END. A throw
    // mid-document (the 'Infinity' _storedInt throw was one)
    // leaves the tail fields unread; the fingerprint
    // migration must not then run and persist that partial
    // state over the store.
    var docPresent = false;
    var docDecoded = false;
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
          final rawText = await file.readAsString();
          // Build 2125 (audit A25-22 / P-29): a large store
          // document decodes on a background isolate — up
          // to 2124 the whole multi-MB document decoded on
          // the UI isolate at startup while six engine
          // loads raced. Small documents decode inline
          // (an isolate hop costs more than they do).
          decoded = rawText.length > 262144
              ? await compute(_decodeStoreDocument, rawText)
              : _decodeStoreDocument(rawText);
        } on FileSystemException {
          // Build 2097 (post-2096 audit C-L7): the file is
          // there but UNREADABLE (a filesystem error), not
          // torn — build 2096's catch-all treated it as
          // damage: it quarantined an intact file and let
          // the next save overwrite whatever the rename
          // left behind. Now: no quarantine, defaults in
          // memory, and _writeStore refuses to write over
          // the original (see _storeUnreadable).
          _storeUnreadable = true;
          storeError = storeUnreadableMessage;
        } catch (_) {
          storeError =
              'The saved data was damaged and could not be '
              'read, so this section started fresh.';
          // Build 2095 (third-pass audit 1.2): quarantine
          // the damaged bytes BEFORE any save can overwrite
          // them (the migration save below used to destroy
          // the evidence in the same launch).
          try {
            await file.rename('${file.path}.corrupt');
          } catch (_) {
            // A failed quarantine must not block the start.
          }
        }
        if (decoded != null) {
          docPresent = true;
          final doc = decoded;
          // Build 2095 (third-pass audit 1.4): a store
          // written by a NEWER build is never overwritten —
          // this build cannot know its fields, and a
          // whole-state save would strip them permanently.
          final storeVersion = storeSchemaVersion(doc);
          if (storeVersion > 1) {
            _storeFromNewerVersion = true;
            storeError =
                'Your saved data was written by a newer '
                'build of Ember. This build will not '
                'overwrite it — update the app to use it.';
          }
          // Build 2098 (post-2097 audit M13): a FOREIGN
          // document — valid JSON carrying none of the
          // store's keys ({"hello":"world"}) — used to decode
          // tolerantly to empty here, take no protection, and
          // be overwritten by the migration save below or any
          // later save. The other three stores got
          // wrong-shape protection in build 2097 (C-L12); the
          // Xray store, the largest of the four, did not. It
          // is protection-shaped now: surfaced, and
          // _writeStore refuses while the file exists (the
          // _storeUnreadable machinery, C-L7).
          const knownStoreKeys = <String>{
            'schemaVersion',
            'profiles',
            'subscriptions',
            'settings',
            'warpProfile',
            'selectedProfileId',
            'connectedProfileId',
            'cfGoodIps',
            'shapeCache',
          };
          // The same protection covers a document whose
          // core payload keys are present but the wrong
          // SHAPE — profiles not a list, settings not a
          // map: the tolerant decode below would read it as
          // empty and a later save would destroy whatever
          // it actually holds. A store this app wrote
          // always carries a list and a map here.
          final coreWrongShape =
              (doc.containsKey('profiles') && doc['profiles'] is! List) ||
              (doc.containsKey('settings') && doc['settings'] is! Map);
          if ((doc.isNotEmpty && !doc.keys.any(knownStoreKeys.contains)) ||
              coreWrongShape) {
            _storeUnreadable = true;
            // Build 2098 (verification F-A4): a store from a
            // NEWER build whose shape also differs keeps the
            // newer-build guidance set above — telling that
            // user "not in the expected format" would send
            // them hunting corruption when the remedy is to
            // update the app. The protection itself (no
            // overwrite) holds either way.
            if (!_storeFromNewerVersion) {
              storeError =
                  'The saved data was not in the expected '
                  'format, so this section started fresh. The '
                  'original file was left untouched.';
            }
          }
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
          // Build 2095 (third-pass audit 1.1): is-checked
          // reads — a wrong-typed value must not abort the
          // rest of the document's load.
          selectedProfileId =
              doc['selectedProfileId'] is String
                  ? doc['selectedProfileId'] as String
                  : '';
          // Build 2092 (UI audit item 5): the connected
          // profile id is persisted beside the selection, so
          // a session adopted after an app restart is
          // attributed to the profile that actually started
          // it — not to whatever happens to be selected now.
          _connectedProfileId =
              doc['connectedProfileId'] is String
                  ? doc['connectedProfileId'] as String
                  : '';
          // Build 2116 (B13-2): the adopted session's
          // underlay name, restored with its profile id.
          _sessionUnderlay =
              doc['sessionUnderlay'] is String
                  ? doc['sessionUnderlay'] as String
                  : '';
          // Build 2107 (verification iteration 2): the
          // Lab-dial candidate persisted beside it, restored
          // into the watchdog stand-down if refreshState
          // adopts this session (see _storedLabDialCandidate).
          _storedLabDialCandidate = doc['labDialCandidate'] is String
              ? doc['labDialCandidate'] as String
              : '';
          if (doc['warpProfile'] is Map) {
            warpProfile = WarpProfile.fromJson(
              (doc['warpProfile'] as Map).cast<String, dynamic>(),
            );
          }
          cfGoodIps = doc['cfGoodIps'] is List
              ? (doc['cfGoodIps'] as List).map((e) => e.toString()).toList()
              : <String>[];
          // Corrupt entries are dropped by the reader itself —
          // a damaged cache must never take the tab down with it
          // (the device-state rule).
          shapeCache = WinningShapeCache.fromJson(doc['shapeCache']);
          // Build 2114: the remote strategy registry is
          // installed BEFORE the Lab memory is parsed — a
          // remembered win names its candidate, and the
          // memory reader validates 'r-' ids against the
          // registry; parsing memory first would drop every
          // remote win.
          dpiRemoteStrategies = installDpiRemoteStrategies(
            dpiRemoteStrategiesFromJson(doc['dpiRemoteStrategies']),
          );
          dpiRemoteUpdatedMs = doc['dpiRemoteUpdatedMs'] is num
              ? (doc['dpiRemoteUpdatedMs'] as num).toInt()
              : 0;
          dpiLabMemory = DpiLabMemory.fromJson(doc['dpiLabMemory']);
          // Build 2120: the saved-result book parses AFTER
          // the remote install too (a saved row validates
          // its candidate id against the registry, like a
          // remembered win), and books of profiles the store
          // no longer carries are pruned on load.
          dpiLabResults = DpiLabResultBook.fromJson(doc['dpiLabResults']);
          dpiLabResults.pruneProfiles(profiles.map((p) => p.id).toSet());
          dpiLabSweepExcluded = dpiLabSelectionFromJson(
            doc['dpiLabSweepExcluded'],
          );
          docDecoded = true;
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
    // Build 2098 (post-2097 audit M12): a document that
    // exists but did not decode to its end is partial —
    // running the migration over it and saving would persist
    // the partial state over the store's unread tail. The
    // migration simply waits for a clean load.
    if (!settings.fingerprintDefaultMigrated &&
        (!docPresent || docDecoded)) {
      clearParserDefaultFingerprints(profiles);
      settings.fingerprintDefaultMigrated = true;
      fingerprintMigrated = true;
    }
    // Build 2103 (diagnosis N2): the one-time address-name
    // heal — stored profiles whose name is exactly their
    // server address (the value the pre-2103 import
    // fallback manufactured) are renamed to the positional
    // form; a user's rename lives in localName since 2045
    // and is never in the heal's population (scope and the
    // honest edge: healAddressDerivedNames). Same partial-
    // document guard as the fingerprint migration above,
    // and the same immediate persist.
    var addressNamesHealed = false;
    if (!settings.addressNameHealed2103 && (!docPresent || docDecoded)) {
      healAddressDerivedNames(profiles);
      settings.addressNameHealed2103 = true;
      addressNamesHealed = true;
    }
    // Build 2123 (audit B-02): the stats sidecar overlays
    // its volatile fields onto the decoded profiles —
    // after every decode/migration above, before the
    // migration-triggered save below (so that save embeds
    // the overlaid values too). Only on a fully decoded
    // document: a partial decode must never be completed
    // from a second file.
    if (docDecoded) await _overlayStatsSidecar();
    _loaded = true;
    // Build 2103 (verification iteration 2): the defaults
    // term carries the same partial-document guard as its
    // siblings (the 2098 M12 doctrine) — a store that did
    // not decode to its end is never overwritten with the
    // partial in-memory state on this trigger either.
    if (fingerprintMigrated ||
        addressNamesHealed ||
        (settings.defaultsJustMigrated2103 &&
            (!docPresent || docDecoded))) {
      await _save();
    }
    // Publish the decoded store immediately (build 2033,
    // WireGuard audit): the geo install and platform probes
    // below can take seconds, and pages must not sit on a
    // false "empty" state for that whole window.
    notifyListeners();
    _wireDiagnosticsSink();
    unawaited(refreshNetworkFingerprint());
    // Build 2125 (audit A25-22 / P-29): the geo install
    // (~27.9 MB of asset copies on first launch) no
    // longer blocks load()'s future — everything chained
    // on load (the shell's MTU mirror, the shortcut sync)
    // used to wait seconds for it. The future is kept on
    // _geoInstall; the connect funnel awaits it before
    // building a config, which is when the core actually
    // needs the files.
    _geoInstall ??= _installGeoFiles();
    unawaited(_geoInstall!);
    await refreshState();
    // EmberWarp housekeeping (build 2030): finish any renewal
    // settle an interrupted run left staged, and learn the
    // core's state for the card.
    unawaited(WarpPlatform.settle());
    unawaited(refreshWarpState());
    notifyListeners();
    if (settings.subUpdateOnLaunch) unawaited(_autoUpdateStale());
    // Build 2095 (V2Ray journey audit #5): the cadence is
    // periodic, not launch-only. The hours chips promise
    // "hours between automatic updates", but _autoUpdateStale
    // used to run only from load() — an always-open app never
    // refreshed, and with "Update on launch" off the per-sub
    // toggle and the chips controlled nothing at all. The
    // staleness check itself still honours each
    // subscription's own toggle and the hours threshold.
    // Build 2147 (features #17/#21a): the housekeeping
    // timer — scheduled profile tests and the scheduled
    // ping sweep ride it. Both gates DEFAULT OFF; with both
    // off the tick is a no-op and the timer costs nothing.
    _housekeepingTimer2147 ??= Timer.periodic(
      const Duration(minutes: 5),
      (_) => unawaited(_housekeepingTick2147()),
    );
    _subAutoTimer ??= Timer.periodic(const Duration(minutes: 30), (_) {
      unawaited(_autoUpdateStale());
    });
  }

  /// Mirrors the diagnostics journal to diagnostics.log in the
  /// workdir, so the record survives the page and the process.
  /// Build 2095 (audit 6-2): appends since the sink was
  /// wired, for the periodic size re-check.
  int _diagAppends = 0;

  /// Build 2123 (audit F-01, gap 3): rotation bounds.
  static const int _diagRotateBytes = 512 * 1024;
  static const int _diagKeepBytes = 256 * 1024;

  /// Rotates [file] past the bound by KEEPING the newest
  /// half (from a line boundary), with a marker at the cut.
  /// Up to 2122 rotation DELETED the file wholesale, so a
  /// verbose failure storm erased the session's earlier
  /// evidence — the lines a degradation report needs most.
  /// The file stays bounded; the recent evidence survives.
  static Future<void> _rotateDiagnosticsLog(File file) async {
    try {
      // Build 2126 (audit A26-15): ASYNC I/O — up to 2125
      // this read + rewrote up to 512 KB synchronously.
      // Both callers are the sink’s own async chain (or
      // the wiring path), and the sink runs on the UI
      // isolate: a rotation landed as a half-megabyte
      // sync stall exactly during the verbose failure
      // storms that fill the log. The semantics are
      // unchanged (same bound, same kept tail, same
      // marker), and the chain’s ordering still holds —
      // the rotation is awaited inside its chain step.
      final bytes = await file.readAsBytes();
      if (bytes.length <= _diagRotateBytes) return;
      var start = bytes.length - _diagKeepBytes;
      while (start < bytes.length && bytes[start] != 0x0A) {
        start++;
      }
      if (start < bytes.length) start++;
      await file.writeAsBytes(
        <int>[
          ...utf8.encode(
            '—— diagnostics.log rotated: older lines dropped, '
            'newest kept (build 2123) ——\n',
          ),
          ...bytes.sublist(start),
        ],
        flush: true,
      );
    } catch (_) {
      // Evidence housekeeping never breaks the journal.
    }
  }

  Future<void> _wireDiagnosticsSink() async {
    try {
      final dir = await workDir();
      await dir.create(recursive: true);
      final file = File('${dir.path}/diagnostics.log');
      if (await file.exists() && await file.length() > _diagRotateBytes) {
        await _rotateDiagnosticsLog(file);
      }
      // Build 2125 (audit A25-19 / P-30): the sink appends
      // ASYNCHRONOUSLY, on a chained queue. Up to 2124 every
      // journal line did a writeAsStringSync + lengthSync on
      // the CALLER's thread — and the callers are the
      // connect paths, which journal heavily exactly while
      // the UI is animating a connect. Lines now queue in
      // order onto a future chain and the file IO yields
      // between them; ordering is preserved (each append
      // awaits the previous), and a failed append still
      // never breaks the journal.
      var sinkTail = Future<void>.value();
      diagnostics.sink = (line) {
        sinkTail = sinkTail.then((_) async {
          try {
            await file.writeAsString('$line\n', mode: FileMode.append);
            // Build 2095 (third-pass audit 6-2): the size
            // check used to run only when the sink was wired
            // (once per process), so a long session's journal
            // grew unbounded. Re-check every 50 appends and
            // rotate past 512 KB like the wiring-time rule —
            // build 2123: rotate by keeping the tail, never
            // by deleting the whole file.
            if (++_diagAppends % 50 == 0 &&
                await file.length() > _diagRotateBytes) {
              await _rotateDiagnosticsLog(file);
            }
          } catch (_) {
            // Evidence, never a failure.
          }
        });
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
  /// Build 2125 (audit A25-22): the geo install's future,
  /// started (once) by load() without blocking it and
  /// awaited by the connect funnel via _ensureGeoInstalled.
  Future<void>? _geoInstall;

  Future<void> _ensureGeoInstalled() async {
    final pending = _geoInstall;
    if (pending != null) {
      await pending;
      return;
    }
    // load() has not run (a connect before it): install
    // inline, as every build up to 2124 did.
    _geoInstall = _installGeoFiles();
    await _geoInstall;
  }

  Future<void> _installGeoFiles() async {
    try {
      final dir = await workDir();
      await dir.create(recursive: true);
      for (final entry in _geoExpectedBytes.entries) {
        // A disposed controller's install stops between
        // files: the install is background completion
        // work, and writing megabytes more for an owner
        // that is gone helps no one (the next controller's
        // load restarts it — the length check skips
        // whatever already landed whole).
        if (_disposed) return;
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

  /// The whole store as one document, built from MEMORY
  /// (build 2095, third-pass audit 4a-1): the single shape
  /// the disk write and the backup export both use — the
  /// export used to re-read state.json from disk, so an
  /// edit still queued in the save chain (or a torn file)
  /// exported stale or partial state.
  Map<String, Object?> _buildStoreDoc() => {
    'schemaVersion': 1,
    'profiles': profiles.map((p) => p.toJson()).toList(),
    'subscriptions': subscriptions.map((s) => s.toJson()).toList(),
    'settings': settings.toJson(),
    'warpProfile': warpProfile.toJson(),
    'selectedProfileId': selectedProfileId,
    // Build 2092 (UI audit item 5): every save carries
    // the live session's profile id (see the load side).
    'connectedProfileId': _connectedProfileId,
    // Build 2107 (verification iteration 2): the live
    // session's Lab-dial candidate, so an app restart can
    // restore the watchdog stand-down for the adopted
    // session. '' unless a Lab strategy is actually live.
    'labDialCandidate': _labDialActive ? _labDialCandidateId : '',
    // Build 2116 (B13-2, 2098 F6): the live session's
    // underlay, persisted like the connected profile id —
    // an adopted session used to lose it and the home
    // card fell back to the generic "an underlay tunnel".
    'sessionUnderlay': _sessionUnderlay,
    'cfGoodIps': cfGoodIps,
    'shapeCache': shapeCache.toJson(),
    'dpiLabMemory': dpiLabMemory.toJson(),
    // Build 2120: the per-config saved Lab results and the
    // sweep's unticked set ride the same document (and so
    // the same backups) as the Lab memory.
    'dpiLabResults': dpiLabResults.toJson(),
    'dpiLabSweepExcluded': dpiLabSelectionToJson(dpiLabSweepExcluded),
    // Build 2114: the installed remote strategies, in the
    // feed's own document shape — a backup carries them,
    // and the load installs them before the Lab memory is
    // read (see the load side).
    'dpiRemoteStrategies': dpiRemoteStrategiesToJson(dpiRemoteStrategies),
    'dpiRemoteUpdatedMs': dpiRemoteUpdatedMs,
  };

  Future<void> _writeStore() async {
    // Never persist before the store has loaded (build 2033,
    // WireGuard audit): during startup the in-memory lists are
    // still empty, and a save fired that early would overwrite
    // the on-disk store with nothing. The write is whole-state,
    // so skipping it loses nothing — the next save carries
    // everything.
    if (!_loaded) return;
    // Build 2095 (audit 1.4): never overwrite a newer
    // build's store.
    if (_storeFromNewerVersion) return;
    try {
      final file = await _stateFile();
      // Build 2097 (post-2096 audit C-L7): never overwrite
      // an intact-but-unreadable store. If the file has
      // since disappeared there is no original left to
      // protect and saves resume.
      if (_storeUnreadable) {
        if (await file.exists()) return;
        _storeUnreadable = false;
      }
      await file.parent.create(recursive: true);
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(jsonEncode(_buildStoreDoc()), flush: true);
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

  // ---- stats sidecar (build 2123, audit B-02 / P-10) ------
  //
  // The whole-store write re-encodes every profile,
  // subscription and setting on every flush — multi-MB and
  // a main-isolate stall with a large store — yet the hot
  // writers (the 30 s stats flush, a manual delay test)
  // only ever change eight volatile per-profile fields:
  // the traffic totals and the last delay/exit results.
  // Those fields now ALSO live in a small sidecar beside
  // state.json, and the hot writers write only the sidecar
  // (kilobytes, whatever the store size). The main document
  // keeps carrying the same fields — they are its schema —
  // as the fallback for a missing sidecar and for backups.

  Future<File> _statsFile() async {
    final file = await _stateFile();
    return File('${file.parent.path}/stats.json');
  }

  Map<String, Object?> _buildStatsDoc() => {
    'schemaVersion': 1,
    'profiles': {
      for (final p in profiles)
        p.id: {
          'delayMs': p.delayMs,
          'delayFailed': p.delayFailed,
          'delayStage': p.delayStage,
          'totalDown': p.totalDownBytes,
          'totalUp': p.totalUpBytes,
          'statsUpdatedMs': p.statsUpdatedMs,
          'exitIp': p.exitIp,
          'exitCountryCode': p.exitCountryCode,
        },
    },
    // Build 2126 (audit A26-17): an in-flight held delta
    // (A25-44) is part of the document while it exists —
    // up to 2125 it lived only in memory, so a process
    // kill while held lost bytes the native counters had
    // already consumed. Absent whenever nothing is held;
    // older builds ignore the key.
    if (_heldStatsId.isNotEmpty)
      'held': {
        'id': _heldStatsId,
        'up': _heldStatsUp,
        'down': _heldStatsDown,
        'atMs': _heldStatsAtMs,
      },
  };

  /// Serialized through the same chain as the main store,
  /// so a sidecar write can never interleave with a store
  /// write or another sidecar write.
  Future<void> _saveStatsSidecar() {
    _saveChain = _saveChain.then((_) => _writeStatsSidecar());
    return _saveChain;
  }

  Future<void> _writeStatsSidecar() async {
    if (!_loaded) return;
    if (_storeFromNewerVersion) return;
    if (_storeUnreadable) return;
    try {
      final file = await _statsFile();
      await file.parent.create(recursive: true);
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(jsonEncode(_buildStatsDoc()), flush: true);
      await tmp.rename(file.path);
    } catch (_) {
      // A failed sidecar write loses only statistics since
      // the last flush; the main store's embedded copies
      // remain as the fallback. Never surfaced, never fatal.
    }
  }

  /// Overlays the sidecar's volatile fields onto the just-
  /// decoded profiles (load path). Freshness rule: the
  /// sidecar wins only when it was written at least as
  /// recently as state.json. A full save that landed after
  /// the last sidecar write — an import, a subscription
  /// refresh's stat carry, a backup restore — already
  /// carries values at least as new in the main document,
  /// and the overlay must not revert them; the next hot
  /// write re-stamps the sidecar and it leads again.
  /// Best-effort throughout: any failure leaves the main
  /// document's values standing, exactly as before 2123.
  Future<void> _overlayStatsSidecar() async {
    try {
      final statsFile = await _statsFile();
      if (!await statsFile.exists()) return;
      final stateFile = await _stateFile();
      final statsModified = (await statsFile.stat()).modified;
      final stateModified = (await stateFile.stat()).modified;
      if (stateModified.isAfter(statsModified)) return;
      final decoded = jsonDecode(await statsFile.readAsString());
      if (decoded is! Map<String, dynamic>) return;
      final byId = decoded['profiles'];
      if (byId is! Map<String, dynamic>) return;
      for (final p in profiles) {
        final entry = byId[p.id];
        if (entry is! Map<String, dynamic>) continue;
        // Build 2125 (audit A25-37): every numeric field is
        // finite-checked before toInt() — a `1e999` entry
        // parses as double.infinity and its toInt() throws;
        // before this guard one corrupt field abandoned the
        // overlay for this AND every later profile in the
        // loop (the P-16 defect class, repeated in the 2123
        // sidecar). A non-finite field is now skipped alone.
        final delayMs = entry['delayMs'];
        if (delayMs is num && delayMs.isFinite) p.delayMs = delayMs.toInt();
        final delayFailed = entry['delayFailed'];
        if (delayFailed is bool) p.delayFailed = delayFailed;
        final delayStage = entry['delayStage'];
        if (delayStage is String) p.delayStage = delayStage;
        final totalDown = entry['totalDown'];
        if (totalDown is num && totalDown.isFinite) {
          p.totalDownBytes = totalDown.toInt();
        }
        final totalUp = entry['totalUp'];
        if (totalUp is num && totalUp.isFinite) {
          p.totalUpBytes = totalUp.toInt();
        }
        final statsUpdatedMs = entry['statsUpdatedMs'];
        if (statsUpdatedMs is num && statsUpdatedMs.isFinite) {
          p.statsUpdatedMs = statsUpdatedMs.toInt();
        }
        final exitIp = entry['exitIp'];
        if (exitIp is String) p.exitIp = exitIp;
        final exitCountryCode = entry['exitCountryCode'];
        if (exitCountryCode is String) p.exitCountryCode = exitCountryCode;
      }
      // Build 2126 (audit A26-17): restore an in-flight
      // held delta (see _buildStatsDoc) — the first poll
      // that matches its profile applies it as usual.
      final held = decoded['held'];
      if (held is Map<String, dynamic>) {
        final heldId = held['id'];
        final heldUp = held['up'];
        final heldDown = held['down'];
        final heldAt = held['atMs'];
        if (heldId is String &&
            heldId.isNotEmpty &&
            heldUp is num &&
            heldUp.isFinite &&
            heldDown is num &&
            heldDown.isFinite) {
          _heldStatsId = heldId;
          _heldStatsUp = heldUp.toInt();
          _heldStatsDown = heldDown.toInt();
          _heldStatsAtMs = heldAt is num && heldAt.isFinite
              ? heldAt.toInt()
              : 0;
        }
      }
    } catch (_) {
      // Statistics overlay is best-effort by design.
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
    // Build 2075 (feature item 21): a pasted Clash YAML
    // document imports its proxies too, not just links.
    // Build 2096 (post-2095 audit M6): a Clash-SHAPED paste
    // that yields no profiles falls through to the link
    // parser — build 2095 let any stray 'proxies:' line
    // hijack a paste of links into an empty Clash import.
    // Build 2097 (post-2096 audit C-L17): parse once — the
    // 2096 shape probed with a full parse and then parsed
    // the same document again to use the result.
    final clashProbe = looksLikeClashYaml(text)
        ? parseClashYaml(text, newProfileId)
        : null;
    if (clashProbe != null && clashProbe.profiles.isNotEmpty) {
      final clash = clashProbe;
      for (final p in clash.profiles) {
        p.subscriptionId = subscriptionId;
        profiles.add(p);
        if (selectedProfileId.isEmpty) selectedProfileId = p.id;
      }
      if (clash.profiles.isNotEmpty) unawaited(_save());
      notifyListeners();
      return clash.profiles.length;
    }
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
  ///
  /// Build 2094: subscription URLs (see [isSubscriptionUrl])
  /// route to [addSubscription] — before this, a pasted
  /// subscription link fell through to the link parser, which
  /// reads http(s) lines as proxy links or nothing at all, and
  /// the import silently added 0 configs. The result names
  /// every subscription added and how many configs it brought;
  /// a failed fetch joins [errors] like a failed Lantern link.
  Future<
    ({
      int added,
      List<String> errors,
      List<({String name, int configs})> subscriptions,
    })
  >
  importLinksAsync(String text) async {
    // Build 2102 (wg-ipv6-import-diagnosis.md, I2): a pasted
    // WireGuard .conf takes the WG path. Builds ≤2101 read
    // the text line-by-line as links and imported nothing —
    // the general paste import had no .conf detection, so a
    // whole config pasted outside the WireGuard page's own
    // paste button was a dead end. The gate is the shared
    // [isWgConfText]; the parse is the WG importer's own
    // (parseWgConf), deduped on the manual-import key like
    // every branch below, with the counts reported honestly.
    if (isWgConfText(text)) {
      final wg = parseWgConf(text, baseName: 'WireGuard', idFor: newProfileId);
      if (!wg.ok) {
        return (
          added: 0,
          errors: [
            'That text looks like a WireGuard config, but it is '
                'not valid — nothing was imported',
          ],
          subscriptions: const <({String name, int configs})>[],
        );
      }
      final known = profiles.map(profileImportKey).toSet();
      var addedWg = 0;
      var dupesWg = 0;
      for (final p in wg.profiles) {
        if (!known.add(profileImportKey(p))) {
          dupesWg++;
          continue;
        }
        profiles.add(p);
        if (selectedProfileId.isEmpty) selectedProfileId = p.id;
        addedWg++;
      }
      if (addedWg > 0) {
        unawaited(_save());
        notifyListeners();
      }
      return (
        added: addedWg,
        errors: [
          if (dupesWg > 0)
            '$dupesWg duplicate WireGuard '
                '${dupesWg == 1 ? 'config was' : 'configs were'} '
                'skipped (already in the list)',
        ],
        subscriptions: const <({String name, int configs})>[],
      );
    }
    // Build 2075 (feature item 21): a pasted Clash YAML
    // document takes the Clash path (with the same
    // store-wide dedupe as links below).
    // Build 2096 (audit M6): same 0-yield fall-through as
    // importLinks — a stray 'proxies:' line must not
    // swallow a paste of links.
    // Build 2097 (post-2096 audit C-L17): parse once, as
    // in importLinks above.
    final clashProbe = looksLikeClashYaml(text)
        ? parseClashYaml(text, newProfileId)
        : null;
    if (clashProbe != null && clashProbe.profiles.isNotEmpty) {
      final clash = clashProbe;
      // Build 2101 (S4/I1): manual import dedupes on the
      // widened import key (see profileImportKey) — here and
      // in every branch below.
      final known = profiles.map(profileImportKey).toSet();
      var addedClash = 0;
      for (final p in clash.profiles) {
        if (!known.add(profileImportKey(p))) continue;
        profiles.add(p);
        if (selectedProfileId.isEmpty) selectedProfileId = p.id;
        addedClash++;
      }
      if (addedClash > 0) {
        unawaited(_save());
        notifyListeners();
      }
      return (
        added: addedClash,
        errors: [
          if (clash.skipped > 0)
            '${clash.skipped} Clash ${clash.skipped == 1 ? 'entry was' : 'entries were'} '
                'skipped (a type Ember does not serve)',
        ],
        subscriptions: const <({String name, int configs})>[],
      );
    }
    final lanternLinks = <LanternPrivateServerLink>[];
    final subUrls = <String>[];
    final seen = <String>{};
    final seenSubUrls = <String>{};
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
      // Build 2094: a subscription URL leaves the link stream
      // here — the fetcher, not the link parser, owns it. The
      // Lantern check above runs first: a Lantern invite is an
      // https URL too, but it is not a subscription.
      if (isSubscriptionUrl(line)) {
        if (seenSubUrls.add(line)) subUrls.add(line);
        continue;
      }
      // Build 2098 (verification, iteration 2): the RAW
      // line goes into rest — detection above used the
      // trimmed form, but the body fall-through re-parses
      // these lines as one document, and an indented
      // document (block-style Clash YAML) does not survive
      // a per-line trim. parseLinksDetailed trims for its
      // own parsing and keeps both forms of what it skips.
      rest.add(rawLine);
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

    // Build 2094: each subscription URL becomes a real
    // subscription (the same add the QR path and the Accounts
    // sheet run), and its configs count toward [added]. A
    // failed fetch surfaces the fetcher's specific words in
    // [errors] and stores nothing — addSubscription already
    // rolled the half-added subscription back.
    final addedSubs = <({String name, int configs})>[];
    for (final url in subUrls) {
      try {
        final sub = await addSubscription(url);
        final count = profilesOf(sub).length;
        addedSubs.add((name: sub.name, configs: count));
        added += count;
      } catch (e) {
        // Build 2095 (audit 5-6): a pasted cleartext link
        // is skipped with its reason — the opt-in confirm
        // lives on the add paths, not inside a bulk import.
        if (e is StateError && e.message == 'cleartext-subscription') {
          errors.add(
            'A subscription link was skipped: it uses '
            'unencrypted http. Add it from the Subscriptions '
            'tab if you want to confirm it there.',
          );
        } else {
          errors.add(
            subFetchErrorText(
              e,
              fallback: 'A subscription link could not be fetched.',
            ),
          );
        }
      }
    }

    final detailed = parseLinksDetailed(rest.join('\n'));
    final parsed = detailed.profiles;
    // Build 2032 (the v2go fold-in): store-wide identity dedupe
    // on manual import — the same server arriving again, under
    // any name, is not added twice; duplicates within the batch
    // itself collapse too.
    // Build 2101 (settings-dns-2099-diagnosis.md, S4/I1): the
    // dedupe key is the widened profileImportKey — protocol +
    // credentials + endpoint + transport shape + SNI. The old
    // coarse key collapsed a panel's multi-variant issues of
    // one UUID on one endpoint (tcp/ws/grpc, tls/reality,
    // different SNIs) into the first copy, so a batch import
    // "added a few, then stopped". Only a true duplicate —
    // same credentials, endpoint AND shape — collapses now.
    // The duplicate count is reported once, after the body
    // branches below have added their own dupes to it.
    final known = profiles.map(profileImportKey).toSet();
    var skippedDupes = 0;
    for (final p in parsed) {
      if (!known.add(profileImportKey(p))) {
        skippedDupes++;
        continue;
      }
      profiles.add(p);
      if (selectedProfileId.isEmpty) selectedProfileId = p.id;
      added++;
    }
    // Build 2095 (V2Ray journey audit #1): nothing above read
    // the paste — try it as a subscription BODY (a base64 blob
    // or an Xray config-JSON document), the form the paste
    // sheet's own hint promises. parseSubscription's only
    // caller used to be the network fetcher, so a pasted body
    // added 0 with a generic message.
    // Build 2097 (post-2096 audit C-L17): the skipped-lines
    // accounting is per line. Build 2096 set a single
    // bodyConsumed flag whenever a body parse yielded
    // anything, which suppressed the error for lines the
    // body never read (a garbage line riding along with a
    // base64 blob). A skipped line counts as consumed when
    // it parses as a body on its own (a base64 blob line);
    // when NO line does but the joined text did, the body
    // was one multi-line document (a JSON config) and the
    // whole block counts as consumed.
    var unread = detailed.skipped;
    List<String> consumedByBody(List<String> skipped, int bodyYield) {
      if (bodyYield == 0) return const [];
      final singles = skipped
          .where((l) => parseSubscription(l).isNotEmpty)
          .toList();
      if (singles.isNotEmpty) return singles;
      // Build 2098 (post-2097 audit L9): the body was one
      // multi-line document (a JSON config) — but a stray
      // line riding with it is not part of the document and
      // keeps its "could not be read" accounting. A line
      // belongs to the document when removing it lowers the
      // joined parse's yield; a line whose removal changes
      // nothing is a stray. (The pre-2098 code counted every
      // skipped line as consumed in this branch, so the
      // stray vanished from the report entirely.)
      final consumed = <String>[];
      for (final l in skipped) {
        final rest = skipped.where((x) => x != l).join('\n');
        if (parseSubscription(rest).length < bodyYield) consumed.add(l);
      }
      return consumed.isNotEmpty ? consumed : skipped;
    }

    if (added == 0) {
      // Build 2098 (post-2097 audit L9): a Clash-shaped
      // paste the probe above already yielded nothing from
      // is not Clash-parsed a second time here.
      var bodyProfiles = parseSubscription(
        text,
        skipClash: clashProbe != null,
      );
      var bodyText = text;
      var fromJoinedDoc = bodyProfiles.isNotEmpty;
      if (bodyProfiles.isEmpty) {
        // Build 2098 (verification, iteration 2): the
        // skipped lines JOINED, parsed whole — the mixed
        // branch below has always had this stage; this
        // branch lacked it, so a Clash block riding with
        // an unparseable line (a failed subscription URL,
        // say) was lost here but imported when any link
        // also parsed. The join is the RAW lines, so an
        // indented document keeps its structure.
        bodyText = detailed.skippedRaw.join('\n');
        bodyProfiles = parseSubscription(bodyText);
        fromJoinedDoc = bodyProfiles.isNotEmpty;
      }
      if (bodyProfiles.isEmpty) {
        // Build 2097 (post-2096 audit C-L17): the joined
        // parse fails when a body line rides with lines
        // that are not part of the document — try each
        // unread line as a body on its own.
        bodyProfiles = [
          for (final l in unread) ...parseSubscription(l),
        ];
        fromJoinedDoc = false;
      }
      if (bodyProfiles.isNotEmpty) {
        // Build 2098 (verification, iteration 2): a
        // structured document is consumed as a whole or
        // not at all — the per-line removal accounting
        // (consumedByBody) judges a line consumed only
        // when removing it lowers the yield, so a Clash
        // entry's field-only lines (udp:, alpn:, …) were
        // reported "could not be read" after a successful
        // import, and the removal tests re-parsed the
        // whole document once per line. Non-document
        // bodies keep the per-line accounting.
        final consumed =
            (fromJoinedDoc && looksLikeClashYaml(bodyText))
                ? unread
                : consumedByBody(unread, bodyProfiles.length);
        unread = unread.where((l) => !consumed.contains(l)).toList();
        for (final p in bodyProfiles) {
          if (!known.add(profileImportKey(p))) {
            skippedDupes++;
            continue;
          }
          profiles.add(p);
          if (selectedProfileId.isEmpty) selectedProfileId = p.id;
          added++;
        }
      }
    } else if (detailed.skipped.isNotEmpty) {
      // Build 2096 (post-2095 audit M6): a MIXED paste — a
      // readable link line plus a subscription BODY (a
      // base64 blob line) — build 2095 gated the body
      // fall-through on added == 0, so the body's configs
      // were silently lost whenever any link parsed. Try
      // the leftover lines as a body.
      // Build 2098 (verification, iteration 2): the join
      // is the RAW skipped lines — the trimmed join loses
      // an indented document's structure (block-style
      // Clash) before the parse ever sees it.
      final leftovers = detailed.skippedRaw.join('\n');
      // Build 2098 (verification F-A1): the Clash probe ran
      // on the WHOLE paste, not on these leftovers — a
      // subset can be a valid Clash document even when the
      // whole paste is not (one link line breaks the YAML
      // document; the surviving block alone parses). The
      // probe's verdict therefore does NOT carry over here:
      // the leftovers take the full parse, Clash route
      // included, as in 2097. (The added == 0 branch above
      // keeps the skip — there the text IS the probed text.)
      var bodyProfiles = parseSubscription(leftovers);
      final fromJoinedDoc = bodyProfiles.isNotEmpty;
      if (bodyProfiles.isEmpty) {
        // Build 2097 (post-2096 audit C-L17): as in the
        // added == 0 branch — per-line bodies when the
        // joined leftovers are not one document.
        bodyProfiles = [
          for (final l in detailed.skipped) ...parseSubscription(l),
        ];
      }
      if (bodyProfiles.isNotEmpty) {
        // The document consumption rule, as in the
        // added == 0 branch (iteration 2): a Clash-shaped
        // joined body is consumed whole or not at all.
        final consumed =
            (fromJoinedDoc && looksLikeClashYaml(leftovers))
                ? unread
                : consumedByBody(unread, bodyProfiles.length);
        unread = unread.where((l) => !consumed.contains(l)).toList();
        for (final p in bodyProfiles) {
          if (!known.add(profileImportKey(p))) {
            skippedDupes++;
            continue;
          }
          profiles.add(p);
          if (selectedProfileId.isEmpty) selectedProfileId = p.id;
          added++;
        }
      }
    }
    // Build 2147 (feature #18): import safety — while the
    // gate is on, unsupported schemes among the skipped
    // lines are NAMED in the import report, and the parsed
    // profiles' safety warnings + tracker-shaped link
    // payloads ride the same report. Warn, never block.
    if (settings.importSafetyFilter) {
      final unsupported = <String>{};
      for (final l in detailed.skipped) {
        if (isUnsupportedSchemeLink(l)) {
          unsupported.add(linkSchemeOf(l)!);
        }
      }
      if (unsupported.isNotEmpty) {
        errors.add(
          'Unsupported protocol '
              '${unsupported.length == 1 ? 'scheme' : 'schemes'} '
              'skipped: ${unsupported.join(', ')} — no engine in '
              'Ember serves them.',
        );
      }
      for (final p in detailed.profiles) {
        errors.addAll(importSafetyWarnings(p));
      }
      for (final l in text.split('\n')) {
        errors.addAll(linkPayloadWarnings(l));
      }
    }
    // Build 2101: the duplicate accounting is reported once,
    // here — every branch above (links and both body
    // fall-throughs) counts into the same total.
    if (skippedDupes > 0) {
      errors.add(
        skippedDupes == 1
            ? '1 duplicate was skipped (already in the list)'
            : '$skippedDupes duplicates were skipped (already in the list)',
      );
    }
    // Build 2095 (V2Ray journey audit #8): lines nothing could
    // read are reported, not dropped in silence — unless the
    // body fall-through just consumed them (the "skipped"
    // line WAS the body).
    if (unread.isNotEmpty) {
      final first = unread.first;
      final shown = first.length > 48 ? '${first.substring(0, 48)}…' : first;
      errors.add(
        unread.length == 1
            ? '1 line could not be read: $shown'
            : '${unread.length} lines could not be read '
                  '(first: $shown)',
      );
    }
    if (added > 0) {
      unawaited(_save());
      notifyListeners();
    }
    return (added: added, errors: errors, subscriptions: addedSubs);
  }

  /// Removes every profile whose last delay test FAILED (build
  /// 2032, the v2go fold-in's "keep only working" cleanup).
  /// Profiles never tested are kept — untested is not dead.
  /// Returns how many were removed. The running profile is
  /// never removed.
  Future<int> keepOnlyWorking() async {
    // Build 2098 (post-2097 audit L12): the session guard
    // deleteProfile has always had — the CONNECTED profile
    // and the CONNECTING target are never victims. The
    // pre-2098 filter excluded only the selected profile,
    // so a session running on a non-selected profile could
    // be deleted out from under its own tunnel. The
    // session exclusion applies only while a session is
    // actually up: sessionProfile falls back to the UI
    // selection when nothing is connected, and with no
    // tunnel there is nothing to protect (the raw
    // selectedProfileId exclusion below already covers
    // the selection exactly as before).
    final sessionId = state.running ? (sessionProfile?.id ?? '') : '';
    final victims = profiles
        .where(
          (p) =>
              p.delayFailed &&
              p.id != selectedProfileId &&
              p.id != sessionId &&
              p.id != _connectingProfileId &&
              // WireGuard profiles are managed on their own page;
              // their delay tests ride the Xray core and fail for
              // UDP-filtered endpoints, so this V2Ray-page cleanup
              // must not silently shrink the WireGuard list
              // (audit, build 2033).
              p.protocol != Protocol.wireguard,
        )
        .toList();
    if (victims.isEmpty) return 0;
    // Build 2097 (post-2096 audit C5): a bulk removal
    // tombstones and forgets shapes like a single delete —
    // a pruned subscription profile used to resurrect at
    // the next refresh because its removal left no trace.
    for (final p in victims) {
      _tombstoneProfile(p);
      shapeCache.forgetProfile(p.id);
    }
    final ids = victims.map((p) => p.id).toSet();
    profiles.removeWhere((p) => ids.contains(p.id));
    _afterBulkRemoval(victims);
    await _save();
    notifyListeners();
    return victims.length;
  }

  /// Build 2098 (post-2097 audit L12): the housekeeping a
  /// BULK removal owes the store, matching deleteProfile —
  /// the bulk paths used to skip all of it: the affected
  /// subscriptions' profileCount went stale until the next
  /// refresh, a removed profile's launcher shortcut stayed
  /// behind, and a selection pointing at a removed profile
  /// could dangle.
  void _afterBulkRemoval(Iterable<Profile> removed) {
    final removedList = removed.toList();
    if (removedList.isEmpty) return;
    final affectedSubs = removedList.map((p) => p.subscriptionId).toSet();
    for (final sub in subscriptions) {
      if (affectedSubs.contains(sub.id)) {
        sub.profileCount = profilesOf(sub).length;
      }
    }
    if (removedList.any((p) => p.id == selectedProfileId)) {
      selectedProfileId = profiles.isEmpty ? '' : profiles.first.id;
    }
    // Build 2093: removed profiles' shortcuts go with them.
    unawaited(syncLauncherShortcuts());
  }

  /// The victims of a "keep only the fastest N" prune of
  /// [sub] (build 2033, policy replaced in build 2076 — see
  /// [planFastestPrune]): computed without changing anything
  /// so the confirm sheet can state the exact count first.
  List<Profile> fastestPruneVictims(Subscription sub, int n) =>
      planFastestPruneFor(profilesOf(sub), n).remove;

  /// Applies the prune [fastestPruneVictims] describes.
  /// Returns how many profiles were removed.
  Future<int> keepFastestInSubscription(Subscription sub, int n) async =>
      applyFastestPrune(planFastestPruneFor(profilesOf(sub), n));

  /// Plans a "keep only the fastest N" prune of [scope]
  /// (build 2076, feature queue #6) with this controller's
  /// live state: the selected profile and the connected
  /// profile are the protected active ones, and the settings'
  /// excluded exit countries apply.
  FastestPrunePlan planFastestPruneFor(List<Profile> scope, int n) =>
      planFastestPrune(
        scope,
        n,
        activeId: _connectedProfileId,
        selectedId: selectedProfileId,
        excludedCountries: settings.excludedCountries.toSet(),
      );

  /// Applies the prune [plan] describes: only the profiles
  /// it lists as removed leave the store, everything else
  /// stays exactly where it was. A plan that is not ready
  /// removes nothing. Returns how many profiles were removed.
  Future<int> applyFastestPrune(FastestPrunePlan plan) async {
    if (plan.state != FastestPruneState.ready || plan.remove.isEmpty) {
      return 0;
    }
    // Build 2097 (post-2096 audit C5): tombstone + forget
    // shapes, as a single delete does — the prune used to
    // resurrect its victims at the next refresh.
    for (final p in plan.remove) {
      _tombstoneProfile(p);
      shapeCache.forgetProfile(p.id);
    }
    final ids = plan.remove.map((p) => p.id).toSet();
    profiles.removeWhere((p) => ids.contains(p.id));
    // Build 2098 (L12): the same bulk-removal housekeeping
    // keepOnlyWorking owes (counts, shortcuts, selection).
    _afterBulkRemoval(plan.remove);
    await _save();
    notifyListeners();
    return plan.remove.length;
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
    String dns = '',
    Map<String, String> customHeaders = const {},
    bool allowCleartext = false,
  }) async {
    // Build 2095 (third-pass audit 5-6): a cleartext http
    // subscription sends the bearer URL — and receives the
    // configs — unencrypted, visible to and tamperable by
    // the carrier. It needs the user's explicit opt-in;
    // the UI catches this code and asks.
    if (!allowCleartext && url.startsWith('http://')) {
      throw StateError('cleartext-subscription');
    }
    final sub = Subscription(
      id: 's${DateTime.now().millisecondsSinceEpoch}-${_subIdCounter++}',
      name: name,
      url: url,
      certPin: certPin,
      hwid: hwid,
      fallbackUrl: fallbackUrl,
      dns: dns,
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

  /// Build 2147 (feature #21b): seed the two built-in
  /// default subscriptions ONCE (the shell calls this after
  /// load). They are added WITHOUT a fetch — the existing
  /// auto-update machinery refreshes them on its cadence
  /// (seeded with auto-update ENABLED, the Subscription
  /// default) — and they stay removable like any other
  /// subscription; the seeded flag is what keeps a deletion
  /// permanent. A URL already present (added by hand) is
  /// not duplicated; the flag is set either way.
  Future<void> seedDefaultSubscriptions2147() async {
    if (settings.defaultSubsSeeded2147) return;
    settings.defaultSubsSeeded2147 = true;
    var changed = false;
    for (final def in kDefaultSubscriptions2147) {
      if (subscriptions.any((s) => s.url == def.url)) continue;
      subscriptions.add(
        Subscription(
          id: 's-default-2147-${def.url.hashCode}',
          name: def.name,
          url: def.url,
        ),
      );
      changed = true;
    }
    await _save();
    if (changed) notifyListeners();
  }

  /// Build 2147 (features #20/#21a): the quarantined
  /// profiles, for the quarantine surface.
  List<Profile> get quarantinedProfiles =>
      profiles.where((p) => p.quarantined).toList();

  /// Restores a quarantined profile: clears the cut and the
  /// strike accounting (the sweep's too). Never deletes.
  Future<void> restoreFromQuarantine(String profileId) async {
    final p = _profileById(profileId);
    if (p == null) return;
    p.quarantined = false;
    p.quarantineStrikes = 0;
    p.quarantineReason = '';
    settings.sweepMissByProfile.remove(profileId);
    await _save();
    notifyListeners();
  }

  /// Build 2147 (feature #21a): the ping sweep — a real
  /// delay test over EVERY non-quarantined config (the
  /// V2Ray page's manual trigger; a scheduled run rides the
  /// 2147 housekeeping timer). A config that answers clears
  /// its miss count; one that does not increments it, and at
  /// the configured strike threshold (default 3, and only
  /// while the sweep gate is on) it is AUTO-CUT into the
  /// quarantine list — disabled, restorable, never deleted.
  /// Returns (tested, answered, cut).
  Future<({int tested, int answered, int cut})> runPingSweep() async {
    var answered = 0;
    var cut = 0;
    final targets = profiles.where((p) => !p.quarantined).toList();
    for (var i = 0; i < targets.length; i += 4) {
      final chunk = targets.skip(i).take(4).toList();
      await Future.wait([
        for (final p in chunk)
          () async {
            final ms = await testDelay(p);
            if (ms >= 0) {
              answered++;
              if (settings.sweepMissByProfile.remove(p.id) != null) {}
              if (settings.quarantineEnabled && p.quarantineStrikes > 0) {
                p.quarantineStrikes = 0;
              }
            } else if (settings.pingSweepEnabled) {
              final misses = (settings.sweepMissByProfile[p.id] ?? 0) + 1;
              settings.sweepMissByProfile[p.id] = misses;
              if (sweepShouldCut(
                consecutiveMisses: misses,
                threshold: settings.pingSweepFailStrikes,
              )) {
                p.quarantined = true;
                p.quarantineReason =
                    'Ping sweep: no answer in $misses consecutive sweeps';
                cut++;
                diagnostics.add(
                  'quarantine',
                  '${p.name} was cut by the ping sweep after '
                      '$misses unanswered sweeps. Restore it '
                      'from the quarantine surface.',
                  ok: false,
                );
              }
            }
          }(),
      ]);
    }
    await _save();
    notifyListeners();
    return (tested: targets.length, answered: answered, cut: cut);
  }

  /// Build 2134 (leg 2): the headers a subscription fetch
  /// sends — the subscription's own custom headers plus,
  /// when the automatic device HWID is enabled, the device
  /// headers (see hwid.dart). With the feature off this
  /// returns the subscription's map untouched, so the
  /// fetch is byte-for-byte build 2133's.
  Map<String, String> _fetchHeaders(Subscription sub) {
    final extra = autoHwidHeaders(
      enabled: settings.subHwidEnabled,
      deviceHwid: settings.deviceHwid,
      subHwid: sub.hwid,
      customHeaders: sub.customHeaders,
    );
    if (extra.isEmpty) return sub.customHeaders;
    return {...sub.customHeaders, ...extra};
  }

  Future<void> updateSubscription(Subscription sub) async {
    // Build 2095 (third-pass audit 2.5): a refresh landing
    // mid-connect rewrites the profile the connect is
    // starting from (fresh id, same identity) — refuse
    // while a connect is in flight on one of this
    // subscription's profiles.
    if (connecting) {
      final live = sessionProfile;
      if (live != null && live.subscriptionId == sub.id) {
        throw StateError(
          'A connection is starting from this subscription — '
          'wait for it to finish, then refresh.',
        );
      }
    }
    // Build 2134 (leg 2): the device id is minted lazily on
    // the first fetch that needs it, then kept stable.
    if (settings.subHwidEnabled && settings.deviceHwid.isEmpty) {
      settings.deviceHwid = generateDeviceHwid();
      await _save();
    }
    // Build 2147 (features #18/#21b): after a successful
    // fetch, unsupported schemes in the body are journaled
    // BY NAME (they were skipped at parse), and — while the
    // import-safety gate is on — the fetched profiles'
    // safety warnings are journaled too. Warn, never block.
    final SubResult result;
    try {
      result = await subscriptionFetcher(
        sub.url,
        certPin: sub.certPin,
        hwid: sub.hwid,
        headers: _fetchHeaders(sub),
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
        // Build 2095 (third-pass audit 5-1): the journal
        // names the subscription and its HOST only — the
        // full URL is a bearer credential (its path/query
        // is the access token) and the diagnostics are
        // shareable.
        'Fetch of ${sub.name.isEmpty ? (Uri.tryParse(sub.url)?.host ?? 'a subscription') : sub.name} failed: '
            '${e is SubFetchException ? e.message : e}',
        ok: false,
      );
      rethrow;
    }
    if (result.usedFallback) {
      diagnostics.add(
        'subscription',
        'The primary URL of ${sub.name.isEmpty ? (Uri.tryParse(sub.url)?.host ?? 'the subscription') : sub.name} '
            'failed; the fallback URL served it.',
        ok: true,
      );
    }
    // Build 2095 (audit 2.5): the subscription may have
    // been deleted while the fetch was in flight — writing
    // its profiles back now would resurrect orphans owned
    // by a subscription that no longer exists.
    if (!subscriptions.contains(sub)) return;
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
    // Build 2095 (third-pass audit 8-5a), narrowed by
    // build 2096 (post-2095 audit M10): a fetched node
    // identical to a LOOSE profile keeps the loose row
    // and drops the fetched copy — but only when the
    // subscription did not own that identity itself
    // (see the exclusion below). Other
    // subscriptions' profiles still do NOT count: two
    // panels serving the same node is normal, each
    // subscription owns its copy through its own
    // refresh/delete lifecycle (the build-2094 two-paste
    // pin caught the wider reading emptying the second
    // subscription). Within-fetch duplicates are KEPT on
    // purpose: the F-M21 design (build 2057, directly
    // above) carries each duplicate's own totals/star/
    // label through the queue-per-identity merge, and
    // the usedIds guard below is what stops refresh
    // growth — an earlier 2095 within-fetch dedupe
    // collapsed the pair and the F-M21 pin caught it.
    // Build 2096 (post-2095 audit L29): profiles the user
    // deleted individually from this subscription stay
    // deleted — their identity keys are tombstoned on the
    // subscription and filtered out of every refresh.
    // Build 2129 (recycle bin): the purged set blocks
    // resurrection exactly like the bin-visible tombstones
    // — purging a bin entry must not un-delete the profile.
    final tombstones = {
      ...sub.deletedProfileKeys,
      ...sub.purgedProfileKeys,
    };
    // Build 2096 (post-2095 audit M10), corrected in the
    // 2096 verification loop: build 2095's loose-profile
    // dedupe dropped a fetched node whenever a LOOSE
    // profile shared its coarse identity — including
    // when the subscription ITSELF owned that node and
    // its copy had just been removed above, so the user
    // lost the subscription copy (star, rename, totals,
    // selection) for good. The exclusion now applies
    // only when the subscription did not previously own
    // the identity: a node the sub already had is
    // re-admitted (and carries its data below), while a
    // node the sub never had still yields to the loose
    // row (the build-2095 audit 8-5a pin). An earlier
    // 2096 reading absorbed the loose row into the
    // subscription copy; the full-suite gate caught it
    // breaking the 8-5a pin, and the audit's text does
    // not ask for the loose row to move.
    final looseKeys = <String>{
      for (final p in profiles.where((p) => p.subscriptionId.isEmpty))
        profileIdentityKey(p),
    };
    final removedKeys = <String>{
      for (final queue in carried.values)
        for (final old in queue) profileIdentityKey(old),
    };
    final storeFetched = <Profile>[
      for (final p in result.profiles)
        // Build 2097 (post-2096 audit C9): the tombstone
        // check uses the narrow tombstone key, not the
        // coarse identity — a same-endpoint variant the
        // user never deleted is no longer dropped as
        // "deleted" for sharing an identity with one they
        // did delete.
        if (!tombstones.contains(profileTombstoneKey(p)) &&
            !(looseKeys.contains(profileIdentityKey(p)) &&
                !removedKeys.contains(profileIdentityKey(p))))
          p,
    ];
    // Build 2097 (post-2096 audit C-L6): the candidate ids
    // some fetched profile matches EXACTLY (primary
    // identity). The VMess legacy fallback below must not
    // spend them on a legacy-only match — build 2096's
    // first-unspent-wins fallback could take the exact
    // candidate of a later fetched profile, and two stored
    // twins differing only in the blanked fields could
    // swap ids/totals.
    final exactReserved = <String>{
      for (final f in result.profiles)
        if (carried[identityOf(f)] case final List<Profile> queue)
          for (final c in queue) c.id,
    };
    final usedIds = <String>{};
    for (final p in storeFetched) {
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
      if (old == null && p.protocol == Protocol.vmess) {
        // Build 2096 (post-2095 audit M11): a profile
        // stored by build 2094 carries the fields 2094's
        // VMess reader dropped as empty, so its identity
        // differs from the same node parsed fresh — the
        // primary lookup misses on the first 2095+
        // refresh and the carry is lost. Fall back to the
        // legacy identity (those fields blanked on both
        // sides) over the unspent candidates.
        final legacyKey = legacyVmessIdentityLink(p);
        outer:
        for (final queue in carried.values) {
          for (final candidate in queue) {
            if (usedIds.contains(candidate.id)) continue;
            // Build 2097 (audit C-L6): never spend a
            // candidate a fetched profile matches exactly.
            if (exactReserved.contains(candidate.id)) continue;
            if (legacyVmessIdentityLink(candidate) == legacyKey) {
              usedIds.add(candidate.id);
              old = candidate;
              break outer;
            }
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
        // Build 2095 (third-pass audit 4c-2): only when the
        // old pin is non-empty — the unconditional copy
        // erased a pin the PROVIDER's fresh link carried
        // whenever the old profile had none.
        if (old.tlsCertPin.isNotEmpty) p.tlsCertPin = old.tlsCertPin;
        // Build 2095 (audit 4c-1): the anti-filter shaping
        // the user set is theirs too — the provider's fresh
        // link wins where it carries a value; the user's
        // value fills only the empties.
        if (p.afUnfilter == false) p.afUnfilter = old.afUnfilter;
        if (p.afEch == false) p.afEch = old.afEch;
        if (p.afFragment.isEmpty) p.afFragment = old.afFragment;
        if (p.afMixedSni == false) p.afMixedSni = old.afMixedSni;
        if (p.afTcpNoise == false) p.afTcpNoise = old.afTcpNoise;
        // Build 2125 (audit A25-24 / P-33): the editor-set
        // Aether options carry too, under the same rule.
        // The identity link has stripped them since build
        // 2096 (M12) — so the match itself survived — but
        // this carry block never copied the values, so a
        // user's cipher-suites / dial-mode / final-mask
        // edits silently reverted on every refresh.
        if (p.cipherSuites.isEmpty) p.cipherSuites = old.cipherSuites;
        if (p.dialMode.isEmpty) p.dialMode = old.dialMode;
        if (p.finalMask.isEmpty) p.finalMask = old.finalMask;
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
        // Build 2095 (audit 4c-4): the TCP-ping results
        // carry too — they used to reset on every refresh
        // while delayMs survived.
        p.tcpPingMs = old.tcpPingMs;
        p.tcpPingFailed = old.tcpPingFailed;
        p.exitIp = old.exitIp;
        p.exitCountryCode = old.exitCountryCode;
        // Build 2096 (post-2095 audit L28): the last
        // speed-test result carries too — it used to
        // reset on every refresh while delayMs survived.
        p.lastSpeedBps = old.lastSpeedBps;
      }
      profiles.add(p);
    }
    // Build 2095 (third-pass audit 4c-3 + feature 3): the
    // userinfo values are kept when the response carries
    // none — the unconditional assignment used to ZERO the
    // stored quota/expiry whenever a refresh came back
    // without the subscription-userinfo header (e.g. via
    // the fallback URL), and the card's usage display
    // vanished. A header reporting total 0 AND expire 0 is
    // indistinguishable from an absent one; keeping the
    // last known values is the honest choice.
    if (result.totalBytes > 0 || result.expireEpochSec > 0) {
      sub
        ..uploadBytes = result.uploadBytes
        ..downloadBytes = result.downloadBytes
        ..totalBytes = result.totalBytes
        ..expireEpochSec = result.expireEpochSec;
    }
    sub
      ..lastUpdatedMs = DateTime.now().millisecondsSinceEpoch
      // Build 2095 (audit 8-5a): the count is what the
      // subscription actually owns after the merge.
      ..profileCount = profilesOf(sub).length;
    // Build 2147 (features #18/#21b): the refresh-side
    // accounting — unsupported schemes named in the journal,
    // and (gate on) the fetched profiles' safety warnings.
    if (result.unsupportedSchemes.isNotEmpty) {
      diagnostics.add(
        'subscription',
        '${sub.name}: ${result.unsupportedSchemes.length} '
            'unsupported protocol '
            '${result.unsupportedSchemes.length == 1 ? 'scheme was' : 'schemes were'} '
            'skipped (${result.unsupportedSchemes.join(', ')}) — '
            'no engine in Ember serves them.',
        ok: false,
      );
    }
    if (settings.importSafetyFilter) {
      for (final p in result.profiles) {
        for (final w in importSafetyWarnings(p)) {
          diagnostics.add('import', w, ok: false);
        }
      }
    }
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
    // Build 2093: a refresh can rename, drop or re-id profiles.
    unawaited(syncLauncherShortcuts());
  }

  /// Build 2095 (V2Ray journey audit #7): the counts are
  /// RETURNED so the caller can show them — every failure
  /// used to be discarded (`catch (_) {}`), and an all-fail
  /// update-all looked identical to an all-success one.
  Future<({int updated, int failed})> updateAllSubscriptions() async {
    var updated = 0;
    var failed = 0;
    for (final sub in List.of(subscriptions)) {
      try {
        await updateSubscription(sub);
        updated++;
      } catch (_) {
        // One bad subscription must not stop the others.
        failed++;
      }
    }
    return (updated: updated, failed: failed);
  }

  bool _sweepRunning = false;

  Future<void> _autoUpdateStale() async {
    // Build 2096 (post-2095 audit L17): no re-entrancy —
    // the launch call and a timer tick used to be able to
    // run two sweeps over the same subscriptions at once.
    if (_sweepRunning) return;
    _sweepRunning = true;
    try {
      await _autoUpdateStaleInner();
    } finally {
      _sweepRunning = false;
    }
  }

  /// Build 2116 (AB-12): how many auto-updating
  /// subscriptions are currently in a failed state — the
  /// V2Ray page's one-line notice reads this.
  int get subAutoRefreshFailing =>
      subscriptions.where((s) => s.autoUpdate && s.failedAttempts > 0).length;

  Future<void> _autoUpdateStaleInner() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final periodMs = settings.subAutoUpdateHours * 3600 * 1000;
    var attempted = false;
    for (final sub in List.of(subscriptions)) {
      if (!sub.autoUpdate) continue;
      if (periodMs > 0 && now - sub.lastUpdatedMs < periodMs) continue;
      // Build 2116 (AB-12): a failed attempt is stamped
      // and backs off — the old sweep retried a dead
      // subscription every 30-minute tick forever and
      // never said a word about it.
      if (sub.failedAttempts > 0 &&
          now - sub.lastAttemptMs < subAutoUpdateBackoffMs(sub.failedAttempts)) {
        continue;
      }
      attempted = true;
      sub.lastAttemptMs = now;
      try {
        await updateSubscription(sub);
        sub.failedAttempts = 0;
      } catch (_) {
        sub.failedAttempts += 1;
      }
    }
    // The stamps are session truth the next launch needs;
    // a failed updateSubscription never reaches its own
    // save, so persist them here.
    if (attempted) {
      await _save();
      notifyListeners();
    }
  }

  /// Build 2095 (third-pass audit 8-5b): the test seam for
  /// the auto-update sweep — the periodic timer cannot be
  /// driven from a host test.
  @visibleForTesting
  Future<void> testAutoUpdateStale() => _autoUpdateStale();

  /// Build 2095 (V2Ray journey audit #4): edits an existing
  /// subscription's fields IN PLACE and refreshes it. Before
  /// this, name/URL/HWID/fallback/headers/pin were settable
  /// only at add time — changing a URL meant deleting the
  /// subscription (wiping all its configs) and re-adding it.
  /// A failed refresh keeps the old configs, exactly like a
  /// manual refresh failure; the error propagates so the
  /// sheet can show the fetcher's words.
  Future<void> editSubscription(
    Subscription sub, {
    required String name,
    required String url,
    String hwid = '',
    String fallbackUrl = '',
    String dns = '',
    String certPin = '',
    Map<String, String> customHeaders = const {},
    bool allowCleartext = false,
  }) async {
    // Build 2095 (audit 5-6): same cleartext rule as add.
    if (!allowCleartext && url.startsWith('http://')) {
      throw StateError('cleartext-subscription');
    }
    // Build 2125 (audit A25-47): the edit used to persist
    // BEFORE the refresh ran, with no way back — a bad
    // new URL (a typo, an expired link) overwrote the
    // working one even though the refresh failed. The old
    // values are snapshotted and restored when the
    // refresh throws; the error still propagates to the
    // caller exactly as before.
    final oldName = sub.name;
    final oldUrl = sub.url;
    final oldHwid = sub.hwid;
    final oldFallbackUrl = sub.fallbackUrl;
    final oldDns = sub.dns;
    final oldCertPin = sub.certPin;
    final oldHeaders = sub.customHeaders;
    sub
      ..name = name
      ..url = url
      ..hwid = hwid
      ..fallbackUrl = fallbackUrl
      ..dns = dns
      ..certPin = certPin
      ..customHeaders = customHeaders;
    await _save();
    notifyListeners();
    try {
      await updateSubscription(sub);
    } catch (_) {
      sub
        ..name = oldName
        ..url = oldUrl
        ..hwid = oldHwid
        ..fallbackUrl = oldFallbackUrl
        ..dns = oldDns
        ..certPin = oldCertPin
        ..customHeaders = oldHeaders;
      await _save();
      notifyListeners();
      rethrow;
    }
  }

  Future<void> deleteSubscription(Subscription sub) async {
    // Build 2095 (V2Ray journey audit #3): the disconnect
    // guard deleteProfile always had — when the live
    // tunnel's profile belongs to this subscription,
    // disconnect first. The store used to delete the config
    // from under a running tunnel and re-point the selection
    // while the tunnel kept running on a config that no
    // longer existed in the list.
    if (state.running || connecting) {
      final liveId = sessionProfile?.id ?? '';
      final hitsLive = profiles.any(
        (p) =>
            p.subscriptionId == sub.id &&
            (p.id == liveId || p.id == selectedProfileId),
      );
      if (hitsLive) await disconnect();
    }
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
    // Build 2093: a rename changes a shortcut's label.
    unawaited(syncLauncherShortcuts());
  }

  /// Build 2095 (feature 14 — quick-edit): renames a
  /// config in place through the same field the editor's
  /// name box writes (the local name override the lists
  /// render). An empty name clears the override.
  Future<void> renameProfile(Profile p, String name) async {
    // Build 2096 (post-2095 audit L13/M5): the same rule
    // the editor applies — the name is sanitized, and a
    // name equal to the provider name is NO override
    // (localName stays empty), where build 2095's
    // quick-edit always wrote the override.
    final clean = sanitizeProfileName(name);
    p.localName = clean == p.name ? '' : clean;
    await _save();
    notifyListeners();
    // Build 2096 (post-2095 audit L12): a rename changes
    // a launcher shortcut's label — re-sync, as
    // updateProfile already did.
    unawaited(syncLauncherShortcuts());
  }

  /// Records [p]'s deletion on its subscription so a
  /// refresh does not resurrect it (build 2096, audit L29).
  /// Build 2097 (post-2096 audit C5): EVERY removal path
  /// goes through here — the bulk cleanups (keep-only-
  /// working, fastest-N prune) used to remove subscription
  /// profiles without tombstoning them, so the next
  /// refresh brought them straight back. The list is
  /// capped (audit L-e): past 500 recorded deletions on
  /// one subscription the oldest fall off — bounded store
  /// growth wins over remembering a deletion from 500
  /// deletions ago.
  void _tombstoneProfile(Profile p) {
    if (p.subscriptionId.isEmpty) return;
    for (final sub in subscriptions) {
      if (sub.id != p.subscriptionId) continue;
      final key = profileTombstoneKey(p);
      if (sub.deletedProfileKeys.contains(key)) return;
      var keys = [...sub.deletedProfileKeys, key];
      if (keys.length > 500) keys = keys.sublist(keys.length - 500);
      sub.deletedProfileKeys = keys;
    }
  }

  /// Build 2129 (recycle bin): every tombstoned profile
  /// across all subscriptions, as the bin lists them —
  /// the subscription it belonged to, the tombstone key,
  /// and the endpoint fields the key itself retains
  /// (protocol / address / port via [parseTombstoneKey];
  /// empty when the key predates the tombstone shape).
  /// The tombstone retains NO name and NO full profile,
  /// so this is all a listing can honestly show.
  List<DeletedProfileEntry> get deletedProfiles => [
    for (final sub in subscriptions)
      for (final key in sub.deletedProfileKeys)
        DeletedProfileEntry(subscription: sub, key: key),
  ];

  /// How many profiles sit in the recycle bin.
  int get deletedProfileCount =>
      subscriptions.fold(0, (n, s) => n + s.deletedProfileKeys.length);

  /// Build 2129 (recycle bin): RESTORE one bin entry —
  /// removes its tombstone, so the profile comes back at
  /// its subscription's NEXT REFRESH (the tombstone kept
  /// no copy of the profile itself; un-tombstoning is
  /// the only restore the data supports). Nothing is
  /// added to the profile list here, and nothing
  /// auto-restores: entries the user never restores stay
  /// tombstoned across refreshes exactly as before.
  Future<void> restoreDeletedProfile(
    Subscription sub,
    String key,
  ) async {
    if (!sub.deletedProfileKeys.contains(key)) return;
    sub.deletedProfileKeys = [
      for (final k in sub.deletedProfileKeys)
        if (k != key) k,
    ];
    await _save();
    notifyListeners();
  }

  /// Build 2129 (recycle bin): PERMANENTLY delete one bin
  /// entry — the key moves to the subscription's purged
  /// set: it leaves the bin, and it keeps blocking
  /// refresh resurrection (the refresh filter reads both
  /// sets), so purging can never un-delete a profile by
  /// accident. There is no way back from a purge.
  Future<void> purgeDeletedProfile(Subscription sub, String key) async {
    if (!sub.deletedProfileKeys.contains(key)) return;
    sub.deletedProfileKeys = [
      for (final k in sub.deletedProfileKeys)
        if (k != key) k,
    ];
    if (!sub.purgedProfileKeys.contains(key)) {
      sub.purgedProfileKeys = [...sub.purgedProfileKeys, key];
    }
    await _save();
    notifyListeners();
  }

  Future<void> deleteProfile(Profile p) async {
    // Build 2096 (post-2095 audit L20): the guard covers
    // the CONNECTING window and the live session profile,
    // not only a running tunnel whose selection still
    // points at the profile — deleting mid-connect used
    // to remove the profile while its connect completed
    // onto a store that no longer held it.
    // Build 2098 (post-2097 audit L14): the SELECTED id is
    // no longer a guard condition — it over-blocked: deleting
    // the selected profile while an UNRELATED session ran
    // disconnected that session first, though nothing about
    // the delete needed it stopped. A live session ON this
    // profile is still caught — by sessionProfile (which
    // falls back to the selection exactly when no connected
    // id is recorded) and by the connecting target. The
    // selection itself is repaired below, as before.
    // Build 2098 (verification F-A2): the seamless-switch
    // TARGET is guarded too — a switch in flight tracks its
    // target only in switchingProfileId, and the 2097 guard
    // caught it via the selection (the target is always the
    // selection when a switch starts). Without it the delete
    // landed mid-switch and the switch then completed onto
    // a removed, tombstoned profile, leaving both persisted
    // ids dangling. disconnect() aborts the switch (it
    // clears switchingProfileId and bumps the tunnel
    // generation), exactly as in 2097.
    if ((state.running || connecting) &&
        (sessionProfile?.id == p.id ||
            _connectingProfileId == p.id ||
            switchingProfileId == p.id)) {
      await disconnect();
    }
    profiles.removeWhere((e) => e.id == p.id);
    // Build 2096 (post-2095 audit L29): tombstone the
    // identity on its subscription so the next refresh
    // does not resurrect a profile the user deleted on
    // purpose. Build 2097 (C9): the tombstone key is the
    // narrow one (see profileTombstoneKey).
    _tombstoneProfile(p);
    // Build 2095 (third-pass audit 7-8): the profile's
    // cached winning shapes go with it.
    shapeCache.forgetProfile(p.id);
    // Build 2095 (third-pass audit 7-6): profileCount is
    // maintained wherever the count changes — a delete
    // recomputes its subscription's count (refresh already
    // writes it; the field was write-only in between).
    if (p.subscriptionId.isNotEmpty) {
      for (final sub in subscriptions) {
        if (sub.id == p.subscriptionId) {
          sub.profileCount = profilesOf(sub).length;
        }
      }
    }
    if (selectedProfileId == p.id) {
      selectedProfileId = profiles.isEmpty ? '' : profiles.first.id;
    }
    await _save();
    notifyListeners();
    // Build 2093: a deleted profile's shortcut must go with it.
    unawaited(syncLauncherShortcuts());
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
    // Build 2093: the starred set is the shortcut set.
    unawaited(syncLauncherShortcuts());
  }

  Future<void> duplicateProfile(Profile p) async {
    // Build 2103 (verification iteration 1, M1): the copy's
    // name derives from the STORED name (label, else provider
    // name), never from displayName — its render-time address
    // fallback would give a nameless profile's copy a stored
    // "<address> (2)" name. A nameless profile's copy is born
    // nameless like its source.
    final visibleName = p.localName.isNotEmpty ? p.localName : p.name;
    final copy = p.copy()
      ..id = newProfileId()
      // Build 2045: the copy is a new hand-added config, so it
      // takes the name the user sees (label included) as its own
      // name and is born with no label — the original keeps its.
      ..name = visibleName.isEmpty ? '' : '$visibleName (2)'
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
    // Build 2123 (audit B-02): the sidecar must carry the
    // zeroed totals too — otherwise its older entry would
    // overlay them back at the next load.
    await _saveStatsSidecar();
    notifyListeners();
  }

  void select(Profile p) {
    // Build 2087: an explicit choice — the per-network winner
    // memory yields to it for the rest of this session (see
    // [_userChoseSelection]).
    _userChoseSelection = true;
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

  /// Build 2095 (audit #15): [appSettingsJson] (the live
  /// AppSettings document) rides the backup under
  /// 'appSettings', minus the secret keys — a restore used
  /// to carry configs only, so every app-level choice was
  /// lost with the device.
  Future<String?> exportBackup({
    Map<String, Object?>? appSettingsJson,
    Map<String, Object?>? engineSections,
  }) async {
    // Build 2098 (post-2097 audit M11): the OUTBOUND path
    // takes the same protection the inbound paths have had
    // since build 2097 (C-L7/C-L11). While the store is
    // protected — a newer build's document, or an intact one
    // this build could not read (incl. a foreign document,
    // M13) — the in-memory state is NOT the user's data:
    // exporting it produced a backup of empty state, and a
    // gist Push then overwrote the healthy synced copy with
    // that empty state. Refuse, exactly as importBackup
    // does; the store's error surface already carries the
    // reason, and every caller surfaces the refusal.
    if (_storeFromNewerVersion || _storeUnreadable) return null;
    // Build 2095 (audit 4a-1): flush the save chain, then
    // export the in-memory document — never a disk re-read.
    await _save();
    final doc = _buildStoreDoc();
    if (appSettingsJson != null) {
      doc['appSettings'] = stripBackupSecrets(appSettingsJson);
    }
    // Build 2116 (AB-05): the other engines' sections ride
    // under their own versioned key — a backup used to
    // silently exclude them, and a restore on a new device
    // lost every OpenVPN profile, the Psiphon settings and
    // both Aether options sets without a word. (What NEVER
    // travels — OpenVPN credentials, the Mozilla account —
    // is stated in the sync/backup copy, not encoded here.)
    if (engineSections != null) {
      doc['engines'] = {'version': 1, ...engineSections};
    }
    // The schema key rides every export (build 2054): a
    // future build that changes the document shape can refuse
    // a backup it cannot read, instead of half-restoring it.
    doc['schemaVersion'] = backupSchemaVersion;
    return jsonEncode(doc);
  }

  /// Restores a backup document; returns null when it is not
  /// one (or fails validation), otherwise a
  /// [BackupRestoreResult] naming what was restored and what
  /// was skipped as damaged (build 2095, V2Ray audit #10 —
  /// the bool era reported plain success while damaged
  /// entries vanished). Transactional (build 2054, audit F-H9): EVERYTHING
  /// is decoded into locals first — profiles and subscriptions
  /// per-entry (one damaged entry is skipped, never fatal),
  /// settings, warp profile, CF IPs and shape cache — and only
  /// when all of it validates does the live state swap, the
  /// tunnel disconnect (a malformed backup must never kill a
  /// live tunnel before failing), and one save persist the
  /// result. A failure anywhere before the swap leaves the
  /// in-memory AND on-disk state exactly as it was.
  Future<BackupRestoreResult?> importBackup(String text) async {
    // Build 2097 (post-2096 audit C-L11): when this build
    // may not persist the store at all — a newer build's
    // document, or an intact-but-unreadable one (C-L7) —
    // a restore used to replace everything in memory,
    // report success, and silently persist NOTHING (the
    // save refused underneath it), so the restore
    // "happened" until the next launch undid it. Refuse
    // up front instead; the store's own error surface
    // already carries the reason.
    if (_storeFromNewerVersion || _storeUnreadable) return null;
    Map<String, dynamic> doc;
    try {
      final raw = jsonDecode(text);
      if (raw is! Map<String, dynamic>) return null;
      doc = raw;
    } catch (_) {
      return null;
    }
    final version = doc['schemaVersion'];
    // Build 2096 (post-2095 audit L30): a PRESENT version
    // must be an int inside the supported range — a
    // string "2" or double 2.0 used to sail past the
    // `is int &&` refusal and half-restore. A MISSING
    // version is a legacy backup (pre-versioning builds
    // wrote none) and still restores.
    if (version != null &&
        (version is! int ||
            version < 1 ||
            version > backupSchemaVersion)) {
      return null;
    }
    if (doc['profiles'] is! List) return null;
    // Build 2116 (AB-06): overlay the LIVE one-time
    // migration flags over the backup's settings and warp
    // documents before they decode. The migrations live
    // inside fromJson, keyed on absent flags — a backup
    // written before a migration lacks the flag, so a
    // restore re-fired the migration over the restored
    // values and silently reversed choices made since (a
    // pre-2114 backup's deliberate autoReconnect ON came
    // back OFF). The live app has already lived through
    // every migration; where its flag stands, the restored
    // document is marked migrated too, and fromJson leaves
    // the restored values alone. (AppSettings' restore
    // already avoided this; the Xray path now matches it.)
    final settingsDoc = doc['settings'];
    if (settingsDoc is Map) {
      final m = settingsDoc.cast<String, dynamic>();
      if (settings.remoteDnsMigrated) m['remoteDnsMigrated'] = true;
      if (settings.defaultsMigrated2101) m['defaultsMigrated2101'] = true;
      if (settings.defaultsMigrated2111) m['defaultsMigrated2111'] = true;
      if (settings.defaultsMigrated2113) m['defaultsMigrated2113'] = true;
      if (settings.defaultsMigrated2103) m['defaultsMigrated2103'] = true;
      if (settings.defaultsReset2114) m['defaultsReset2114'] = true;
      if (settings.domainStrategyMigrated) {
        m['domainStrategyMigrated'] = true;
      }
    }
    final warpDoc = doc['warpProfile'];
    if (warpDoc is Map && warpProfile.defaultsReset2114) {
      warpDoc.cast<String, dynamic>()['defaultsReset2114'] = true;
    }
    late final List<Profile> newProfiles;
    late final List<Subscription> newSubscriptions;
    late final XraySettings newSettings;
    late final WarpProfile newWarpProfile;
    late final List<String> newCfGoodIps;
    late final WinningShapeCache newShapeCache;
    late final DpiLabMemory newDpiLabMemory;
    late final DpiLabResultBook newDpiLabResults;
    late final Set<String> newDpiLabSweepExcluded;
    late final List<DpiRemoteStrategy> newDpiRemoteStrategies;
    late final int newDpiRemoteUpdatedMs;
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
      // Build 2114: installed BEFORE the memory parse, as
      // in the main load — the memory reader validates 'r-'
      // win ids against the registry. This is the one early
      // mutation in this path: the registry is inert data,
      // and a restore that fails later leaves the restored
      // strategies' candidates installed until the next
      // load; the store on disk is untouched either way.
      newDpiRemoteStrategies = installDpiRemoteStrategies(
        dpiRemoteStrategiesFromJson(doc['dpiRemoteStrategies']),
      );
      newDpiRemoteUpdatedMs = doc['dpiRemoteUpdatedMs'] is num
          ? (doc['dpiRemoteUpdatedMs'] as num).toInt()
          : 0;
      newDpiLabMemory = DpiLabMemory.fromJson(doc['dpiLabMemory']);
      // Build 2120: as in the main load — the book parses
      // after the remote install above, and is pruned to
      // the restored profile set.
      newDpiLabResults = DpiLabResultBook.fromJson(doc['dpiLabResults']);
      newDpiLabResults.pruneProfiles(newProfiles.map((p) => p.id).toSet());
      newDpiLabSweepExcluded = dpiLabSelectionFromJson(
        doc['dpiLabSweepExcluded'],
      );
      newSelectedId = doc['selectedProfileId'] is String
          ? doc['selectedProfileId'] as String
          : '';
      if (!newProfiles.any((p) => p.id == newSelectedId)) {
        newSelectedId = newProfiles.isEmpty ? '' : newProfiles.first.id;
      }
    } catch (_) {
      // Any decode failure: null, state untouched.
      return null;
    }
    // Validation passed — only now may the live tunnel go.
    // Build 2097 (post-2096 audit C-L11): a CONNECTING
    // attempt goes too — build 2096 stopped only a running
    // tunnel, so a restore mid-connect swapped the store
    // under the in-flight attempt, which then completed
    // onto the restored profiles. disconnect() bumps the
    // generation, aborting the attempt.
    if (state.running || connecting) await disconnect();
    profiles = newProfiles;
    subscriptions = newSubscriptions;
    settings = newSettings;
    warpProfile = newWarpProfile;
    cfGoodIps = newCfGoodIps;
    shapeCache = newShapeCache;
    dpiLabMemory = newDpiLabMemory;
    dpiLabResults = newDpiLabResults;
    dpiLabSweepExcluded = newDpiLabSweepExcluded;
    dpiRemoteStrategies = newDpiRemoteStrategies;
    dpiRemoteUpdatedMs = newDpiRemoteUpdatedMs;
    selectedProfileId = newSelectedId;
    // Build 2095 (audit 4a-2): a restore never carries a
    // live-session claim — the field used to keep whatever
    // the target (or the backup) last wrote, so a restart
    // could adopt a session under a restored profile that
    // never connected here.
    _connectedProfileId = '';
    // Build 2116 (B13-2): the session's underlay name is
    // part of the same live-session claim.
    _sessionUnderlay = '';
    // Build 2103 (verification iteration 2): a restore is
    // a store replacement, so the one-time address-name
    // heal runs here too when the restored settings have
    // not had it — a pre-2103 backup's address-named
    // profiles are healed in the restore session itself,
    // not left for the next launch (the flag persists
    // either way, so nothing could be lost, only deferred).
    if (!settings.addressNameHealed2103) {
      healAddressDerivedNames(profiles);
      settings.addressNameHealed2103 = true;
    }
    // Build 2116 (AB-16): the fingerprint migration gets
    // the same restore treatment as the name heal above —
    // it ran only in load(), so a pre-2070 backup's
    // restored profiles kept the parser-manufactured
    // 'chrome' (and lost the uTLS rotation) until the next
    // launch. Under the same flag guard as load(): a
    // backup whose settings already carry the migration
    // is never re-cleared.
    if (!settings.fingerprintDefaultMigrated) {
      clearParserDefaultFingerprints(profiles);
      settings.fingerprintDefaultMigrated = true;
    }
    await _save();
    notifyListeners();
    final rawSubs = doc['subscriptions'];
    final rawAppSettings = doc['appSettings'];
    // Build 2095 (audit 4a-3): the bounded transforms,
    // detected against the raw document.
    final notes = <String>[];
    final knownProtocols = Protocol.values.map((e) => e.name).toSet();
    var unknownProtocols = 0;
    for (final raw in (doc['profiles'] as List)) {
      if (raw is Map && !knownProtocols.contains(raw['protocol'])) {
        unknownProtocols++;
      }
    }
    if (unknownProtocols > 0) {
      notes.add(
        '$unknownProtocols ${unknownProtocols == 1 ? 'config has' : 'configs have'} '
        'a protocol this build does not know and was read as VLESS.',
      );
    }
    final rawSettings = doc['settings'];
    if (rawSettings is Map) {
      final rawSocks = rawSettings['socksPort'];
      final rawHttp = rawSettings['httpPort'];
      if ((rawSocks is num && rawSocks.toInt() != newSettings.socksPort) ||
          (rawHttp is num && rawHttp.toInt() != newSettings.httpPort)) {
        notes.add(
          'The proxy ports were reset to ${newSettings.socksPort}/${newSettings.httpPort} '
          '(the backup pair was not usable).',
        );
      }
      final rawMtu = rawSettings['tunnelMtu'];
      if (rawMtu is num && rawMtu.toInt() != newSettings.tunnelMtu) {
        notes.add(
          'The tunnel MTU was clamped to ${newSettings.tunnelMtu}.',
        );
      }
    }
    return BackupRestoreResult(
      notes: notes,
      profiles: newProfiles.length,
      skippedProfiles:
          (doc['profiles'] as List).length - newProfiles.length,
      subscriptions: newSubscriptions.length,
      skippedSubscriptions:
          (rawSubs is List ? rawSubs.length : 0) - newSubscriptions.length,
      appSettingsJson: rawAppSettings is Map
          ? stripBackupSecrets(
              rawAppSettings.map(
                (k, v) => MapEntry(k.toString(), v as Object?),
              ),
            )
          : null,
      // Build 2116 (AB-05): the engine sections pass
      // through for the caller to apply (the version key
      // is the document's own, not a section).
      engineSections: doc['engines'] is Map
          ? {
              for (final e in (doc['engines'] as Map).entries)
                if (e.key.toString() != 'version')
                  e.key.toString(): e.value as Object?,
            }
          : null,
    );
  }

  // ---- tunnel -----------------------------------------------------------

  Future<void> refreshState() async {
    state = _stampVerified(await XrayPlatform.state());
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
      // Build 2092 (UI audit item 5): the persisted connected
      // id (restored at load) names the session's profile; a
      // stale id that names nothing is dropped, and only a
      // store that never recorded one (pre-2092) falls back
      // to the old selection guess.
      if (_connectedProfileId.isNotEmpty &&
          _profileById(_connectedProfileId) == null) {
        _connectedProfileId = '';
      }
      if (_connectedProfileId.isEmpty) {
        _connectedProfileId = selectedProfileId;
      }
      // Build 2107 (verification iteration 2): restore the
      // watchdog stand-down for an adopted Lab-dialed
      // session from the candidate persisted at dial time.
      // Only an Xray-core session can be Lab-dialed (never
      // WARP or AWG), the candidate must still apply to the
      // adopted profile, and Stock (s0) never stands the
      // watchdog down — its dial is the stored profile itself.
      // Verification iteration 3: the restore is one-shot,
      // toggle-gated, and CONSUMES the stored value (see
      // _labAdoptionDone) — refreshState runs routinely
      // during live sessions, and an unconsumed candidate
      // could resurrect onto a later session that was never
      // Lab-dialed.
      // The _loaded gate (iteration 4): the shell fires a
      // refreshState concurrently with load(), and a latch
      // consumed before the store doc was read would lose
      // the adoption for the whole process.
      if (!_labAdoptionDone && _loaded) {
        _labAdoptionDone = true;
        final stored = _storedLabDialCandidate;
        _storedLabDialCandidate = '';
        if (!_labDialActive &&
            settings.dpiLabEnabled &&
            stored.isNotEmpty &&
            stored != shapeStock &&
            !warpSession &&
            !state.awg) {
          final adopted = _profileById(_connectedProfileId);
          if (adopted != null && dpiLabCandidateApplies(stored, adopted)) {
            _labDialActive = true;
            _labDialCandidateId = stored;
            _labStandDownJournaled = false;
          }
        }
      }
      // Build 2106 (verification iteration 2, L-2): the
      // recompute latch names a session whose feature was
      // on; toggling the feature off releases it, so an
      // off→on within the same session retries the pins
      // instead of staying latched to the first failure.
      if (!settings.providerDnsEnabled && _providerPinsAdoptedFor.isNotEmpty) {
        _providerPinsAdoptedFor = '';
      }
      // Build 2105: a session adopted after an app restart
      // has no pins in memory (they are process state) —
      // recompute them for the adopted profile, or the first
      // watchdog rotation silently rebuilds the config
      // without the pin and the server name falls back to
      // the tunnel DNS the feature exists to avoid.
      // Build 2106 (verification M1): once per adopted
      // session — the latch is set BEFORE the lookup starts,
      // so concurrent refreshes cannot spawn duplicates and
      // a failed lookup is not retried on every refresh.
      if (_sessionProviderPins.isEmpty &&
          settings.providerDnsEnabled &&
          _providerPinsAdoptedFor != _connectedProfileId) {
        final adopted = _profileById(_connectedProfileId);
        if (adopted != null) {
          _providerPinsAdoptedFor = adopted.id;
          unawaited(
            _providerDnsPins(adopted).then((pins) {
              if (pins.isNotEmpty &&
                  _connectedProfileId == adopted.id &&
                  state.running) {
                _sessionProviderPins = pins;
              }
            }),
          );
        }
      }
      // Build 2110: the same adopted-session recompute for
      // the server-name pins — the default resolution path
      // has no feature gate, so an adopted session's first
      // rotation would otherwise rebuild the config with
      // the name unpinned and unstamped (the C1 failure,
      // returning through the rotation door).
      if (_sessionServerPins.isEmpty &&
          _serverPinsAdoptedFor != _connectedProfileId) {
        final adopted = _profileById(_connectedProfileId);
        if (adopted != null) {
          _serverPinsAdoptedFor = adopted.id;
          unawaited(
            _serverNamePins(adopted).then((pins) {
              if (pins.isNotEmpty &&
                  _connectedProfileId == adopted.id &&
                  state.running) {
                _sessionServerPins = pins;
              }
            }),
          );
        }
      }
      // Build 2119 (audit F-02): the same adopted-session
      // gap for the data-plane proof. _proofVerifiedSinceMs
      // is process state: a session adopted after an app
      // restart was never proven in THIS process, yet the
      // shell bar read bare "Connected" — the verified
      // flag existed and no UI consumed it. The proof now
      // runs once per adopted session (latched by sinceMs,
      // set BEFORE the proof starts, like the pin
      // recomputes above); on success the session is
      // stamped verified and the bar upgrades. A failed
      // proof tears nothing down — the adopted-session
      // posture is not to re-judge the session, only to
      // stop claiming a proof ran: the bar shows the
      // honest "Connected — not answering" until a proof
      // passes in this process. The WireGuard protocol
      // leg is exempt, exactly as at connect (its walk
      // runs the handshake proof itself), as are AWG and
      // standalone-WARP sessions, whose bars are not the
      // plain-Xray word.
      if (!warpSession &&
          !awgSession &&
          state.sinceMs != 0 &&
          _proofVerifiedSinceMs != state.sinceMs &&
          _adoptionProofFor != state.sinceMs) {
        final adopted = _profileById(_connectedProfileId);
        if (adopted != null && adopted.protocol != Protocol.wireguard) {
          _adoptionProofFor = state.sinceMs;
          final sinceMs = state.sinceMs;
          unawaited(
            awaitXrayCarries(() {}).then((carried) {
              if (carried &&
                  state.running &&
                  state.sinceMs == sinceMs &&
                  _connectedProfileId == adopted.id) {
                _proofVerifiedSinceMs = sinceMs;
                // Build 2125 (A25-11): the re-proof
                // cadence starts from this proof.
                _proofVerifiedAtMs = DateTime.now().millisecondsSinceEpoch;
                state = state.withVerified(true);
                notifyListeners();
              } else if (state.running &&
                  state.sinceMs == sinceMs &&
                  _connectedProfileId == adopted.id) {
                // Build 2126 (audit A26-07): a failed
                // adoption proof arms the re-proof retry.
                // Up to 2125 nothing set the retry time
                // for an adopted session, so one that
                // started unlatched stayed unlatched —
                // and unstamped — for its whole life even
                // when the data plane was fine. The
                // poll's re-proof now retries it on the
                // normal cadence.
                _reproofNextAtMs =
                    DateTime.now().millisecondsSinceEpoch +
                    _reproofCadenceMs;
              }
            }),
          );
        }
      }
      _startPolling();
      _fetchExitInfo();
    } else if (!state.paused) {
      _expectRunning = false;
      _connectedProfileId = '';
      // Build 2107 (verification iteration 3): a session-end
      // path that bypasses _stopTunnel still ends the
      // Lab-dial state with the session.
      _clearLabDialState();
      // Build 2106 (verification M1): the pin recompute
      // latch names a session that no longer exists.
      _providerPinsAdoptedFor = '';
      // Build 2110: the server-pin latch likewise.
      _serverPinsAdoptedFor = '';
      exitInfo = null;
      _lastAwgRx = -1;
      _lastAwgTx = -1;
    } else {
      // Build 2081 (verification V-8): a paused session is
      // held, not ended — the expectation and the connected
      // profile survive a refresh while paused (a Resume
      // re-enters the running branch above). Only the exit
      // line clears: there is no exit while paused. The
      // expectation is deliberately NOT set true here: after
      // an app restart mid-pause the supervision state is
      // unknown, and the next open re-reads it from the
      // running branch once the session resumes.
      exitInfo = null;
    }
    notifyListeners();
  }

  /// Reads the core's traffic deltas for the "proxy" outbound and
  /// adds them to the connected profile's cumulative totals. The
  /// native side reads the core's CUMULATIVE counters and converts
  /// against its remembered baseline (build 2125, A25-06 — the
  /// query no longer resets anything), so each call accounts
  /// exactly the bytes since the previous successful one; a call
  /// that fails loses nothing.
  Future<void> _pollStats() async {
    if (_statsBusy || !state.running) return;
    // Build 2123 (audit B-01): the sub-cadence gate — see
    // _lastStatsQueryMs. A skipped tick loses nothing (the
    // counters keep accumulating until the next read); a
    // failed read likewise only defers the accounting.
    final queryNowMs = DateTime.now().millisecondsSinceEpoch;
    if (queryNowMs - _lastStatsQueryMs < 12000) return;
    _lastStatsQueryMs = queryNowMs;
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
      // Build 2125 (audit A25-44): deltas consumed under an
      // id no profile currently matches are HELD, not
      // dropped — the native counters have already
      // advanced past them (and before build 2125's
      // A25-06 they were reset outright), so dropping them
      // lost the bytes permanently. A held delta lands on
      // the first later poll whose id matches a profile;
      // a hold under a DIFFERENT id is dropped with a
      // journal line (that session's profile is gone —
      // its totals have nowhere to live).
      if (_heldStatsId.isNotEmpty && _heldStatsId != id) {
        diagnostics.add(
          'stats',
          'dropping ${_heldStatsUp + _heldStatsDown} '
              'held bytes of a session whose profile is gone.',
        );
        _heldStatsId = '';
        _heldStatsUp = 0;
        _heldStatsDown = 0;
        _heldStatsAtMs = 0;
      }
      // Build 2126 (audit A26-17): the held portion
      // travels separately from here — the profile totals
      // take the merged sum, but the traffic history
      // books the held bytes at their CONSUMPTION time
      // (below), not this applying poll's hour.
      final heldUp = _heldStatsId == id ? _heldStatsUp : 0;
      final heldDown = _heldStatsId == id ? _heldStatsDown : 0;
      final heldAtMs = _heldStatsAtMs;
      var matched = false;
      for (final p in profiles) {
        if (p.id != id) continue;
        matched = true;
        _heldStatsId = '';
        _heldStatsUp = 0;
        _heldStatsDown = 0;
        _heldStatsAtMs = 0;
        p.totalUpBytes += up + heldUp;
        p.totalDownBytes += down + heldDown;
        p.statsUpdatedMs = DateTime.now().millisecondsSinceEpoch;
        // Build 2050 (audit B-M1): the write is debounced —
        // display reads memory, so nothing visible waits on
        // disk; _flushStatsSave lands the rest at session end.
        // The pending flag is set BEFORE the history record
        // (build 2105, verification iteration 1): the native
        // counters were already consumed above, so nothing the
        // history does may leave these totals unpersisted.
        _statsSavePending = true;
        _scheduleStatsFlush();
        // Build 2105: the traffic history takes the same
        // deltas into its hourly buckets — only while its
        // toggle is on; off, this branch never runs and the
        // store is never loaded. Isolated in its own try: a
        // history failure (any error, not just an Exception)
        // never strands the totals path.
        if (settings.trafficHistoryEnabled) {
          try {
            final history = await _trafficHistoryStore();
            if (history != null) {
              // Build 2126 (A26-17): the held portion is
              // booked at its consumption time; only this
              // poll's fresh delta takes this poll's hour.
              if (heldUp > 0 || heldDown > 0) {
                history.record(p.id, heldUp, heldDown, heldAtMs);
              }
              history.record(
                p.id,
                up,
                down,
                DateTime.now().millisecondsSinceEpoch,
              );
            }
          } catch (_) {
            // History is a chart, not the accounting.
          }
        }
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        // Build 2125 (audit A25-44): the stats SIDECAR now
        // flushes on every consuming poll — it is a small
        // file (that is what build 2123 made it for), so
        // the force-stop/LMK loss window shrinks from
        // 30 s to one poll interval. The history flush
        // keeps its 30 s debounce (its file is the store's
        // hourly buckets, rewritten whole).
        _statsSavePending = false;
        _statsFlushTimer?.cancel();
        _statsFlushTimer = null;
        await _saveStatsSidecar();
        if (nowMs - _lastStatsSaveMs >= 30000) {
          _lastStatsSaveMs = nowMs;
          final history = _trafficHistory;
          if (history != null && history.dirty) await history.flush();
        }
        notifyListeners();
        break;
      }
      if (!matched) {
        // Build 2125 (A25-44): no profile carries this
        // session's id right now — hold the consumed
        // deltas for a later poll instead of dropping
        // them (see the hold block above). Build 2126
        // (A26-17): an existing same-id hold accumulates
        // and keeps its ORIGINAL consumption time; the
        // hold is persisted to the sidecar at once, so a
        // kill while held loses nothing.
        if (_heldStatsId != id) {
          _heldStatsAtMs = DateTime.now().millisecondsSinceEpoch;
        }
        _heldStatsId = id;
        _heldStatsUp = up + heldUp;
        _heldStatsDown = down + heldDown;
        await _saveStatsSidecar();
      }
    } finally {
      _statsBusy = false;
    }
  }

  /// Persists stats totals a debounced poll left pending
  /// (build 2050): called at session end, so a disconnect never
  /// loses the tail of the session's traffic.
  Future<void> _flushStatsSave() async {
    _statsFlushTimer?.cancel();
    _statsFlushTimer = null;
    // Build 2105: the traffic history flushes at the same
    // points as the stats totals, dirty or not-pending alike.
    final history = _trafficHistory;
    if (history != null && history.dirty) {
      await history.flush();
    }
    if (!_statsSavePending) return;
    _statsSavePending = false;
    _lastStatsSaveMs = DateTime.now().millisecondsSinceEpoch;
    // Build 2123 (audit B-02): sidecar, not the whole store.
    await _saveStatsSidecar();
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
  /// Build 2147 (feature #14): a forced fresh exit read
  /// for the leak test's RUN ALL — clears the stored exit
  /// and the failure backoff, then fetches again. The
  /// result lands in [exitInfo] through the usual path.
  void refreshExitInfo() {
    exitInfo = null;
    _exitFailures = 0;
    _exitNextTryAt = null;
    _fetchExitInfo();
    notifyListeners();
  }

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
          // Build 2129 (leg 6): the online answer stays
          // primary; when it carries no country, the
          // offline range tables fill that field only
          // (see lib/net/geo_country.dart).
          exitInfo = await exitInfoWithOfflineCountry(ExitInfo.fromMap(m));
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
    state = _stampVerified(sample);
    if (sample.chainProblem.isNotEmpty &&
        sample.chainProblem != _lastChainProblem) {
      _lastChainProblem = sample.chainProblem;
      chainNotice = sample.chainProblem;
      diagnostics.add('chain', sample.chainProblem, ok: false);
    }
    if (sample.running) {
      // Build 2075: supervise the session's sidecar engine.
      // The core can be perfectly alive while a dead sidecar
      // blackholes every byte; check every fifth tick, and
      // when the sidecar is gone, end the session through
      // the ordinary drop path below (the next tick sees the
      // core down and the auto-reconnect / failover
      // machinery takes it from there, restarting the
      // sidecar with the session).
      if (_sessionSidecarPort != 0 && ++_sidecarTick % 5 == 0) {
        final st = _sessionSidecarKind == 'mieru'
            ? await MieruPlatform.state()
            : _sessionSidecarKind == 'sudokubox'
            ? await SudokuBoxPlatform.state()
            : await SingBoxPlatform.state();
        if (!st.running) {
          _sidecarUnreadyTicks = 0;
          diagnostics.add(
            'connect',
            'The $_sidecarLabel '
                'stopped mid-session; the session is being '
                'recovered.',
            ok: false,
          );
          unawaited(XrayPlatform.stop());
        } else if (!st.ready) {
          // Build 2125 (audit A25-27 / P-32): the listener
          // health is supervised too — up to 2124 only the
          // PROCESS was checked, so a sidecar that stayed
          // alive with a wedged listener blackholed the
          // session forever under a "Connected" label. Two
          // consecutive unready checks (the ready flag can
          // flicker once) take the same recovery path as a
          // dead process.
          if (++_sidecarUnreadyTicks >= 2) {
            _sidecarUnreadyTicks = 0;
            diagnostics.add(
              'connect',
              'The $_sidecarLabel '
                  'is running but its listener stopped '
                  'answering; the session is being recovered.',
              ok: false,
            );
            unawaited(XrayPlatform.stop());
          }
        } else {
          _sidecarUnreadyTicks = 0;
        }
      }
      // A tunnel that came up outside connect() (e.g. the service
      // outlived the page) still gets its exit line.
      _fetchExitInfo();
      // Build 2125 (audit A25-11 / P-12): the verified
      // latch's re-proof cadence.
      _maybeReproof(sample);
      // Build 2050 (audit B-H1): the stats query spawns native
      // processes, so it runs only when the tunnel's own byte
      // counters MOVED since the previous sample. A completely
      // idle tunnel skips it entirely; a busy one loses
      // nothing — the core's counters keep accumulating until
      // the next read (cumulative + baseline deltas since
      // build 2125; nothing is reset on read).
      if (last == null ||
          sample.upBytes != last.upBytes ||
          sample.downBytes != last.downBytes) {
        unawaited(_pollStats());
      }
      unawaited(_watchdogTick(sample));
      // Build 2147 (feature #12): the stall failover's own
      // tick — gated separately from the watchdog, it MOVES
      // the session instead of only changing its shape.
      unawaited(_stallFailoverTick(sample));
      // Build 2147 (features #1/#13): session-scoped upkeep —
      // the fetch proxy directives follow the session, and
      // the exit monitor re-checks the exit on its cadence.
      _syncFetchDirectives2147(sample);
      _exitMonitorTick2147(sample);
    }
    if (!sample.running && sample.paused) {
      // Build 2081 (verification V-8): the tunnel is PAUSED
      // from its notification, not dropped — the service is
      // still foreground with a Resume action, so this is a
      // held session, not an unexpected drop. The poll keeps
      // running, the expectation and the connected profile
      // stay (a Resume re-enters the running branch above),
      // and no reconnect is scheduled. The rates go to zero
      // and the rate baseline clears, so the first tick after
      // a Resume measures fresh traffic instead of a rate
      // averaged over the paused gap. The counted totals are
      // flushed (a pause is a session boundary, like a stop);
      // the sidecars stay up — the resumed core dials through
      // them again, and reaping them here would force a
      // needless restart on Resume.
      upRate = 0;
      downRate = 0;
      _lastSample = null;
      _lastSampleAt = null;
      exitInfo = null;
      unawaited(_flushStatsSave());
    }
    if (!sample.running && !sample.paused) {
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
      // Build 2107 (verification iteration 3): the drop ends
      // the Lab-dial state BEFORE the stats save below, so
      // the document it writes never pairs an empty connected
      // id with a dead session's candidate.
      _clearLabDialState();
      exitInfo = null;
      unawaited(_flushStatsSave());
      // Build 2075: a dropped session's sidecar + DNSCrypt
      // proxy are reaped here too — a reconnect restarts
      // them through the normal connect path, and without a
      // reconnect nothing may linger. Build 2127 (H1): the
      // Zapret desync proxy reaps on the same condition —
      // its session is a plain Xray one, so neither sidecar
      // marker is set for it.
      if (_sessionSidecarPort != 0 ||
          _sessionSidecarKind.isNotEmpty ||
          _sessionZapretStrategy.isNotEmpty) {
        unawaited(_stopSidecars());
      }
      if (_sessionDnsCrypt) {
        _sessionDnsCrypt = false;
        unawaited(DnsCryptPlatform.stop());
      }
      if (wasExpected && sample.userStopped) {
        // Build 2087 (analysis A2): the stop was the user's
        // own — the notification's Disconnect (the native
        // ACTION_STOP marks it; the app's own stop funnels
        // through the same action and has already cleared the
        // expectation itself). End the episode exactly like a
        // manual disconnect: no drop handling, no retry —
        // a session the user ended must not resurrect.
        _cancelReconnect();
        _expectRunning = false;
      } else if (wasExpected) {
        _onUnexpectedDrop(droppedId);
      }
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
      // Build 2116 (B13-1, 2098 F-A3): the session has
      // truly ended here — no retry will run — so a
      // deferred chain exit is consumed, as at a manual
      // disconnect. It used to outlive this end until
      // some later explicit disconnect.
      _consumePendingChainExit();
      return;
    }
    if (!shouldAutoReconnect(
      sessionExpected: _expectRunning,
      enabled: settings.autoReconnect,
      attemptsMade: _reconnectAttempts,
      maxAttempts: settings.reconnectMaxAttempts,
    )) {
      _expectRunning = false;
      // Build 2116 (B13-1): same true end — the policy
      // declines a retry, so the session is over.
      _consumePendingChainExit();
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
          // Build 2087: the retry restores a session that was
          // established and died — the one entry allowed to
          // walk the dead profile's fallback group (manual
          // connects no longer do; see [connect]).
          await connect(groupWalk: true);
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
      // Build 2116 (B13-1, 2098 F-A3): the episode is
      // exhausted — a true session end, so a deferred
      // chain exit is consumed here too.
      _consumePendingChainExit();
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

  /// Drives one state-poll tick against the platform channel's
  /// current answer (build 2081, V-8 test seam): the poll's
  /// drop/pause decisions run without waiting for the real
  /// 2 s timer.
  @visibleForTesting
  Future<void> testPollTick() => _pollTick();

  /// Arms the auto-reconnect expectation exactly as a
  /// successful connect does (build 2081, V-8 test seam):
  /// the poll treats a later tunnel-down sample as an
  /// unexpected drop for [profileId].
  @visibleForTesting
  void testExpectSession({required String profileId, String kind = 'xray'}) {
    _expectRunning = true;
    _reconnectKind = kind;
    _connectedProfileId = profileId;
  }

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

  /// Drives the chain path's WARP identity provisioning
  /// (build 2087, analysis A1): registers a fresh identity
  /// directly on the probe port when none is saved, so a host
  /// test can observe the one-attempt-per-episode rule without
  /// a full connect.
  @visibleForTesting
  Future<void> testProvisionWarpIdentityForChain() =>
      _provisionWarpIdentityForChain();

  /// True after a provisioning attempt failed in the current
  /// connect episode (build 2087).
  @visibleForTesting
  bool get testWarpProvisionFailed => _warpProvisionFailed;

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
  // ---------------------------------------------------------------
  // Build 2147 session machinery (#1/#2/#12/#13/#17/#21a)
  // ---------------------------------------------------------------

  /// Feature #2: this session's discovered MTU (0 = none).
  int _sessionMtuOverride = 0;

  /// Features #17/#21a: the housekeeping timer (see load()).
  Timer? _housekeepingTimer2147;

  /// Feature #21a state: the scheduled sweep's last run
  /// (in-memory cadence guard).
  int _sweepLastRunMs = 0;

  /// Feature #12 state: the last downlink total seen moving
  /// and when the current stall began.
  int _stallLastDown = -1;
  DateTime? _stallSince;

  /// Feature #13 state: the last exit re-check and the last
  /// exit identity journaled.
  DateTime _exitCheckedAt = DateTime.fromMillisecondsSinceEpoch(0);
  String _exitLastKey = '';
  bool _exitOutageNoted = false;

  /// Feature #2's probe: open a TCP connection to the dial
  /// endpoint and push a payload of [size] bytes; ANY answer
  /// (data, reset, close) within the timeout proves the path
  /// carries that size. A silent timeout is the black hole.
  Future<bool> _probeMtuSize2147(String host, int port, int size) async {
    Socket? socket;
    StreamSubscription<Uint8List>? sub;
    try {
      socket = await Socket.connect(
        host,
        port,
        timeout: const Duration(milliseconds: 2500),
      );
      final answered = Completer<bool>();
      sub = socket.listen(
        (_) {
          if (!answered.isCompleted) answered.complete(true);
        },
        onError: (_) {
          if (!answered.isCompleted) answered.complete(true);
        },
        onDone: () {
          if (!answered.isCompleted) answered.complete(true);
        },
      );
      socket.add(Uint8List(size));
      await socket.flush();
      return await answered.future.timeout(
        const Duration(milliseconds: 2500),
        onTimeout: () => false,
      );
    } catch (_) {
      return false;
    } finally {
      await sub?.cancel();
      socket?.destroy();
    }
  }

  /// Feature #2's walk: candidates descending; the first
  /// size that answers is the largest that fits.
  Future<int?> _discoverMtu2147(String host, int port) async {
    final answered = <bool>[];
    for (final size in kMtuWalkCandidates) {
      final ok = await _probeMtuSize2147(host, port, size);
      answered.add(ok);
      if (ok) break;
    }
    return pickMtuFromWalk(answered);
  }

  /// Feature #12: the stall failover — independent of the
  /// shape watchdog (its own gate, DEFAULT OFF). While the
  /// session runs, if the downlink does not move for the
  /// configured window, the session MOVES: the next member
  /// of the fallback group, or a reconnect when the group
  /// has nothing else.
  Future<void> _stallFailoverTick(XrayState sample) async {
    if (!settings.stallFailover) {
      _stallSince = null;
      _stallLastDown = -1;
      return;
    }
    if (!sample.running || connecting || _switchBusy) return;
    if (_stallLastDown < 0 || sample.downBytes != _stallLastDown) {
      _stallLastDown = sample.downBytes;
      _stallSince = null;
      return;
    }
    _stallSince ??= DateTime.now();
    final window = Duration(
      seconds: settings.stallFailoverSeconds < 5
          ? 5
          : settings.stallFailoverSeconds,
    );
    if (DateTime.now().difference(_stallSince!) < window) return;
    _stallSince = null;
    _stallLastDown = -1;
    final current = sessionProfile;
    if (current == null) return;
    diagnostics.add(
      'stall',
      'No downlink for ${window.inSeconds}s — the stall '
          'failover is moving the session.',
      ok: false,
    );
    final next = fallbackGroupMembers(current)
        .where((m) => m.id != current.id && !m.quarantined)
        .firstOrNull;
    if (next != null) {
      await switchServer(next);
    } else {
      _scheduleReconnect();
    }
  }

  /// Feature #1: keep the fetch proxy directives in step
  /// with the session — set while a session runs and the
  /// gate is on, cleared otherwise.
  void _syncFetchDirectives2147(XrayState sample) {
    final want = sample.running && settings.fetchViaTunnel
        ? 'SOCKS 127.0.0.1:${settings.socksPort}'
        : '';
    if (subFetchProxyDirective != want) subFetchProxyDirective = want;
    if (regionHopProxyDirective != want) regionHopProxyDirective = want;
  }

  /// Feature #13: the exit monitor — while a session runs
  /// and the gate is on, the exit identity is re-checked
  /// every minute and changes are journaled (a mid-session
  /// exit move is exactly the silent reroute this feature
  /// exists to surface). The exit machinery only fetches
  /// while [exitInfo] is null, so a re-check forces a fresh
  /// lookup by clearing it; the comparison happens when the
  /// fresh answer lands.
  void _exitMonitorTick2147(XrayState sample) {
    if (!settings.exitMonitorEnabled || !sample.running) return;
    final info = exitInfo;
    if (info == null) {
      // A known exit that stops answering is a change too —
      // journaled once per outage.
      if (_exitLastKey.isNotEmpty && !_exitOutageNoted) {
        _exitOutageNoted = true;
        diagnostics.add(
          'exit',
          'Exit monitor: the exit check no longer answers '
              'mid-session (last known exit: '
              '${_exitLastKey.replaceAll('|', ', ')}).',
          ok: false,
        );
      }
      return;
    }
    _exitOutageNoted = false;
    final key = '${info.ip}|${info.countryEn}';
    if (_exitLastKey.isEmpty) {
      _exitLastKey = key;
      _exitCheckedAt = DateTime.now();
      return;
    }
    if (key != _exitLastKey) {
      diagnostics.add(
        'exit',
        'Exit monitor: the exit moved mid-session — '
            '${_exitLastKey.replaceAll('|', ' (')}) → '
            '${info.ip} (${info.countryEn}).',
        ok: true,
      );
      _exitLastKey = key;
      _exitCheckedAt = DateTime.now();
      return;
    }
    if (DateTime.now().difference(_exitCheckedAt) <
        const Duration(seconds: 60)) {
      return;
    }
    _exitCheckedAt = DateTime.now();
    exitInfo = null;
    _fetchExitInfo();
  }

  /// Features #17/#21a: the housekeeping tick — scheduled
  /// profile tests (the starred set) and the scheduled ping
  /// sweep, each on its own gate and cadence.
  Future<void> _housekeepingTick2147() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (settings.scheduledTests &&
        now - settings.lastScheduledTestAtMs >=
            settings.scheduledTestIntervalMin * 60000) {
      settings.lastScheduledTestAtMs = now;
      final starred = profiles.where((p) => p.starred).toList();
      for (final p in starred) {
        await testDelay(p);
      }
      await _save();
      notifyListeners();
    }
    // The scheduled sweep runs at most hourly — a full
    // delay test of every config is heavy, and the strike
    // accounting (3 consecutive MISSES) is meaningless if
    // the sweeps land minutes apart.
    if (settings.pingSweepEnabled &&
        now - _sweepLastRunMs >= 3600000) {
      _sweepLastRunMs = now;
      await runPingSweep();
    }
  }

  Future<void> _watchdogTick(XrayState sample) async {
    // Build 2095 (feature 2): the user's master switch.
    if (!settings.stallWatchdog) return;
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
    // Build 2106 (journey audit F-02): an AmneziaWG session
    // stands this watchdog down too — the same exclusion
    // _adaptiveTick has always had, missing here. The probe
    // below is a SOCKS request to a listener an AWG session
    // does not have, so it failed every time; after two
    // failures the escalation rotated a core the native
    // side refuses to rotate while the WG Tunnel engine is
    // live, and journaled "Restarting the core; adaptive
    // failover takes it from here" while nothing restarted
    // and the adaptive tick stood down on its own AWG
    // guard. Futile probe cycles plus diagnostics that
    // lied. A dead AWG peer is handled where handling
    // exists: the connect-time peer walk's adoption proof
    // (F-01) before a session is adopted, and the backend's
    // own handshake retries after.
    if (awgSession) return;
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
      // Build 2096 (post-2095 audit L3): re-check the
      // master switch after the probe await — a user who
      // turned the watchdog OFF while the probe was in
      // flight is honoured before anything rotates.
      if (!settings.stallWatchdog) return;
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
    // Build 2096 (audit L3): the escalation itself also
    // stands down when the switch went off mid-flight.
    if (!settings.stallWatchdog) return;
    // Build 2107 (verification iteration 1): a session dialed
    // with a remembered DPI Lab strategy keeps that strategy —
    // the shapes below are computed from the stored profile,
    // so escalating would silently discard the Lab's win (an
    // af-* candidate has no shape representation at all), and
    // a shape win recorded from such an escalation would name
    // a config the Lab never graded. Adaptive failover owns
    // recovery for a Lab-dialed session.
    // Verification iteration 2: the stand-down holds only
    // while the Lab is still ON (toggling it off mid-session
    // restores the 2106 watchdog behaviour for that session),
    // it resets the watchdog bases like every other terminal
    // branch (otherwise a stalled Lab session re-ran the
    // probe cycle and re-journaled every two ticks forever),
    // and it journals once per session.
    if (_labDialActive && settings.dpiLabEnabled) {
      if (!_labStandDownJournaled) {
        _labStandDownJournaled = true;
        diagnostics.add(
          'watchdog',
          'This session was dialed with the DPI Lab strategy '
              '($_labDialCandidateId) for this network; shape '
              'escalation stands down'
              '${settings.adaptiveFailover ? ' and adaptive failover takes it from here.' : '.'}',
        );
      }
      _resetWatchdogBases();
      return;
    }
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
          olcrtcUnderlay: settings.underlay == 'olcrtc',
          wgWstunnelPort: _sessionWgWstunnelPort,
          sidecarSocksPort: _sessionSidecarPort,
          wgPeerProfiles: _wgPeersFor(p),
          // Build 2105: the session's provider-DNS pins ride
          // every rotation (see _sessionProviderPins) — while
          // the feature is still on; a mid-session toggle-off
          // is honoured at the next rotation. Build 2110: the
          // server-name pins ride UNCONDITIONALLY (the
          // default resolution path has no toggle), merged
          // under the provider pins per name.
          serverHostPins: _mergedServerPins(
            _sessionServerPins,
            settings.providerDnsEnabled
                ? _sessionProviderPins
                : const {},
          ),
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
        olcrtcUnderlay: settings.underlay == 'olcrtc',
        wgWstunnelPort: _sessionWgWstunnelPort,
        sidecarSocksPort: _sessionSidecarPort,
        wgPeerProfiles: _wgPeersFor(p),
        // Build 2105: the session's provider-DNS pins ride
        // every rotation (see _sessionProviderPins) — while
        // the feature is still on; a mid-session toggle-off
        // is honoured at the next rotation. Build 2110: the
        // server-name pins ride unconditionally, merged
        // under the provider pins per name (as above).
        serverHostPins: _mergedServerPins(
          _sessionServerPins,
          settings.providerDnsEnabled ? _sessionProviderPins : const {},
        ),
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
  /// 'dnstt' | 'olcrtc').
  /// Applies to the NEXT V2Ray session: a running session
  /// keeps the shape it started with.
  Future<void> setUnderlay(String value) async {
    settings.underlay = switch (value) {
      'psiphon' => 'psiphon',
      'warp' => 'warp',
      'dnstt' => 'dnstt',
      'olcrtc' => 'olcrtc',
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
      'olcrtc' =>
        'Underlay set to OLCRTC: the next V2Ray session '
            'will run over a WebRTC video-call tunnel.',
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

  /// Persists the OLCRTC underlay fields (build 2134).
  /// The provider/transport are whitelist-clamped here as
  /// well as at store read, so the settings page can pass
  /// its raw selections.
  Future<void> saveOlcrtcSettings({
    required String provider,
    required String transport,
    required String room,
    required String key,
    required String token,
    required String dns,
    Map<String, String> params = const {},
  }) async {
    settings.olcrtcProvider = kOlcrtcProviders.contains(provider)
        ? provider
        : 'jitsi';
    settings.olcrtcTransport = kOlcrtcTransports.contains(transport)
        ? transport
        : 'datachannel';
    settings.olcrtcRoom = room.trim();
    settings.olcrtcKey = key.trim();
    settings.olcrtcToken = token.trim();
    settings.olcrtcDns = dns.trim().isEmpty ? '8.8.8.8:53' : dns.trim();
    // Per-transport tuning ('' = upstream default).
    settings.olcrtcVp8Fps = (params['vp8Fps'] ?? settings.olcrtcVp8Fps).trim();
    settings.olcrtcVp8Batch = (params['vp8Batch'] ?? settings.olcrtcVp8Batch)
        .trim();
    settings.olcrtcSeiFps = (params['seiFps'] ?? settings.olcrtcSeiFps).trim();
    settings.olcrtcSeiBatch = (params['seiBatch'] ?? settings.olcrtcSeiBatch)
        .trim();
    settings.olcrtcSeiFrag = (params['seiFrag'] ?? settings.olcrtcSeiFrag)
        .trim();
    settings.olcrtcSeiAckMs = (params['seiAckMs'] ?? settings.olcrtcSeiAckMs)
        .trim();
    settings.olcrtcVideoWidth =
        (params['videoWidth'] ?? settings.olcrtcVideoWidth).trim();
    settings.olcrtcVideoHeight =
        (params['videoHeight'] ?? settings.olcrtcVideoHeight).trim();
    settings.olcrtcVideoFps = (params['videoFps'] ?? settings.olcrtcVideoFps)
        .trim();
    settings.olcrtcVideoCodec =
        (params['videoCodec'] ?? settings.olcrtcVideoCodec).trim();
    settings.olcrtcVideoQrSize =
        (params['videoQrSize'] ?? settings.olcrtcVideoQrSize).trim();
    settings.olcrtcVideoQrRecovery =
        (params['videoQrRecovery'] ?? settings.olcrtcVideoQrRecovery).trim();
    settings.olcrtcVideoTileModule =
        (params['videoTileModule'] ?? settings.olcrtcVideoTileModule).trim();
    settings.olcrtcVideoTileRs =
        (params['videoTileRs'] ?? settings.olcrtcVideoTileRs).trim();
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

  /// Build 2080: the chain path's identity provisioning —
  /// the ensureIdentity equivalent the Aether slots always
  /// had and this path never did. A chained core cannot
  /// register a missing identity: its registration egress
  /// would ride the --upstream through the very exit-node
  /// the chain is trying to prove, so readiness simply never
  /// arrived. When no identity is saved, one is registered
  /// first by a DIRECT run on the probe port — the
  /// standalone card's own first-run path (a normal run
  /// registers a missing identity; AETHER_REPROVISION=0
  /// only forbids silently replacing a REFUSED one) — then
  /// stopped, and only then does the chained session start,
  /// against the settled identity in the same store
  /// (noBackupFilesDir/emberwarp).
  ///
  /// Build 2087 (analysis A1): the registration run gets the
  /// chain grace (150 s) on both sides of the channel — its
  /// bind follows the Cloudflare registration round-trips,
  /// and the native readiness wait now retries the greeting
  /// connect until its deadline instead of latching an error
  /// on the first refusal. And a failed registration is
  /// remembered for the rest of the connect episode
  /// ([_warpProvisionFailed]): the fallback-group walk must
  /// not re-run it per member.
  Future<void> _provisionWarpIdentityForChain() async {
    final before = await WarpPlatform.state();
    if (before.identityPresent) {
      _warpProvisionFailed = false;
      return;
    }
    if (_warpProvisionFailed) {
      // Already attempted in this episode: the one failure
      // is already in the journal; fail this member quietly
      // instead of starting the core again.
      throw StateError('underlay-failed');
    }
    diagnostics.add(
      'chain',
      'No saved WARP identity yet — registering one directly '
          'before the chained session (a chained core cannot '
          'register through its own exit).',
    );
    final probeArgs = buildWarpArgs(warpProfile, port: warpProbePort);
    final ok = await _awaitWarpReady(
      probeArgs,
      port: warpProbePort,
      wait: const Duration(seconds: 150),
      nativeWait: const Duration(seconds: 150),
    );
    await WarpPlatform.stop();
    if (!ok) {
      _warpProvisionFailed = true;
      diagnostics.add(
        'chain',
        'The WARP identity could not be registered directly; '
            'the chained session was not started.',
        ok: false,
      );
      throw StateError('underlay-failed');
    }
    diagnostics.add(
      'chain',
      'WARP identity registered; the chained session starts '
          'against it.',
      ok: true,
    );
  }

  /// Starts the EmberWarp core with [args] (unless it already
  /// runs) and waits for its data-plane readiness — the core
  /// answers its SOCKS greeting only after a gateway carried
  /// a real check, so a ready answer IS the proof. False on
  /// timeout, process death, or a refused identity; the
  /// journal says which.
  ///
  /// Build 2080: a core that is already running is NEVER
  /// restarted from here. In chain mode the VPN service now
  /// spawns the core with the session, so by the time this
  /// wait runs the core is normally mid-scan — the old code
  /// respawned it (killing the scan and restarting the clock
  /// this wait measures) whenever it was running but not yet
  /// ready. [wait] is the readiness budget: 90 s direct; a
  /// chained start passes the chain budget (150 s), matching
  /// the core's chained greeting wait.
  ///
  /// Build 2087 (analysis A1): [nativeWait], when given, is
  /// handed to the native start as the greeting-wait budget,
  /// so a spawn whose bind is slow (the registration run)
  /// gets the same window on both sides of the channel. The
  /// native wait itself now retries the greeting connect
  /// until its deadline, so a 'starting' stage is a scan in
  /// flight, not a race already lost.
  Future<bool> _awaitWarpReady(
    List<String> args, {
    int port = 20850,
    Duration wait = const Duration(seconds: 90),
    Duration? nativeWait,
  }) async {
    final before = await WarpPlatform.state();
    if (!before.running) {
      diagnostics.add('warp', 'Starting the EmberWarp core…');
      final spawned = await WarpPlatform.start(
        args,
        port: port,
        greetingWaitMs: nativeWait?.inMilliseconds,
      );
      if (!spawned) {
        // Build 2095 (third-pass audit 3-2): include the
        // core's own error (mirrors the DNSTT path).
        final st = await WarpPlatform.state();
        diagnostics.add(
          'warp',
          'The EmberWarp core could not start.'
              '${st.error.isEmpty ? '' : ' The core said: ${st.error}'}',
          ok: false,
        );
        return false;
      }
    } else if (!before.ready) {
      diagnostics.add(
        'warp',
        'The EmberWarp core is already starting; waiting for '
            'its scan to finish…',
      );
    }
    final deadline = DateTime.now().add(wait);
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
    // Build 2095 (audit 3-2): the last state error rides
    // along instead of the bare timeout sentence.
    final lastErr = warpState.error;
    diagnostics.add(
      'warp',
      'The EmberWarp core did not become ready in time.'
          '${lastErr.isEmpty ? '' : ' The core said: $lastErr'}',
      ok: false,
    );
    return false;
  }

  /// The standalone WARP session (the WARP MASQUE card):
  /// the core first, readiness-proven, then the TUN service
  /// in warp mode — no Xray process anywhere in the path.
  Future<void> connectWarp() async {
    if (connecting) return; // Build 2095 (audit 2.2).
    // Build 2095 (audit 2.1): same generation discipline
    // as _connectSelected.
    _tunnelGen++;
    final gen = _tunnelGen;
    connecting = true;
    lastError = null;
    exitInfo = null;
    // Build 2125 (audit A25-14 / P-15, surfacing half):
    // with the kill switch on, the journal states the
    // window it cannot cover — from here until the new
    // tunnel's data-plane proof lands there is no TUN to
    // hold (a switch has already torn the old one down),
    // so traffic is direct in between. The hold covers a
    // tunnel that EXISTS and drops; it cannot cover the
    // window before one exists. (Closing the window
    // itself is parked: it needs a pre-established
    // blackhole TUN — a different service shape, beyond
    // this build's safe blast radius.)
    if (settings.killSwitch) {
      diagnostics.add(
        'connect',
        'Kill switch: the connect/switch window is not '
            'covered until the new tunnel proves it '
            'carries traffic — the hold applies once a '
            'tunnel exists.',
        ok: false,
      );
    }
    // A fresh connect supersedes a pending retry (build 2042).
    _cancelReconnectTimer();
    // Build 2098 (post-2097 audit M4): whether this attempt
    // issued its native start — the cancellation path below
    // uses it to stop a start that raced the disconnect
    // (the same startIssued discipline _connectSelected got
    // in build 2097 C2; connectWarp never received it).
    var startIssued = false;
    notifyListeners();
    try {
      await stopOtherEngine?.call();
      if (state.running) await _stopTunnel();
      final args = buildWarpArgs(warpProfile);
      if (!await _awaitWarpReady(args)) {
        throw StateError('warp-failed');
      }
      if (gen != _tunnelGen) throw const _ConnectCancelled();
      await XrayPlatform.setOnWarp(
        name: warpSessionName,
        dns: settings.localDns,
        ipv6: settings.ipv6Route,
        mtu: settings.tunnelMtu,
        warpArgs: args,
        killSwitch: settings.killSwitch,
      );
      startIssued = true;
      for (var i = 0; i < 40; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        state = await XrayPlatform.state();
        // Build 2098 (post-2097 audit M4): C2's order — the
        // aliveness check belongs AFTER the state read, so a
        // disconnect landing inside the await is seen before
        // this attempt can adopt the session it just stopped.
        // connectWarp kept the pre-C2 order (check, then read).
        if (gen != _tunnelGen) throw const _ConnectCancelled();
        if (state.running) break;
      }
      if (!state.running) {
        // Build 2095 (audit 3-1): same coreProblem carry
        // as _connectSelected.
        final problem = state.coreProblem;
        if (problem.isNotEmpty) {
          diagnostics.add('connect', 'Start failed: $problem', ok: false);
          throw StateError('start-failed: $problem');
        }
        throw StateError('start-failed');
      }
      warpSession = true;
      // Build 2123 (audit C-01): as on the V2Ray path —
      // an uncovered IPv6 family is journaled at adoption,
      // not left silent.
      final warpIpv6Note = ipv6UncoveredSessionNote(settings);
      if (warpIpv6Note != null) {
        diagnostics.add('warp', warpIpv6Note, ok: false);
      }
      // The session is up and nobody disconnected it (build
      // 2042): a later unexpected drop may auto-reconnect it.
      _expectRunning = true;
      _reconnectKind = 'warp';
      _connectedProfileId = '';
      // Build 2092 (UI audit item 5): the underlay session's
      // empty connected id is persisted too (see _save).
      unawaited(_save());
      _lastSample = state;
      _lastSampleAt = DateTime.now();
      _startPolling();
      _fetchExitInfo();
    } catch (e) {
      // Build 2095 (audit 2.1): a superseded attempt
      // unwinds quietly.
      if (e is _ConnectCancelled) {
        lastError = null;
        // Build 2098 (post-2097 audit M4): if this attempt
        // already issued its start, the disconnect's stop may
        // have raced ahead of it (stop landed before setOnWarp
        // executed) and left the TUN up under a session the
        // user already ended — stop the start itself, exactly
        // as _connectSelected's C2 path does. The pre-2098
        // catch stopped only the WARP core, which cannot bring
        // a raised TUN down.
        if (startIssued) {
          state = await XrayPlatform.state();
          if (state.running) await _stopTunnel();
        }
        if (!state.running) unawaited(WarpPlatform.stop());
        return;
      }
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

  /// Starts the OLCRTC underlay client and waits until
  /// its local SOCKS listener accepts (build 2134). The
  /// client opens that listener only AFTER its WebRTC
  /// link to the server peer is up, so readiness is real
  /// link proof — and can take a while (room join + peer
  /// discovery + handshake), hence the 110 s budget
  /// (inside OlcrtcCore's 120 s probe window). The
  /// generated YAML is written to filesDir/olcrtc/
  /// config.yaml first; its path is the client's only
  /// argument and the value the native ChainSupervisor
  /// respawns with. Throws StateError(
  /// 'olcrtc-not-configured') when the fields are
  /// incomplete, and StateError('underlay-failed') after
  /// stopping the client again when it will not start —
  /// a chained session must never start against a dead
  /// underlay. [checkAlive] is the caller's cancellation
  /// check: the readiness wait observes it (build 2135,
  /// audit A34-04).
  Future<List<String>> _startOlcrtcUnderlay(
    void Function() checkAlive,
  ) async {
    if (!olcrtcConfigured(settings)) {
      diagnostics.add(
        'chain',
        'OLCRTC is the selected underlay but its settings '
            'are incomplete — a provider, a room and the '
            'shared key (64 hex digits) are all required. '
            'Open OLCRTC settings on the home card.',
        ok: false,
      );
      throw StateError('olcrtc-not-configured');
    }
    final coreDir = await AndroidCore.dataDir();
    final dir = Directory('${File(coreDir).parent.path}/olcrtc');
    await dir.create(recursive: true);
    final configFile = File('${dir.path}/config.yaml');
    await AtomicJsonStore.writeText(configFile, buildOlcrtcYaml(settings));
    final args = [configFile.path];
    diagnostics.add(
      'chain',
      'Starting the OLCRTC underlay (${settings.olcrtcProvider} '
          'room ${settings.olcrtcRoom} over '
          '${settings.olcrtcTransport})…',
    );
    if (!await OlcrtcPlatform.start(args)) {
      final st = await OlcrtcPlatform.state();
      diagnostics.add(
        'chain',
        'The OLCRTC client would not start'
            '${st.error.isEmpty ? '' : ': ${st.error}'}',
        ok: false,
      );
      throw StateError('underlay-failed');
    }
    final deadline = DateTime.now().add(const Duration(seconds: 110));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      // Build 2135 (audit A34-04): the wait observes
      // cancellation. Up to 2134 the loop polled only the
      // client's state, so a Disconnect tap during link-up
      // appeared ignored until the wait resolved (up to
      // 110 s). Now the tap aborts the wait at the next
      // poll: the client is stopped here — no orphan — and
      // the attempt unwinds as cancelled, exactly like a
      // cancellation at any other pre-start step.
      try {
        checkAlive();
      } on _ConnectCancelled {
        await OlcrtcPlatform.stop();
        rethrow;
      }
      final st = await OlcrtcPlatform.state();
      if (st.ready) {
        diagnostics.add(
          'chain',
          'The OLCRTC link is up; the client is listening '
              'on 127.0.0.1:$olcrtcListenPort.',
          ok: true,
        );
        return args;
      }
      if (!st.running || st.stage == 'error') {
        diagnostics.add(
          'chain',
          'The OLCRTC client stopped during start'
              '${st.error.isEmpty ? '' : ': ${st.error}'}',
          ok: false,
        );
        throw StateError('underlay-failed');
      }
    }
    diagnostics.add(
      'chain',
      'The OLCRTC link did not come up in time (the peer '
          'may be offline or the room unreachable); the '
          'chained session was not started.',
      ok: false,
    );
    await OlcrtcPlatform.stop();
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
    if (connecting) return; // Build 2095 (audit 2.2).
    // Build 2095 (audit 2.1): a disconnect during the
    // candidate walk stops the walk.
    _tunnelGen++;
    var gen = _tunnelGen;
    // A fresh connect supersedes a pending retry (build 2042).
    _cancelReconnectTimer();
    // Build 2087 (analysis A1): a new connect episode — the
    // chain path's WARP registration gets one fresh attempt
    // (see [_warpProvisionFailed]).
    _warpProvisionFailed = false;
    // Build 2139 (A34-02 re-fix): a new connect episode —
    // the no-DNS warning may fire once per profile again
    // (see _providerDnsNoDnsWarned).
    _providerDnsNoDnsWarned.clear();
    awgFallbackNotice = '';
    final group = profiles
        .where(
          (p) =>
              p.protocol == Protocol.wireguard &&
              wgGroupKey(p) == wgGroupKey(first),
        )
        .toList();
    // Build 2147 (feature #10): the profile's own fallback
    // endpoints walk right after the primary — the same
    // profile with a rewritten endpoint (copies, the stored
    // profile is untouched), before the group's other
    // members. An empty list adds nothing: the walk is
    // exactly every earlier build's.
    final ordered = [
      first,
      ...wgConnectCandidates(first).skip(1),
      ...group.where((p) => p.id != first.id && !p.quarantined),
    ];
    Object? lastFailure;
    // Build 2050 (audit C-1): the name of a candidate whose
    // AmneziaWG attempt failed, so a plain-WireGuard success
    // below can say — visibly, not only in the journal — that
    // the session is NOT obfuscated.
    String? awgFailedFor;
    // Build 2106 (journey audit F-01): HOW the AmneziaWG
    // attempt failed — true when the engine started but the
    // peer stayed silent through the adoption window, false
    // when the engine could not start at all. The fallback
    // notice below words itself by this, so neither failure
    // is described as the other.
    var awgFailureWasSilence = false;
    // Build 2106 (verification iteration 2, L-1): the third
    // failure kind — the session ENDED inside the window
    // (revoked, dropped) rather than staying silent. Worded
    // as its own kind for the same reason.
    var awgFailureWasDeath = false;
    for (final candidate in ordered) {
      // Build 2095 (audit 2.1).
      if (gen != _tunnelGen) return;
      selectedProfileId = candidate.id;
      notifyListeners();
      if (candidate.hasUnsupportedJParams) {
        // Build 2106 (journey audit F-05): J1–J3 are stored
        // and exported, but the WG Tunnel engine has no slot
        // for them — journal that they are ignored instead
        // of letting the session present them as applied
        // obfuscation.
        diagnostics.add(
          'awg',
          '${candidate.name} carries J1–J3 parameters, which '
              'this AmneziaWG engine does not support — they '
              'are ignored.',
          ok: false,
        );
      }
      // Build 2106 (journey audit F-05): the AWG branch keys
      // on the parameters the engine actually runs — a
      // candidate whose only Amnezia parameters are J1–J3
      // goes straight to the plain leg below, because the
      // obfuscated engine would apply nothing for it.
      if (candidate.hasSupportedAmneziaParams) {
        bool awgUp;
        try {
          awgUp = await _connectAwg(candidate);
        } on _ConnectCancelled {
          // Build 2096 (audit H4): a disconnect superseded
          // the AWG attempt — the whole walk ends, it does
          // NOT fall through to the plain leg.
          return;
        }
        if (awgUp) {
          // Build 2106 (journey audit F-01): Up is the
          // engine's START verdict, not the walk's adoption
          // verdict. Builds 2104–2105 adopted the session
          // here on Up alone, so a started-but-silent peer
          // (blocked UDP, wrong key, dead server, DPI)
          // showed Connected forever with zero traffic and
          // no fallback — the mirror image of the 2103 bug
          // (working tunnels torn down). The walk now
          // demands the same class of proof the plain leg
          // below demands: the peer must demonstrably answer
          // inside the adoption window (see
          // _awgAdoptionProof). A peer that answers is
          // adopted and never re-proven; a silent one costs
          // only its place in this walk.
          final proven = await _awgAdoptionProof();
          if (proven == null) return; // Superseded mid-proof.
          if (proven) {
            // AmneziaWG is up, its peer answers, and nobody
            // disconnected it (build 2042): a later
            // unexpected drop may auto-reconnect it through
            // this same fallback path.
            _expectRunning = true;
            _reconnectKind = 'wireguard';
            await _save();
            return;
          }
          awgFailedFor = candidate.name;
          awgFailureWasSilence = !_awgProofDied;
          awgFailureWasDeath = _awgProofDied;
          diagnostics.add(
            'awg',
            _awgProofDied
                ? 'The AmneziaWG session for ${candidate.name} '
                      'ended before it carried traffic; falling '
                      'back to plain WireGuard for this peer.'
                : 'The AmneziaWG peer for ${candidate.name} has '
                      'not answered; falling back to plain '
                      'WireGuard for this peer.',
            ok: false,
          );
          // End the unproven leg before the plain leg runs:
          // the same gen discipline as the plain leg's
          // silent-peer stop below (build 2098, M5) —
          // absorb ONLY this stop's own bump; any extra
          // bump is a user disconnect landing inside the
          // stop, and it ends the walk.
          final genBeforeOwnDisconnect = _tunnelGen;
          // Build 2106 (verification iteration 2, M-1): a
          // NOTIFICATION disconnect landing inside this
          // stop adds no Dart bump — the native stop funnel
          // marks every stop a user stop, so the flag cannot
          // tell it apart from this walk's own stop. The
          // engine's notification-stop sequence can: only
          // the notification's entry points advance it.
          // Snapshot it now; re-read after the stop.
          final userStopSeqBefore = state.awgUserStopSeq;
          // This stop is a step of the walk, not a session
          // end — a deferred chain exit survives it (build
          // 2098, verification iteration 2).
          await disconnect(consumeChainExit: false);
          if (_tunnelGen != genBeforeOwnDisconnect + 1) return;
          await refreshState();
          if (state.awgUserStopSeq != userStopSeqBefore) {
            // The user stopped this session from its
            // notification while the walk was tearing the
            // leg down. Their stop wins: the walk ends, the
            // plain leg does NOT reconnect over it.
            return;
          }
          gen = _tunnelGen;
          // Build 2110 (wg-start diagnosis D1): ONE
          // vanilla-safe attempt before the plain leg. The
          // shaped attempt above was SILENT (the session did
          // not die — the peer simply never answered) and
          // this profile rewrites the handshake itself
          // (S/H): a server that is not an AmneziaWG server
          // — a vanilla WireGuard endpoint, Cloudflare WARP
          // above all — silently drops such initiations, so
          // retry once with the shaping neutralized (junk
          // and the I1 signature KEPT: they ride separate
          // datagrams and cannot block a handshake). A
          // genuine AmneziaWG server answers the shaped
          // attempt first and never reaches this leg; a
          // profile without shaping keeps the 2106 walk
          // exactly. The stored profile is never rewritten —
          // the attempt runs on a copy.
          if (awgFailureWasSilence && candidate.hasInitiationShaping) {
            final retryProfile = candidate.copyWithoutInitiationShaping();
            diagnostics.add(
              'awg',
              'Retrying ${candidate.name} once with the '
                  'handshake shaping removed (S=0, H '
                  'standard; junk and I1 kept) — if this '
                  'server is a plain WireGuard server, the '
                  'shaped handshake was being dropped.',
            );
            bool retryUp;
            try {
              retryUp = await _connectAwg(retryProfile);
            } on _ConnectCancelled {
              // As the shaped attempt above: a disconnect
              // superseding the retry ends the whole walk.
              return;
            }
            if (retryUp) {
              final retryProven = await _awgAdoptionProof();
              if (retryProven == null) return; // Superseded.
              if (retryProven) {
                diagnostics.add(
                  'awg',
                  '${candidate.name} answered with the '
                      'handshake shaping removed — this '
                      'server is a plain WireGuard server, '
                      'not an AmneziaWG one.',
                  ok: true,
                );
                // Adopted exactly like the shaped leg.
                _expectRunning = true;
                _reconnectKind = 'wireguard';
                await _save();
                return;
              }
              awgFailureWasSilence = !_awgProofDied;
              awgFailureWasDeath = _awgProofDied;
              diagnostics.add(
                'awg',
                'The de-shaped retry for ${candidate.name} '
                    'was not answered either; falling back '
                    'to plain WireGuard for this peer.',
                ok: false,
              );
              // The same teardown discipline as the shaped
              // leg's stop above (gen bump + notification
              // stop sequence).
              final retryGenBeforeStop = _tunnelGen;
              final retryStopSeqBefore = state.awgUserStopSeq;
              await disconnect(consumeChainExit: false);
              if (_tunnelGen != retryGenBeforeStop + 1) return;
              await refreshState();
              if (state.awgUserStopSeq != retryStopSeqBefore) return;
              gen = _tunnelGen;
            } else {
              diagnostics.add(
                'awg',
                'The de-shaped retry for ${candidate.name} '
                    'could not start; falling back to plain '
                    'WireGuard for this peer.',
                ok: false,
              );
            }
          }
        } else {
          awgFailedFor = candidate.name;
          awgFailureWasSilence = false;
          awgFailureWasDeath = false;
          // Build 2104: the start-failure line says exactly
          // that, per peer. The pre-2104 line announced a
          // downgrade to "plain WireGuard" as if the session
          // had left the AWG engine behind, while the walk's
          // next Amnezia candidate ran the full AWG engine
          // again — the owner's 2026-11-18 device logs show
          // the device start after such an announcement
          // still composing the full Amnezia set (session
          // B: junk params, i1 set). The plain leg itself
          // runs through the Xray core's WireGuard outbound,
          // which carries no Amnezia fields at all. Build
          // 2106: a peer that starts but stays silent takes
          // the branch above, with its own line — the two
          // failures are no longer conflated.
          diagnostics.add(
            'awg',
            'AmneziaWG engine could not start for ${candidate.name}; '
                'falling back to plain WireGuard for this peer.',
            ok: false,
          );
        }
      }
      // The plain WireGuard leg (build 2057, audit F-M10): the
      // fallback-group walk directly, NOT connect() — connect()
      // routes WireGuard back into this function, and calling it
      // here would recurse.
      try {
        await _connectWithFallbackGroup();
      } catch (e) {
        // Build 2095 (audit 2.1): a user disconnect inside
        // the leg cancels the whole walk; a plain failure
        // moves to the next candidate (the leg's own gen
        // bumps are absorbed).
        if (e is _ConnectCancelled) return;
        lastFailure = e;
        gen = _tunnelGen;
        continue;
      }
      // Build 2096 (post-2095 audit H3): the leg bumps
      // _tunnelGen itself (every _connectSelected attempt
      // does), so a successful leg ALWAYS left gen stale —
      // the build-2095 check here returned after every
      // successful leg, which made the carries probe below
      // and every next-peer attempt unreachable: a silent
      // first peer showed "connected" with no traffic and
      // no fallback. Absorb the leg's own bumps now that
      // it succeeded (a disconnect DURING the leg throws
      // _ConnectCancelled out of it, handled above; one
      // landing after it bumps the gen again and the
      // probe loop + verdict re-checks below catch it).
      gen = _tunnelGen;
      // The TUN is up; WireGuard is connectionless, so only a
      // carried request proves the peer. The exit lookup rides
      // the same path; a tunnel-check request is the verdict.
      final deadline = DateTime.now().add(const Duration(seconds: 12));
      var carries = false;
      while (DateTime.now().isBefore(deadline)) {
        if (gen != _tunnelGen) return;
        await refreshState();
        if (!state.running) break;
        if (exitInfo != null) {
          carries = true;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 800));
      }
      if (gen != _tunnelGen) return;
      if (!carries && state.running) {
        final ms = await XrayPlatform.tunnelCheck(
          settings.socksPort,
          socksUser: _lanUser,
          socksPass: _lanPass,
        );
        carries = ms >= 0;
        // Build 2097 (post-2096 audit N2): the tunnel check
        // can take seconds — a disconnect landing inside it
        // must not be followed by this walk adopting the
        // session (setting _expectRunning below would leave
        // an expected-but-dead session the supervision could
        // auto-reconnect after the user's stop lands).
        if (gen != _tunnelGen) return;
      }
      // Build 2135 (audit A34-05): the same grace the Xray
      // leg's proof takes (see awaitXrayCarries) — when
      // bytes came back during the window, ONE confirmation
      // re-check after ~5 s before this peer is stamped
      // silent. Zero downlink: the pre-2135 verdict stands,
      // and the failure tail below runs exactly as before.
      if (!carries && state.running && await _proofSawDownlink()) {
        if (gen != _tunnelGen) return;
        diagnostics.add(
          'connect',
          'The WireGuard proof window closed, but bytes '
              'are coming back — one confirmation re-check '
              'after a short grace.',
        );
        await Future<void>.delayed(const Duration(seconds: 5));
        if (gen != _tunnelGen) return;
        await refreshState();
        if (gen != _tunnelGen) return;
        if (state.running) {
          if (exitInfo != null) {
            carries = true;
          } else {
            final ms = await XrayPlatform.tunnelCheck(
              settings.socksPort,
              socksUser: _lanUser,
              socksPass: _lanPass,
            );
            if (gen != _tunnelGen) return;
            carries = ms >= 0;
          }
        }
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
          // obfuscation the profile carries. Build 2106
          // (F-01): worded by the failure kind — a peer that
          // never answered is not described as an engine
          // that could not start.
          awgFallbackNotice = awgFailureWasDeath
              ? 'The AmneziaWG session for $awgFailedFor ended '
                    'before it carried traffic — this session '
                    'runs as plain WireGuard, without '
                    'obfuscation.'
              : awgFailureWasSilence
              ? 'The AmneziaWG peer for $awgFailedFor did not '
                    'answer — this session runs as plain '
                    'WireGuard, without obfuscation.'
              : 'AmneziaWG could not start for $awgFailedFor — '
                    'this session runs as plain WireGuard, without '
                    'obfuscation.';
        }
        await _save();
        return;
      }
      lastFailure = StateError('peer-silent');
      // Build 2098 (post-2097 audit M5): disconnect() bumps
      // _tunnelGen exactly once — snapshot before it and
      // absorb ONLY that one bump (build 2096 H3's reason for
      // re-baselining here). The pre-2098 code re-baselined
      // unconditionally, so a USER disconnect landing inside
      // this await was absorbed as if it were the walk's own,
      // and the walk went on to connect the next peer over
      // the user's stop. Any extra bump ends the walk.
      final genBeforeOwnDisconnect = _tunnelGen;
      // Build 2098 (verification, iteration 2): this stop
      // is a step of the walk, not a session end — a chain
      // exit deferred during the session must survive it
      // (see disconnect's consumeChainExit).
      await disconnect(consumeChainExit: false);
      if (_tunnelGen != genBeforeOwnDisconnect + 1) return;
      gen = _tunnelGen;
    }
    throw StateError(
      lastFailure is StateError && lastFailure.message == 'no-profile'
          ? 'no-profile'
          : 'wg-all-peers-failed',
    );
  }

  /// Whether an AWG state sample proves the peer answered:
  /// a completed handshake (the backend parser's own age —
  /// a handshake response is keyed, so no reflector can
  /// forge one) or any received byte. Pure and static, so
  /// the verdict is unit-testable without a device (build
  /// 2106, journey audit F-01).
  static bool awgPeerCarries(XrayState s) =>
      s.awg &&
      s.running &&
      (s.awgHandshakeAgeSec >= 0 || s.awgRxBytes > 0);

  /// Build 2106 (verification iteration 2, L-1): set by
  /// [_awgAdoptionProof] when its false verdict is a session
  /// DEATH (the sample stopped running, not a user stop)
  /// rather than a silent window — the walk words its
  /// journal line and the fallback notice by it. Reset at
  /// every proof start; read only by the walk, immediately
  /// after the proof returns.
  bool _awgProofDied = false;

  /// Build 2106 (journey audit F-01): the AWG leg's
  /// adoption proof, run by the peer walk on a session
  /// [_connectAwg] has brought Up. The session is adopted
  /// only once the peer demonstrably answers — the proof
  /// signals in [awgPeerCarries], the backend's own state
  /// for THIS session — inside a bounded window that
  /// mirrors the plain leg's carries window below (12 s,
  /// same poll cadence). Returns true on proof, false when
  /// the window closes on silence (or the session dies
  /// inside it), and null when a disconnect supersedes
  /// the attempt mid-proof — the walk then ends, like
  /// every other superseded step.
  ///
  /// Superseded includes a stop the user issued from the
  /// tunnel's own notification (verification iteration 1,
  /// H1): that stop lands entirely in the native layer
  /// and never bumps [_tunnelGen]; its trace in the merged
  /// state is `userStopped` — the WG Tunnel engine's own
  /// flag, cleared at every start, so it can only mean
  /// THIS session's stop. It is read as superseded, never
  /// as peer silence: the first draft of this proof
  /// returned false for it, and the walk went on to
  /// reconnect the plain leg over the user's Disconnect.
  /// (The exit lookup is deliberately NOT a proof signal
  /// here: it rides a SOCKS port an AWG session does not
  /// have, so any landing would be another session's —
  /// the handshake/rx signals are session-fresh by
  /// construction.)
  ///
  /// This is NOT the 2040–2103 handshake gate, and it must
  /// never become one. That gate lived INSIDE the connect,
  /// parsed a UAPI key no device emits, and tore down
  /// tunnels that had already handshook. This window lives
  /// in the WALK, before adoption: its signal is the
  /// backend's own parsed state (the keys the device
  /// really emits), a peer that answers inside it is
  /// adopted and never re-proven or torn down by any
  /// deadline afterwards (the handshake age stays
  /// display-only for an adopted session), and silence
  /// costs the peer only its place in this walk — its
  /// plain leg and the next peer still run.
  Future<bool?> _awgAdoptionProof() async {
    final gen = _tunnelGen;
    _awgProofDied = false;
    final deadline = DateTime.now().add(const Duration(seconds: 12));
    while (true) {
      if (gen != _tunnelGen) return null;
      await refreshState();
      // Check-after-every-await, the discipline the rest
      // of the controller observes: a disconnect landing
      // inside the refresh — in-app (gen bump) or from the
      // notification (userStopped) — ends the walk before
      // the sample is believed.
      if (gen != _tunnelGen) return null;
      if (state.userStopped) return null;
      if (!state.running) {
        // The session ended inside the window — a death,
        // not silence (verification iteration 2, L-1); the
        // walk words the fallback by this flag.
        _awgProofDied = true;
        return false;
      }
      if (awgPeerCarries(state)) return true;
      if (!DateTime.now().isBefore(deadline)) return false;
      await Future<void>.delayed(const Duration(milliseconds: 800));
    }
  }

  /// Connects [p] on the AmneziaWG engine (build 2040,
  /// queue 2h; build 2104: WG Tunnel's backend). The
  /// backend's VpnService brings the TUN up in the main
  /// process and its amneziawg-go device runs the profile's
  /// obfuscation parameters for real. Returns true once the
  /// backend reports the session Up — the handshake is NOT
  /// a gate: builds 2040–2103 demanded a completed handshake
  /// parsed out of a UAPI dump within 12 s, the parse never
  /// matched the keys the device emits, and tunnels that
  /// had already handshook were torn down as "never
  /// answered" (see the verdict note in the body). A peer
  /// that has not answered yet is retried by WireGuard
  /// itself in the background; only a start failure returns
  /// false, and the caller then falls back to plain
  /// WireGuard. Throws [_ConnectCancelled] when a
  /// disconnect supersedes the attempt mid-flight (build
  /// 2096, post-2095 audit H4); a session left running by
  /// a failed attempt is stopped by the attempt itself
  /// before it returns (build 2104, verification iteration
  /// 1, finding 3) — never left behind for the plain path
  /// or a later disconnect to reap.
  Future<bool> _connectAwg(Profile p) async {
    _tunnelGen++;
    // Build 2096 (post-2095 audit H4): this path had NO
    // generation re-check at all — a disconnect landing in
    // the pre-start window bumped the gen and stopped
    // nothing (nothing was started yet), and the attempt
    // then started the tunnel AFTER the disconnect had
    // completed. Capture the gen and re-check it after
    // every await, like _connectSelected's checkAlive.
    final gen = _tunnelGen;
    connecting = true;
    _connectingProfileId = p.id;
    lastError = null;
    // Build 2107: any new attempt supersedes an earlier
    // failed connect's DPI Lab offer.
    dpiLabOfferProfileId = '';
    _clearLabDialState();
    exitInfo = null;
    wgExitUnverified = false;
    notifyListeners();
    try {
      // One tunnel at a time: the Mozilla engine goes off first.
      await stopOtherEngine?.call();
      if (gen != _tunnelGen) throw const _ConnectCancelled();
      // Build 2100 (verification iteration 1, H1): a held
      // kill-switch blackhole reports running=false, so the
      // stop below used to be skipped exactly in the hold
      // state — and a held fd can only be released by the
      // XrayVpnService stop path. Read a fresh sample and stop first
      // whenever anything is up OR held, then OBSERVE the
      // release before starting AWG: _stopTunnel only fires
      // the stop intent and returns (in the hold state
      // running is already false, so its wait loop breaks on
      // the first poll), while the fd close happens on the
      // main-process stop thread. In the hold case the
      // bounded poll below is the mechanism that observes
      // the release (in the running case _stopTunnel's wait
      // observes running=false, which is set only after the
      // fd closes); the backend's cold start is not relied
      // on for the ordering. The platform revoke remains
      // only as a backstop. Never rely on the revoke: it is
      // unproven for a same-app establish, and its
      // stopForeground(REMOVE) would strip the AWG
      // notification sharing id 2.
      state = await XrayPlatform.state();
      final wasHeld = state.killSwitchHeld;
      // Build 2104 (verification iteration 1, finding 10):
      // the problem SEQUENCE recorded before this start —
      // the up-wait below treats an advance as this start's
      // own failure report. Iteration 2 (M3): a sequence,
      // not the problem string — engine failures are
      // templated, so a repeat failure reproduces the
      // identical text and a string sentinel cannot tell
      // it from a stale echo.
      final problemSeqBefore = state.awgProblemSeq;
      if (state.running || wasHeld) await _stopTunnel();
      if (gen != _tunnelGen) throw const _ConnectCancelled();
      // Build 2100 (verification iteration 2, Low): in the
      // hold case, wait — bounded, 10 x 200 ms — until the
      // hold is observed clear before issuing the AWG start.
      // The fingerprint refresh runs in this window only
      // when it has not run yet; it is NOT the margin (it
      // normally already ran at controller init). If the hold
      // has not cleared when the bound expires, proceed
      // anyway — the revoke is the backstop, and the start
      // must not hang on a wedged service.
      if (wasHeld) {
        for (var i = 0; i < 10; i++) {
          state = await XrayPlatform.state();
          if (!state.killSwitchHeld) break;
          if (gen != _tunnelGen) throw const _ConnectCancelled();
          await Future<void>.delayed(
            const Duration(milliseconds: 200),
          );
        }
        if (gen != _tunnelGen) throw const _ConnectCancelled();
      }
      if (networkFp.isEmpty) await refreshNetworkFingerprint();
      if (gen != _tunnelGen) throw const _ConnectCancelled();
      // Build 2110 (wg-start diagnosis, defect 2): the
      // engine-switch funnel — observe the PREVIOUS engine
      // fully down before this start, instead of assuming
      // the stop landed. The Xray side's `running` flips
      // false before the AWG backend actually releases the
      // VPN slot (and vice versa), and a start issued into
      // the dying tunnel's slot is silently swallowed by
      // the backend or revoked by the platform. Bounded —
      // the Kotlin door fails fast and journals when a
      // start is genuinely refused.
      await _awaitPreviousEngineDown(() {
        if (gen != _tunnelGen) throw const _ConnectCancelled();
      });
      if (gen != _tunnelGen) throw const _ConnectCancelled();
      // Build 2110 (wg-start diagnosis D1): journal the
      // EFFECTIVE initiation-shaping parameters of this
      // attempt, so the next Diagnostics export shows what
      // the handshake actually carried — the 2026-11-18
      // export carried no S/H values at all, which is why
      // D1 stayed a suspect instead of a verdict. The
      // de-shaped retry attempt journals its neutralized
      // values too; the contrast is the diagnostic value.
      String shown(String v) => v.trim().isEmpty ? '—' : v.trim();
      diagnostics.add(
        'awg',
        'AmneziaWG parameters for ${p.name}: '
            'S1=${shown(p.awgS1)} S2=${shown(p.awgS2)} '
            'H1=${shown(p.awgH1)} H2=${shown(p.awgH2)} '
            'H3=${shown(p.awgH3)} H4=${shown(p.awgH4)}, '
            '${p.awgI1.trim().isEmpty ? 'no I1 signature' : 'I1 signature present'}',
      );
      if (p.hasInitiationShaping) {
        diagnostics.add(
          'awg',
          'This profile rewrites the WireGuard handshake '
              'itself (S/H parameters) — the server must be an '
              'AmneziaWG server; a plain WireGuard server '
              'silently drops such handshakes.',
          ok: false,
        );
      }
      // Build 2110 (wg-start diagnosis A1): the DNS handed
      // to the engine, family-guarded — a set the backend
      // would filter to EMPTY is substituted with the
      // family-matching Cloudflare resolver and journaled
      // (see awgDnsGuardedFor).
      final (awgDns, dnsGuardNote) = awgDnsGuardedFor(p, settings);
      if (dnsGuardNote != null) {
        diagnostics.add('awg', dnsGuardNote, ok: false);
      }
      // Build 2116 (audit C2-07 companion): the hand-off
      // carries the profile's whole peer group — a
      // multi-peer .conf is ONE tunnel definition, and the
      // engine runs every peer it carries. Up to 2115 only
      // the selected profile's own peer was handed over.
      final wgGroup = [
        p,
        ...profiles.where(
          (x) =>
              x.id != p.id &&
              x.protocol == Protocol.wireguard &&
              wgGroupKey(x) == wgGroupKey(p),
        ),
      ];
      if (wgGroup.length > 1) {
        diagnostics.add(
          'awg',
          'This profile\'s config carries ${wgGroup.length} peers — '
              'all of them are handed to the WireGuard engine.',
        );
      }
      await XrayPlatform.setOnAwg(
        // Build 2104: the hand-off is the profile's canonical
        // .conf text — the Kotlin side parses it with WG
        // Tunnel's own parser into the Config the backend
        // runs (builds 2040–2103 composed a UAPI string for
        // the deleted hand-built bridge instead).
        settings: wgConfFromProfiles(wgGroup),
        name: p.name,
        addresses: p.localAddress,
        // Build 2102 (diagnosis C1): the profile's own .conf
        // DNS when it carries one — a v6-only profile's IPv6
        // resolvers are the only ones its peer can carry;
        // the Settings IPv4 local DNS is dropped inside such
        // a tunnel and name resolution dies. Profiles with
        // no DNS line keep the Settings value (awgDnsFor).
        // Build 2110: family-guarded (awgDnsGuardedFor,
        // computed above) — never zero resolvers.
        dns: awgDns,
        // Build 2103 (diagnosis D1, the cross-build trap):
        // the AWG ::/0 gate is the PROFILE's own IPv6
        // footprint, no longer the Xray Settings toggle —
        // that toggle's default is OFF now (v2rayNG
        // parity for the Xray TUN), and the owner's
        // v6-only WARP+AWG profile must keep its route
        // under the new default. Build 2104: the flag now
        // gates the full-tunnel AllowedIPs default on the
        // Kotlin side (a peer carrying no AllowedIPs of its
        // own); the ::/0 route itself derives from the
        // Config's AllowedIPs in the backend's TUN builder
        // — build 2102's C3 intent, re-homed.
        ipv6: profileHasIpv6(p),
        // Build 2102 (diagnosis C2): whether the profile
        // carries IPv4 at all — since 2104 it gates the
        // IPv4 half of the AllowedIPs default, so a v6-only
        // profile's IPv4 traffic is not blackholed into a
        // ::/0-only peer (the routes derive from the
        // Config's AllowedIPs, as above).
        ipv4: profileHasIpv4(p),
        // Build 2059 (audit §6 WG-conf divergence): the AWG
        // TUN MTU came from Settings like every other
        // engine. Build 2104: the argument still rode but
        // the backend's default (1280) ruled — a named loss.
        // Build 2116 (audit B3-1): the loss is restored —
        // the Kotlin side reads this argument as the
        // fallback when the profile carries no usable MTU,
        // and the profile's own MTU is no longer nulled.
        mtu: settings.tunnelMtu,
        // Build 2127 (H4): the kill switch — the WG
        // library raises its lockdown if this session
        // drops unexpectedly.
        killSwitch: settings.killSwitch,
      );
      // Build 2096 (audit H4): the start was issued — if a
      // disconnect landed while it was in flight, its stop
      // may have raced ahead of our start, so stop the
      // tunnel ourselves rather than leaving it up in a
      // state the shell believes is stopped.
      if (gen != _tunnelGen) {
        await _stopTunnel();
        throw const _ConnectCancelled();
      }
      // The service reports itself once the tunnel is really up.
      for (var i = 0; i < 40; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        if (gen != _tunnelGen) {
          await _stopTunnel();
          throw const _ConnectCancelled();
        }
        state = await XrayPlatform.state();
        if (state.running) break;
        // Build 2104 (verification iteration 1, finding 10;
        // iteration 2, M3): a NEW core problem — the problem
        // sequence advanced — means the engine has already
        // reported this start failed, even when its text is
        // identical to the previous failure's. Stop waiting
        // out the window and surface its reason below.
        if (state.awgProblemSeq != problemSeqBefore) {
          break;
        }
      }
      // Build 2104 (verification iteration 1, finding 20): a
      // disconnect can land during the final state() await
      // above — re-check the generation before adopting, or
      // the walk would adopt a session over a completed
      // disconnect.
      if (gen != _tunnelGen) {
        await _stopTunnel();
        throw const _ConnectCancelled();
      }
      if (!state.running) {
        // Build 2104 (verification iteration 1, finding 3):
        // stop the attempt before reporting failure. The
        // backend can accept a start whose TUN comes up
        // only after this wait (a hostname endpoint's DNS
        // bootstrap runs detached), and a late Up must not
        // be left running behind the plain leg the walk
        // falls back to. XrayPlatform.stop is the dual stop;
        // no Xray session is live here.
        await XrayPlatform.stop();
        // Iteration 2 (L6): the stop is fire-and-forget on
        // the Kotlin side (it launches the backend stop) —
        // observe the session actually end, bounded, before
        // returning, so the plain leg's establish does not
        // race the AWG teardown; and a disconnect landing
        // during this window cancels the walk outright.
        for (var i = 0; i < 10; i++) {
          state = await XrayPlatform.state();
          if (!state.running) break;
          await Future<void>.delayed(
            const Duration(milliseconds: 200),
          );
        }
        if (gen != _tunnelGen) throw const _ConnectCancelled();
        final problem = state.coreProblem;
        if (problem.isNotEmpty &&
            state.awgProblemSeq != problemSeqBefore) {
          lastError = problem;
          diagnostics.add(
            'awg',
            'AmneziaWG did not start for ${p.name}: $problem',
            ok: false,
          );
        } else {
          diagnostics.add(
            'awg',
            'AmneziaWG did not start for ${p.name}.',
            ok: false,
          );
        }
        return false;
      }
      // Build 2104: NO handshake proof, and no tear-down.
      // (Build 2106: still true of THIS function — the
      // adoption proof lives in the peer walk, which runs
      // it on the session this returns; see
      // _awgAdoptionProof. Nothing here gates or tears
      // down.) Builds 2040–2103 waited here up to 12 s for a
      // handshake age parsed out of the device's UAPI dump,
      // then declared the peer dead and returned false —
      // but the parse hunted `latest_handshake=`, a key no
      // device emits (the real keys are
      // latest_handshake_time_sec= on the v1 API and
      // last_handshake_time_sec= on the v3 API), so the age
      // was permanently -1, the proof ALWAYS expired, and
      // the app tore down tunnels that had already
      // handshook (the owner's 2026-11-18 device logs:
      // handshake responses received the same second, the
      // app declared "never answered" 12 s later and closed
      // the tunnel at ~18 s). The WG Tunnel backend reports
      // the session Up; that is the verdict. A peer that has
      // not answered yet is retried by WireGuard itself in
      // the background, and the handshake age stays what it
      // is now — a display figure, never a gate.
      _connectedProfileId = p.id;
      _lastSample = state;
      _lastSampleAt = DateTime.now();
      _startPolling();
      // Build 2116 (audit WGX-1/WGX-2): a family this
      // profile does not route is journaled at adoption —
      // never silent (the owner's Iranian-exit report was
      // a v6-only profile whose IPv4 rode direct).
      final uncoveredNote = wgUncoveredFamilyNote(p);
      if (uncoveredNote != null) {
        diagnostics.add('awg', '${p.name}: $uncoveredNote', ok: false);
      }
      // Build 2116 (audit WGX): the session's exit is
      // measured once, off the adoption path — it stamps
      // the session, it never gates it.
      unawaited(_verifyWgExit(p, gen));
      if (state.awgHandshakeAgeSec >= 0) {
        diagnostics.add(
          'awg',
          'AmneziaWG handshake with ${p.name} '
              '(${state.awgHandshakeAgeSec}s ago) — the '
              'peer answers on the obfuscated path.',
          ok: true,
        );
      } else {
        diagnostics.add(
          'awg',
          'AmneziaWG tunnel is up for ${p.name}; the peer '
              'has not answered yet — WireGuard keeps '
              'retrying the handshake in the background.',
          ok: true,
        );
      }
      return true;
    } on _ConnectCancelled {
      // Build 2096 (audit H4): a superseded attempt is not
      // a failure — the caller (the peer walk) ends the
      // whole walk on it.
      rethrow;
    } catch (e) {
      lastError = e.toString();
      diagnostics.add('awg', 'AmneziaWG failed for ${p.name}: $e', ok: false);
      return false;
    } finally {
      connecting = false;
      if (_connectingProfileId == p.id) _connectingProfileId = '';
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
  /// Build 2116 (audit WGX): the live WG session's exit,
  /// measured ONCE after adoption through a throwaway
  /// measured config (the delay test's machinery — an
  /// app-process fetch cannot ride the WG TUN, Ember
  /// excludes its own UID from it). The result stamps
  /// [exitInfo] and the profile's stored exit; an Iranian
  /// exit on a full-tunnel profile is journaled as what it
  /// is; a failed measurement stamps [wgExitUnverified].
  /// Fire-and-forget by design: it never gates, delays or
  /// tears down the session it describes (the 2104/2115
  /// verification-teardown lessons).
  Future<void> _verifyWgExit(Profile p, int gen) async {
    try {
      final (config, startedSidecar) = await _testConfigFor(p);
      if (startedSidecar) {
        // A WG profile never starts the sidecar; if that
        // ever changes, the measurement's transport is no
        // longer the honest one — say unverified instead.
        if (gen == _tunnelGen && _connectedProfileId == p.id) {
          wgExitUnverified = true;
          notifyListeners();
        }
        return;
      }
      final r = await XrayPlatform.measureDelayEx(
        config,
        rounds: 1,
        timeoutMs: settings.delayTestTimeoutMs,
      );
      if (gen != _tunnelGen || _connectedProfileId != p.id) return;
      final ip = (r['ip'] as String?) ?? '';
      final cc = (r['countryCode'] as String?) ?? '';
      if (ip.isEmpty) {
        wgExitUnverified = true;
        diagnostics.add(
          'awg',
          'The exit of ${p.name} could not be verified — the '
              'session is connected, but where it exits is '
              'unproven.',
          ok: false,
        );
      } else {
        wgExitUnverified = false;
        p.exitIp = ip;
        if (cc.isNotEmpty) p.exitCountryCode = cc;
        exitInfo = ExitInfo(ip: ip, countryCode: cc, countryEn: '');
        final routed = wgRoutedFamilies(p);
        if (cc == 'IR' && routed.v4 && routed.v6) {
          diagnostics.add(
            'awg',
            'Connected — exit: Iran ($ip). This profile '
                'routes all traffic, so the server itself '
                'exits in Iran (or the account is a local '
                'one); the tunnel is working as configured.',
            ok: false,
          );
        } else {
          diagnostics.add(
            'awg',
            'Exit verified for ${p.name}: $ip'
                '${cc.isNotEmpty ? ' ($cc)' : ''} — measured '
                'through a test tunnel of the same profile.',
            ok: true,
          );
        }
        unawaited(_save());
      }
      notifyListeners();
    } catch (_) {
      if (gen == _tunnelGen && _connectedProfileId == p.id) {
        wgExitUnverified = true;
        notifyListeners();
      }
    }
  }

  /// the full connect path. Never throws.
  Future<bool> switchServer(Profile next) async {
    if (_switchBusy || connecting) return false;
    if (!next.protocol.connectable) return false;
    // Build 2075: a seamless rotation rebuilds the core
    // config in place — it cannot restart a sidecar engine
    // for a different profile, so a sidecar session (or a
    // sidecar target) takes the full connect path instead.
    if (_sessionSidecarPort != 0 || servedViaSidecar(next)) {
      return false;
    }
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
      var dialProfile = win == null
          ? next
          : profileWithShape(next, win.shapeId);
      // Build 2107: a switch re-dials on the same network, so
      // the Lab's remembered strategy applies here under the
      // same rule as connect (Lab on, no shape win of its own).
      var labCandidateId = '';
      if (win == null) {
        final labDial = _dpiLabDial(next);
        if (labDial != null) {
          dialProfile = labDial.profile;
          // Stock (s0) never stands the watchdog down (see
          // the connect fast path).
          if (labDial.candidateId != shapeStock) {
            labCandidateId = labDial.candidateId;
          }
        }
      }
      // Build 2105: the switched-to profile's provider-DNS
      // pins — computed now for the config, but only ADOPTED
      // as the session's once the rotation is live (below): a
      // refused switch must leave the live session's pins
      // describing the live profile. Build 2110: the
      // server-name pins follow the same discipline, merged
      // under the provider pins per name.
      final pins = await _providerDnsPins(dialProfile);
      final serverPins = await _serverNamePins(dialProfile, journal: true);
      final config = buildTunnelConfig(
        dialProfile,
        settings,
        serverHostPins: _mergedServerPins(serverPins, pins),
      );
      // Build 2127 (H1): the Zapret proxy's flags are
      // per-candidate — a rotation whose dial needs a
      // different strategy than the running proxy's (or
      // one where none runs, or none where one runs)
      // cannot be seamless: the proxy must restart with
      // the config, which only the full connect path
      // does. Refuse here, before anything is touched;
      // the live session keeps running exactly as it was
      // and the caller falls back to a full connect.
      if (dialProfile.zapretStrategy != _sessionZapretStrategy) {
        return false;
      }
      // Count the old exit's tail into its own totals before
      // the core is replaced (the new core's counters start at 0).
      await _pollStats();
      // Build 2098 (verification, iteration 2): a disconnect
      // landing during the awaits above has already ended
      // the session this switch was rotating — do not rotate
      // a stopped core back to life for it.
      if (_tunnelGen != gen) return false;
      final rotated = await XrayPlatform.rotateConfig(config);
      if (!rotated) return false;
      if (_tunnelGen != gen) {
        // The disconnect (or a delete guard's disconnect)
        // landed INSIDE the rotate: the rotate respawned
        // the core on the new config, but the session it
        // belonged to is over. Stop the respawned core and
        // never write the new profile's ids — the pre-2098
        // code checked the generation only inside the proof
        // loop below, AFTER the ids were written and saved,
        // so a mid-rotate disconnect (or a mid-switch
        // delete, F-A2) left the tunnel running the new
        // profile with its ids persisted. A superseding
        // CONNECT is the one exception: it owns the core's
        // next state, so leave the core to it.
        if (!connecting) await _stopTunnel();
        return false;
      }
      // The rotated config is live from here: new bytes belong
      // to the new profile.
      selectedProfileId = next.id;
      _connectedProfileId = next.id;
      _sessionProviderPins = pins;
      _sessionServerPins = serverPins;
      _wdShape = win?.shapeId ?? shapeStock;
      // The rotated session's Lab-dial state follows the
      // config actually rotated in (build 2107).
      _labDialActive = labCandidateId.isNotEmpty;
      _labDialCandidateId = labCandidateId;
      _labStandDownJournaled = false;
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
  ///
  /// Build 2087 (owner report on build 2084): [groupWalk] is
  /// false for every manual connect — the power button, a
  /// server tap, the editor's test-connect, auto-connect. A
  /// manual connect tries the selected profile ONLY: a
  /// subscription member the user tapped connects as itself
  /// or fails with its own error, never silently substitutes
  /// the subscription's fastest measured member (the group
  /// walk's candidate order) the way every manual connect
  /// could before. Only the auto-reconnect passes true: the
  /// session it restores was established and then died, so
  /// walking its fallback group is the failover the owner
  /// ordered in build 2035 — as is the mid-session watchdog's
  /// switch, which never came through here.
  Future<void> connect({bool groupWalk = false}) async {
    // Build 2095 (third-pass audit 2.2): re-entry guard —
    // a second connect while one is in flight interleaved
    // stopOtherEngine/setOn and the first attempt's finally
    // cleared `connecting` under the second.
    if (connecting) return;
    // Build 2087 (analysis A1): a new connect episode — the
    // chain path's WARP registration gets one fresh attempt
    // (see [_warpProvisionFailed]).
    _warpProvisionFailed = false;
    // Build 2139 (A34-02 re-fix): a new connect episode —
    // the no-DNS warning may fire once per profile again
    // (see _providerDnsNoDnsWarned).
    _providerDnsNoDnsWarned.clear();
    // Build 2065 (item 13): advance the TLS fingerprint rotation
    // cursor once per user connect, before any config is built.
    // Only profiles without their own fingerprint consume a step.
    final sel = selected;
    if (settings.rotateTlsFingerprint &&
        sel != null &&
        sel.fingerprint.isEmpty) {
      settings.tlsFingerprintIndex =
          (settings.tlsFingerprintIndex + 1) % tlsFingerprintRotationSet.length;
      unawaited(_save());
    }
    final p = selected;
    if (p != null && p.protocol == Protocol.wireguard) {
      await connectWireGuardWithFallback(p);
      return;
    }
    // Build 2136 (item 14): auto-fastest group — with the
    // toggle on, a connect whose selected profile belongs
    // to a fallback group starts from the group's best
    // stored delay instead of the tapped member; the
    // group walk below remains the failover. Only a
    // strictly better TESTED member (delayMs >= 0) takes
    // the start; untested selections keep their place.
    // Off, selection is exactly 2135's.
    if (settings.autoFastestGroup && p != null) {
      final members = fallbackGroupMembers(p)
          .where((m) => m.protocol.connectable && m.delayMs >= 0)
          .toList();
      if (members.isNotEmpty) {
        final best = members.first;
        if (best.id != p.id &&
            (p.delayMs < 0 || best.delayMs < p.delayMs)) {
          diagnostics.add(
            'group',
            'Auto-fastest: ${best.name} (${best.delayMs} ms) '
                'starts this connect ahead of ${p.name}'
                '${p.delayMs >= 0 ? ' (${p.delayMs} ms)' : ''}.',
            ok: true,
          );
          select(best);
        }
      }
    }
    await _connectWithFallbackGroup(allowGroupWalk: groupWalk);
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

  // ---- DPI Strategy Lab (build 2107) --------------------------------------

  /// The Lab-shaped dial profile for [p] on the current
  /// network, or null when the Lab may not speak: the feature
  /// is off, no win is remembered for this network, or the
  /// remembered candidate cannot shape this profile. Called
  /// by the connect and switch fast paths ONLY where the
  /// shape cache has no win of its own — a per-profile proven
  /// winner always outranks the Lab's network-level one.
  ({Profile profile, String candidateId})? _dpiLabDial(Profile p) {
    if (!settings.dpiLabEnabled) return null;
    final win = dpiLabMemory.lookup(networkFp);
    if (win == null) return null;
    if (!dpiLabCandidateApplies(win.candidateId, p)) {
      // A win exists for this network but cannot shape this
      // profile (its shape changed since the win was proven,
      // or the win came from a different profile class) —
      // journal the non-application rather than silently
      // dialing stock (build 2107, verification iteration 3).
      diagnostics.add(
        'dpilab',
        'DPI Lab: ${win.candidateId} is remembered for this '
            'network but does not apply to ${p.name} — the '
            'stored profile is used instead.',
      );
      return null;
    }
    final candidate = dpiLabCandidateById(win.candidateId);
    diagnostics.add(
      'dpilab',
      'DPI Lab: ${candidate?.label ?? win.candidateId} was '
          'confirmed on this network (${win.ms} ms through '
          '${win.profileName}) — dialing ${p.name} with it '
          'first.',
      ok: true,
    );
    return (
      profile: profileWithCandidate(p, win.candidateId),
      candidateId: win.candidateId,
    );
  }

  /// Runs Lab discovery for [p] on the current network (the
  /// wizard's engine): candidates probed in order with the
  /// delay test's throwaway cores, each that answers
  /// confirmed by the endurance check; the sweep runs every
  /// candidate (build 2115). Only throwaway cores
  /// run — a live session is never touched. Every verdict is
  /// journaled; the results are the caller's to present.
  /// Remembering a winner is a separate, explicit step
  /// ([rememberDpiLabWin]) — a run alone changes nothing.
  Future<List<DpiLabResult>> runDpiLab(
    Profile p, {
    void Function(DpiLabResult result)? onResult,
    bool Function()? isCancelled,
  }) async {
    // Defence in depth (build 2107, verification iteration
    // 1): the page is only reachable with the Lab on, but the
    // run itself re-checks the gate — and refuses to overlap
    // a run already in flight.
    if (!settings.dpiLabEnabled) return const [];
    if (_dpiLabRunning) return const [];
    // An ineligible profile is refused here, not journaled
    // as a run that tested nothing (iteration 4).
    if (!dpiLabEligible(p)) return const [];
    _dpiLabRunning = true;
    try {
      return await _runDpiLabGuarded(
        p,
        onResult: onResult,
        isCancelled: isCancelled,
      );
    } finally {
      _dpiLabRunning = false;
    }
  }

  Future<List<DpiLabResult>> _runDpiLabGuarded(
    Profile p, {
    void Function(DpiLabResult result)? onResult,
    bool Function()? isCancelled,
  }) async {
    // The run's evidence belongs to the network it is
    // measured on: refresh the fingerprint NOW (the stored
    // one may predate a network change) and keep it for the
    // matching remember step, so a win can never be filed
    // under a network it was not measured on.
    await refreshNetworkFingerprint();
    _dpiLabRunFp = networkFp;
    // Build 2120: the run tests the owner's ticked subset —
    // the journal names the count actually probed, not the
    // full candidate list.
    final sweepCount = dpiLabCandidatesFor(
      p,
    ).where((c) => !dpiLabSweepExcluded.contains(c.id)).length;
    diagnostics.add(
      'dpilab',
      'DPI Lab run for ${p.name} on '
          '${dpiLabNetworkLabel(networkFp)}: testing '
          '$sweepCount strategies.',
    );
    final results = await runDpiLabDiscovery(
      profile: p,
      settings: settings,
      // Build 2147 (feature #3): candidate racing, DEFAULT OFF.
      race: settings.dpiLabRacing,
      excludeIds: dpiLabSweepExcluded,
      // Build 2110: the Lab's probe configs resolve the
      // server name like every other config (C1).
      serverHostPins: await _serverNamePins(p),
      measure: (config) async {
        try {
          // Build 2109: the Lab's discovery probes are delay
          // tests, so they wait the configured per-request
          // timeout — the Lab's own 8 s quick budget still caps
          // each request, so the setting can only shorten the
          // Lab's timeout, never lengthen past its budget.
          return await XrayPlatform.measureDelayEx(
            config,
            rounds: 2,
            budgetMs: dpiLabQuickBudgetMs,
            timeoutMs: settings.delayTestTimeoutMs,
          );
        } catch (_) {
          return const {'ms': -1, 'ip': '', 'countryCode': ''};
        }
      },
      endure: (config) async {
        try {
          return await XrayPlatform.endurance(config);
        } catch (_) {
          return null;
        }
      },
      onResult: (r) {
        // Build 2120: every measured result is saved to the
        // config's book as it lands — a stopped run keeps
        // what it measured, and the next visit shows these
        // rows with their age instead of an empty list. The
        // save is the chained store write; the journal line
        // below is unaffected.
        dpiLabResults.record(
          p.id,
          r,
          measuredMs: DateTime.now().millisecondsSinceEpoch,
          networkFp: _dpiLabRunFp,
        );
        unawaited(_save());
        diagnostics.add(
          'dpilab',
          switch (r.verdict) {
            DpiLabVerdict.works =>
              '${r.candidate.label}: confirmed — ${r.ms} ms, '
                  'held through 5.4 s (probes ${r.p0} / ${r.p1} '
                  '/ ${r.p2} ms).',
            DpiLabVerdict.freezes =>
              '${r.candidate.label}: answered in ${r.ms} ms '
                  'but the session froze (probes ${r.p0} / '
                  '${r.p1} / ${r.p2} ms).',
            DpiLabVerdict.unconfirmed =>
              '${r.candidate.label}: answered in ${r.ms} ms '
                  'but the confirmation round could not run — '
                  'nothing is proven about this strategy.',
            DpiLabVerdict.blocked => '${r.candidate.label}: no answer.',
          },
          ok: r.verdict == DpiLabVerdict.works
              ? true
              : r.verdict == DpiLabVerdict.freezes ||
                    r.verdict == DpiLabVerdict.unconfirmed
              ? null
              : false,
        );
        onResult?.call(r);
      },
      // Build 2127 (H1): a zap candidate's probe config
      // chains through the desync proxy, so the proxy runs
      // for exactly that candidate's probe — started here,
      // stopped by the release whatever the verdict. A
      // proxy that will not start grades the candidate
      // blocked (the runner's prepare contract), never a
      // false measurement against a dead port.
      prepareCandidate: (candidateId) async {
        try {
          final started = await ZapretPlatform.start(
            buildZapretArgs(candidateId),
          );
          if (!started) return false;
          await _awaitSidecarReady(
            ZapretPlatform.state,
            'Zapret desync proxy',
          );
          return true;
        } catch (_) {
          return false;
        }
      },
      releaseCandidate: (candidateId) async {
        await ZapretPlatform.stop();
      },
      isCancelled: isCancelled,
    );
    final winner = dpiLabWinner(results);
    diagnostics.add(
      'dpilab',
      winner == null
          ? 'DPI Lab: no strategy carried traffic on this '
                'network.'
          : 'DPI Lab: ${winner.candidate.label} is the '
                'strategy that works on this network.',
      ok: winner != null,
    );
    return results;
  }

  /// The saved Lab results for [profileId] (build 2120):
  /// candidate id → the saved evidence, for the Lab page's
  /// rows. Empty when the config was never tested.
  Map<String, DpiLabSavedResult> dpiLabSavedFor(String profileId) =>
      dpiLabResults.forProfile(profileId);

  /// Ticks or unticks one candidate for the sweep (build
  /// 2120): the selection persists immediately, so it
  /// survives a restart whether or not a run follows. The
  /// stored fact is the EXCLUSION — unticking is the only
  /// way a strategy leaves the sweep.
  Future<void> setDpiLabCandidateExcluded(
    String candidateId,
    bool excluded,
  ) async {
    final changed = excluded
        ? dpiLabSweepExcluded.add(candidateId)
        : dpiLabSweepExcluded.remove(candidateId);
    if (!changed) return;
    await _save();
    notifyListeners();
  }

  /// Remembers a Lab result as this network's strategy (the
  /// wizard's explicit action). Without [manual], only a
  /// CONFIRMED result (verdict works) is filed — a freezes
  /// or blocked result did not prove it carries traffic.
  /// With [manual] (build 2115: the owner's hand pick from
  /// the results list) any result that ANSWERED may be
  /// filed — his tap is his decision — but the journal keeps
  /// the honest verdict, and a blocked result is still
  /// refused: it never answered, so there is nothing to
  /// file. The gate itself is [dpiLabCanRemember].
  ///
  /// Returns the network fingerprint the win was filed
  /// under, or '' when nothing was recorded (the Lab is off,
  /// the result is not rememberable, or the network is
  /// unknown) — the caller must not claim a remember that
  /// did not happen (build 2107, verification iteration 1:
  /// the page previously announced "Remembered" even when
  /// an unknown network made this a silent no-op, and named
  /// the LIVE network rather than the one filed under).
  Future<String> rememberDpiLabWin(
    Profile p,
    DpiLabResult result, {
    bool manual = false,
  }) async {
    if (!settings.dpiLabEnabled) return '';
    if (!dpiLabCanRemember(result, manual: manual)) return '';
    // File the win under the network the RUN measured (see
    // runDpiLab), not whatever network the phone is on by
    // the time the user taps Remember.
    final fp = _dpiLabRunFp.isNotEmpty ? _dpiLabRunFp : networkFp;
    if (fp.isEmpty) return '';
    dpiLabMemory.record(
      fp,
      DpiLabWin(
        candidateId: result.candidate.id,
        profileId: p.id,
        profileName: p.displayName,
        ms: result.ms,
        exitCountry: result.exitCountry,
        verifiedMs: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    if (manual && result.verdict != DpiLabVerdict.works) {
      diagnostics.add(
        'dpilab',
        'DPI Lab: ${result.candidate.label} filed for '
            '${dpiLabNetworkLabel(fp)} as your pick — it '
            'answered in ${result.ms} ms but '
            '${result.verdict == DpiLabVerdict.freezes ? 'froze in confirmation' : 'its confirmation could not run'}; '
            'not a confirmed win.',
        ok: true,
      );
    } else {
      diagnostics.add(
        'dpilab',
        'DPI Lab: ${result.candidate.label} remembered for '
            '${dpiLabNetworkLabel(fp)}.',
        ok: true,
      );
    }
    await _save();
    notifyListeners();
    return fp;
  }

  /// Forgets one network's Lab win (the Lab page's control).
  Future<void> forgetDpiLabWin(String networkFpKey) async {
    dpiLabMemory.forget(networkFpKey);
    await _save();
    notifyListeners();
  }

  /// Forgets every network's Lab win (the Lab page's control).
  Future<void> clearDpiLabMemory() async {
    dpiLabMemory.clear();
    await _save();
    notifyListeners();
  }

  /// Drops stale Lab wins and persists the drop (build 2107,
  /// verification iteration 2): the page's list filters stale
  /// wins through lookup, which evicts in memory only — the
  /// same entries were otherwise re-read from disk and
  /// re-evicted on every launch.
  Future<void> pruneDpiLabMemory() async {
    final before = dpiLabMemory.length;
    for (final fp in dpiLabMemory.wins.keys.toList()) {
      dpiLabMemory.lookup(fp);
    }
    if (dpiLabMemory.length != before) {
      await _save();
      notifyListeners();
    }
  }

  /// Fetches the community DPI strategy feed and installs
  /// what validates (build 2114; the Lab page's Strategy
  /// updates card). Returns a user-ready result line. A
  /// failed fetch changes nothing — the previously
  /// installed strategies stay. The strategies are data:
  /// they join the Lab's candidate set and are applied
  /// only while the Lab master toggle is on, like every
  /// Lab consult path.
  Future<String> refreshDpiStrategies() async {
    try {
      // Build 2125 (audit A25-55): with a session up, the
      // feed is fetched through it (the updater's 2098
      // pattern) — direct GitHub is blocked on exactly
      // the networks the Lab serves.
      // Build 2126 (audit A26-20): the session proxy's
      // credentials ride along when its inbound demands
      // them — the same selection the shell wires for
      // the updater (the LAN login when ready, else the
      // local-proxy login).
      final dpiCredsReady =
          settings.lanShareAuthReady ||
          (!settings.lanShareEnabled && settings.localProxyAuthReady);
      final body = await fetchDpiStrategyFeedBody(
        proxy: state.running
            ? '127.0.0.1:${settings.httpPort}'
            : null,
        proxyCredentials: state.running && dpiCredsReady
            ? (settings.lanShareAuthReady
                  ? (user: settings.lanShareUser, pass: settings.lanSharePass)
                  : (
                      user: settings.localProxyUser,
                      pass: settings.localProxyPass,
                    ))
            : null,
      );
      final parsed = parseDpiStrategyFeedBody(body);
      // Build 2125 (audit A25-54): a feed that validates
      // but carries ZERO usable strategies never
      // uninstalls the installed set — an all-invalid
      // document used to wipe every community strategy
      // silently.
      if (parsed.isEmpty && dpiRemoteStrategies.isNotEmpty) {
        diagnostics.add(
          'dpilab',
          'DPI Lab: the strategy feed carried no usable '
              'strategies; the ${dpiRemoteStrategies.length} '
              'installed ones were kept.',
          ok: false,
        );
        return 'The feed carried no usable strategies — '
            'your ${dpiRemoteStrategies.length} installed '
            'ones were kept.';
      }
      dpiRemoteStrategies = installDpiRemoteStrategies(parsed);
      dpiRemoteUpdatedMs = DateTime.now().millisecondsSinceEpoch;
      diagnostics.add(
        'dpilab',
        'DPI Lab: strategy feed installed ${parsed.length} '
            'remote strateg${parsed.length == 1 ? 'y' : 'ies'}.',
        ok: true,
      );
      await _save();
      notifyListeners();
      return parsed.isEmpty
          ? 'The feed validated but carries no strategies yet.'
          : '${parsed.length} community '
                'strateg${parsed.length == 1 ? 'y' : 'ies'} installed.';
    } on DpiStrategyFeedException catch (e) {
      diagnostics.add(
        'dpilab',
        'DPI Lab: strategy update failed — ${e.message}',
        ok: false,
      );
      return e.message;
    } catch (e) {
      diagnostics.add(
        'dpilab',
        'DPI Lab: strategy update failed: $e',
        ok: false,
      );
      return 'The strategy update failed — try again later.';
    }
  }

  /// Preselect the remembered winner for [networkKey], if the
  /// profile still exists. Returns true when a preselect happened.
  ///
  /// Build 2087 (owner report on build 2084 — "I pick one
  /// config and it connects another"): this runs on EVERY
  /// network-identity application, including the default-
  /// network change the TUN itself causes as a session comes
  /// up, and it used to route through [select] — whose
  /// tap-while-running logic then switched the just-
  /// established session to the remembered winner. The user
  /// picked one config; the app connected the remembered one,
  /// every time. Preselection is a start-of-day convenience
  /// only now: it yields to any explicit selection made this
  /// session and to any live or in-flight session, and it
  /// sets the selection directly instead of through [select],
  /// so it can never trigger a session switch.
  bool preselectForNetwork(String networkKey) {
    if (_userChoseSelection) return false;
    if (state.running || connecting || _connectedProfileId.isNotEmpty) {
      return false;
    }
    final id = settings.lastProfileByNetwork[networkKey];
    if (id == null || id.isEmpty) return false;
    if (selectedProfileId == id) return false;
    for (final p in profiles) {
      if (p.id == id) {
        selectedProfileId = p.id;
        unawaited(_save());
        notifyListeners();
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
    // Build 2095 (audit 2.6): a connect in flight is not
    // "idle" — the old gate read only state.running, which
    // stays false through the whole pre-start window.
    if (state.running || scanRunning || connecting) return false;
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

  /// Connects the selected profile. Throws a short message on
  /// failure. With [allowGroupWalk] and fallback groups on
  /// (build 2035), a failed connect walks the selected
  /// profile's fallback group — up to 3 further members, each
  /// failure starting that member's cooldown — and only
  /// throws when every tried member failed. Since build 2087
  /// only the auto-reconnect walks (see [connect]): a manual
  /// connect's failure is the selected profile's own and
  /// surfaces as-is.
  Future<void> _connectWithFallbackGroup({bool allowGroupWalk = true}) async {
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
    // Build 2087: the profile this call set out to connect,
    // captured BEFORE the attempt. The catch below used to
    // re-read [selected] after the failure — by then a
    // network-identity application could have moved the
    // selection (see [preselectForNetwork]), so the walk
    // proceeded in the wrong profile's group and marked the
    // wrong profile failed.
    final first = selected;
    try {
      await _connectSelected();
      return;
    } catch (e) {
      // Build 2097 (post-2096 audit C1): a user disconnect is
      // not a failure to fail over from. _ConnectCancelled
      // rethrows unconditionally — in the default
      // configuration (adaptiveFailover on) this catch used
      // to swallow it and walk fallback candidates under
      // fresh generations, so a member could connect AFTER
      // the user disconnected.
      if (e is _ConnectCancelled) rethrow;
      if (!allowGroupWalk || !settings.adaptiveFailover) rethrow;
      if (first == null) rethrow;
      markFallbackFailed(first.id);
      Object? lastError = e;
      var attempts = 0;
      var candidates = fallbackCandidates(first);
      // Smart dial racing (build 2075, feature item 5): the
      // serial walk costs one full connect timeout per dead
      // member. With racing on, the first three candidates'
      // endpoints are probed in parallel and the first that
      // answers is tried first; every probe outcome is
      // learned into the candidate's TCP ping fields. The
      // selected profile's own failed attempt above is never
      // raced — a healthy first choice connects exactly as
      // before.
      if (settings.smartDialRacing && candidates.length > 1) {
        final raced = candidates.take(3).toList();
        // Build 2098 (post-2097 audit M2): the race is a long
        // await OUTSIDE any attempt's checkAlive discipline —
        // snapshot the generation before it and re-check after.
        // A disconnect landing during the race used to be
        // consumed here, and the candidate loop then connected
        // its first candidate under a fresh generation.
        final raceGen = _tunnelGen;
        final winner = await raceProfileTcp(
          raced,
          onResult: (p, ms) {
            p.tcpPingMs = ms;
            p.tcpPingFailed = ms < 0;
          },
        );
        // Build 2098 (post-2097 audit M2): nothing in the
        // race bumps the generation itself, so any change is
        // an outside intervention (a user disconnect, or a
        // newer connect) — the walk is cancelled/superseded
        // and must not enter its first candidate.
        if (_tunnelGen != raceGen) throw const _ConnectCancelled();
        if (winner != null && winner.id != raced.first.id) {
          candidates = [winner, ...candidates.where((c) => c.id != winner.id)];
          diagnostics.add(
            'connect',
            'Dial racing: ${winner.name} answered first and '
                'is tried before the rest of the group.',
            ok: true,
          );
        }
        notifyListeners();
      }
      for (final next in candidates) {
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
          // Build 2097 (post-2096 audit C1): the walk's own
          // candidates are cancellations too — a disconnect
          // landing inside a candidate's attempt ends the
          // walk, it does not mark the candidate failed and
          // move on to the next one.
          if (err is _ConnectCancelled) rethrow;
          lastError = err;
          markFallbackFailed(next.id);
        }
      }
      adaptiveNotice =
          'Fallback group: ${first.name} failed and no other member '
          'in its group connected.';
      // Build 2107 (verification iteration 1): each member's
      // own failure tail set the DPI Lab offer to the LAST
      // member tried — but the offer must name the profile
      // the user actually picked, with the substitution
      // journaled, not silently point at a group member.
      if (settings.dpiLabEnabled && dpiLabEligible(first)) {
        dpiLabOfferProfileId = first.id;
        diagnostics.add(
          'dpilab',
          'DPI Lab: the failed-connect offer names '
              '${first.name} — the config you picked; the '
              'fallback walk also tried the other members of '
              'its group.',
        );
      } else {
        // The picked profile is one the Lab cannot grade
        // (the WireGuard leg's walk reaches this code too):
        // a member's failure tail may have set the offer to
        // a member the user never picked — the correct
        // terminal state is no offer (build 2107,
        // verification iteration 2). Ungated (iteration 3):
        // a mid-walk toggle-off must not strand a member's
        // offer either — while the Lab is off the field is
        // simply '' and the Home row stays hidden.
        dpiLabOfferProfileId = '';
      }
      notifyListeners();
      throw lastError ?? e;
    }
  }

  /// Waits for a sidecar's local listener (build 2075): the
  /// native core reports readiness when its TCP probe
  /// connects; a stage error fails fast with the core's own
  /// plain message (its stderr tail's last line rides along
  /// in the native error string).
  Future<void> _awaitSidecarReady(
    Future<SidecarState> Function() stateOf,
    String label,
  ) async {
    for (var i = 0; i < 40; i++) {
      final st = await stateOf();
      if (st.ready) return;
      if (st.stage == 'error') {
        throw StateError(
          st.error.isNotEmpty ? st.error : 'The $label stopped while starting.',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    throw StateError('The $label did not open its listener in time.');
  }

  /// Build 2126 (feature pick 3): true when the sing-box
  /// sidecar serves [p] because its Shadowsocks plugin is
  /// ShadowTLS and the ShadowTLS fronting setting is on —
  /// the one sidecar diversion that is a settings decision
  /// rather than a profile property.
  bool shadowTlsServed(Profile p) =>
      settings.shadowTlsFronting && p.shadowTlsPlugin != null;

  /// Build 2127 (H2): true when the Sudoku sidecar serves
  /// [p] — a Sudoku profile while the Sudoku engine
  /// setting is on. The second settings-gated diversion,
  /// the ShadowTLS shape: with the setting off the
  /// profile is NOT sidecar-served (and connect refuses
  /// it in plain words — see _connectSelected).
  bool sudokuServed(Profile p) =>
      settings.sudokuEnabled && p.protocol == Protocol.sudoku;

  /// Build 2147 (feature #6): true when the sing-box sidecar
  /// serves [p] as an SSH outbound — an SSH profile while the
  /// SSH engine setting is on. The third settings-gated
  /// diversion, the Sudoku shape: with the setting off the
  /// profile is NOT sidecar-served (and connect refuses it
  /// in plain words — see _connectSelected).
  bool sshServed(Profile p) =>
      settings.sidecarSshEnabled && p.protocol == Protocol.ssh;

  /// The effective sidecar truth for [p] (build 2126): the
  /// profile's own sidecar routing ([Profile.servedBySidecar])
  /// or the settings-gated ShadowTLS diversion above. Every
  /// sidecar decision on the connect / test / switch paths
  /// reads THIS, so a diverted profile is treated as
  /// sidecar-served everywhere the intrinsic routing is —
  /// pins skipped, seamless switch refused, underlay
  /// chaining skipped, tests start the sidecar first.
  /// Build 2127 adds the Sudoku diversion the same way.
  bool servedViaSidecar(Profile p) =>
      p.servedBySidecar ||
      shadowTlsServed(p) ||
      sudokuServed(p) ||
      sshServed(p);

  /// The supervision label for the session's sidecar
  /// engine kind (build 2127: a third kind joined).
  String get _sidecarLabel => switch (_sessionSidecarKind) {
    'mieru' => 'Mieru client',
    'sudokubox' => 'Sudoku engine',
    _ => 'sing-box engine',
  };

  /// Starts the sidecar engine serving [p] (build 2075) and
  /// returns its local SOCKS port. The config is validated
  /// in plain language BEFORE any process starts, so a
  /// malformed profile fails with its real reason.
  Future<int> _startSidecarFor(Profile p) async {
    // Build 2095 (audit 2.6): mark the start in flight so
    // a config test cannot race a second sidecar up.
    _sidecarBusy = true;
    try {
      return await _startSidecarInner(p);
    } finally {
      _sidecarBusy = false;
    }
  }

  Future<int> _startSidecarInner(Profile p) async {
    // Build 2127 (H2): the Sudoku branch — its own fork
    // binary, its own config directory, its own port.
    // Checked first: the protocol sets are disjoint, so
    // the order costs the other branches nothing.
    if (sudokuServed(p)) {
      final err = sudokuConfigError(p);
      if (err != null) throw StateError(err);
      diagnostics.add(
        'sidecar',
        'Sudoku: "${p.name}" is served by the Sudoku '
            'engine (Hiddify sing-box fork).',
        ok: true,
      );
      final coreDir = await AndroidCore.dataDir();
      final dir = Directory('${File(coreDir).parent.path}/sudokubox');
      await dir.create(recursive: true);
      final configFile = File('${dir.path}/config.json');
      await AtomicJsonStore.writeText(
        configFile,
        compactJson(buildSudokuConfig(p, logLevel: settings.logLevel)),
      );
      final started = await SudokuBoxPlatform.start([
        'run',
        '-c',
        configFile.path,
      ]);
      if (!started) {
        final st = await SudokuBoxPlatform.state();
        throw StateError(
          st.error.isNotEmpty ? st.error : 'The Sudoku engine could not start.',
        );
      }
      await _awaitSidecarReady(SudokuBoxPlatform.state, 'Sudoku engine');
      _sessionSidecarKind = 'sudokubox';
      return sudokuListenPort;
    }
    if (p.protocol.servedByMieru) {
      final err = mieruConfigError(p);
      if (err != null) throw StateError(err);
      final started = await MieruPlatform.start(
        jsonEncode(buildMieruConfig(p, logLevel: settings.logLevel)),
      );
      if (!started) {
        final st = await MieruPlatform.state();
        throw StateError(
          st.error.isNotEmpty ? st.error : 'The Mieru client could not start.',
        );
      }
      await _awaitSidecarReady(MieruPlatform.state, 'Mieru client');
      _sessionSidecarKind = 'mieru';
      return mieruListenPort;
    }
    final err = singBoxConfigError(p);
    if (err != null) throw StateError(err);
    // Build 2125 (audit A25-16, surfacing half): the
    // sidecar is only the dialer and its egress is direct
    // (the app is disallowed from its own VPN), so a
    // hostname-addressed sidecar server is resolved by
    // the sidecar through the system resolver in
    // plaintext — visible to the network and poisonable.
    // The config-side fix (a dns section in the sidecar
    // config mirroring the session posture) is PARKED:
    // the vendored sing-box is 1.14.4, whose DNS grammar
    // cannot be validated in this environment (the ARM
    // binary cannot run here and no 1.14.4 source is on
    // hand), and a wrong shape would fail every sidecar
    // start. Until it can be proven, the exposure is at
    // least journaled on every such connect.
    if (InternetAddress.tryParse(p.address) == null) {
      diagnostics.add(
        'sidecar',
        'sidecar DNS note: "${p.name}" is addressed by '
            'hostname (${p.address}); the sing-box sidecar '
            'resolves it through the system resolver in '
            'plaintext, outside the tunnel.',
      );
    }
    // Build 2126 (feature pick 3): a ShadowTLS-diverted
    // session says what carries it and what the front
    // cannot do — ShadowTLS is TCP-only in the core, so
    // this session's UDP has nowhere to go (the protocol's
    // real property, shared by every reference client).
    if (shadowTlsServed(p)) {
      final st = p.shadowTlsPlugin!;
      diagnostics.add(
        'sidecar',
        'ShadowTLS fronting: "${p.name}" is served by the '
            'sing-box engine with a ShadowTLS v${st.version} '
            'front (handshake host ${st.host}). ShadowTLS '
            'carries TCP only — this session cannot relay UDP.',
        ok: true,
      );
    }
    final coreDir = await AndroidCore.dataDir();
    final dir = Directory('${File(coreDir).parent.path}/singbox');
    await dir.create(recursive: true);
    final configFile = File('${dir.path}/config.json');
    // Build 2116 (AB-13): atomic — a kill mid-write tore
    // this session config and the next start inherited it.
    await AtomicJsonStore.writeText(
      configFile,
      // Build 2125 (A25-33): compact, like the tunnel/test
      // configs — the core reads it, nobody else does.
      compactJson(buildSingBoxConfig(
        p,
        logLevel: settings.logLevel,
        // Build 2126 (D1 + D8): the sidecar toggles.
        geckoPacketSizes: settings.geckoPacketSizes,
        sidecarTlsFragment: settings.sidecarTlsFragment,
        // Build 2127 (H3): the SNI spoofing rules, only
        // while their toggle is on — off, the emitted
        // route section is 2126's exactly.
        sniSpoofRules: settings.sniSpoofEnabled
            ? settings.sniSpoofRules
            : const [],
      )),
    );
    final started = await SingBoxPlatform.start(['run', '-c', configFile.path]);
    if (!started) {
      final st = await SingBoxPlatform.state();
      throw StateError(
        st.error.isNotEmpty ? st.error : 'The sing-box engine could not start.',
      );
    }
    await _awaitSidecarReady(SingBoxPlatform.state, 'sing-box engine');
    _sessionSidecarKind = 'singbox';
    return singBoxListenPort;
  }

  /// Stops the sidecar engines (build 2075; the Sudoku
  /// engine joined in build 2127) and the Zapret desync
  /// proxy (build 2127, H1), and clears the session
  /// markers. Idempotent — safe from every teardown path.
  Future<void> _stopSidecars() async {
    _sessionSidecarPort = 0;
    _sessionSidecarKind = '';
    _sessionZapretStrategy = '';
    // Build 2126 (audit A26-16): the unready debounce is
    // per-session evidence — it resets with the session,
    // so a stale count cannot pair with the next
    // session's warm-up flicker into a spurious recovery.
    _sidecarUnreadyTicks = 0;
    await SingBoxPlatform.stop();
    await MieruPlatform.stop();
    await SudokuBoxPlatform.stop();
    await ZapretPlatform.stop();
  }

  /// Starts the Zapret desync proxy for a connect whose
  /// dial profile carries a DPI Lab zap win (build 2127,
  /// H1) and waits for its listener. Fails LOUDLY, unlike
  /// DNSCrypt: the built config chains the tunnel's proxy
  /// outbound through this proxy, so a proxy that is not
  /// there would blackhole the session under a "Connected"
  /// label — the connect throws StateError('zapret-start')
  /// and the shell shows the plain line instead.
  Future<void> _startZapretForConnect(String strategy) async {
    // A previous attempt's proxy (an earlier fallback-walk
    // member, a failed start) never carries into this one.
    await ZapretPlatform.stop();
    final started = await ZapretPlatform.start(buildZapretArgs(strategy));
    if (!started) {
      final st = await ZapretPlatform.state();
      diagnostics.add(
        'zapret',
        'The Zapret desync proxy could not start.'
            '${st.error.isEmpty ? '' : ' The core said: ${st.error}'}',
        ok: false,
      );
      throw StateError('zapret-start');
    }
    try {
      await _awaitSidecarReady(ZapretPlatform.state, 'Zapret desync proxy');
    } catch (e) {
      diagnostics.add('zapret', '$e', ok: false);
      await ZapretPlatform.stop();
      throw StateError('zapret-start');
    }
    _sessionZapretStrategy = strategy;
    diagnostics.add(
      'zapret',
      'Zapret desync proxy up on 127.0.0.1:$zapretListenPort '
          '($strategy) — this session chains through it.',
      ok: true,
    );
  }

  /// Starts the DNSCrypt proxy for a session whose DNS
  /// transport is 'dnscrypt' (build 2075). A failure is a
  /// diagnostics warning, not a connect failure: the built
  /// config always carries a plain fallback resolver behind
  /// the proxy (see _dnsSection), so DNS still answers.
  Future<void> _startDnsCrypt() async {
    try {
      final coreDir = await AndroidCore.dataDir();
      final dir = Directory('${File(coreDir).parent.path}/dnscrypt');
      await dir.create(recursive: true);
      final toml = File('${dir.path}/dnscrypt-proxy.toml');
      // Build 2116 (AB-13): atomic, like the sing-box
      // config above.
      await AtomicJsonStore.writeText(toml, buildDnsCryptConfig(dir.path));
      final started = await DnsCryptPlatform.start(['-config', toml.path]);
      if (!started) {
        // Build 2095 (third-pass audit 3-3): the core's own
        // error rides along — the DNSTT path already did
        // this; the bare sentence told the user nothing.
        final st = await DnsCryptPlatform.state();
        diagnostics.add(
          'dnscrypt',
          'The DNSCrypt proxy could not start; DNS uses the '
              'config fallback resolver for this session.'
              '${st.error.isEmpty ? '' : ' The core said: ${st.error}'}',
          ok: false,
        );
        return;
      }
      _sessionDnsCrypt = true;
      SidecarState? lastSt;
      for (var i = 0; i < 12; i++) {
        final st = await DnsCryptPlatform.state();
        lastSt = st;
        if (st.ready) return;
        if (st.stage == 'error') break;
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      diagnostics.add(
        'dnscrypt',
        'The DNSCrypt proxy did not come up; DNS uses the '
            'config fallback resolver until it does.'
            '${(lastSt?.error.isEmpty ?? true) ? '' : ' The core said: ${lastSt!.error}'}',
        ok: false,
      );
    } catch (_) {
      diagnostics.add(
        'dnscrypt',
        'The DNSCrypt proxy could not start; DNS uses the '
            'config fallback resolver for this session.',
        ok: false,
      );
    }
  }

  /// The WireGuard profiles of [p]'s .conf group (build
  /// 2075, feature item 27) when the multi-peer setting is
  /// on and the group really has siblings; empty otherwise
  /// (the builder then emits the single peer, as always).
  List<Profile> _wgPeersFor(Profile p) {
    if (!settings.wgUseAllPeers || p.protocol != Protocol.wireguard) {
      return const [];
    }
    final key = wgGroupKey(p);
    final group = profiles
        .where((x) => x.protocol == Protocol.wireguard && wgGroupKey(x) == key)
        .toList();
    return group.length > 1 ? group : const [];
  }

  /// Applies the routing-by-network-type policy (build
  /// 2075, feature item 26): the active routing preset
  /// follows the transport — the Wi-Fi preset on Wi-Fi, the
  /// mobile preset on mobile data. A running tunnel keeps
  /// the preset it started with; the swap lands at the next
  /// connect (a network change that drops the tunnel makes
  /// the auto-reconnect pick it up, which is the case that
  /// matters). Called by the shell on every network change.
  Future<void> applyRoutingForNetwork(NetworkIdentity id) async {
    if (!settings.routingByNetwork) return;
    final target = id.isWifi
        ? settings.routingPresetWifi
        : id.isMobile
        ? settings.routingPresetMobile
        : null;
    if (target == null || target == settings.routingPreset) return;
    settings.routingPreset = target;
    await _save();
    diagnostics.add(
      'routing',
      'Routing preset is now "${target.name}" for this network type.',
    );
    notifyListeners();
  }

  /// The plain-Xray carries proof (build 2116, audit
  /// AB-01): the WireGuard leg's pattern — poll the exit
  /// lookup for up to 12 s, then let one tunnel check be
  /// the verdict. True when a request demonstrably carried
  /// through the tunnel. [checkAlive] is the caller's
  /// cancellation check, run around the awaits: a
  /// disconnect landing inside the proof cancels the
  /// connect instead of adopting a stopped session.
  /// Public so the verdict is unit-testable without a
  /// device (the awgPeerCarries precedent).
  /// Build 2135 (audit A34-05): holds an already-consumed
  /// stats delta for the accounting poll, mirroring the
  /// hold the poll itself makes when no profile matches
  /// (build 2125, A25-44): the native counters advance on
  /// every read, so a read made outside the poll must hand
  /// its delta over or the session's totals lose the
  /// bytes. A hold owned by a DIFFERENT profile is left
  /// alone — the poll's own drop rule governs it.
  void _holdStatsDelta(String id, int up, int down) {
    if (id.isEmpty || (up <= 0 && down <= 0)) return;
    if (_heldStatsId.isNotEmpty && _heldStatsId != id) return;
    if (_heldStatsId != id) {
      _heldStatsAtMs = DateTime.now().millisecondsSinceEpoch;
    }
    _heldStatsId = id;
    _heldStatsUp += up;
    _heldStatsDown += down;
    unawaited(_saveStatsSidecar());
  }

  /// Build 2135 (audit A34-05): whether any bytes came BACK
  /// through the tunnel since the core's counters were last
  /// read — the slow-but-alive signature the proof's grace
  /// re-check keys on. Best-effort: a failed read, or
  /// counters this session does not move, reads as "no
  /// bytes" and the caller keeps the pre-2135 behaviour.
  /// The read consumes the native delta, so whatever it
  /// carried is held for the accounting poll (see
  /// [_holdStatsDelta]) under the id the poll itself
  /// would use.
  Future<bool> _proofSawDownlink() async {
    final delta = await XrayPlatform.trafficStats(statsApiPort(settings));
    if (delta == null) return false;
    final up = delta['up'] ?? 0;
    final down = delta['down'] ?? 0;
    if (up > 0 || down > 0) {
      _holdStatsDelta(
        _connectedProfileId.isNotEmpty
            ? _connectedProfileId
            : selectedProfileId,
        up,
        down,
      );
    }
    return down > 0;
  }

  Future<bool> awaitXrayCarries(
    void Function() checkAlive, {
    bool freshProof = false,
  }) async {
    // Build 2126 (audit A26-01): a FRESH proof must not
    // consult the cached [exitInfo] — the connect-time
    // value is never cleared mid-session, so the loop
    // below would pass instantly on stale data (the 2125
    // re-proof's defect: a server dying mid-session kept
    // its "verified" stamp forever). A fresh proof is
    // decided by the tunnel check alone — a live probe
    // through the tunnel, the same evidence the connect
    // path below accepts when no exit lookup ever lands.
    if (freshProof) {
      checkAlive();
      await refreshState();
      if (!state.running) return false;
      final ms = await XrayPlatform.tunnelCheck(
        settings.socksPort,
        socksUser: _lanUser,
        socksPass: _lanPass,
      );
      checkAlive();
      return ms >= 0;
    }
    _fetchExitInfo();
    final deadline = DateTime.now().add(const Duration(seconds: 12));
    while (DateTime.now().isBefore(deadline)) {
      checkAlive();
      await refreshState();
      if (!state.running) return false;
      if (exitInfo != null) return true;
      await Future<void>.delayed(const Duration(milliseconds: 800));
    }
    checkAlive();
    if (!state.running) return false;
    if (exitInfo != null) return true;
    final ms = await XrayPlatform.tunnelCheck(
      settings.socksPort,
      socksUser: _lanUser,
      socksPass: _lanPass,
    );
    checkAlive();
    if (ms >= 0) return true;
    // Build 2135 (audit A34-05): ONE confirmation re-check
    // after a short grace, only when bytes actually came
    // back during the window — a slow-but-alive server (a
    // just-started desync chain on a loaded carrier) can
    // miss the fixed 12 s budget on its first request
    // while its replies are already moving. Zero downlink
    // keeps the pre-2135 verdict exactly: no grace, no
    // second check. The honesty rule is untouched — the
    // re-check is the same live tunnel check, and nothing
    // is stamped carried without a check passing.
    if (!await _proofSawDownlink()) return false;
    checkAlive();
    diagnostics.add(
      'connect',
      'The first proof window closed, but bytes are '
          'coming back through the tunnel — one '
          'confirmation re-check after a short grace.',
    );
    await Future<void>.delayed(const Duration(seconds: 5));
    checkAlive();
    await refreshState();
    if (!state.running) return false;
    if (exitInfo != null) return true;
    final recheckMs = await XrayPlatform.tunnelCheck(
      settings.socksPort,
      socksUser: _lanUser,
      socksPass: _lanPass,
    );
    checkAlive();
    return recheckMs >= 0;
  }

  Future<void> _connectSelected() async {
    final p = selected;
    if (p == null) throw StateError('no-profile');
    // Build 2089: every parsed protocol is served now —
    // AnyTLS connects through the sing-box sidecar like
    // the other 2075 protocols. The refusal below survives
    // only for a protocol no engine serves, of which there
    // is currently none.
    if (!p.protocol.connectable) throw StateError('unsupported');
    // Build 2127 (H2): a Sudoku profile with its engine
    // switch off refuses HERE, in plain words — the
    // protocol is connectable (its engine is in the app),
    // so 'unsupported' would be a lie, and letting it
    // fall through would build an Xray config for a
    // protocol the Xray core cannot speak.
    if (p.protocol == Protocol.sudoku && !settings.sudokuEnabled) {
      throw StateError('sudoku-off');
    }
    // Build 2147 (feature #6): the SSH diversion's gate, the
    // Sudoku shape — plain words, never an Xray config for a
    // protocol the Xray core cannot speak.
    if (p.protocol == Protocol.ssh && !settings.sidecarSshEnabled) {
      throw StateError('ssh-off');
    }
    // Build 2147 (features #20/#21a): a quarantined profile
    // refuses in plain words — it was cut for failing, and
    // only an explicit restore connects it again.
    if (p.quarantined) throw StateError('quarantined');
    // A Shadowsocks plugin is stored but never applied (build
    // 2057, audit F-M11): the core has no plugin support, so say
    // so in the diagnostics at connect time — the home card
    // badges the profile too, and neither leaves the handshake
    // failure unexplained. Build 2126: a shadow-tls plugin
    // with fronting on is the exception — the sidecar applies
    // it (see _startSidecarInner's fronting note), so the
    // not-applied line must not run for a diverted profile.
    if (p.hasUnsupportedPlugin && !shadowTlsServed(p)) {
      diagnostics.add(
        'ss',
        'Plugin "${p.plugin}" is not applied — the core has no '
            'plugin support; this session connects without it.',
        ok: false,
      );
    }
    // Build 2095 (fourth-pass audit 3.5/3.4): the same
    // honesty for Hysteria2 — a non-salamander obfs is
    // never applied, and source port hopping is carried
    // but not applied; both are journaled at connect so a
    // failed handshake is never unexplained.
    if (p.hasUnappliedObfs) {
      diagnostics.add(
        'hy2',
        'Obfs "${p.obfs}" is not applied — this build applies '
            'salamander (Xray core) and gecko (sing-box engine); '
            'this session connects without it.',
        ok: false,
      );
    }
    // Build 2116 (audit B2-2/B2-7): the shapes that used to
    // be journaled as dropped are applied now — by the
    // sing-box sidecar, which is also where the session is
    // served from, so the journal says that instead.
    if (p.hy2SidecarServed) {
      diagnostics.add(
        'hy2',
        p.hyMport.isNotEmpty
            ? 'Port hopping (${p.hyMport}) is applied by the '
                  'sing-box engine — the Xray core has no '
                  'port-hopping field.'
            : 'Gecko obfs is applied by the sing-box engine — '
                  'the Xray core has no gecko support.',
        ok: true,
      );
    }
    // Build 2116 (audit S-02): a NaiveProxy padding
    // parameter is carried on the profile but sing-box's
    // naive outbound has no padding option — journaled so
    // the loss is never silent (the supported extras ARE
    // applied: singbox_config).
    if (p.hasUnappliedNaivePadding) {
      diagnostics.add(
        'naive',
        'The link\'s padding parameter is not applied — the '
            'sing-box engine has no NaiveProxy padding option; '
            'this session connects without it.',
        ok: false,
      );
    }
    // Build 2116 (audit G-16): a TCP header type the core
    // cannot emit used to be dropped silently; the ones it
    // can emit are in the config now (config_builder), and
    // the rest are journaled here.
    if (p.hasUnappliedTcpHeader) {
      diagnostics.add(
        'xray',
        'TCP header type "${p.headerType}" is not one the '
            'core can emit; this session runs as plain TCP.',
        ok: false,
      );
    }
    // Build 2096 (post-2095 audit M1): a REALITY profile
    // on QUIC/KCP runs with TLS substituted at emit time
    // (the core refuses the pairing) — journaled here so
    // the substitution the builder makes is never silent.
    if (p.hasRealityTransportMismatch) {
      diagnostics.add(
        'xray',
        'REALITY does not load on ${p.network}; this session '
            'runs with TLS instead.',
        ok: false,
      );
    }
    // Build 2125 (audit A25-14 / P-15, surfacing half):
    // the same uncovered-window note as connectWarp — see
    // there. The hold covers a tunnel that exists and
    // drops; the window before one exists is journaled,
    // not hidden.
    if (settings.killSwitch) {
      diagnostics.add(
        'connect',
        'Kill switch: the connect/switch window is not '
            'covered until the new tunnel proves it '
            'carries traffic — the hold applies once a '
            'tunnel exists.',
        ok: false,
      );
    }
    // A fresh connect supersedes a pending retry (build 2042).
    _cancelReconnectTimer();
    // A full connect supersedes any switch in flight (build 2039).
    _tunnelGen++;
    // Build 2095 (audit 2.1): capture the generation and
    // re-check it after every pre-start await and before
    // setOn — disconnect() bumps it, and the old code never
    // re-read it on this path, so a stop pressed during the
    // pre-start window was overtaken by the connect.
    final gen = _tunnelGen;
    void checkAlive() {
      if (gen != _tunnelGen) throw const _ConnectCancelled();
    }

    connecting = true;
    _connectingProfileId = p.id;
    lastError = null;
    // Build 2107: a new attempt supersedes any earlier failed
    // connect's DPI Lab offer; this attempt's own failure tail
    // sets it afresh when the Lab is on.
    dpiLabOfferProfileId = '';
    exitInfo = null;
    // Build 2097 (post-2096 audit N4): a new attempt starts
    // with a clean chain notice — the previous session's
    // problem report (or sidecar note) is superseded by
    // this attempt, whose own branches/sampler set it
    // afresh. (Not cleared at disconnect: the notice is
    // documented to outlive the session it reports on.)
    chainNotice = '';
    // Build 2097 (post-2096 audit C2): whether this attempt
    // issued its native start — the cancellation path below
    // uses it to stop a start that raced the disconnect.
    var startIssued = false;
    notifyListeners();
    try {
      // One tunnel at a time: the Mozilla engine goes off first.
      await stopOtherEngine?.call();
      if (state.running) await _stopTunnel();
      checkAlive();
      // Build 2110 (wg-start diagnosis, defect 2): the
      // engine-switch funnel — _stopTunnel's wait observes
      // `running` go false, but an AWG session's backend
      // tunnel can still hold the VPN slot past that point;
      // observe it fully down before this start (bounded —
      // see _awaitPreviousEngineDown).
      await _awaitPreviousEngineDown(checkAlive);
      checkAlive();
      // Build 2098 (verification F-A3): a chain exit deferred
      // during the session just stopped is NOT consumed
      // here. An earlier 2098 revision consumed it at this
      // point (audit L16) and the verification sweep proved
      // the consumption corrupts the in-flight attempt: the
      // consume's select() re-points the selection to the
      // deferred target while THIS attempt connects the
      // profile the user tapped — a failed attempt spends
      // the deferral (a retry then connects the target, not
      // the tapped profile), a successful one gets the
      // target recorded as this network's winner although
      // the tapped profile carried the traffic, and select()
      // marks the selection user-chosen, disabling
      // per-network preselection for the session. There is
      // no correct mid-connect point for the consumption —
      // every point after the user's tap lets a stale
      // deferral override a fresher intent — so consumption
      // stays where 2097 had it: in disconnect(), at a true
      // session end with no attempt in flight. L16 is
      // therefore PARTIAL: the deferral can still outlive a
      // reconnect's internal stop until the next explicit
      // disconnect (timing only; no wrong state results).
      if (networkFp.isEmpty) await refreshNetworkFingerprint();
      checkAlive();
      // Fast path (build 2029A): a shape that already proved
      // itself on THIS network is dialed directly, without
      // re-running any funnel.
      final win = shapeCache.lookup(p.id, networkFp);
      var dialProfile = win == null ? p : profileWithShape(p, win.shapeId);
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
      // Build 2107 (DPI Strategy Lab): with the Lab on and no
      // per-profile shape win of its own, a strategy the Lab
      // confirmed on THIS network is dialed first. The Lab's
      // memory ranks below the shape cache (a win proven for
      // this very profile outranks a network-level one) and
      // the branch is unreachable while the Lab is off, so an
      // off Lab leaves this dial exactly the 2106 one. One
      // deliberate difference for a Lab-dialed session: the
      // watchdog's shape escalation stands down (see
      // [_labDialActive]) — its shapes are computed from the
      // stored profile and would silently discard the Lab
      // strategy; adaptive failover owns recovery instead.
      _clearLabDialState();
      if (win == null) {
        final labDial = _dpiLabDial(p);
        if (labDial != null) {
          dialProfile = labDial.profile;
          // A Stock (s0) win dials the stored profile itself —
          // there is no Lab strategy for the watchdog to
          // discard, so escalation stays armed for it (build
          // 2107, verification iteration 2).
          if (labDial.candidateId != shapeStock) {
            _labDialActive = true;
            _labDialCandidateId = labDial.candidateId;
            // Build 2116 (B13-6, 2107-L1): persist the
            // stand-down NOW, before the native start
            // completes. The adoption restore reads the
            // candidate from the store; if the process died
            // between the core starting and the next routine
            // save, the store still held the previous (or no)
            // candidate and a relaunched app adopted the
            // Lab-dialed session WITHOUT the stand-down —
            // the watchdog could then discard the strategy
            // the session was dialed with.
            await _save();
          }
        }
      }
      // The chain (build 2029A): the Psiphon underlay comes up
      // FIRST and must prove its handshake before Xray starts;
      // the native ChainSupervisor then owns its health for
      // the session's life.
      // Build 2075: a sidecar-served profile (TUIC / AnyTLS /
      // Snell / NaiveProxy / Mieru / Tailscale / OpenConnect)
      // does not chain through an underlay — the sidecar IS
      // the dialer, and stacking the chain under it would
      // dial the local sidecar through the underlay. The
      // session connects through its sidecar directly, and
      // says so when an underlay was configured.
      final sidecarServed = servedViaSidecar(p);
      if (sidecarServed && settings.underlay != 'none') {
        diagnostics.add(
          'connect',
          '${p.protocol.label} runs on its sidecar engine, so '
              'this session does not chain through the '
              '${settings.underlay} underlay.',
        );
        // Build 2097 (post-2096 audit N4): the degradation
        // is user-visible too, not log-only — chainNotice
        // is the Home surface for exactly this, and build
        // 2096 left it empty for the sidecar route while
        // the Home underlay chips implied a chained
        // session.
        chainNotice =
            '${p.protocol.label} runs on its sidecar engine, so '
            'this session does not chain through the '
            '${settings.underlay} underlay.';
      }
      final chained = settings.underlay == 'psiphon' && !sidecarServed;
      final warpChained = settings.underlay == 'warp' && !sidecarServed;
      final dnsttChained = settings.underlay == 'dnstt' && !sidecarServed;
      final olcrtcChained = settings.underlay == 'olcrtc' && !sidecarServed;
      ({String region, String upstream, List<String> protocols})? chainParams;
      if (chained) {
        chainNotice = '';
        _lastChainProblem = '';
        chainParams = await _startUnderlay();
        checkAlive();
      }
      // The Warp chain (build 2030) starts in the opposite
      // order: the warp core's egress must ride Xray's
      // exit-node, so Xray (with its secondary inbound) starts
      // FIRST; the VPN service spawns the core itself as the
      // session starts (build 2080 — the Dart side used to
      // spawn it only after a post-start poll, burning the
      // supervisor's grace before the scan began), and its
      // readiness — a gateway proven through the exit —
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
        // Build 2080: a missing identity is provisioned
        // directly BEFORE the session — a chained core cannot
        // register through its own exit.
        await _provisionWarpIdentityForChain();
        checkAlive();
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
        checkAlive();
      }
      // The OLCRTC chain (build 2134): like DNSTT, the
      // client comes up FIRST and must open its listener
      // before Xray starts — for OLCRTC the listener also
      // proves the WebRTC link itself is up; the native
      // ChainSupervisor then owns its health for the
      // session's life.
      var olcrtcArgs = const <String>[];
      if (olcrtcChained) {
        chainNotice = '';
        _lastChainProblem = '';
        olcrtcArgs = await _startOlcrtcUnderlay(checkAlive);
        checkAlive();
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
          checkAlive();
          wgWstunnelOn = true;
          _sessionWgWstunnelPort = wstunnelListenPort;
        }
      }
      // The sidecar engines (build 2075): a TUIC / Snell /
      // NaiveProxy / Mieru / Tailscale / OpenConnect session
      // starts its sidecar FIRST and waits for its local
      // listener; the tunnel config then dials the sidecar
      // as a plain SOCKS outbound. A sidecar that will not
      // start fails the connect with its own plain message.
      var sidecarPort = 0;
      _sessionSidecarPort = 0;
      _sessionSidecarKind = '';
      // Build 2126 (A26-16): session boundary — see
      // _stopSidecars.
      _sidecarUnreadyTicks = 0;
      if (sidecarServed) {
        sidecarPort = await _startSidecarFor(p);
        checkAlive();
        _sessionSidecarPort = sidecarPort;
        diagnostics.add(
          'connect',
          '${p.protocol.label} is served by the '
              '$_sidecarLabel '
              'on 127.0.0.1:$sidecarPort.',
          ok: true,
        );
      }
      // The DNSCrypt transport (build 2075): the local proxy
      // comes up before the core, whose DNS section points
      // at it. Non-fatal on failure (see _startDnsCrypt).
      _sessionDnsCrypt = false;
      if (settings.remoteDnsProto == 'dnscrypt') {
        await _startDnsCrypt();
        checkAlive();
      }
      // The Zapret desync proxy (build 2127, H1): when the
      // dial profile carries a Lab zap win, the proxy comes
      // up before the core, whose proxy outbound chains
      // through it (config_builder). Fatal on failure —
      // there is no fallback resolver trick for a chained
      // outbound (see _startZapretForConnect).
      if (dialProfile.zapretStrategy.isNotEmpty) {
        await _startZapretForConnect(dialProfile.zapretStrategy);
        checkAlive();
      }
      // Build 2125 (A25-22): the geo files must exist
      // before the core starts on this config — load()
      // starts their install without blocking on it, so
      // the funnel completes the wait here (a no-op once
      // installed; _installGeoFiles swallows its own
      // failures, exactly as when load awaited it).
      await _ensureGeoInstalled();
      checkAlive();
      // Build 2147 (feature #2): Auto MTU discovery — the
      // PMTU black-hole walk against the dial endpoint,
      // before the core starts. The winner becomes this
      // session's MTU override and is remembered in
      // settings.autoMtuFound for display; no answer keeps
      // the manual value. Gate DEFAULT OFF.
      _sessionMtuOverride = 0;
      if (settings.autoMtu && !sidecarServed) {
        final found = await _discoverMtu2147(
          dialProfile.address,
          dialProfile.port,
        );
        if (found != null) {
          _sessionMtuOverride = found;
          if (settings.autoMtuFound != found) {
            settings.autoMtuFound = found;
            unawaited(_save());
          }
          diagnostics.add(
            'mtu',
            'Auto MTU: $found answers on this path — used for '
                'this session.',
            ok: true,
          );
        } else {
          diagnostics.add(
            'mtu',
            'Auto MTU: no size answered — the manual MTU '
                '(${settings.tunnelMtu}) rules.',
            ok: false,
          );
        }
        checkAlive();
      }
      // Build 2147 (feature #5): Balancer mode — for an
      // opted-in subscription group on the plain path (no
      // underlay chain, no sidecar, no Lab zapret win), one
      // core carries the whole group behind an observatory +
      // leastPing balancer. Any failure to build it falls
      // back to the plain single-profile config below.
      String? balancerConfig;
      if (p.subscriptionId.isNotEmpty &&
          settings.balancerGroupIds.contains(p.subscriptionId) &&
          !sidecarServed &&
          !chained &&
          !warpChained &&
          !dnsttChained &&
          !olcrtcChained &&
          dialProfile.zapretStrategy.isEmpty) {
        final members = profiles
            .where(
              (m) => m.subscriptionId == p.subscriptionId && !m.quarantined,
            )
            .toList();
        if (members.length > 1) {
          try {
            balancerConfig = buildBalancerTunnelConfig(
              members,
              settings,
              serverHostPins: _mergedServerPins(
                _sessionServerPins = await _serverNamePins(
                  dialProfile,
                  journal: true,
                ),
                _sessionProviderPins = await _providerDnsPins(dialProfile),
              ),
            );
            diagnostics.add(
              'connect',
              'Balancer mode: ${members.length} configs of this '
                  'group share one core (observatory + leastPing).',
              ok: true,
            );
          } catch (_) {
            balancerConfig = null;
          }
        }
      }
      final config =
          balancerConfig ??
          buildTunnelConfig(
            dialProfile,
            settings,
            psiphonUnderlay: chained,
        warpUnderlay: warpChained,
        warp: warpProfile,
        dnsttUnderlay: dnsttChained,
        olcrtcUnderlay: olcrtcChained,
        wgWstunnelPort: _sessionWgWstunnelPort,
        sidecarSocksPort: sidecarPort,
        wgPeerProfiles: _wgPeersFor(p),
        // Build 2105: provider-DNS pins for the server
        // hostname (empty unless the feature is on and the
        // subscription's DNS answered). Kept on the
        // controller: a watchdog shape rotation rebuilds this
        // session's config and must carry the same pins.
        // Build 2110: merged with the server-name pins (the
        // default v2rayNG-method-"1" resolution), which are
        // kept alongside and ride rotations unconditionally.
        serverHostPins: _mergedServerPins(
          _sessionServerPins = await _serverNamePins(
            dialProfile,
            journal: true,
          ),
          _sessionProviderPins = await _providerDnsPins(dialProfile),
        ),
      );
      checkAlive();
      // Build 2111: journal the session's effective remote DNS
      // servers once per connect, so a Diagnostics export shows
      // the list the core actually runs (the 2110 export is how
      // the dead-DoH defect was proven; the next one is how this
      // build's UDP-first list is verified on-device).
      diagnostics.add(
        'dns',
        'Remote DNS servers for this session: '
            '${primaryResolvers(settings).join(', ')}.',
      );
      // Build 2125 (audit A25-23 / P-19): on the plain
      // WireGuard leg the TUN DNS is family-guarded, like
      // the AWG leg's since build 2110 — an IPv6-only local
      // DNS with the IPv6 route off would otherwise be
      // filtered to zero resolvers by the TUN builder. The
      // profile's uncovered family is journaled here too
      // (the AWG adoption has journaled it since 2116; the
      // plain adoption below only had the IPv6-route note).
      var tunDns = settings.localDns;
      if (p.protocol == Protocol.wireguard) {
        final guarded = wgPlainTunDnsGuarded(
          tunDns,
          ipv6: settings.ipv6Route,
        );
        if (guarded.$2 != null) {
          diagnostics.add('dns', guarded.$2!, ok: false);
        }
        tunDns = guarded.$1;
        final famNote = wgUncoveredFamilyNote(p);
        if (famNote != null) {
          diagnostics.add('connect', '${p.name}: $famNote', ok: false);
        }
      }
      await XrayPlatform.setOn(
        config: config,
        name: p.name,
        socksPort: settings.socksPort,
        dns: tunDns,
        ipv6: settings.ipv6Route,
        // Build 2147 (feature #2): the session's discovered
        // MTU wins while Auto MTU is on; otherwise the stored
        // manual value, untouched.
        mtu: _sessionMtuOverride > 0
            ? _sessionMtuOverride
            : settings.tunnelMtu,
        socksUser: _lanUser,
        socksPass: _lanPass,
        killSwitch: settings.killSwitch,
        underlay: chained
            ? 'psiphon'
            : warpChained
            ? 'warp'
            : dnsttChained
            ? 'dnstt'
            : olcrtcChained
            ? 'olcrtc'
            : 'none',
        underlayRegion: chainParams?.region ?? '',
        underlayUpstream: chainParams?.upstream ?? '',
        underlayProtocols: chainParams?.protocols ?? const [],
        warpArgs: warpArgs,
        dnsttArgs: dnsttArgs,
        olcrtcArgs: olcrtcArgs,
        wgWstunnel: wgWstunnelOn,
        wstunnelArgs: wstunnelArgs,
      );
      startIssued = true;
      // The service reports itself once the tunnel is really up.
      for (var i = 0; i < 40; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        state = await XrayPlatform.state();
        // Build 2097 (post-2096 audit C2): the aliveness
        // check belongs AFTER the state read — a disconnect
        // landing inside the await used to be followed by
        // this attempt adopting the session it just stopped
        // (setting _connectedProfileId/_expectRunning and
        // starting polling for it below).
        checkAlive();
        if (state.running) break;
      }
      if (!state.running) {
        // Build 2095 (third-pass audit 3-1): the native
        // service publishes WHY a start failed in
        // coreProblem — carry it instead of the bare code,
        // and journal it so the diagnostics show the cause.
        final problem = state.coreProblem;
        if (problem.isNotEmpty) {
          diagnostics.add('connect', 'Start failed: $problem', ok: false);
          throw StateError('start-failed: $problem');
        }
        throw StateError('start-failed');
      }
      if (warpChained &&
          !await _awaitWarpReady(
            warpArgs,
            wait: const Duration(seconds: 150),
          )) {
        // Build 2098 (post-2097 audit M1): aliveness FIRST.
        // A disconnect landing in the (up to 150 s) underlay
        // wait is a cancellation, not an underlay failure —
        // the pre-2098 order threw 'underlay-failed' before
        // the checkAlive below, so the fallback walk caught
        // a generic failure and dialed the next group member
        // AFTER the user had disconnected. checkAlive throws
        // _ConnectCancelled, which the walk rethrows (C1).
        checkAlive();
        // Xray is up but the underlay never proved itself:
        // tear the whole session down rather than showing a
        // chained "Connected" over a dead warp core.
        await _stopTunnel();
        throw StateError('underlay-failed');
      }
      // Build 2097 (post-2096 audit C2): the underlay wait
      // can take over two minutes — a disconnect landing in
      // it must not be adopted either.
      checkAlive();
      // Build 2116 (audit AB-01): the data-plane proof.
      // Builds ≤2115 adopted a plain Xray session on
      // `running` alone — "Connected" meant the VPN service
      // was up, never that traffic flowed (the fugui class:
      // a session can run perfectly and carry nothing).
      // The WireGuard leg has always proved carrying before
      // adopting (the 12 s carries window in
      // connectWireGuardWithFallback); plain Xray gets the
      // same proof here: an exit lookup through the tunnel,
      // then one tunnel check as the verdict. A session
      // that carries nothing is torn down and thrown into
      // the fallback walk like any other failed attempt —
      // it is never stamped Connected. The WireGuard
      // protocol leg is exempt: the walk runs this same
      // proof itself around this function. The demoting
      // watchdogs stay DEFAULT OFF (the defaults law) —
      // the proof is at adoption, not a new always-on guard.
      if (p.protocol != Protocol.wireguard) {
        final carried = await awaitXrayCarries(checkAlive);
        checkAlive();
        if (!carried) {
          diagnostics.add(
            'connect',
            'The tunnel started but carried no traffic '
                'within 12 s — it is not marked connected.',
            ok: false,
          );
          await _stopTunnel();
          throw StateError('no-traffic');
        }
        _proofVerifiedSinceMs = state.sinceMs;
        // Build 2125 (A25-11): the re-proof cadence starts
        // from this proof.
        _proofVerifiedAtMs = DateTime.now().millisecondsSinceEpoch;
        state = state.withVerified(true);
      }
      _connectedProfileId = p.id;
      // Build 2098 (post-2097 audit M16): the session's
      // underlay, captured from THIS attempt's chain shape —
      // the underlay card names the session from this, never
      // from the (possibly since-changed) setting.
      _sessionUnderlay = chained
          ? 'psiphon'
          : warpChained
          ? 'warp'
          : dnsttChained
          ? 'dnstt'
          : olcrtcChained
          ? 'olcrtc'
          : '';
      // Build 2123 (audit C-01): an IPv6 family this
      // session does not capture is journaled at adoption —
      // never silent. The WireGuard path has journaled its
      // uncovered family since 2116; the main V2Ray path
      // had no equivalent, and the default itself stays
      // exactly as ordered (v2rayNG parity).
      final ipv6Note = ipv6UncoveredSessionNote(settings);
      if (ipv6Note != null) {
        diagnostics.add('connect', ipv6Note, ok: false);
      }
      // Build 2092 (UI audit item 5): record the actually-
      // connected profile id in the store at once — a group
      // walk lands here once per tried member, so the final
      // write names the member that connected, and an app
      // restart adopts the session under its true profile.
      unawaited(_save());
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
      if (settings.underlay == 'olcrtc' && !state.running) {
        unawaited(OlcrtcPlatform.stop());
      }
      if (!state.running) {
        unawaited(WstunnelPlatform.stop());
      }
      // Build 2075: a failed sidecar session reaps its
      // sidecar and the DNSCrypt proxy the same way — no
      // helper outlives the session that started it.
      if (!state.running) {
        unawaited(_stopSidecars());
        if (_sessionDnsCrypt) {
          _sessionDnsCrypt = false;
          unawaited(DnsCryptPlatform.stop());
        }
      }
      // Build 2095 (audit 2.1): a superseded attempt
      // unwinds quietly — the user cancelled it; there is
      // no failure to report and nothing to rethrow.
      if (e is _ConnectCancelled) {
        lastError = null;
        // Build 2097 (post-2096 audit C2): if this attempt
        // already issued its start, the disconnect's stop may
        // have raced ahead of it (stop landed before setOn
        // executed) and left the tunnel up under a session
        // the user already ended. No newer attempt can own
        // the service yet — it cannot start until this
        // attempt's finally clears `connecting` — so a
        // tunnel that is up now is this attempt's own start:
        // stop it rather than leaving it behind.
        if (startIssued) {
          state = await XrayPlatform.state();
          if (state.running) await _stopTunnel();
        }
        return;
      }
      lastError = e.toString();
      // Build 2107 (verification iteration 4): a terminally
      // failed attempt ends its Lab-dial state with it — the
      // flags were set pre-start, and leaving them set would
      // persist a stale candidate beside an empty connected
      // id on the walk's saves.
      _clearLabDialState();
      // Build 2107: a terminally failed attempt with the DPI
      // Lab on leaves the Lab OFFERED for this profile (the
      // Home card carries the action). A cancelled attempt
      // returned above and never reaches this line. The Lab
      // itself runs only when the user taps the offer.
      if (settings.dpiLabEnabled && dpiLabEligible(p)) {
        dpiLabOfferProfileId = p.id;
      }
      rethrow;
    } finally {
      connecting = false;
      if (_connectingProfileId == p.id) _connectingProfileId = '';
      notifyListeners();
    }
  }

  /// A manual disconnect also ends the adaptive failover's
  /// session: counters and notice reset.
  Future<void> disconnect({bool consumeChainExit = true}) async {
    // A manual disconnect ends the auto-reconnect episode too
    // (build 2042): the expectation flag clears first, so a
    // poll tick landing mid-stop can never schedule a retry.
    _expectRunning = false;
    _cancelReconnect();
    _adaptiveFails = 0;
    _adaptiveSwitches = 0;
    adaptiveNotice = '';
    awgFallbackNotice = '';
    // Build 2107: a manual disconnect also ends any pending
    // DPI Lab offer — the failure it pointed at is closed.
    dpiLabOfferProfileId = '';
    _clearLabDialState();
    // Build 2106 (F-04): the pin notice describes a live
    // session's connect; a disconnect ends it.
    providerDnsNotice = '';
    // A switch in flight must not resurrect the tunnel after a
    // manual disconnect (build 2039).
    _tunnelGen++;
    switchNotice = '';
    switchingProfileId = null;
    await _stopTunnel();
    // Build 2097 (post-2096 audit N3): the session has
    // ended — a chain applied during it now takes its
    // deferred exit selection, so the next connect runs
    // the chain the user applied.
    // Build 2098 (verification, iteration 2): an internal
    // caller that stops the tunnel as a STEP of a larger
    // operation — the WireGuard peer walk resetting
    // between peers — passes consumeChainExit: false. No
    // session has ended from the user's point of view
    // there, and spending the deferral mid-walk latches
    // _userChoseSelection and loses the deferred exit
    // entirely when the walk then fails (the F-A3 defect
    // class, reached through this call instead of
    // _connectSelected's internal stop).
    if (consumeChainExit) _consumePendingChainExit();
  }

  /// Applies a chain exit deferred by a live-session chain
  /// apply (build 2097, post-2096 audit N3). Called from
  /// [disconnect] only, and only when that disconnect is a
  /// true session end — the WireGuard peer walk's internal
  /// reset stop passes consumeChainExit: false (build 2098
  /// verification, iteration 2). Consuming it inside
  /// _connectSelected's internal stop corrupted the
  /// in-flight attempt's selection bookkeeping, so the
  /// mid-connect consumption was reverted (F-A3; see the
  /// note at that stop).
  void _consumePendingChainExit() {
    if (pendingChainExitId.isEmpty) return;
    final target = _profileById(pendingChainExitId);
    pendingChainExitId = '';
    if (target != null) select(target);
  }

  Future<void> _stopTunnel() async {
    // Build 2107 (verification iteration 2): the session-end
    // funnel clears the Lab-dial state, so the invariant
    // "the flag describes the live session" rests here and
    // not on the ordering of the paths that end sessions
    // (WARP connects, poll drops, notification stops all
    // pass through this funnel). A connect that goes on to
    // Lab-dial sets the flag again at its fast path, which
    // runs after this stop.
    _clearLabDialState();
    // Build 2116: the WG exit stamp describes a live
    // session; any stop ends its claim.
    wgExitUnverified = false;
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
    // Build 2098 (post-2097 audit M16): the session's
    // captured underlay ends with the session.
    _sessionUnderlay = '';
    // Build 2092 (UI audit item 5): the cleared id reaches
    // the store with the stop, so a later adopt never
    // resurrects a dead session's profile.
    unawaited(_save());
    _sessionWgWstunnelPort = 0;
    // Build 2105: the session's provider-DNS pins end with it
    // too — a later session computes its own.
    _sessionProviderPins = const {};
    // Build 2106 (verification M1): the adopted-session
    // recompute latch ends with the session too.
    _providerPinsAdoptedFor = '';
    // Build 2110: the server-name pins and their latch end
    // with the session likewise.
    _sessionServerPins = const {};
    _serverPinsAdoptedFor = '';
    // Build 2075: the session's sidecar engine and DNSCrypt
    // proxy end with the session, whoever ended it. Build
    // 2127 (H1): the Zapret desync proxy ends on the same
    // condition (see the drop path's note).
    if (_sessionSidecarPort != 0 ||
        _sessionSidecarKind.isNotEmpty ||
        _sessionZapretStrategy.isNotEmpty) {
      await _stopSidecars();
    }
    if (_sessionDnsCrypt) {
      _sessionDnsCrypt = false;
      await DnsCryptPlatform.stop();
    }
    exitInfo = null;
    // Build 2050: the session's final totals reach disk even
    // when the last debounced write is still pending.
    await _flushStatsSave();
    notifyListeners();
  }

  // ---- tests --------------------------------------------------------------

  /// Builds the throwaway-core test config for [p],
  /// starting its sidecar first when the profile is
  /// sidecar-served (build 2075). Returns the config and
  /// whether a sidecar was started (the caller stops it).
  /// Throws StateError('sidecar-busy') when a live session
  /// owns the sidecar slot.
  Future<(String, bool)> _testConfigFor(Profile p) async {
    // Build 2127 (H2): a Sudoku profile whose engine
    // switch is off is not sidecar-served, so without
    // this gate its test would build an Xray config the
    // core cannot run and fail obscurely — refuse with
    // the same plain word as the connect path.
    if (p.protocol == Protocol.sudoku && !settings.sudokuEnabled) {
      throw StateError('sudoku-off');
    }
    // Build 2147 (feature #6): the test path's SSH gate.
    if (p.protocol == Protocol.ssh && !settings.sidecarSshEnabled) {
      throw StateError('ssh-off');
    }
    if (!servedViaSidecar(p)) {
      // Build 2110 (fugui-hostname diagnosis C1): a test
      // config resolves the server name exactly as the
      // tunnel config does — app-side, pinned, UseIP —
      // or a hostname-form profile would fail its delay
      // test for the same reason it failed to connect.
      return (
        buildTestConfig(
          p,
          settings,
          serverHostPins: await _serverNamePins(p),
        ),
        false,
      );
    }
    if (_sessionSidecarPort != 0 || state.running || _sidecarBusy) {
      throw StateError('sidecar-busy');
    }
    final port = await _startSidecarFor(p);
    return (buildTestConfig(p, settings, sidecarSocksPort: port), true);
  }

  /// The overall budget of a bulk Test All pass for one
  /// profile (build 2109, adjustable delay-test timeout): a
  /// dead config must not burn more than the per-request
  /// timeout, but the pass keeps its historic ~10 s floor —
  /// at the default 8 s timeout this is exactly the 10000 ms
  /// of every build ≤2108, so a longer timeout is actually
  /// honored in bulk mode instead of being silently capped
  /// at 10 s. Pure, so the floor is unit-testable.
  int delayTestBulkBudgetMs(int timeoutMs) =>
      timeoutMs > 10000 ? timeoutMs : 10000;

  /// The real delay of one profile, run through a throwaway core.
  /// Build 2032: the same test also captures the exit identity
  /// through the test core (the v2go fold-in) and stores it on
  /// the profile, so the list shows where a config exits
  /// without connecting to it.
  /// Build 2101 (settings-dns-2099-diagnosis.md, S3/S5): the
  /// row clears to pending before measuring (the owner's
  /// clear-first spec); the verdict records its stage on
  /// [Profile.delayStage]; a sidecar-busy refusal is a distinct
  /// outcome, not a failure; and the bulk pass ([bulk]) runs
  /// one request round under a ~10 s budget and leaves the
  /// store save to the scan's end instead of saving per test.
  /// Build 2109: the per-request timeout is the
  /// `delayTestTimeoutSec` setting (default 8 s — the fixed
  /// value of every build ≤2108); the bulk budget is
  /// [delayTestBulkBudgetMs] of that timeout.
  Future<int> testDelay(Profile p, {bool bulk = false}) async {
    // Build 2075: sidecar-served profiles test through their
    // sidecar (see _testConfigFor); a profile no engine
    // serves still refuses outright (none today — AnyTLS
    // joined the sidecar in build 2089).
    if (!p.protocol.connectable) {
      p.delayStage = 'not-testable';
      return -1;
    }
    _testing.add(p.id);
    notifyListeners();
    p.delayMs = -1;
    p.delayFailed = false;
    p.delayStage = '';
    var startedSidecar = false;
    try {
      final (config, started) = await _testConfigFor(p);
      startedSidecar = started;
      final timeoutMs = settings.delayTestTimeoutMs;
      final r = await XrayPlatform.measureDelayEx(
        config,
        rounds: bulk ? 1 : 2,
        budgetMs: bulk ? delayTestBulkBudgetMs(timeoutMs) : 0,
        timeoutMs: timeoutMs,
      );
      final ms = (r['ms'] as num?)?.toInt() ?? -1;
      p.delayMs = ms;
      p.delayFailed = ms < 0;
      p.delayStage = 'core';
      if (ms >= 0) {
        final ip = (r['ip'] as String?) ?? '';
        final cc = (r['countryCode'] as String?) ?? '';
        if (ip.isNotEmpty) p.exitIp = ip;
        if (cc.isNotEmpty) p.exitCountryCode = cc;
      }
      if (!bulk) await _saveStatsSidecar(); // build 2123 (B-02): volatile fields only
      return ms;
    } on StateError catch (e) {
      // Build 2101 (D3): _testConfigFor refuses with
      // 'sidecar-busy' while a live session owns the sidecar
      // slot. That is not a dead profile — before this build
      // it collapsed into the same bare -1 failure as a dead
      // server, so every sidecar profile "failed" its test
      // whenever anything was connected.
      if (e.message == 'sidecar-busy') {
        p.delayMs = -1;
        p.delayFailed = false;
        p.delayStage = 'sidecar-busy';
      } else {
        p.delayMs = -1;
        p.delayFailed = true;
        p.delayStage = 'core';
      }
      if (!bulk) await _saveStatsSidecar(); // build 2123 (B-02): volatile fields only
      return -1;
    } catch (_) {
      p.delayMs = -1;
      p.delayFailed = true;
      p.delayStage = 'core';
      if (!bulk) await _saveStatsSidecar(); // build 2123 (B-02): volatile fields only
      return -1;
    } finally {
      // Build 2075: a test that started a sidecar stops it —
      // the sidecar belongs to the test, never to the store.
      if (startedSidecar) await _stopSidecars();
      _testing.remove(p.id);
      notifyListeners();
    }
  }

  /// Asks the running Test All funnel to stop: stages finish
  /// the item in flight and take no new ones. Profiles the
  /// funnel never reached keep the CLEARED pending state the
  /// run started them from (build 2101 clear-first — before
  /// it, they kept the previous run's results, which read as
  /// fresh measurements).
  void stopTestAll() {
    _scanCancel = true;
  }

  /// Test All, as a funnel (build 2026, Stage A — MLM's
  /// measurement order): cheap TCP probes first, a TLS-SNI
  /// pre-check second, then the real proxied-request tests
  /// through throwaway cores, fed fastest-stage-1-answer first.
  /// The ranking afterwards is by the REAL test alone (the
  /// servers page sorts by delayMs, as before). Cancellable via
  /// [stopTestAll]. UDP-only protocols skip the cheap stages
  /// entirely.
  /// Build 2101 (settings-dns-2099-diagnosis.md, S3/S5): the
  /// cheap stages no longer hand down final verdicts — a
  /// stage-1 failure (domain OR IP-literal) and a stage-2
  /// failure alike DEMOTE the profile to the real test's
  /// fall-through feed instead of marking it dead untested
  /// (the pre-checks are stricter than the core itself: a
  /// native-TLS fingerprint and a 3 s budget against the
  /// core's uTLS and full timeouts, and most free configs are
  /// IP-literal, which made stage 1 the single largest source
  /// of false "no ping" results). Only the real core test
  /// fails a profile now, and it records its stage. The run
  /// also clears every tested profile's previous result to
  /// pending BEFORE measuring (the owner's spec, 2026-11-18)
  /// and saves the store once at the end, not per test.
  /// Runs the funnel over [only] when given (build 2033:
  /// the servers page passes the profiles its current
  /// search/filter actually shows, so a filtered view tests
  /// what the user sees — before, Test All always ran the
  /// whole store and overwrote results the user had filtered
  /// away). Returns true when the run was cancelled.
  /// Build 2125 (audit A25-31 / P-36): Test All's per-probe
  /// progress notify, throttled — up to 2124 every probe
  /// completion notified, so a scan over N profiles cost
  /// O(N²) row rebuilds and visibly janked. At most one
  /// notify per 200 ms during a scan; the scan's phase
  /// changes and its final notify stay immediate.
  int _scanNotifyLastMs = 0;

  void _notifyScanProgress() {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _scanNotifyLastMs < 200) return;
    _scanNotifyLastMs = now;
    notifyListeners();
  }

  Future<bool> testAllDelays({List<Profile>? only}) async {
    if (scanRunning) return _scanCancel;
    final seenIds = <String>{};
    final all = (only ?? profiles)
        .where((p) => p.protocol.connectable && seenIds.add(p.id))
        .toList();
    _scanCancel = false;
    scanRunning = true;
    scanPhase = 'tcp';
    scanTotal = all.length;
    scanDone = 0;
    scanAlive = 0;
    // Build 2101 (owner spec 2026-11-18): clear-first — every
    // profile this run will test goes back to pending before
    // anything is measured, so the list never shows a previous
    // run's numbers as if they were this run's, and a profile
    // the run never reaches reads as untested, not as its old
    // result. Persisted once here; the run's own results land
    // with the single save in the finally below.
    for (final p in all) {
      p.delayMs = -1;
      p.delayFailed = false;
      p.delayStage = '';
    }
    await _save();
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
        } else {
          // Build 2101 (D2): a stage-1 failure demotes to the
          // real test for IP-literal addresses too — it used
          // to be final, and most free configs are IP-literal.
          // The probe is one 3 s shot against 32 concurrent
          // sockets; the core test is the honest arbiter.
          fallThrough.add(p);
        }
        _notifyScanProgress();
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
          // Build 2098 (post-2097 audit M10): the TLS-SNI
          // pre-check applies only where 'tls' IS stream
          // security (VLESS/VMess/Trojan). On any other
          // protocol a stored 'tls' is meaningless metadata
          // (see the sanitizer), and running the handshake
          // here failed a check the endpoint cannot pass —
          // the profile was marked dead without a real test.
          // Those pass through to stage 3 untouched, like
          // REALITY and plain streams already did.
          if (p.security != 'tls' ||
              (p.protocol != Protocol.vless &&
                  p.protocol != Protocol.vmess &&
                  p.protocol != Protocol.trojan)) {
            tlsChecked.add(p);
          } else if (await tlsSniAnswers(p.address, p.port, funnelSniOf(p))) {
            tlsChecked.add(p);
          } else {
            // Build 2101 (D1): a stage-2 failure demotes to
            // the real test instead of ending the profile's
            // run — the pre-check speaks native TLS with a
            // 3 s budget where the core test speaks uTLS with
            // the profile's own fingerprint and full timeouts,
            // so endpoints the pre-check cannot satisfy still
            // pass the real test.
            fallThrough.add(p);
          }
          _notifyScanProgress();
        });
        survivors
          ..clear()
          ..addAll(tlsChecked);
      }

      // Stage 3 — the real tests, bounded by the Test All
      // concurrency setting (default 8 since build 2101), fed
      // in funnel order. Each test runs the bulk shape (one
      // request round, ~10 s budget, no per-test store save —
      // build 2101, S5).
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
          final ms = await testDelay(p, bulk: true);
          scanDone++;
          if (ms >= 0) scanAlive++;
          _notifyScanProgress();
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
              // Build 2110: the endurance core resolves the
              // server name like every other config (C1).
              buildTestConfig(
                p,
                settings,
                serverHostPins: await _serverNamePins(p),
              ),
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
            _notifyScanProgress();
          });
          await _save();
        }
      }
    } finally {
      // Build 2101 (S5): the run's results persist with ONE
      // store save here (plus the clear-first save at start),
      // not one save per tested profile.
      await _save();
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
    // Build 2075: a sidecar-served profile sandboxes through
    // its sidecar like the delay test (AnyTLS joined the
    // sidecar in build 2089).
    if (!p.protocol.connectable) {
      return SandboxTestResult.failed(
        'no engine in the app serves this protocol yet',
      );
    }
    _testing.add(p.id);
    notifyListeners();
    var startedSidecar = false;
    try {
      final (config, started) = await _testConfigFor(p);
      startedSidecar = started;
      final r = SandboxTestResult.fromMap(
        // Build 2109: the sandbox's delay rounds wait the
        // configured delay-test timeout (default 8 s — the
        // fixed value of every build ≤2108).
        await XrayPlatform.sandboxTest(
          config,
          timeoutMs: settings.delayTestTimeoutMs,
        ),
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
      await _saveStatsSidecar(); // build 2123 (B-02): volatile fields only
      return r;
    } catch (_) {
      p.delayMs = -1;
      p.delayFailed = true;
      await _saveStatsSidecar(); // build 2123 (B-02)
      return SandboxTestResult.failed('the sandbox test did not answer');
    } finally {
      if (startedSidecar) await _stopSidecars();
      _testing.remove(p.id);
      notifyListeners();
    }
  }

  /// The proxied service reachability check of one profile
  /// (build 2091): the same isolated-core shape as
  /// [sandboxTest] — one throwaway core asks the six
  /// [serviceCheckTargets] for a real HTTPS HEAD through the
  /// config, on a free port, without touching the live tunnel.
  /// Unlike the sandbox test this stores nothing on the
  /// profile: reachability is a property of the run, not of
  /// the config, and a stale verdict must never outlive it.
  Future<ServiceCheckResult> serviceCheck(Profile p) async {
    // Build 2075: a sidecar-served profile checks through its
    // sidecar like the delay test (AnyTLS joined the sidecar
    // in build 2089).
    if (!p.protocol.connectable) {
      return ServiceCheckResult.failed(
        'no engine in the app serves this protocol yet',
      );
    }
    _testing.add(p.id);
    notifyListeners();
    var startedSidecar = false;
    try {
      final (config, started) = await _testConfigFor(p);
      startedSidecar = started;
      return ServiceCheckResult.fromMap(
        await XrayPlatform.serviceCheck(
          config,
          serviceCheckTargets.map((t) => t.host).toList(),
        ),
      );
    } catch (_) {
      return ServiceCheckResult.failed('the service check did not answer');
    } finally {
      if (startedSidecar) await _stopSidecars();
      _testing.remove(p.id);
      notifyListeners();
    }
  }

  /// The download rate (bytes/s) through one profile's own core.
  Future<int> testSpeed(Profile p) async {
    if (!p.protocol.connectable) return -1;
    _testing.add(p.id);
    notifyListeners();
    var startedSidecar = false;
    try {
      final (config, started) = await _testConfigFor(p);
      startedSidecar = started;
      final bps = await XrayPlatform.speedTest(config);
      // Build 2095 (V2Ray journey audit, batch 8): the
      // result persists on the profile — the row shows the
      // last measured rate instead of the number living
      // only in a SnackBar.
      p.lastSpeedBps = bps;
      return bps;
    } catch (_) {
      return -1;
    } finally {
      if (startedSidecar) await _stopSidecars();
      _testing.remove(p.id);
      notifyListeners();
    }
  }

  // ---- logs ---------------------------------------------------------------

  /// The tails of the core logs, newest content last. The
  /// diagnostics journal's mirror (build 2029A) leads, so the
  /// plain-language record — checks, watchdog escalations,
  /// chain events — is the first thing on the page.
  // Build 2125 (audit A25-20 / P-31): the readLogs
  // freshness cache. The viewer polls every 2.5 s; up to
  // 2124 every poll re-read and re-decoded every log file
  // (~700 KB) even when nothing had written a byte.
  // readLogs now stats the eleven source files first and
  // returns the previously composed text when no file's
  // length or mtime moved; any change re-composes exactly
  // as before (the output for a given file state is
  // byte-identical to the uncached path).
  String? _logsCacheText;
  Map<String, String>? _logsCacheSig;

  Future<Map<String, String>> _logsSignature(Directory dir) async {
    final paths = <String>[
      '${dir.path}/diagnostics.log',
      '${dir.path}/xray.log',
      '${dir.path}/tunlink.log',
      '${dir.path}/awg.log',
      '${dir.path}/awg-stderr.log',
      '${dir.path}/awg-stderr.log.old',
      '${dir.parent.path}/crash.log',
      '${dir.parent.path}/dnstt/dnstt-stdout.log',
      '${dir.parent.path}/dnstt/dnstt-stderr.log',
      '${dir.parent.path}/olcrtc/olcrtc-stdout.log',
      '${dir.parent.path}/olcrtc/olcrtc-stderr.log',
      '${dir.parent.path}/wstunnel/wstunnel-stdout.log',
      '${dir.parent.path}/wstunnel/wstunnel-stderr.log',
    ];
    final sig = <String, String>{};
    for (final path in paths) {
      try {
        final st = await File(path).stat();
        sig[path] = st.type == FileSystemEntityType.notFound
            ? 'absent'
            : '${st.size}@${st.modified.microsecondsSinceEpoch}';
      } catch (_) {
        sig[path] = 'error';
      }
    }
    return sig;
  }

  Future<String> readLogs() async {
    final dir = await workDir();
    final sig = await _logsSignature(dir);
    final cachedText = _logsCacheText;
    final cachedSig = _logsCacheSig;
    if (cachedText != null && cachedSig != null) {
      var same = cachedSig.length == sig.length;
      if (same) {
        for (final e in sig.entries) {
          if (cachedSig[e.key] != e.value) {
            same = false;
            break;
          }
        }
      }
      if (same) return cachedText;
    }
    final text = await _readLogsUncached(dir);
    _logsCacheText = text;
    _logsCacheSig = sig;
    return text;
  }

  Future<String> _readLogsUncached(Directory dir) async {
    final out = StringBuffer();
    final diagFile = File('${dir.path}/diagnostics.log');
    out.writeln('—— diagnostics ——');
    try {
      if (await diagFile.exists()) {
        final lines = await diagFile.readAsLines();
        // Build 2123 (audit F-01, gap 3): the export tail
        // widens from 120 to 400 lines — with rotation now
        // keeping the newest 256 KB, a 120-line export
        // would still cut the evidence the file retained.
        out.writeln(
          lines.skip(lines.length > 400 ? lines.length - 400 : 0).join('\n'),
        );
      } else {
        out.writeln('(none yet)');
      }
    } catch (e) {
      out.writeln('($e)');
    }
    // Build 2099: awg.log joins this group — the AWG engine's
    // log file lives in this same workDir, beside xray.log;
    // only crash.log is special-cased below. Build 2104: the
    // writer is now WgTunnelEngine's kermit file sink (the
    // WG Tunnel backend's device log, same file name).
    // Build 2100: awg-stderr.log joins this group — the old
    // Go bridge's stderr capture file (Go runtime
    // panic/fatal output), in the same workDir group as
    // awg.log. Build 2104: nothing writes it anymore (the
    // bridge is deleted — a named loss); it stays in the
    // list so an upgraded device's last panic evidence
    // still surfaces here.
    // Build 2100 (verification iteration 1, L1): its .old
    // joins too — rotation runs at every session start, so a
    // retry after a death moves the panic stack to .old, and
    // a diagnostics paste taken after the retry must still
    // show it. (Clear leaves .old alone, like crash.log.old:
    // rotation archives are evidence, not clutter.)
    for (final name in ['xray.log', 'tunlink.log', 'awg.log', 'awg-stderr.log', 'awg-stderr.log.old', 'crash.log']) {
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
      'olcrtc/olcrtc-stdout.log',
      'olcrtc/olcrtc-stderr.log',
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
    // Build 2125 (A25-20): a Clear must not be masked by
    // the readLogs freshness cache.
    _logsCacheText = null;
    _logsCacheSig = null;
    final dir = await workDir();
    // Build 2099: awg.log is emptied with its workDir group.
    // Build 2100: awg-stderr.log (the Go bridge's stderr
    // capture file, same workDir group as awg.log) joins it.
    for (final name in ['xray.log', 'tunlink.log', 'awg.log', 'awg-stderr.log', 'diagnostics.log']) {
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
      'olcrtc/olcrtc-stdout.log',
      'olcrtc/olcrtc-stderr.log',
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
