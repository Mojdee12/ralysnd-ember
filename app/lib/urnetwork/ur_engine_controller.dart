import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../atomic_json_store.dart';
import '../core/android_core.dart';
import '../core/poll_policy.dart';
import 'ur_platform.dart';
import 'urnetwork_client.dart';

/// The connect budget (build 2156): the SDK device builds
/// its provider grid in-process; on a filtered network the
/// first connect can take a while. The Lantern engine's
/// budget is the precedent.
const urConnectBudget = Duration(seconds: 240);

/// The give-up words for a connect that never landed.
String urGiveUpMessage() {
  return 'URnetwork did not connect in four minutes. Try again a '
      'little later.';
}

/// Owns the URnetwork engine's state for the UI (build
/// 2156), mirroring LanternController: fetches the platform
/// state (the :urnetwork process's published snapshot),
/// polls while the engine runs, derives the per-second
/// rates, and keeps the last failure verbatim.
///
/// Auth has no login UI: the engine reuses the build-2154
/// accounts. A connect resolves the account's device
/// session — the cached client JWT from the SecretStore
/// vault while it is fresh (see [urClientJwtCacheFresh]),
/// a new auth-client exchange when it is not — and hands
/// the JWT to the service as a start argument. Keys and
/// JWTs never touch the settings JSON, the state file or
/// a journal line.
class UrEngineController extends ChangeNotifier {
  UrState _state = const UrState();

  UrState get state => _state;

  String? _lastError;
  String? get lastError => _state.error ?? _lastError;

  Future<void> Function()? stopOtherEngine;

  /// Set by the shell: the global tunnel MTU (the Xray
  /// settings value), read at connect time. Defaults to
  /// 1500 (the unchanged behaviour) when unwired.
  int Function() tunnelMtu = () => 1500;

  /// Set by the shell: the Settings kill switch — read at
  /// connect time; with it on, an unexpectedly dead
  /// session's TUN is held as a blackhole and the SDK
  /// device is told traffic must not fall back to local
  /// routes. Defaults to false when unwired.
  bool Function() killSwitchEnabled = () => false;

  /// Set by the shell: the build-2154 URnetwork accounts
  /// (labels + ids only — the keys stay in the vault).
  List<UrAccount> Function() accountsProvider = () => const [];

  /// The client seam (tests): builds the API client for
  /// one account key. Production is the real client.
  UrNetworkClient Function(String apiKey) clientFactory =
      (key) => UrNetworkClient(apiKey: key);

  /// The vault seams (tests): the SecretStore statics in
  /// production.
  Future<bool> Function(String key, String value) secretStore =
      SecretStore.store;
  Future<String?> Function(String key) secretLoad = SecretStore.load;
  Future<void> Function(String key) secretDelete = SecretStore.delete;

  Timer? _poller;

  /// The busy flag has an OWNER, as in the Lantern
  /// controller — connect() and disconnect() claim it with
  /// a token and release it only while the token is still
  /// theirs; disconnect() STEALS the claim.
  Object? _busyToken;
  bool get _busy => _busyToken != null;
  bool _startRequested = false;

  bool get connecting => _busy;

  int _lastUp = 0;
  int _lastDown = 0;
  DateTime? _lastTick;
  int upRate = 0;
  int downRate = 0;

  // ---- Persisted options (the Lantern precedent: an
  // options document beside the data dir, NOT the settings
  // JSON — nothing here is a credential) ----

  /// The account the engine connects with; '' = the first
  /// account. Only meaningful when more than one account
  /// exists (the picker shows only then).
  String accountId = '';

  /// The picked country's provider-locations id; '' =
  /// Best Available (the owner's one-tap default).
  String locationId = '';

  /// The picked country's display name + ISO code, kept
  /// with the id so the picker can render the choice
  /// before the catalogue is fetched.
  String locationName = '';
  String locationCode = '';

  /// The account a connect will use: the picked one when
  /// it still exists, else the first account, else null.
  UrAccount? get activeAccount {
    final accounts = accountsProvider();
    if (accounts.isEmpty) return null;
    for (final account in accounts) {
      if (account.id == accountId) return account;
    }
    return accounts.first;
  }

