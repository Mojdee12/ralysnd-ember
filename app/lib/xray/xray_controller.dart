/// The V2Ray engine's brain: the user's profiles and subscriptions,
/// their persistence, and the tunnel's on/off state — everything the
/// Ember UI binds to.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../core/android_core.dart';
import '../psiphon/psiphon_platform.dart';
import 'config_builder.dart';
import 'diagnostics.dart';
import 'exit_info.dart';
import 'fallback_groups.dart';
import 'lantern_import.dart';
import 'link_parser.dart';
import 'profile_codec.dart';
import 'scan_probes.dart';
import 'shape_cache.dart';
import 'shapes.dart';
import 'sub_fetcher.dart';
import 'warp_args.dart';
import 'warp_platform.dart';
import 'wg_conf.dart';
import 'xray_models.dart';
import 'xray_platform.dart';

class XrayController extends ChangeNotifier {
  List<Profile> profiles = [];
  List<Subscription> subscriptions = [];
  XraySettings settings = XraySettings();

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

  /// The session name a standalone WARP tunnel reports under.
  static const warpSessionName = 'WARP';
  String selectedProfileId = '';

  XrayState state = XrayState.stopped;
  bool connecting = false;
  int upRate = 0;
  int downRate = 0;
  String? lastError;

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
  int _adaptiveFails = 0;
  int _adaptiveSwitches = 0;
  int _pollTicks = 0;
  bool _adaptiveBusy = false;

  /// Fallback groups (build 2035): when each profile last failed
  /// a fallback attempt. A member that failed is skipped for
  /// [fallbackCooldown] so the group does not flap straight back
  /// onto the config that just died. In-memory only: a process
  /// restart clears the cooldowns, and a member that recovered
  /// meanwhile rejoins the group on its own.
  final Map<String, DateTime> _fallbackFailedAt = {};

  /// True while [profileId]'s last fallback failure is still
  /// inside the cooldown window.
  bool isCoolingDown(String profileId) {
    final at = _fallbackFailedAt[profileId];
    if (at == null) return false;
    if (DateTime.now().difference(at) >= fallbackCooldown) {
      _fallbackFailedAt.remove(profileId);
      return false;
    }
    return true;
  }

  /// The ids currently inside their cooldown window (expired
  /// entries are dropped as a side effect).
  Set<String> get _coolingDownIds {
    final now = DateTime.now();
    _fallbackFailedAt.removeWhere(
      (id, at) => now.difference(at) >= fallbackCooldown,
    );
    return _fallbackFailedAt.keys.toSet();
  }

  /// Records a fallback failure for [profileId] (the clock
  /// starts now) and notifies listeners so the servers page's
  /// fallback card shows the cooldown at once.
  void markFallbackFailed(String profileId) {
    _fallbackFailedAt[profileId] = DateTime.now();
    notifyListeners();
  }

  /// The members of [p]'s fallback group, in failover order
  /// (see fallback_groups.dart).
  List<Profile> fallbackGroupMembers(Profile p) =>
      fallbackGroupMembersOf(profiles, p);

