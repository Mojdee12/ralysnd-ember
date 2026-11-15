import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../atomic_json_store.dart';
import '../core/poll_policy.dart';
import '../core/android_core.dart';
import 'openvpn_models.dart';
import 'openvpn_platform.dart';

/// Owns the OpenVPN engine's state for the UI (build 2025),
/// mirroring LanternController: the platform state poll, the
/// user's own imported profiles (filesDir/openvpn/state.json),
/// per-profile latency results, and the connect flow with its
/// credential rules. Build 2028: the bundled TunnelBear pack
/// is gone (owner's ruling — a generic client only); saved
/// credentials are per-profile, keyed by the profile id.
class OpenVpnController extends ChangeNotifier {
  OpenVpnState _state = const OpenVpnState();

  OpenVpnState get state => _state;

  String? _lastError;

  /// The store's complaint, when it has one (build 2071,
  /// review §5.4): set when a save fails or the saved file
  /// was damaged at load, cleared by the next successful
  /// save. [lastError] reports it after the engine's own
  /// errors, so a failing disk is visible instead of every
  /// change being lost silently, forever.
  String? storeError;

  String? get lastError => _state.error ?? _lastError ?? storeError;

  Future<void> Function()? stopOtherEngine;

  Timer? _poller;
  bool _busy = false;
  bool _startRequested = false;

  bool get connecting => _busy;

  // The last poll's counters, for the per-second rates.
  int _lastUp = 0;
  int _lastDown = 0;
  DateTime? _lastTick;
  int upRate = 0;
  int downRate = 0;

  // ── Profiles ────────────────────────────────────────────────

  /// The user's imported profiles — the only profiles there
  /// are (build 2028).
  List<OvpnProfile> userProfiles = const [];

  /// The selected profile id, persisted.
  String selectedId = '';

  OvpnProfile? get selected {
    for (final p in userProfiles) {
      if (p.id == selectedId) return p;
    }
    return userProfiles.firstOrNull;
  }

  /// The latest latency result per profile id.
  final Map<String, OvpnPing> pings = {};
  bool pinging = false;

  Future<File> _storeFile() async {
    final filesDir = File(await AndroidCore.dataDir()).parent.path;
    return File('$filesDir/openvpn/state.json');
  }

  Future<void> load() async {
    await _loadStore();
    await _migrateInlineCredentials();
    _state = await OpenVpnPlatform.state();
    _syncPoller();
    notifyListeners();
  }

  /// Build 2029A migration for carried-over profiles whose
  /// text still holds an `<auth-user-pass>` block: the core
  /// never reads credentials from the text (it takes them
  /// only through its API), so a profile stored by an older
  /// build would reach the server with none and die with
  /// NEED_CREDS. Lift the pair into the encrypted vault and
  /// store the profile with the block stripped. A profile
  /// whose pair cannot be saved stays as-is — connect()
  /// still extracts the pair in memory as a fallback.
  Future<void> _migrateInlineCredentials() async {
    var changed = false;
    final migrated = <OvpnProfile>[];
    for (final p in userProfiles) {
      final pair = p.hasInlineCredentials
          ? inlineCredentialsOf(p.config)
          : null;
      if (pair == null || p.credKey.isEmpty) {
        migrated.add(p);
        continue;
      }
      try {
        final saved = await OpenVpnPlatform.saveCredentials(
          p.credKey,
          pair.user,
          pair.pass,
        );
        if (!saved) {
          migrated.add(p);
          continue;
        }
      } catch (_) {
        migrated.add(p);
        continue;
      }
      migrated.add(
        OvpnProfile.parse(
          id: p.id,
          name: p.name,
          text: stripInlineCredentials(p.config),
          credKey: p.credKey,
        ),
      );
      changed = true;
    }
    if (changed) {
      userProfiles = migrated;
      await _saveStore();
    }
  }

  /// The shared atomic store for this file (build 2054, audit
  /// F-H8), cached so every write for this file goes through
  /// one serialization chain.
  AtomicJsonStore? _store;

  Future<AtomicJsonStore> _atomicStore() async {
    return _store ??= AtomicJsonStore(await _storeFile());
  }

  /// True once the store has loaded (build 2054, audit F-H8):
  /// a save before load would persist the empty in-memory
  /// lists over the user's profiles. Set even when the file
  /// is torn or missing — defaults loaded is still loaded.
  bool _loaded = false;

  Future<void> _loadStore() async {
    try {
      final store = await _atomicStore();
      final doc = await store.read();
      // Build 2071 (review §5.4): a damaged store still
      // starts empty — but it says so on the error surface
      // instead of silently pretending nothing was saved.
      if (store.lastReadProblem != null) {
        storeError = storeDamagedMessage;
      }
      if (doc == null) return;
      selectedId = doc['selectedId'] is String
          ? doc['selectedId'] as String
          : '';
      final list = (doc['profiles'] as List?) ?? const [];
      // Per-entry decode (build 2054, audit F-H8): one
      // torn/bad entry is skipped on its own. The old
      // all-or-nothing load discarded EVERY profile on any
      // bad entry, and the next save overwrote the file with
      // the empty state.
      final kept = <OvpnProfile>[];
      for (final e in list) {
        if (e is! Map) continue;
        try {
          kept.add(
            OvpnProfile.fromJson(e.cast<dynamic, dynamic>()),
          );
        } catch (_) {
          // One damaged entry is dropped, never the store.
        }
      }
      userProfiles = kept;
    } catch (_) {
      // A corrupt store must not take the engine down with it.
    } finally {
      _loaded = true;
    }
  }

