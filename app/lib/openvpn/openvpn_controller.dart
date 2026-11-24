import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

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

  /// Set by the shell: the Settings kill switch (build
  /// 2125, audit A25-04) — read at connect time and passed
  /// to the TUN start; with it on, an unexpectedly ended
  /// connected session's TUN is held as a blackhole
  /// instead of being released to direct traffic.
  /// Defaults to false when unwired.
  bool Function() killSwitchEnabled = () => false;

  Timer? _poller;

  /// Build 2097 (post-2096 audit C4): the busy flag has an
  /// OWNER. connect() and disconnect() each claim it with a
  /// token and release it only while the token is still
  /// theirs — a superseded connect settling mid-disconnect
  /// used to clear the flag unconditionally in its finally,
  /// so `connecting` read false during the disconnect's
  /// wait, shell stop guards could skip a needed stop, and
  /// a fresh connect() could pass its entry guard and setOn
  /// during the disconnect. disconnect() STEALS the claim:
  /// it is the superseding operation.
  Object? _busyToken;
  bool get _busy => _busyToken != null;

  /// The profile an in-flight connect is starting (build
  /// 2097, post-2096 audit C-L9): the delete guard judges by
  /// the attempt's target, not by a selection that can drift
  /// while the attempt runs.
  String _connectingId = '';

  /// Build 2098 (post-2097 audit L3): the generation of the
  /// connect attempt that registered [_connectingId]. The
  /// two finallys clear the id only while the registration
  /// is still theirs — value equality on the id alone let a
  /// finished attempt's outer finally clear a same-profile
  /// RECONNECT's registration (registered during the inner
  /// finally's refresh await), stripping its delete guard.
  int _connectingGen = 0;

  /// Build 2095 (third-pass audit 2.1): the connect
  /// generation — disconnect() bumps it; an in-flight
  /// connect re-checks it after its pre-start awaits.
  int _connectGen = 0;
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
      if (store.lastReadProblem == 'damaged') {
        storeError = storeDamagedMessage;
      }
      // Build 2097 (post-2096 audit C-L7): an UNREADABLE
      // store (intact file, filesystem error) is not
      // damage — build 2096 set the damaged message and
      // let the first save overwrite the intact original
      // with the empty state. The file is protected now:
      // defaults in memory, saves refused (see
      // _storeProtected).
      if (store.lastReadProblem == 'unreadable') {
        _storeProtected = true;
        storeError = storeUnreadableMessage;
      }
      if (doc == null) return;
      // Build 2095 (third-pass audit 1.4): never overwrite
      // a newer build's store.
      if (storeSchemaVersion(doc) > 1) {
        // Build 2096 (post-2095 audit M15/L34): the
        // defensive version read (a string "1" used to
        // throw here), and the unified >1 behaviour —
        // decode and use in-session like the Xray/Psiphon
        // stores, never save (the flag above blocks every
        // write). Build 2095 refused to decode here while
        // the other stores decoded; the inconsistency was
        // the defect.
        _storeFromNewerVersion = true;
        storeError =
            'Your saved data was written by a newer build '
            'of Ember — this build will not overwrite it.';
      }
      // Build 2098 (post-2097 audit L10): a non-empty
      // document carrying NEITHER of this store's keys is
      // foreign (a synced or misplaced file) — the pre-2098
      // load read it as an empty store with no surface and
      // no protection, and the next save overwrote it.
      if (doc.isNotEmpty &&
          !doc.containsKey('profiles') &&
          !doc.containsKey('selectedId')) {
        _storeProtected = true;
        storeError = storeDamagedMessage;
        return;
      }
      selectedId = doc['selectedId'] is String
          ? doc['selectedId'] as String
          : '';
      // Build 2097 (post-2096 audit C-L12): a valid-JSON
      // document whose 'profiles' is not a list (a foreign
      // or synced document) used to throw on this cast into
      // the silent catch below — the store reset in memory
      // with NO error surface and NO protection, and the
      // next save overwrote the foreign file. It is
      // damage-shaped now: surfaced, and the file is
      // protected from overwrite.
      final rawProfiles = doc['profiles'];
      if (rawProfiles != null && rawProfiles is! List) {
        _storeProtected = true;
        storeError = storeDamagedMessage;
        return;
      }
      final list = (rawProfiles as List?) ?? const [];
      // Build 2098 (post-2097 audit L10): a NON-EMPTY list
      // whose entries are ALL non-Maps is not a torn profile
      // or two (the per-entry skip below owns those) — it is
      // a foreign document wearing a list. Damage-shaped:
      // surfaced, and the file is protected from overwrite.
      if (list.isNotEmpty && !list.any((e) => e is Map)) {
        _storeProtected = true;
        storeError = storeDamagedMessage;
        return;
      }
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

  /// Build 2095 (audit 1.4): the on-disk store belongs to
  /// a newer build; saves are refused.
  bool _storeFromNewerVersion = false;

  /// Build 2097 (post-2096 audit C-L7/C-L12): the on-disk
  /// document is not safely ours to overwrite — it was
  /// unreadable at load (intact) or valid JSON of the
  /// wrong shape (foreign). Saves are refused while it
  /// exists; if the file disappears, saves resume.
  bool _storeProtected = false;

  /// Build 2116 (AB-05): replaces the user profiles with a
  /// restored backup's set and persists them. Credentials
  /// are NOT part of a backup — they stay in the device
  /// vault — so restored profiles that need a username or
  /// password ask for it again on first connect.
  Future<void> restoreProfiles(List<OvpnProfile> profiles) async {
    // Build 2125 (audit A25-45): a restore that arrived
    // before the first load persisted nothing — _saveStore
    // early-returns while !_loaded, so the restored set
    // lived only in memory and vanished on the next
    // launch, silently. Load first so the restore lands
    // like any other.
    if (!_loaded) await load();
    userProfiles = profiles;
    if (selectedId.isNotEmpty &&
        !userProfiles.any((p) => p.id == selectedId)) {
      selectedId = '';
    }
    notifyListeners();
    await _saveStore();
  }

  Future<void> _saveStore() async {
    // Saving the selection must never be able to take the app
    // down (2026 fix contract: a country tap is a pure state
    // change; a store failure is retried on the next change,
    // never fatal here). Build 2054 (audit F-H8): never persist
    // before load, and write atomically through the shared store.
    if (!_loaded) return;
    if (_storeFromNewerVersion) return;
    // Build 2097 (post-2096 audit C-L7/C-L12): never
    // overwrite a protected document (unreadable or
    // wrong-shaped at load) while it exists.
    if (_storeProtected) {
      final f = (await _atomicStore()).file;
      if (await f.exists()) return;
      _storeProtected = false;
    }
    try {
      final store = await _atomicStore();
      await store.write({
        'schemaVersion': 1,
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
        // Build 2098 (post-2097 audit L7): an import landing
        // DURING a connect attempt must not re-point the
        // selection under it — the profile still imports
        // (or is found), the selection just stays put until
        // no attempt owns it.
        if (!_busy) selectedId = existing.id;
        await _saveStore();
        notifyListeners();
        return existing;
      }
    }
    final id = ovpnContentId(normalized);
    final p = OvpnProfile.parse(id: id, name: label, text: body, credKey: id);
    // Build 2097 (IMP-2): a channel-level failure of the
    // validate call itself (no handler, a native error)
    // used to escape importProfile as a raw
    // PlatformException past the page's StateError catch —
    // an uncaught async error and no message at all. It is
    // a core rejection for the user's purposes and now
    // surfaces as one.
    final String verdict;
    try {
      verdict = await OpenVpnPlatform.validate(p.config);
    } on PlatformException {
      throw StateError('core-rejected:validator-unavailable');
    } on MissingPluginException {
      throw StateError('core-rejected:validator-unavailable');
    }
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
    // Build 2098 (L7): same rule as the existing-profile
    // path above — no selection re-point mid-connect.
    if (!_busy) selectedId = id;
    await _saveStore();
    notifyListeners();
    return p;
  }

  Future<void> deleteProfile(String id) async {
    // Build 2095 (whole-app journey audit #8): disconnect
    // first when the live tunnel is this profile — the
    // store used to delete the running profile (and its
    // vault entry) from under the session, the exact hole
    // deleteSubscription had in the V2Ray store.
    // Build 2096 (post-2095 audit L20): the connecting
    // window counts too — while _busy, the profile being
    // connected is the attempt's captured target (build
    // 2097, post-2096 audit C-L9: the selection itself can
    // drift mid-connect when the user taps another profile,
    // and a guard keyed on it deleted the connecting
    // profile from under its own connect).
    if ((_state.running && _state.profileId == id) ||
        (_busy && _connectingId == id)) {
      await disconnect();
    }
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

  /// Build 2095 (whole-app journey audit #34): renames a
  /// profile — the display name only. The id (and with it
  /// the vault credKey) never changes, so saved credentials
  /// and the selection survive; the parse is recomputed
  /// from the stored config text, exactly as on load.
  Future<void> renameProfile(String id, String newName) async {
    final name = newName.trim();
    if (name.isEmpty) return;
    userProfiles = [
      for (final p in userProfiles)
        if (p.id == id)
          OvpnProfile.parse(id: p.id, name: name, text: p.config, credKey: p.credKey)
        else
          p,
    ];
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
    // Build 2095 (third-pass audit 2.2): _busy was only set
    // after the validation awaits — a second connect in
    // that window interleaved with the first.
    if (_busy) return;
    // Build 2096 (post-2095 audit L35): the claim happens
    // HERE, before the credential/validation awaits — in
    // 2095 the set still sat below them despite the
    // comment above, so two connects in the validation
    // window both passed the guard and the second
    // silently superseded the first. The outer finally
    // releases the claim on every exit, throws included.
    // Build 2097 (post-2096 audit C4): the claim is a token
    // this attempt owns; the finallys release it only while
    // it is still theirs.
    final busyToken = Object();
    _busyToken = busyToken;
    final gen = ++_connectGen;
    var targetId = '';
    var startIssued = false;
    try {
    final p = selected;
    if (p == null) throw StateError('no-profile');
    targetId = p.id;
    _connectingId = p.id;
    _connectingGen = gen;
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
    // Build 2095 (whole-app journey audit #15): a config
    // that points at external files (ca/cert/key/tls-auth
    // file paths) can never connect on a phone — the files
    // are not inside it and the import cannot carry them.
    // It used to sail through to the core and fail
    // obscurely mid-handshake; now it stops here, before
    // the tunnel starts, with the reason in plain words.
    final externalRefs = p.unsupported
        .where((u) => u.contains(' file ('))
        .toList();
    if (externalRefs.isNotEmpty) {
      throw StateError(
        'This config points at external files (${externalRefs.join(', ')}) '
        'that are not inside it. Re-export it with the certificates '
        'and keys inlined (<ca>, <cert>, <key> blocks) and import '
        'that file.',
      );
    }
    final verdict = await OpenVpnPlatform.validate(p.config);
    if (verdict.isNotEmpty) throw StateError('core-rejected:$verdict');
    // Build 2095 (audit 2.1): a disconnect during the
    // credential/validation window cancels the connect.
    if (gen != _connectGen) return;
    _lastError = null;
    _startRequested = true;
    notifyListeners();
    try {
      await stopOtherEngine?.call();
      if (gen != _connectGen) return;
      startIssued = true;
      await OpenVpnPlatform.setOn(
        profileId: p.id,
        name: p.name,
        config: p.config,
        credKey: p.credKey,
        user: user,
        pass: pass,
        needsCreds: needsCreds,
        // Build 2125 (A25-04): the kill switch.
        killSwitch: killSwitchEnabled(),
      );
      var deadline = DateTime.now().add(const Duration(seconds: 90));
      DateTime? verifyingSince;
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 600));
        // Build 2096 (post-2095 audit L19): a disconnect
        // during the poll ends the wait quietly — the
        // loop used to spin to a spurious connect-timeout
        // surface after the user had already stopped it.
        // Build 2097 (post-2096 audit C3): quietly is not
        // enough — this attempt issued its start, and the
        // disconnect's single stop may have landed before
        // setOn executed, leaving the service to come up
        // after the disconnect completed. Stop our own
        // start before unwinding. (A gen mismatch here can
        // only be a disconnect's: a fresh connect cannot
        // enter while this attempt owns the busy claim.)
        if (gen != _connectGen) {
          if (startIssued) await OpenVpnPlatform.stop();
          return;
        }
        await refresh();
        if (_state.connected) return;
        // Build 2099 (verification-loop V8): while the native
        // side is in its verifying phase, this poll's 90 s
        // budget must not expire — the native connect deadline
        // no longer covers verifying (V1), and its probe
        // window (~76 s worst case) starts at CONNECTED, which
        // can land near the end of this budget; expiring here
        // surfaced a spurious connect-timeout for a session
        // that was about to verify. The extension is bounded:
        // verifying gets its own 120 s from first sight, after
        // which the timeout stands (the native verify loop
        // always ends in verified or NO_DATA well before it).
        if (_state.phase == 'verifying') {
          verifyingSince ??= DateTime.now();
          final verifyDeadline = verifyingSince.add(
            const Duration(seconds: 120),
          );
          if (verifyDeadline.isAfter(deadline)) deadline = verifyDeadline;
        }
        if (_state.phase == 'error') {
          throw StateError(_state.error ?? 'connect-failed');
        }
        if (!_state.running && _state.error != null) {
          throw StateError(_state.error!);
        }
      }
      throw StateError(_state.error ?? 'connect-timeout');
    } finally {
      // Build 2097 (post-2096 audit C4): release only what
      // this attempt still owns — a disconnect that
      // superseded it holds the claim now and releases it
      // itself; clearing unconditionally here used to drop
      // the flag mid-disconnect.
      if (identical(_busyToken, busyToken)) {
        _busyToken = null;
        _startRequested = false;
      }
      // Build 2098 (L3): clear only our own registration.
      if (_connectingId == targetId && _connectingGen == gen) {
        _connectingId = '';
      }
      await refresh();
    }
    } finally {
      // Build 2096 (audit L35): release the entry claim
      // (the inner finally already cleared it on the
      // start path; this covers the pre-start exits).
      // Build 2097 (C4): only while it is still ours.
      if (identical(_busyToken, busyToken)) _busyToken = null;
      // Build 2098 (L3): clear only our own registration —
      // a same-profile reconnect may have registered during
      // the inner finally's refresh await.
      if (_connectingId == targetId && _connectingGen == gen) {
        _connectingId = '';
      }
    }
  }

  Future<void> disconnect() async {
    // Build 2095 (audit 2.1): cancel any in-flight connect.
    _connectGen++;
    // Build 2097 (post-2096 audit C4): disconnect STEALS
    // the busy claim — it is the superseding operation, and
    // the in-flight connect's finally must not clear a claim
    // it no longer owns.
    final busyToken = Object();
    _busyToken = busyToken;
    // Build 2098 (post-2097 audit L1): the superseding
    // operation owns _startRequested now. The connect's
    // finally clears it only while it still owns the busy
    // token — the token this disconnect just stole — so
    // without this line the flag leaked true forever and
    // _syncPoller kept the state poller running for the
    // rest of the session.
    _startRequested = false;
    notifyListeners();
    try {
      await OpenVpnPlatform.stop();
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      var polls = 0;
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 400));
        await refresh();
        if (!_state.running) return;
        // Build 2097 (post-2096 audit C3): re-issue the
        // stop while the service still reports running — a
        // single stop landing before an in-flight setOn
        // executes used to leave the tunnel up after this
        // disconnect completed, with nobody left to stop it.
        if (++polls % 5 == 0) await OpenVpnPlatform.stop();
      }
    } finally {
      if (identical(_busyToken, busyToken)) _busyToken = null;
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