  /// Ordered failover candidates for [p]: its group first, then
  /// the rest of the list. Used by the failover watcher and by
  /// the connect-time fallback in [connect].
  List<Profile> fallbackCandidates(Profile p) => fallbackOrder(
    all: profiles,
    current: p,
    coolingDownIds: _coolingDownIds,
  );

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
        final doc = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
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
    } catch (_) {
      // A damaged store starts empty rather than crashing the tab.
    }
    _loaded = true;
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

  /// The routing presets name geoip:/geosite: categories, so the core
  /// needs its data files beside the config it runs from.
  Future<void> _installGeoFiles() async {
    try {
      final dir = await workDir();
      await dir.create(recursive: true);
      for (final name in ['geoip.dat', 'geosite.dat']) {
        final target = File('${dir.path}/$name');
        if (await target.exists() && await target.length() > 1000000) continue;
        final data = await rootBundle.load('assets/geo/$name');
        await target.writeAsBytes(data.buffer.asUint8List(), flush: true);
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
    } catch (_) {
      // Persistence failure must not take the UI down.
    }
  }

  Future<void> save() => _save();

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

  /// Adds a subscription by URL and fetches it.
  Future<Subscription> addSubscription(String url, {String name = ''}) async {
    final sub = Subscription(
      id: 's${DateTime.now().millisecondsSinceEpoch}',
      name: name,
      url: url,
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
    final result = await fetchSubscription(sub.url);
    // Traffic totals survive the refresh: profiles are recreated with
    // fresh ids, so carry the totals over by profile identity —
    // subscription + the share link without its display name.
    String identityOf(Profile p) => profileToLink(p).split('#').first;
    final prevSelected = selected;
    final carried = <String, Profile>{
      for (final old in profiles.where((p) => p.subscriptionId == sub.id))
        identityOf(old): old,
    };
    profiles.removeWhere((p) => p.subscriptionId == sub.id);
    final usedIds = <String>{};
    for (final p in result.profiles) {
      p.subscriptionId = sub.id;
      final old = carried[identityOf(p)];
      if (old != null) {
        p.totalDownBytes = old.totalDownBytes;
        p.totalUpBytes = old.totalUpBytes;
        p.statsUpdatedMs = old.statsUpdatedMs;
        // Build 2033 (WireGuard audit): keep the OLD id and
        // the last test results for a profile that is still
        // the same server. Before this, every refresh minted
        // fresh ids — a launch-time auto-update could make
        // stored profiles (WireGuard ones included) vanish
        // from under the selection, which then silently
        // jumped elsewhere.
        if (usedIds.add(old.id)) {
          p.id = old.id;
          p.delayMs = old.delayMs;
          p.delayFailed = old.delayFailed;
          p.exitIp = old.exitIp;
          p.exitCountryCode = old.exitCountryCode;
        }
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
      selectedProfileId = (sameProtocol.isNotEmpty
              ? sameProtocol.first
              : profiles.first)
          .id;
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

  Future<void> duplicateProfile(Profile p) async {
    final copy = p.copy()
      ..id = newProfileId()
      ..name = '${p.name} (2)'
      ..subscriptionId = ''
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
    profiles.sort((a, b) => a.name.compareTo(b.name));
    unawaited(_save());
    notifyListeners();
  }

  // ---- backup / restore -------------------------------------------------

  Future<String> exportBackup() async {
    final file = await _stateFile();
    if (await file.exists()) return file.readAsString();
    return jsonEncode({
      'profiles': profiles.map((p) => p.toJson()).toList(),
      'subscriptions': subscriptions.map((s) => s.toJson()).toList(),
      'settings': settings.toJson(),
      'selectedProfileId': selectedProfileId,
    });
  }

  /// Restores a backup document; returns false when it is not one.
  Future<bool> importBackup(String text) async {
    try {
      final doc = jsonDecode(text) as Map<String, dynamic>;
      if (doc['profiles'] is! List) return false;
      if (state.running) await disconnect();
      profiles = ((doc['profiles'] as List?) ?? [])
          .map((e) => Profile.fromJson((e as Map).cast<String, dynamic>()))
          .toList();
      subscriptions = ((doc['subscriptions'] as List?) ?? [])
          .map((e) => Subscription.fromJson((e as Map).cast<String, dynamic>()))
          .toList();
      if (doc['settings'] is Map) {
        settings = XraySettings.fromJson(
          (doc['settings'] as Map).cast<String, dynamic>(),
        );
      }
      selectedProfileId = doc['selectedProfileId'] as String? ?? '';
      if (!profiles.any((p) => p.id == selectedProfileId)) {
        selectedProfileId = profiles.isEmpty ? '' : profiles.first.id;
      }
      await _save();
      notifyListeners();
      return true;
    } catch (_) {
      return false;
    }
  }

  // ---- tunnel -----------------------------------------------------------

  Future<void> refreshState() async {
    state = await XrayPlatform.state();
    // A standalone WARP session reports under its own name
    // (build 2030): the card's state follows the service, not
    // a local flag, so an app restart mid-session reads true.
    warpSession = state.running && state.name == warpSessionName;
    if (state.running) {
      if (_connectedProfileId.isEmpty) {
        _connectedProfileId = selectedProfileId;
      }
      _startPolling();
      _fetchExitInfo();
    } else {
      _connectedProfileId = '';
      exitInfo = null;
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
      final delta = await XrayPlatform.trafficStats(statsApiPort(settings));
      if (delta == null) return;
      final up = delta['up'] ?? 0;
      final down = delta['down'] ?? 0;
      if (up <= 0 && down <= 0) return;
      final id = _connectedProfileId.isNotEmpty
          ? _connectedProfileId
          : selectedProfileId;
      for (final p in profiles) {
        if (p.id != id) continue;
        p.totalUpBytes += up;
        p.totalDownBytes += down;
        p.statsUpdatedMs = DateTime.now().millisecondsSinceEpoch;
        await _save();
        notifyListeners();
        break;
      }
    } finally {
      _statsBusy = false;
    }
  }

  /// Fires the exit-IP lookup (once at a time, never awaited by the
  /// connection path): fills [exitInfo] when the tunnel answers and
  /// silently leaves it null when it does not.
  void _fetchExitInfo() {
    if (_exitFetching || exitInfo != null || !state.running) return;
    _exitFetching = true;
    () async {
      try {
        // A standalone WARP session's proxy is the warp core's
        // port, not the Xray SOCKS port (build 2030).
        final m = await XrayPlatform.exitInfo(
          warpSession ? warpSessionPort : settings.socksPort,
        );
        if (m != null && state.running) {
          exitInfo = ExitInfo.fromMap(m);
          notifyListeners();
        }
      } finally {
        _exitFetching = false;
      }
    }();
  }

  void _startPolling() {
    _poll ??= Timer.periodic(const Duration(seconds: 2), (_) async {
      final sample = await XrayPlatform.state();
      final now = DateTime.now();
      final last = _lastSample;
      final lastAt = _lastSampleAt;
      if (last != null && lastAt != null && sample.running) {
        final dt = now.difference(lastAt).inMilliseconds / 1000.0;
        if (dt > 0) {
          upRate = ((sample.upBytes - last.upBytes) / dt).round().clamp(0, 1 << 62);
          downRate =
              ((sample.downBytes - last.downBytes) / dt).round().clamp(0, 1 << 62);
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
        unawaited(_pollStats());
        unawaited(_watchdogTick(sample));
      }
      if (!sample.running) {
        _poll?.cancel();
        _poll = null;
        upRate = 0;
        downRate = 0;
        _lastSample = null;
        _lastSampleAt = null;
        _connectedProfileId = '';
        exitInfo = null;
      }
      unawaited(_adaptiveTick());
      notifyListeners();
    });
  }

  /// The adaptive failover watcher (build 2026, Stage A),
  /// driven from the 2 s state poll: every ~16 s of tunnel-up
  /// time it asks the tunnel for one real proxied request.
  /// Three consecutive silences mean the tunnel is dead in
  /// practice (the 2025 watchdog covers a wedged CORE; this
  /// covers a live core whose exit path died). It then switches
  /// — through the normal connect path — to the next member of
  /// the dead profile's fallback group (build 2035: same
  /// subscription first, tested by delay then untested, a
  /// member that just failed cooling down for 10 minutes), and
  /// says so in [adaptiveNotice]. At most 3 switches per manual
  /// session, then it gives up loudly instead of flapping
  /// forever. With the setting OFF this returns immediately:
  /// nothing watches, nothing switches, 2025 behaviour exactly.
  Future<void> _adaptiveTick({bool force = false}) async {
    if (!settings.adaptiveFailover ||
        !state.running ||
        connecting ||
        _adaptiveBusy) {
      return;
    }
    if (!force && ++_pollTicks % 8 != 0) return;
    _adaptiveBusy = true;
    try {
      final ms = await XrayPlatform.tunnelCheck(settings.socksPort);
      if (ms >= 0) {
        _adaptiveFails = 0;
        return;
      }
      if (!state.running) return; // Stopped by hand meanwhile.
      _adaptiveFails++;
      if (_adaptiveFails < 3) return;
      _adaptiveFails = 0;
      if (_adaptiveSwitches >= 3) {
        if (!adaptiveNotice.contains('gave up')) {
          adaptiveNotice =
              'Adaptive failover gave up after 3 switches — the '
              'tunnel is still not answering.';
          notifyListeners();
        }
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
        adaptiveNotice =
            'Fallback group: the tunnel stopped answering and '
            'no other member in its group — or anywhere else — '
            'is available to switch to.';
        notifyListeners();
        return;
      }
      final best = candidates.first;
      _adaptiveSwitches++;
      selectedProfileId = best.id;
      try {
        await _connectSelected();
        adaptiveNotice =
            'Fallback group: switched to ${best.name} '
            '(${best.subscriptionId == current.subscriptionId ? 'same group' : 'another group'}).';
      } catch (_) {
        markFallbackFailed(best.id);
        adaptiveNotice =
            'Fallback group: switching to ${best.name} failed.';
      }
      notifyListeners();
    } finally {
      _adaptiveBusy = false;
    }
  }

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
    if (_wdBusy || connecting || scanRunning) return;
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
      final ms = await XrayPlatform.tunnelCheck(settings.socksPort);
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
    final first = await XrayPlatform.tunnelCheck(settings.socksPort);
    await Future<void>.delayed(const Duration(milliseconds: 2500));
    final second = await XrayPlatform.tunnelCheck(settings.socksPort);
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
        exit: (port) => XrayPlatform.exitInfo(port),
      );
      final List<CheckStage> stages;
      if (state.running) {
        diagnostics.add('check', 'Checking the running tunnel…');
        stages = await checker.checkLive(socksPort: settings.socksPort);
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

  /// Sets the chain underlay ('none' | 'psiphon' | 'warp').
  /// Applies to the NEXT V2Ray session: a running session
  /// keeps the shape it started with.
  Future<void> setUnderlay(String value) async {
    settings.underlay = switch (value) {
      'psiphon' => 'psiphon',
      'warp' => 'warp',
      _ => 'none',
    };
    diagnostics.add(
      'chain',
      switch (settings.underlay) {
        'psiphon' =>
          'Underlay set to Psiphon: the next V2Ray session '
              'will run over a Psiphon tunnel.',
        'warp' =>
          'Underlay set to Warp: the next V2Ray session '
              'will run over the EmberWarp core.',
        _ =>
          'Underlay off: the next V2Ray session connects '
              'directly.',
      },
    );
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
        warpArgs: args,
      );
      for (var i = 0; i < 40; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        state = await XrayPlatform.state();
        if (state.running) break;
      }
      if (!state.running) throw StateError('start-failed');
      warpSession = true;
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
    } else if (before.running) {
      await PsiphonPlatform.stop();
    }
    await PsiphonPlatform.setOn(
      vpnMode: false,
      region: params.region,
      upstream: params.upstream,
      protocols: params.protocols,
      dns: settings.localDns,
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

  /// Connects a WireGuard profile with peer fallback (build
  /// 2032, the ENG1 behaviour on Ember's carrier): the chosen
  /// peer is tried first; when its tunnel carries nothing —
  /// judged by a real request through the live tunnel, never
  /// by the TUN merely being up — the next peer of the same
  /// imported config (same interface keys) is tried, in order.
  /// Throws StateError('wg-all-peers-failed') when no peer of
  /// the group carries traffic.
  Future<void> connectWireGuardWithFallback(Profile first) async {
    final group = profiles
        .where(
          (p) =>
              p.protocol == Protocol.wireguard &&
              wgGroupKey(p) == wgGroupKey(first),
        )
        .toList();
    final ordered = [
      first,
      ...group.where((p) => p.id != first.id),
    ];
    Object? lastFailure;
    for (final candidate in ordered) {
      selectedProfileId = candidate.id;
      notifyListeners();
      try {
        await connect();
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
        final ms = await XrayPlatform.tunnelCheck(settings.socksPort);
        carries = ms >= 0;
      }
      if (carries) {
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

  /// Connects the selected profile (a manual connect: the
  /// adaptive failover's session counters start over). Throws a
  /// short message on failure. With fallback groups on (build
  /// 2035), a failed connect walks the selected profile's
  /// fallback group — up to 3 further members, each failure
  /// starting that member's cooldown — and only throws when
  /// every tried member failed.
  Future<void> connect() async {
    _adaptiveFails = 0;
    _adaptiveSwitches = 0;
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
      final dialProfile = win == null
          ? p
          : profileWithShape(p, win.shapeId);
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
      final config = buildTunnelConfig(
        dialProfile,
        settings,
        psiphonUnderlay: chained,
        warpUnderlay: warpChained,
        warp: warpProfile,
      );
      await XrayPlatform.setOn(
        config: config,
        name: p.name,
        socksPort: settings.socksPort,
        dns: settings.localDns,
        ipv6: settings.ipv6Route,
        underlay: chained
            ? 'psiphon'
            : warpChained
            ? 'warp'
            : 'none',
        underlayRegion: chainParams?.region ?? '',
        underlayUpstream: chainParams?.upstream ?? '',
        underlayProtocols: chainParams?.protocols ?? const [],
        warpArgs: warpArgs,
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
    _adaptiveFails = 0;
    _adaptiveSwitches = 0;
    adaptiveNotice = '';
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
    exitInfo = null;
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
      final r = await XrayPlatform.measureDelayEx(
        buildTestConfig(p, settings),
      );
      final ms = (r['ms'] as num?)?.toInt() ?? -1;
      p.delayMs = ms;
      p.delayFailed = ms < 0;
      if (ms >= 0) {
        final ip = (r['ip'] as String?) ?? '';
        final cc = (r['countryCode'] as String?) ?? '';
        if (ip.isNotEmpty) p.exitIp = ip;
        if (cc.isNotEmpty) p.exitCountryCode = cc;
      }
      // Windows desktop (FROZEN 2.0.7 rule): a single landed
      // result re-sorts the list fastest-first, except inside a
      // test-all run (the run sorts once at its end).
      if (Platform.isWindows && !scanRunning) {
        profiles = sortedByDelay(profiles);
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
          } else if (await tlsSniAnswers(
            p.address,
            p.port,
            funnelSniOf(p),
          )) {
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
      // Windows desktop (FROZEN 2.0.7 rule): a finished test-all
      // run re-sorts the list fastest-first and persists it.
      if (Platform.isWindows) {
        profiles = sortedByDelay(profiles);
        unawaited(_save());
      }
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
    for (final name in ['xray.log', 'tunlink.log']) {
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
    for (final name in ['xray.log', 'tunlink.log']) {
      try {
        await File('${dir.path}/$name').writeAsString('');
      } catch (_) {
        // Not there yet.
      }
    }
  }
}
