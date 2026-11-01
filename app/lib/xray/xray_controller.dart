/// The V2Ray engine's brain: the user's profiles and subscriptions,
/// their persistence, and the tunnel's on/off state — everything the
/// Ember UI binds to.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'config_builder.dart';
import 'exit_info.dart';
import 'link_parser.dart';
import 'profile_codec.dart';
import 'sub_fetcher.dart';
import 'xray_models.dart';
import 'xray_platform.dart';

class XrayController extends ChangeNotifier {
  List<Profile> profiles = [];
  List<Subscription> subscriptions = [];
  XraySettings settings = XraySettings();
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

  Future<File> _stateFile() async =>
      File('${(await workDir()).path}/state.json');

  /// The engine's folder, from the platform backend: on Android the
  /// folder beside the core's data dir it has always been; on Windows
  /// the app data folder's xray folder.
  Future<Directory> workDir() => XrayPlatform.workDir();

  Future<void> load() async {
    try {
      final file = await _stateFile();
      if (await file.exists()) {
        final doc = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
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
      }
    } catch (_) {
      // A damaged store starts empty rather than crashing the tab.
    }
    _loaded = true;
    await _installGeoFiles();
    await refreshState();
    notifyListeners();
    if (settings.subUpdateOnLaunch) unawaited(_autoUpdateStale());
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

  Future<void> _save() async {
    try {
      final file = await _stateFile();
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode({
        'profiles': profiles.map((p) => p.toJson()).toList(),
        'subscriptions': subscriptions.map((s) => s.toJson()).toList(),
        'settings': settings.toJson(),
        'selectedProfileId': selectedProfileId,
      }));
    } catch (_) {
      // Persistence failure must not take the UI down.
    }
  }

  Future<void> save() => _save();

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
    final carried = <String, Profile>{
      for (final old in profiles.where((p) => p.subscriptionId == sub.id))
        identityOf(old): old,
    };
    profiles.removeWhere((p) => p.subscriptionId == sub.id);
    for (final p in result.profiles) {
      p.subscriptionId = sub.id;
      final old = carried[identityOf(p)];
      if (old != null) {
        p.totalDownBytes = old.totalDownBytes;
        p.totalUpBytes = old.totalUpBytes;
        p.statsUpdatedMs = old.statsUpdatedMs;
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
      selectedProfileId = profiles.first.id;
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
        final m = await XrayPlatform.exitInfo(settings.socksPort);
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
      if (sample.running) {
        // A tunnel that came up outside connect() (e.g. the service
        // outlived the page) still gets its exit line.
        _fetchExitInfo();
        unawaited(_pollStats());
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
      notifyListeners();
    });
  }

  /// Connects the selected profile. Throws a short message on failure.
  Future<void> connect() async {
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
      if (state.running) await disconnect();
      final config = buildTunnelConfig(p, settings);
      await XrayPlatform.setOn(
        config: config,
        name: p.name,
        socksPort: settings.socksPort,
        dns: settings.localDns,
        ipv6: settings.ipv6Route,
        tunCapture: settings.tunCapture,
      );
      // The service reports itself once the tunnel is really up.
      for (var i = 0; i < 40; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        state = await XrayPlatform.state();
        if (state.running) break;
      }
      if (!state.running) throw StateError('start-failed');
      _connectedProfileId = p.id;
      _lastSample = state;
      _lastSampleAt = DateTime.now();
      _startPolling();
      _fetchExitInfo();
    } catch (e) {
      lastError = e.toString();
      rethrow;
    } finally {
      connecting = false;
      notifyListeners();
    }
  }

  Future<void> disconnect() async {
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

  /// Adopts the backend's recorded failure (the Windows backend
  /// keeps one) after a failed test, so the page can say why instead
  /// of only "Failed".
  Future<void> _adoptBackendError() async {
    try {
      final sample = await XrayPlatform.state();
      if (sample.lastError.isNotEmpty) lastError = sample.lastError;
    } catch (_) {
      // The recorded log lines still carry the reason.
    }
  }

  /// The real delay of one profile, run through a throwaway core.
  Future<int> testDelay(Profile p) async {
    if (!p.protocol.supportedByCore) return -1;
    _testing.add(p.id);
    notifyListeners();
    try {
      final ms = await XrayPlatform.measureDelay(buildTestConfig(p, settings));
      p.delayMs = ms;
      p.delayFailed = ms < 0;
      if (ms < 0) await _adoptBackendError();
      await _save();
      return ms;
    } catch (_) {
      p.delayMs = -1;
      p.delayFailed = true;
      await _adoptBackendError();
      await _save();
      return -1;
    } finally {
      _testing.remove(p.id);
      notifyListeners();
    }
  }

  /// Delays for every profile, a few at a time.
  Future<void> testAllDelays() async {
    final queue = List.of(profiles);
    Future<void> worker() async {
      while (queue.isNotEmpty) {
        final p = queue.removeAt(0);
        await testDelay(p);
      }
    }

    await Future.wait([worker(), worker(), worker(), worker()]);
    notifyListeners();
  }

  /// The download rate (bytes/s) through one profile's own core.
  Future<int> testSpeed(Profile p) async {
    if (!p.protocol.supportedByCore) return -1;
    _testing.add(p.id);
    notifyListeners();
    try {
      final rate = await XrayPlatform.speedTest(buildTestConfig(p, settings));
      if (rate < 0) await _adoptBackendError();
      return rate;
    } catch (_) {
      await _adoptBackendError();
      return -1;
    } finally {
      _testing.remove(p.id);
      notifyListeners();
    }
  }

  // ---- logs ---------------------------------------------------------------

  /// The tails of the core logs, newest content last.
  Future<String> readLogs() async {
    final dir = await workDir();
    final out = StringBuffer();
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
