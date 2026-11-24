import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/poll_policy.dart';
import '../atomic_json_store.dart';
import '../core/android_core.dart';
import '../xray/lantern_import.dart';
import 'lantern_platform.dart';
import 'lantern_private.dart';

/// The connect budget (build 2129): the gomobile core
/// fetches its server list in-process at init; a first fetch
/// on a filtered network can take minutes, and the list is
/// needed only once — later connects reuse the core's kept
/// list and land in seconds. The pre-2129 warm/cold ladder
/// and its WARP-leg bootstrap died with the CLI subprocess
/// contract they drove (the leg rerouted a stdin the new
/// core does not have).
const lanternConnectBudget = Duration(seconds: 240);

/// The give-up words for a connect that never landed.
String lanternGiveUpMessage() {
  return 'Lantern did not connect in four minutes. Try again a '
      'little later — the first server list is needed only once, '
      'and later connects take seconds.';
}

/// Owns the Lantern engine's state for the UI, mirroring
/// PsiphonController: fetches the platform state (the
/// :lantern process's published snapshot), polls while the
/// engine runs, derives the per-second rates, and keeps the
/// last failure verbatim so the UI can show it loudly.
class LanternController extends ChangeNotifier {
  LanternState _state = const LanternState();

  LanternState get state => _state;

  /// The captured platform error of the last failed start, when
  /// the state itself carries none.
  String? _lastError;
  String? get lastError => _state.error ?? _lastError;

  Future<void> Function()? stopOtherEngine;

  /// Set by the shell: the global tunnel MTU (build 2038, queue 2f) —
  /// the Xray settings value, read at connect time. Defaults to 1500
  /// (the unchanged behaviour) when unwired.
  int Function() tunnelMtu = () => 1500;

  /// Set by the shell: the tunnel's DNS (build 2057, audit §6
  /// engine low) — the Xray settings localDns, read at connect
  /// time. Defaults to 1.1.1.1 (the unchanged behaviour) when
  /// unwired.
  String Function() localDns = () => '1.1.1.1';

  /// Set by the shell: the Settings kill switch (build
  /// 2125, audit A25-04) — read at connect time and passed
  /// to the TUN start; with it on, an unexpectedly dead
  /// session's TUN is held as a blackhole instead of
  /// being closed to direct traffic. Defaults to false
  /// when unwired.
  bool Function() killSwitchEnabled = () => false;

  Timer? _poller;

  /// Build 2097 (post-2096 audit C4): the busy flag has an
  /// OWNER, as in the OpenVPN/Aether controllers — connect()
  /// and disconnect() claim it with a token and release it
  /// only while the token is still theirs; disconnect()
  /// STEALS the claim (the superseding operation).
  Object? _busyToken;
  bool get _busy => _busyToken != null;
  bool _startRequested = false;

  bool get connecting => _busy;

  // The last poll's counters, for the per-second rates.
  int _lastUp = 0;
  int _lastDown = 0;
  DateTime? _lastTick;
  int upRate = 0;
  int downRate = 0;

  Future<void> load() async {
    // The persisted options: the server mode + the private
    // server's key and confirmed identity, the picked server
    // tag and the smart-routing toggle (build 2129).
    try {
      final doc = await (await _optionsStore()).read();
      if (doc != null) {
        privateMode = doc['privateMode'] == true;
        privateKey = (doc['privateKey'] as String?) ?? '';
        privateName = (doc['privateName'] as String?) ?? '';
        privateCountry = (doc['privateCountry'] as String?) ?? '';
        privateCode = (doc['privateCode'] as String?) ?? '';
        selectedTag = (doc['selectedTag'] as String?) ?? '';
        // DEFAULT OFF: an absent key is off, and the core is
        // forced off at every init regardless (bridge init);
        // a stored ON is re-applied to the core by
        // setSmartRouting when the page is opened.
        smartRouting = doc['smartRouting'] == true;
      }
    } catch (_) {}
    _state = await LanternPlatform.state();
    _syncPoller();
    notifyListeners();
  }