  Future<void> _saveStore() async {
    // Saving the selection must never be able to take the app
    // down (2026 fix contract: a country tap is a pure state
    // change; a store failure is retried on the next change,
    // never fatal here). Build 2054 (audit F-H8): never persist
    // before load, and write atomically through the shared store.
    if (!_loaded) return;
    try {
      final store = await _atomicStore();
      await store.write({
        'selectedId': selectedId,
        'profiles': [for (final p in userProfiles) p.toJson()],
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
      // Deliberately swallowed — see above.
    }
  }

  void select(String id) {
    selectedId = id;
    notifyListeners();
    unawaited(_saveStore());
  }

  /// Imports one profile from picked/pasted text. Returns the
  /// profile, or throws a short message for the UI.
  ///
  /// Build 2029A: import is IDEMPOTENT BY CONTENT. The id is
  /// derived from the normalized config text, so importing
  /// content that is already in the list — including the same
  /// content still stored under a legacy timestamp id from an
  /// older build — selects the existing profile instead of
  /// adding a twin whose fresh id would orphan the saved
  /// credentials (they are keyed by profile id) and leave the
  /// next connect to die with NEED_CREDS. An embedded
  /// `<auth-user-pass>` pair is lifted into the vault and the
  /// block stripped from the stored text (the core takes
  /// credentials only through its API).
  Future<OvpnProfile> importProfile(String name, String text) async {
    final clean = text.trim();
    if (clean.isEmpty || !clean.contains('client')) {
      throw StateError('not-an-ovpn-profile');
    }
    var label = name.replaceAll(RegExp(r'\.ovpn$', caseSensitive: false), '');
    if (label.isEmpty) label = 'Imported profile';
    final pair = inlineCredentialsOf(clean);
    final body = pair == null ? clean : stripInlineCredentials(clean);
    final normalized = normalizeConfig(body);
    for (final existing in userProfiles) {
      if (existing.config == normalized) {
        selectedId = existing.id;
        await _saveStore();
        notifyListeners();
        return existing;
      }
    }
    final id = ovpnContentId(normalized);
    final p = OvpnProfile.parse(id: id, name: label, text: body, credKey: id);
    final verdict = await OpenVpnPlatform.validate(p.config);
    if (verdict.isNotEmpty) throw StateError('core-rejected:$verdict');
    if (pair != null) {
      // Best-effort: a vault failure must not block the import;
      // the connect flow then asks for the pair instead.
      try {
        await OpenVpnPlatform.saveCredentials(id, pair.user, pair.pass);
      } catch (_) {
        // The profile imports; its credentials were not saved.
      }
    }
    userProfiles = [...userProfiles, p];
    selectedId = id;
    await _saveStore();
    notifyListeners();
    return p;
  }

  Future<void> deleteProfile(String id) async {
    userProfiles = [
      for (final p in userProfiles)
        if (p.id != id) p,
    ];
    if (selectedId == id) {
      selectedId = userProfiles.firstOrNull?.id ?? '';
    }
    await OpenVpnPlatform.deleteCredentials(id);
    await _saveStore();
    notifyListeners();
  }

  // ── Latency ─────────────────────────────────────────────────

  /// Measures one profile's first remote. What is measured is
  /// the endpoint's responsiveness BEFORE any tunnel exists:
  /// a TCP handshake round trip, or one OpenVPN UDP reset
  /// exchange. Profiles whose control channel is authenticated
  /// (tls-auth/tls-crypt) cannot be measured this way and
  /// report that honestly.
  Future<OvpnPing> pingProfile(OvpnProfile p) async {
    final remote = p.firstRemote;
    final result = remote == null
        ? const OvpnPing(ms: -1, method: 'NO_ADDRESS')
        : await OpenVpnPlatform.ping(
            host: remote.host,
            port: remote.port,
            proto: (remote.proto ?? p.proto),
            authenticatedControl: p.authenticatedControl,
          );
    pings[p.id] = result;
    notifyListeners();
    return result;
  }

  Future<void> pingAll() async {
    if (pinging) return;
    pinging = true;
    notifyListeners();
    try {
      for (final p in userProfiles) {
        await pingProfile(p);
      }
    } finally {
      pinging = false;
      notifyListeners();
    }
  }

  // ── Session ─────────────────────────────────────────────────

  Future<void> refresh() async {
    final before = _state;
    _state = await OpenVpnPlatform.state();
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
    final want = _state.running || _startRequested;
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

  void _deriveRates(OpenVpnState before) {
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

  /// Whether the selected profile can connect without asking:
  /// no auth needed, inline credentials, or a vault entry.
  Future<bool> hasUsableCredentials(OvpnProfile p) async {
    if (!p.needsAuth || p.hasInlineCredentials) return true;
    if (p.credKey.isEmpty) return false;
    return OpenVpnPlatform.hasCredentials(p.credKey);
  }

  /// Connects the selected profile. When it needs credentials
  /// and none are usable, throws StateError('credentials-required')
  /// and the UI asks (with an optional save) and calls again
  /// with [user]/[pass] as one-shot credentials. When a saved
  /// entry exists but cannot be read on this device, throws
  /// StateError('credentials-unreadable') instead (build 2027):
  /// the UI routes back to the same prompt so he can enter
  /// and re-save them — an unreadable entry must never
  /// degrade into an empty-credential connect (the service
  /// now also refuses that shape natively, as defence in
  /// depth).
  Future<void> connect({String user = '', String pass = ''}) async {
    final p = selected;
    if (p == null) throw StateError('no-profile');
    if (!_state.available) throw StateError('core-unavailable');
    // Build 2029A: a carried-over profile whose text still
    // holds its credentials inline (the load-time vault
    // migration could not run, e.g. the keystore refused):
    // hand the pair to the core through the API path, which
    // is the only path it reads. Without this the session
    // started with an empty pair and died with NEED_CREDS.
    if (user.isEmpty && p.hasInlineCredentials) {
      final pair = inlineCredentialsOf(p.config);
      if (pair != null) {
        user = pair.user;
        pass = pair.pass;
      }
    }
    final needsCreds = p.needsAuth && !p.hasInlineCredentials;
    if (needsCreds && user.isEmpty) {
      final status = p.credKey.isEmpty
          ? 'none'
          : await OpenVpnPlatform.credentialStatus(p.credKey);
      if (status == 'unreadable') {
        throw StateError('credentials-unreadable');
      }
      if (status != 'ok' && pass.isEmpty) {
        throw StateError('credentials-required');
      }
    }
    final verdict = await OpenVpnPlatform.validate(p.config);
    if (verdict.isNotEmpty) throw StateError('core-rejected:$verdict');
    _busy = true;
    _lastError = null;
    _startRequested = true;
    notifyListeners();
    try {
      await stopOtherEngine?.call();
      await OpenVpnPlatform.setOn(
        profileId: p.id,
        name: p.name,
        config: p.config,
        credKey: p.credKey,
        user: user,
        pass: pass,
        needsCreds: needsCreds,
      );
      final deadline = DateTime.now().add(const Duration(seconds: 90));
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 600));
        await refresh();
        if (_state.connected) return;
        if (_state.phase == 'error') {
          throw StateError(_state.error ?? 'connect-failed');
        }
        if (!_state.running && _state.error != null) {
          throw StateError(_state.error!);
        }
      }
      throw StateError(_state.error ?? 'connect-timeout');
    } finally {
      _busy = false;
      _startRequested = false;
      await refresh();
    }
  }

  Future<void> disconnect() async {
    _busy = true;
    notifyListeners();
    try {
      await OpenVpnPlatform.stop();
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 400));
        await refresh();
        if (!_state.running) return;
      }
    } finally {
      _busy = false;
      await refresh();
    }
  }

  /// The engine's on-disk log (the service writes it), readable
  /// even after a failed start — the loud-failure path.
  Future<String> readLogs() async {
    final filesDir = File(await AndroidCore.dataDir()).parent.path;
    final f = File('$filesDir/openvpn/openvpn.log');
    if (!await f.exists()) return '(none yet)';
    final lines = await f.readAsLines();
    return lines.skip(lines.length > 300 ? lines.length - 300 : 0).join('\n');
  }

  /// The breadcrumb trail (build 2028): every connect leaves
  /// its stage markers in openvpn/breadcrumbs.log — written by
  /// the Dart connect flow, the Kotlin service and the native
  /// bridge (setBreadcrumbFile points there). Before this
  /// build NO in-app surface read this file: the log page
  /// showed only openvpn.log, which a session dying in the
  /// native preamble barely writes to — the owner's "my log
  /// is empty" while the diagnostics card (which reads the
  /// trail natively) still named the death stage. The log
  /// page now shows the trail next to the engine log.
  Future<String> readTrail() async {
    final filesDir = File(await AndroidCore.dataDir()).parent.path;
    final f = File('$filesDir/openvpn/breadcrumbs.log');
    if (!await f.exists()) return '(none yet)';
    final lines = await f.readAsLines();
    return lines.skip(lines.length > 300 ? lines.length - 300 : 0).join('\n');
  }

  /// Both log surfaces the log page renders, read together.
  Future<({String trail, String logs})> readLogBundle() async =>
      (trail: await readTrail(), logs: await readLogs());

  Future<void> clearLogs() async {
    final filesDir = File(await AndroidCore.dataDir()).parent.path;
    for (final name in ['openvpn.log', 'breadcrumbs.log']) {
      final f = File('$filesDir/openvpn/$name');
      if (await f.exists()) await f.delete();
    }
  }

  @override
  void dispose() {
    _poller?.cancel();
    super.dispose();
  }
}

extension<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