  Future<void> load() async {
    try {
      final doc = await (await _optionsStore()).read();
      if (doc != null) {
        accountId = (doc['accountId'] as String?) ?? '';
        locationId = (doc['locationId'] as String?) ?? '';
        locationName = (doc['locationName'] as String?) ?? '';
        locationCode = (doc['locationCode'] as String?) ?? '';
      }
    } catch (_) {}
    _state = await UrPlatform.state();
    _syncPoller();
    notifyListeners();
  }

  Future<void> _persistOptions() async {
    try {
      await (await _optionsStore()).write({
        'accountId': accountId,
        'locationId': locationId,
        'locationName': locationName,
        'locationCode': locationCode,
      });
    } catch (_) {}
  }

  Future<AtomicJsonStore> _optionsStore() async {
    final filesDir = File(await AndroidCore.dataDir()).parent.path;
    return AtomicJsonStore(File('$filesDir/urnetwork_engine_options.json'));
  }

  Future<void> setAccount(String id) async {
    if (id == accountId) return;
    accountId = id;
    notifyListeners();
    await _persistOptions();
  }

  /// Picks the connect location: a catalogue row, or null
  /// for Best Available. Persisted; a live session is NOT
  /// switched — the pick applies to the next connect (the
  /// page says so).
  Future<void> setLocation(UrCountry? country) async {
    locationId = country?.locationId ?? '';
    locationName = country?.name ?? '';
    locationCode = country?.countryCode ?? '';
    notifyListeners();
    await _persistOptions();
  }

  // ---- The country catalogue ----

  List<UrCountry> countries = const [];
  bool countriesLoading = false;
  String? countriesError;

  /// Fetches the provider-locations catalogue through the
  /// active account (the same catalogue the 2154 source
  /// uses for its create sheet). A failure keeps the last
  /// good list and words itself plainly.
  Future<void> refreshCountries() async {
    final account = activeAccount;
    if (account == null || countriesLoading) return;
    countriesLoading = true;
    countriesError = null;
    notifyListeners();
    try {
      final client = await _clientFor(account);
      countries = await client.fetchCountries();
    } on UrNetworkException catch (e) {
      countriesError = e.message;
    } catch (_) {
      countriesError = 'The location list could not be loaded.';
    } finally {
      countriesLoading = false;
      notifyListeners();
    }
  }

  // ---- Session resolution (auth) ----

  Future<UrNetworkClient> _clientFor(UrAccount account) async {
    final key = await secretLoad(urNetworkVaultKey(account.id));
    if (key == null || key.isEmpty) {
      throw const UrNetworkException(
        UrErrorKind.keyRefused,
        'This account has no saved key — remove the account and add it again.',
      );
    }
    return clientFactory(key);
  }

  /// Resolves the account's device session for a connect:
  /// the vault-cached client JWT while it is fresh, else
  /// one auth-client exchange (which mints a NEW client —
  /// the superseded cached client is then removed from
  /// the account, best-effort, so exchanges do not pile
  /// clients up). The fresh session replaces the cache in
  /// the vault before it is used; a vault refusal fails
  /// the connect rather than starting on an uncached
  /// session that would re-exchange at every connect.
  Future<UrClientSession> resolveSession(
    UrAccount account, {
    int? nowMs,
  }) async {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final cached = decodeUrClientJwtCache(
      await secretLoad(urClientJwtVaultKey(account.id)),
    );
    if (urClientJwtCacheFresh(cached, now)) return cached!;
    final client = await _clientFor(account);
    final session = await client.exchangeClientSession();
    final stored = await secretStore(
      urClientJwtVaultKey(account.id),
      encodeUrClientJwtCache(session),
    );
    if (!stored) {
      throw StateError(
        'The device session could not be saved to the vault.',
      );
    }
    final superseded = cached?.clientId ?? '';
    if (superseded.isNotEmpty && superseded != session.clientId) {
      try {
        await client.removeProxy(superseded);
      } catch (_) {
        // Best-effort housekeeping only: a stale client on
        // the account never blocks a connect.
      }
    }
    return session;
  }