  /// Writes the whole options document: the store replaces
  /// the document on write, so every writer carries every
  /// field.
  Future<void> _persistOptions() async {
    try {
      await (await _optionsStore()).write({
        'privateMode': privateMode,
        'privateKey': privateKey,
        'privateName': privateName,
        'privateCountry': privateCountry,
        'privateCode': privateCode,
        'selectedTag': selectedTag,
        'smartRouting': smartRouting,
      });
    } catch (_) {}
  }

  Future<AtomicJsonStore> _optionsStore() async {
    final filesDir = File(await AndroidCore.dataDir()).parent.path;
    return AtomicJsonStore(File('$filesDir/lantern_options.json'));
  }

  Future<void> refresh() async {
    final before = _state;
    _state = await LanternPlatform.state();
    _deriveRates(before);
    _syncPoller();
    notifyListeners();
  }

  /// App-foreground state for the poll cadence (build 2050).
  bool _foreground = true;

  /// The shell's lifecycle feed (build 2050): live 2 s poll
  /// only while foregrounded; a 30 s heartbeat otherwise.
  void setForeground(bool fg) {
    if (fg == _foreground) return;
    _foreground = fg;
    if (_poller != null) {
      _poller!.cancel();
      _poller = null;
      _syncPoller();
    }
  }

  void _syncPoller() {
    final want = _state.running || _state.coreRunning || _startRequested;
    if (want && _poller == null) {
      _poller = Timer.periodic(
        enginePollPeriod(foreground: _foreground),
        (_) => refresh(),
      );
    } else if (!want && _poller != null) {
      _poller!.cancel();
      _poller = null;
      upRate = 0;
      downRate = 0;
    }
  }

  void _deriveRates(LanternState before) {
    final now = DateTime.now();
    final last = _lastTick;
    if (!before.running || !_state.running || last == null) {
      _lastUp = _state.upBytes;
      _lastDown = _state.downBytes;
      _lastTick = now;
      upRate = 0;
      downRate = 0;
      return;
    }
    final dt = now.difference(last).inMilliseconds / 1000.0;
    if (dt > 0) {
      upRate = ((_state.upBytes - _lastUp) / dt).round().clamp(0, 1 << 62);
      downRate = ((_state.downBytes - _lastDown) / dt).round().clamp(
        0,
        1 << 62,
      );
    }
    _lastUp = _state.upBytes;
    _lastDown = _state.downBytes;
    _lastTick = now;
  }

  // ---- Build 2129: server selection ----

  /// The picked server's tag, persisted like LML's
  /// lanternTag: "" (the default) is Automatic —
  /// Mobile.startVPN() — and a tag pins the connect through
  /// Mobile.connectToServer(tag).
  String selectedTag = '';

  Future<void> setSelectedTag(String tag) async {
    if (tag == selectedTag) return;
    selectedTag = tag;
    notifyListeners();
    await _persistOptions();
  }

  /// Asks the core for its server list (the service
  /// initializes the core if needed and publishes the list);
  /// polls the state until the list lands or the budget ends.
  Future<void> refreshServers() async {
    final before = _state.serversJson;
    try {
      await LanternPlatform.fetchServers();
    } catch (_) {
      return;
    }
    for (var i = 0; i < 30; i++) {
      await Future<void>.delayed(const Duration(seconds: 1));
      await refresh();
      if (_state.serversJson != before && _state.servers >= 0) return;
      if (_state.error != null) return;
    }
  }

  // ---- Build 2129: smart routing (the real API) ----

  /// The user's smart-routing choice, DEFAULT OFF. Distinct
  /// from the Smart/Private server-mode buttons: this is
  /// Lantern's routing setting itself (rule-listed
  /// destinations sent direct), backed by
  /// Mobile.setSmartRoutingEnabled. The bridge forces it OFF
  /// at every core init; turning it on here applies it to the
  /// core and persists the choice.
  bool smartRouting = false;

  Future<void> setSmartRouting(bool on) async {
    smartRouting = on;
    notifyListeners();
    await _persistOptions();
    try {
      await LanternPlatform.setSmartRouting(on);
    } catch (_) {}
    await refresh();
  }

  // ---- Private server (build 2129: the API replaces H8) ----

  /// The server mode — false is Smart (Lantern's public
  /// fleet, the core's own choice; the default), true is
  /// Private: the owner's own server, registered with the
  /// core through Mobile.addServerManagerInstance before the
  /// connect, then PINNED via connectToServer(tag).
  bool privateMode = false;

  /// The private server's invite link (the access key),
  /// stored verbatim; the app parses it at registration.
  String privateKey = '';

  /// The private entry's identity: its tag (the invite's
  /// name/alias, else its IP) and its geolocated country.
  String privateName = '';
  String privateCountry = '';
  String privateCode = '';

  /// The VIP entry's headline (owner's naming, build
  /// 2127): "VIP · `country`" once the country is known,
  /// plain "VIP" before the first registration lands it.
  String get vipLabel =>
      privateCountry.isNotEmpty ? 'VIP · $privateCountry' : 'VIP';

  Future<void> setPrivateMode(bool value) async {
    privateMode = value;
    notifyListeners();
    await _persistOptions();
  }

  /// The tag the stored private key registers under
  /// ("" when the key does not parse) — the picker's
  /// private row carries this same tag in the core's list.
  String get privateTag {
    final link = parseLanternPrivateServerLink(privateKey);
    return link == null ? '' : lanternPrivateTag(link);
  }

  /// Build 2132: the rows the Servers picker shows — the
  /// core's list with the owner's private server GUARANTEED
  /// present. The core list only carries the private entry
  /// when getAvailableServers surfaces the stored
  /// registration, which the owner's device did not do
  /// reliably; the app knows the key and its tag, so when
  /// the list lacks the tag the row is synthesized from the
  /// saved key's identity (its geolocated country/code ride
  /// along). No key — or an unparseable one — and the core
  /// list stands as-is.
  List<LanternServer> get pickerServers {
    final servers = _state.serverList;
    if (privateKey.trim().isEmpty) return servers;
    final tag = privateTag;
    if (tag.isEmpty) return servers;
    if (servers.any((s) => s.tag == tag)) return servers;
    return [
      ...servers,
      LanternServer(
        tag: tag,
        country: privateCountry,
        countryCode: privateCode,
        isLantern: false,
      ),
    ];
  }

  /// Build 2131: the registration connect() performs,
  /// exposed for a live switch — the Servers page registers
  /// the private server with the core before switching a
  /// running session to it. False (with [lastError] set)
  /// means the caller must NOT switch.
  Future<bool> registerPrivateForSwitch() => _registerPrivateServer();

  /// Build 2131: switches a RUNNING session to [tag]
  /// ("" = Automatic) inside the live tunnel — no TUN
  /// rebuild; the core re-selects via SelectServer. The
  /// poller and the refresh below surface the new exit.
  Future<void> liveSwitch(String tag) async {
    try {
      await LanternPlatform.switchServer(tag);
    } catch (_) {}
    await refresh();
  }

  /// Stores a newly pasted key. A different key is a
  /// different server: the previous entry's identity is
  /// cleared (it re-lands at the next registration) and its
  /// registration is removed from the core best-effort
  /// (Mobile.deletePrivateServerByName).
  Future<void> setPrivateKey(String value) async {
    final key = value.trim();
    if (key == privateKey) return;
    final old = parseLanternPrivateServerLink(privateKey);
    privateKey = key;
    privateName = '';
    privateCountry = '';
    privateCode = '';
    notifyListeners();
    await _persistOptions();
    if (old != null) {
      try {
        await LanternPlatform.removePrivateServer(lanternPrivateTag(old));
      } catch (_) {}
    }
  }