  /// Drops the account's cached session (a connect that
  /// ended in a platform error may have been rejected
  /// server-side; the next tap then re-exchanges instead
  /// of retrying a dead token).
  Future<void> _dropCachedSession(String forAccountId) async {
    try {
      await secretDelete(urClientJwtVaultKey(forAccountId));
    } catch (_) {}
  }

  // ---- Polling ----

  Future<void> refresh() async {
    final before = _state;
    _state = await UrPlatform.state();
    _deriveRates(before);
    _syncPoller();
    notifyListeners();
  }

  bool _foreground = true;

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

  void _deriveRates(UrState before) {
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

  // ---- Connect / disconnect ----

  int _startGen = 0;

  Future<void> connect() async {
    if (_busy) return;
    final gen = ++_startGen;
    final busyToken = Object();
    _busyToken = busyToken;
    _lastError = null;
    _startRequested = true;
    notifyListeners();
    try {
      final account = activeAccount;
      if (account == null) {
        _lastError =
            'Add a URnetwork account first — Settings → URnetwork '
            'holds the accounts this engine connects with.';
        return;
      }
      final UrClientSession session;
      try {
        session = await resolveSession(account);
      } on UrNetworkException catch (e) {
        _lastError = e.message;
        return;
      } on StateError catch (e) {
        _lastError = e.message;
        return;
      }
      if (gen != _startGen) return;
      await stopOtherEngine?.call();
      if (gen != _startGen) return;
      await _startAndAwait(session: session, account: account, gen: gen);
    } finally {
      if (identical(_busyToken, busyToken)) {
        _busyToken = null;
        _startRequested = false;
      }
      await refresh();
    }
  }

  Future<void> _startAndAwait({
    required UrClientSession session,
    required UrAccount account,
    int gen = 0,
  }) async {
    if (gen != _startGen) return;
    await UrPlatform.setOn(
      on: true,
      jwt: session.jwt,
      locationId: locationId,
      locationName: locationName,
      locationCode: locationCode,
      mtu: tunnelMtu(),
      killSwitch: killSwitchEnabled(),
    );
    final started = DateTime.now();
    while (true) {
      await Future<void>.delayed(const Duration(milliseconds: 600));
      if (gen != _startGen) {
        await UrPlatform.stop();
        return;
      }
      await refresh();
      // Honesty rule: "connected" is the SDK device's own
      // verdict in the published state, nothing local.
      if (_state.connected) return;
      if (_state.error != null && !_state.running) {
        await _dropCachedSession(account.id);
        throw StateError(_state.error!);
      }
      if (DateTime.now().difference(started) >= urConnectBudget) {
        throw StateError(urGiveUpMessage());
      }
    }
  }

  Future<void> disconnect() async {
    _startGen++;
    final busyToken = Object();
    _busyToken = busyToken;
    _startRequested = false;
    notifyListeners();
    try {
      await UrPlatform.stop();
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 400));
        await refresh();
        if (!_state.running) return;
      }
    } finally {
      if (identical(_busyToken, busyToken)) _busyToken = null;
      await refresh();
    }
  }

  // ---- Logs (diagnostics) ----

  /// The engine's on-disk logs: the :urnetwork service's
  /// own journal (lifecycle lines — names and stages only,
  /// never a credential) plus the shared crash.log tail.
  Future<String> readLogs() async {
    final filesDir = File(await AndroidCore.dataDir()).parent.path;
    final out = StringBuffer();
    final journal = File('$filesDir/urnetwork/service.log');
    out.writeln('══ urnetwork service.log ══');
    try {
      if (await journal.exists()) {
        final lines = await journal.readAsLines();
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
    final crash = File('$filesDir/crash.log');
    out.writeln('══ crash.log ══');
    try {
      if (await crash.exists()) {
        final text = await crash.readAsString();
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
    try {
      await File('$filesDir/urnetwork/service.log').writeAsString('');
    } catch (_) {}
    try {
      await File('$filesDir/crash.log').writeAsString('');
    } catch (_) {}
  }

  @override
  void dispose() {
    _poller?.cancel();
    super.dispose();
  }
}