  /// Registers the private server with the core through the
  /// API and waits for the service's verdict in the state.
  /// Returns false with [_lastError] set in plain words when
  /// the registration fails; the caller then does NOT start
  /// the core — a failed registration never falls back to
  /// public servers silently.
  Future<bool> _registerPrivateServer() async {
    final link = parseLanternPrivateServerLink(privateKey);
    if (link == null) {
      _lastError =
          'That key is not a Lantern private-server link — paste '
          'the whole lantern:// key from your server.';
      return false;
    }
    final tag = lanternPrivateTag(link);
    final before = _state.privateResult;
    try {
      await LanternPlatform.addPrivateServer(
        ip: link.ip,
        port: link.port,
        token: link.token,
        tag: tag,
      );
    } catch (e) {
      _lastError = 'Adding your private server failed: $e';
      return false;
    }
    // The service publishes the outcome ("ok|<tag>" or
    // "error|<words>"); registration success is also
    // fire-and-forget in the official client, so a verdict
    // that never changes within the budget reads as
    // registered — the pinned connect that follows is the
    // real proof, and its failure surfaces there.
    final started = DateTime.now();
    final deadline = started.add(const Duration(seconds: 30));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await refresh();
      final result = _state.privateResult;
      if (result.startsWith('error|')) {
        _lastError = result.substring('error|'.length);
        return false;
      }
      // A fresh ok ends the wait; an ok that predates this
      // attempt is accepted after a grace period (the new
      // registration's identical verdict would be
      // indistinguishable from it, and either way the server
      // stands registered under this tag).
      if (result.startsWith('ok|') &&
          (result != before ||
              DateTime.now().difference(started) >
                  const Duration(seconds: 6))) {
        break;
      }
    }
    if (_state.privateResult.startsWith('error|')) {
      _lastError = _state.privateResult.substring('error|'.length);
      return false;
    }
    privateName = tag;
    final location = await geolocateLanternServer(link.ip);
    privateCountry = location?.country ?? '';
    privateCode = location?.code ?? '';
    await _persistOptions();
    return true;
  }

  // ---- Connect / disconnect ----

  int _startGen = 0;

  Future<void> connect() async {
    if (_busy) return; // Build 2095 (audit 2.2).
    // Build 2095 (audit 2.1): disconnect() bumps the
    // generation; _startAndAwait's wait loop honours it.
    final gen = ++_startGen;
    final busyToken = Object();
    _busyToken = busyToken;
    _lastError = null;
    _startRequested = true;
    notifyListeners();
    try {
      // Private mode without a key has nothing to connect
      // through — fail in plain words before any engine
      // arbitration moves.
      if (privateMode && privateKey.trim().isEmpty) {
        _lastError =
            'Private mode needs your server key first — paste the '
            'lantern:// key from your server on the Lantern page.';
        return;
      }
      await stopOtherEngine?.call();
      // Build 2096 (post-2095 audit H5): a disconnect that
      // landed during the arbitration await must not be
      // followed by starting the core at all.
      if (gen != _startGen) return;
      // Private mode registers the owner's server with the
      // core BEFORE the start, then pins the connect to its
      // tag. A failed registration ends the connect here,
      // loudly: no core start, no silent fall-back to the
      // public fleet.
      var tag = selectedTag;
      if (privateMode) {
        if (!await _registerPrivateServer()) return;
        if (gen != _startGen) return;
        tag = lanternPrivateTag(parseLanternPrivateServerLink(privateKey)!);
      }
      await _startAndAwait(tag: tag, gen: gen);
    } finally {
      if (identical(_busyToken, busyToken)) {
        _busyToken = null;
        _startRequested = false;
      }
      await refresh();
    }
  }

  Future<void> _startAndAwait({required String tag, int gen = 0}) async {
    // Build 2096 (post-2095 audit H5): the start is
    // gen-gated, and a superseded wait stops its own core on
    // the way out (a disconnect during connect must not
    // resurrect the core).
    if (gen != _startGen) return;
    await LanternPlatform.setOn(
      on: true,
      mtu: tunnelMtu(),
      dns: localDns(),
      // Build 2125 (A25-04): the kill switch.
      killSwitch: killSwitchEnabled(),
      tag: tag,
    );
    final started = DateTime.now();
    while (true) {
      await Future<void>.delayed(const Duration(milliseconds: 600));
      if (gen != _startGen) {
        await LanternPlatform.stop();
        return;
      }
      await refresh();
      // Honesty rule: "connected" is the core's own verdict
      // in the published state, nothing local.
      if (_state.connected) return;
      if (_state.error != null && !_state.running) {
        throw StateError(_state.error!);
      }
      if (DateTime.now().difference(started) >= lanternConnectBudget) {
        throw StateError(lanternGiveUpMessage());
      }
    }
  }

  Future<void> disconnect() async {
    // Build 2095 (audit 2.1): break any in-flight start.
    _startGen++;
    // Build 2097 (post-2096 audit C4): steal the busy claim.
    final busyToken = Object();
    _busyToken = busyToken;
    // Build 2098 (post-2097 audit L1): the superseding
    // operation owns _startRequested now.
    _startRequested = false;
    notifyListeners();
    try {
      await LanternPlatform.stop();
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 400));
        await refresh();
        if (!_state.running && !_state.coreRunning) return;
      }
    } finally {
      if (identical(_busyToken, busyToken)) _busyToken = null;
      await refresh();
    }
  }

  // ---- Logs (diagnostics) ----

  /// The engine's on-disk logs: the gomobile core's logDir
  /// files (filesDir/lantern/logs — the bridge's Opts logDir,
  /// reachable by the diagnostics export) plus crash.log.
  Future<String> readLogs() async {
    final filesDir = File(await AndroidCore.dataDir()).parent.path;
    final out = StringBuffer();
    final logDir = Directory('$filesDir/lantern/logs');
    var found = false;
    try {
      if (await logDir.exists()) {
        final files = await logDir.list().toList();
        files.sort((a, b) => a.path.compareTo(b.path));
        for (final entity in files) {
          if (entity is! File) continue;
          found = true;
          out.writeln('══ ${entity.path.split('/').last} ══');
          final lines = await entity.readAsLines();
          out.writeln(
            lines.skip(lines.length > 300 ? lines.length - 300 : 0).join('\n'),
          );
          out.writeln();
        }
      }
    } catch (_) {}
    if (!found) {
      out.writeln('══ core logs ══');
      out.writeln('(none yet)');
      out.writeln();
    }
    // Build 2070 (review §3.4): the crash.log section — the
    // recorder's file lives in filesDir itself, and this
    // service's start net writes to it; decoded leniently
    // because a stack trace must never break the viewer.
    final crash = File('$filesDir/crash.log');
    out.writeln('══ crash.log ══');
    try {
      if (await crash.exists()) {
        final text = utf8.decode(
          await crash.readAsBytes(),
          allowMalformed: true,
        );
        final lines = text.split('\n');
        out.writeln(
          lines.skip(lines.length > 300 ? lines.length - 300 : 0).join('\n'),
        );
      } else {
        out.writeln('(none yet)');
      }
    } catch (e) {
      out.writeln('($e)');
    }
    out.writeln();
    return out.toString();
  }

  Future<void> clearLogs() async {
    final filesDir = File(await AndroidCore.dataDir()).parent.path;
    final logDir = Directory('$filesDir/lantern/logs');
    try {
      if (await logDir.exists()) {
        await for (final entity in logDir.list()) {
          if (entity is File) await entity.delete();
        }
      }
    } catch (_) {}
    // Build 2070 (review §3.4): Clear means all of it — the
    // shared crash.log is truncated, not deleted (the
    // recorder appends to it from every engine).
    try {
      await File('$filesDir/crash.log').writeAsString('');
    } catch (_) {
      // Not there yet.
    }
  }

  @override
  void dispose() {
    _poller?.cancel();
    super.dispose();
  }
}
