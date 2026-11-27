import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../atomic_json_store.dart';
import '../core/poll_policy.dart';
import '../core/android_core.dart';
import '../xray/wg_conf.dart';
import 'aether_platform.dart';

/// Owns one Aether slot's state for the UI (build 2032):
/// 'cfwarp' (the standalone WARP page) or 'masque' (the MASQUE /
/// WireGuard / WARP-in-WARP page). Mirrors LanternController's
/// shape: platform state polled while anything runs, failures
/// kept verbatim and shown loudly, and a connect flow that
/// follows ralysnd's rules exactly:
///
///  1. An identity first — registered by the binary's own
///     ladder when the slot has none (never silently replaced).
///  2. The engine runs to its own CONNECTED stage.
///  3. Real data must move (both slots — MASQUE since build
///     2080, the WARP page since build 2087, analysis B3): the
///     CfDataProbe port runs bounded transfers through the
///     slot's SOCKS and every answer is validated. A stage
///     line and a SOCKS greeting are signals, not proof — the
///     Iranian-exit diagnosis (2026-11-15) is the record of
///     where trusting them led. Build 2115 runs this proof
///     FIRST: it is the stronger evidence, and the step after
///     it can no longer keep it from ever running.
///  4. A Cloudflare trace through the tunnel verifies the
///     exit: warp=on counts the exit verified — handshake
///     alone never counts (both slots since build 2080;
///     before, MASQUE fetched the trace for display and never
///     checked it). A trace that lands warp=off is still
///     fatal — the exit is PROVEN not to be WARP. But since
///     build 2115 a trace that never lands at all is NOT
///     fatal: the 2026-11-19 diagnosis proved the fetch
///     itself failing on a tunnel the engine had validated
///     end-to-end, and tearing the engine down over an
///     unanswered check showed a working WARP as "not
///     connected". That session connects with its exit
///     unverified (see [exitUnverified]).
///  5. Only then does the device TUN come up against the slot's
///     SOCKS, supervised by the VPN service.
///
/// For the MASQUE slot with transport 'auto' (the default
/// since build 2083), steps 2–4 run natively as ONE call —
/// the carrier ladder (AetherSlot.connectMasque): the rungs
/// H3 → H2 → H2+fragment → H2+semi-python+fragment →
/// H2+semi-python+tlshello each get a real engine run with
/// the same trace + data proofs, a rung fails after one
/// full scan cycle and the walk advances, and the winner is
/// remembered per network. An explicit h3/h2 transport and
/// the cfwarp slot keep the Dart-side flow above.
/// Build 2096 (post-2095 audit M22): thrown inside a
/// connect's proof waits when a disconnect supersedes
/// the attempt — the connect then tears its engine down
/// and returns quietly instead of burning minutes
/// proxy-only before the single pre-TUN check notices.
class _AetherSuperseded implements Exception {
  const _AetherSuperseded();
}

class AetherController extends ChangeNotifier {
  AetherController(this.slot);

  /// 'cfwarp' | 'masque'
  final String slot;

  bool get isWarp => slot == 'cfwarp';
  String get displayName => isWarp ? 'WARP' : 'MASQUE';
  int get socksPort =>
      isWarp ? AetherPlatform.cfwarpSocksPort : AetherPlatform.masqueSocksPort;

  AetherState _engine = const AetherState();
  AetherState get state => _engine;

  AetherOptions options = const AetherOptions();
  bool _optionsLoaded = false;

  bool tunRunning = false;

  /// The name on the shared TUN session (the xrayState
  /// map's 'name'): this slot's [displayName] when the TUN
  /// is an Aether one, the profile's name when it is an
  /// Xray session's. The TUN is shared by every engine, so
  /// [tunRunning] alone never proves the TUN is THIS
  /// engine's to drop (build 2098 verification, iteration 2).
  String tunName = '';
  int tunSinceMs = 0;
  int upBytes = 0;
  int downBytes = 0;
  int upRate = 0;
  int downRate = 0;

  /// The last Cloudflare trace through the tunnel (ip, loc,
  /// warp, …), from the connect proof or a manual refresh.
  Map<String, String>? exitTrace;

  /// Build 2115: this session connected on the data proof
  /// alone — real traffic moved through the tunnel, but no
  /// Cloudflare trace ever landed to verify the exit. The
  /// session is up; its exit is shown as unverified rather
  /// than the engine being torn down over an unanswered
  /// check (the 2026-11-19 diagnosis).
  bool exitUnverified = false;

  /// The native side's last trace failure, in its own words
  /// (build 2115) — why the exit is unverified, when it is.
  String get exitTraceError => _engine.traceError;

  /// The connect proofs' retry budgets. Fields, not
  /// constants, so the behavioral tests can shrink them
  /// (build 2115); the shell never touches them and the
  /// shipped values are the long-standing ones.
  Duration dataProofBudget = const Duration(seconds: 90);
  Duration warpProofBudget = const Duration(seconds: 45);

  /// The last endpoint scan's outcome, when one ran this session.
  ({String server, String rtt, DateTime at})? lastScan;

  String? _lastError;

  /// The store's complaint, when it has one (build 2071,
  /// review §5.4): set when a save fails or the saved file
  /// was damaged at load, cleared by the next successful
  /// save. [lastError] reports it after the engine's own
  /// errors, so a failing disk is visible instead of every
  /// change being lost silently, forever.
  String? storeError;

  String? get lastError => _engine.error.isNotEmpty
      ? _engine.error
      : _lastError ?? storeError;

  Future<void> Function()? stopOtherEngine;

  /// Set by the shell: the global tunnel MTU (build 2038, queue 2f) —
  /// the Xray settings value, read at connect time. Defaults to 1500
  /// (the unchanged behaviour) when unwired.
  int Function() tunnelMtu = () => 1500;

  /// Set by the shell: the Settings kill switch (build
  /// 2097, post-2096 audit C7) — read at connect time and
  /// passed to the TUN start, whose native side has
  /// honoured it since build 2063. Defaults to false (the
  /// unchanged behaviour) when unwired.
  bool Function() killSwitchEnabled = () => false;

  /// Build 2125 (audit A25-15 / P-22): the user's tunnel
  /// DNS and IPv6 choices, read at connect time and passed
  /// to the TUN start — the same callback shape as
  /// [killSwitchEnabled] above. Up to 2124 the Aether TUN
  /// starts passed NEITHER, so every WARP/MASQUE session
  /// silently took the platform defaults (DNS 1.1.1.1,
  /// IPv6 on) while the Xray path honoured the Settings
  /// values: a custom DNS was bypassed and an IPv6-off
  /// choice leaked. The defaults here keep the platform
  /// values when unwired.
  String Function() tunDns = () => '1.1.1.1';
  bool Function() tunIpv6 = () => true;

  /// Build 2126 (audit A26-30): where the TUN-DNS
  /// family guard's substitution note goes when the
  /// shell wires one (the shared diagnostics journal) —
  /// the same callback shape as the reads above.
  void Function(String message)? dnsGuardNote;

  Timer? _poller;

  /// Build 2097 (post-2096 audit C4/L-g): the busy flag has
  /// an OWNER, as in the OpenVPN controller — connect(),
  /// disconnect() and scanEndpoints() claim it with a token
  /// and release it only while the token is still theirs.
  /// The un-owned bool let a superseded operation's finally
  /// clear the flag mid-disconnect, and the scan's finally
  /// stop a slot a fresh connect had just started.
  /// disconnect() STEALS the claim (the superseding op).
  Object? _busyToken;
  bool get _busy => _busyToken != null;
  bool get connecting => _busy;

  /// Fully up: TUN raised AND the engine at its CONNECTED stage.
  bool get connected => tunRunning && _engine.connected;

  bool get _anyLive => _engine.running || tunRunning || _busy;

  Future<File> _optionsFile() async {
    final filesDir = File(await AndroidCore.dataDir()).parent.path;
    return File('$filesDir/aether_${slot}_options.json');
  }

  /// The shared atomic store for this slot's file (build 2054,
  /// audit F-H8), cached so every write for this file goes
  /// through one serialization chain.
  AtomicJsonStore? _store;

  Future<AtomicJsonStore> _atomicStore() async {
    return _store ??= AtomicJsonStore(await _optionsFile());
  }

  /// The options document as persisted: the options plus
  /// the last scan (build 2095, whole-app journey audit
  /// #57 — the scan result used to live only in memory, so
  /// the Servers tab forgot it at every restart).
  /// Build 2095 (audit 1.4): the on-disk store belongs to
  /// a newer build; saves are refused.
  bool _storeFromNewerVersion = false;

  /// Build 2097 (post-2096 audit C-L7/C-L12): the on-disk
  /// document is not safely ours to overwrite — it was
  /// unreadable at load (intact), foreign (none of the
  /// options keys), or its fields failed to decode.
  /// Saves are refused while it exists; if the file
  /// disappears, saves resume.
  bool _storeProtected = false;

  Map<String, dynamic> _optionsDoc() => {
    'schemaVersion': 1,
    ...options.toJson(),
    // Build 2116 (B5-7): the exit-unverified stamp is a
    // session fact, not an option — it rides the same
    // document so a restarted app re-stamps the session it
    // re-adopts instead of calling it plain Connected
    // (2115-R2).
    'exitUnverified': exitUnverified,
    if (lastScan != null)
      'lastScan': {
        'server': lastScan!.server,
        'rtt': lastScan!.rtt,
        'at': lastScan!.at.millisecondsSinceEpoch,
      },
  };

  /// Persists the exit stamp through the same guarded
  /// write setOptions uses (build 2116, B5-7).
  Future<void> _saveStamp() async {
    if (!_optionsLoaded) return;
    try {
      final store = await _atomicStore();
      if (_storeProtected) {
        if (await store.file.exists()) return;
        _storeProtected = false;
      }
      if (!_storeFromNewerVersion) await store.write(_optionsDoc());
    } catch (_) {}
  }

  Future<void> load() async {
    if (!_optionsLoaded) {
      _optionsLoaded = true;
      try {
        final store = await _atomicStore();
        final doc = await store.read();
        // Build 2071 (review §5.4): a damaged options file
        // still falls back to the defaults — but it says so
        // on the error surface instead of silently
        // pretending nothing was ever saved.
        if (store.lastReadProblem == 'damaged') {
          storeError = storeDamagedMessage;
        }
        // Build 2097 (post-2096 audit C-L7): an UNREADABLE
        // store (intact file, filesystem error) is not
        // damage — build 2096 set the damaged message and
        // let the first save overwrite the intact original.
        if (store.lastReadProblem == 'unreadable') {
          _storeProtected = true;
          storeError = storeUnreadableMessage;
        }
        if (doc != null && storeSchemaVersion(doc) > 1) {
          // Build 2095 (third-pass audit 1.4): never
          // overwrite a newer build's store.
          _storeFromNewerVersion = true;
          storeError =
              'Your saved data was written by a newer '
              'build of Ember — this build will not '
              'overwrite it.';
        }
        // Build 2096 (post-2095 audit L34): a newer
        // document decodes in-session like the other
        // stores — the flag still blocks every save.
        if (doc != null) {
          // Build 2097 (post-2096 audit C-L12): a FOREIGN
          // document (none of the options keys — a synced
          // or misplaced file) or one whose fields fail to
          // decode used to fall silently into the defaults,
          // and the next save overwrote it. Both are
          // damage-shaped now: surfaced, file protected.
          const knownKeys = {
            'protocol',
            'scan',
            'ip',
            'transport',
            'transportExplicit',
            'ech',
            'fragment',
            'noize',
            'keepalive',
            'peer',
            'lastScan',
            'schemaVersion',
            'exitUnverified',
          };
          // Build 2098 (post-2097 audit L10): the any-key
          // test also passed a document carrying ONLY
          // metadata keys (lastScan/schemaVersion) — no
          // actual options — which then reset every option
          // silently. A real Aether store always carries
          // option keys; metadata alone is foreign too.
          final hasOptionKey = doc.keys.any(
            (k) =>
                knownKeys.contains(k) &&
                k != 'lastScan' &&
                k != 'schemaVersion' &&
                k != 'exitUnverified',
          );
          if (doc.isNotEmpty && !hasOptionKey) {
            _storeProtected = true;
            storeError = storeDamagedMessage;
          } else {
            try {
              options = AetherOptions.fromJson(doc);
            } catch (_) {
              _storeProtected = true;
              storeError = storeDamagedMessage;
            }
          }
          // Build 2098 (post-2097 audit L10): the casts
          // below used to sit OUTSIDE the decode guard —
          // a wrong-typed 'server' (or 'at') threw out of
          // the load entirely. Type-test every field; a bad
          // lastScan is dropped, never fatal.
          // Build 2116 (B5-7): the persisted exit stamp.
          if (doc['exitUnverified'] == true) exitUnverified = true;
          final ls = doc['lastScan'];
          if (ls is Map &&
              ls['server'] is String &&
              (ls['server'] as String).isNotEmpty) {
            lastScan = (
              server: ls['server'] as String,
              rtt: ls['rtt'] is String ? ls['rtt'] as String : '',
              at: DateTime.fromMillisecondsSinceEpoch(
                ls['at'] is num ? (ls['at'] as num).toInt() : 0,
              ),
            );
          }
          // Build 2083: the one-time transport migration
          // (migrateMasqueTransport): a stored unmarked 'h3'
          // — indistinguishable from the old shipped default
          // — lands on 'auto'; an unmarked 'h2' is marked as
          // the explicit pick it can only be. Persisted when
          // it changes anything, so the stored file carries
          // the marker from now on; a failed write surfaces
          // like any other store failure (build 2071).
          final migrated = migrateMasqueTransport(options);
          if (!identical(migrated, options)) {
            options = migrated;
            try {
              if (!_storeFromNewerVersion && !_storeProtected) {
                await store.write(_optionsDoc());
              }
              if (store.lastWriteError != null) {
                storeError = storeSaveFailedMessage;
              }
            } catch (_) {
              // Persistence is best-effort; the session keeps
              // the migrated choice.
            }
          }
        }
      } catch (_) {
        // A damaged options file falls back to the defaults.
      }
      if (isWarp) {
        // The cfwarp slot's protocol is WireGuard by construction.
        options = options.copyWith(protocol: 'wg');
      }
    }
    await refresh();
  }

  Future<void> setOptions(AetherOptions next) async {
    // Build 2125 (audit A25-45): the restore path ran
    // neither of load()'s disciplines — a restored
    // pre-2083 unmarked 'h3' was thereafter read as an
    // explicit H3 pick (load() migrates it to 'auto'),
    // and a restore that arrived before the first load
    // assigned in memory, then silently never persisted
    // (the !_optionsLoaded return below). The migration
    // runs here exactly as in load(), and an unloaded
    // controller loads first so the restore lands.
    if (!_optionsLoaded) await load();
    options = migrateMasqueTransport(next);
    notifyListeners();
    // Build 2054 (audit F-H8): never persist before load, and
    // write atomically through the shared store — the old
    // direct write could tear the file and silently reset the
    // options on the next launch.
    if (!_optionsLoaded) return;
    try {
      final store = await _atomicStore();
      // Build 2097 (post-2096 audit C-L7/C-L12): never
      // overwrite a protected document while it exists.
      if (_storeProtected) {
        if (await store.file.exists()) return;
        _storeProtected = false;
      }
      if (!_storeFromNewerVersion) await store.write(_optionsDoc());
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
      // Persistence is best-effort; the session keeps the choice.
    }
  }

  Future<void> refresh() async {
    final beforeUp = upBytes;
    final beforeDown = downBytes;
    final beforeAt = _lastTick;
    _engine = await AetherPlatform.state(slot);
    final tun = await AetherPlatform.tunState();
    tunRunning = tun['running'] == true;
    tunName = (tun['name'] as String?) ?? '';
    tunSinceMs = (tun['sinceMs'] as num?)?.toInt() ?? 0;
    upBytes = (tun['up'] as num?)?.toInt() ?? 0;
    downBytes = (tun['down'] as num?)?.toInt() ?? 0;
    final now = DateTime.now();
    if (beforeAt != null && tunRunning) {
      final dt = now.difference(beforeAt).inMilliseconds / 1000.0;
      if (dt > 0) {
        upRate = ((upBytes - beforeUp) / dt).round().clamp(0, 1 << 62);
        downRate = ((downBytes - beforeDown) / dt).round().clamp(0, 1 << 62);
      }
    } else {
      upRate = 0;
      downRate = 0;
    }
    _lastTick = now;
    _syncPoller();
    notifyListeners();
    // Build 2125 (audit A25-28 / P-33): the Dart-side
    // data-plane re-probe (see _maybeProbeDataPlane). The
    // cadence clock starts when a session ESTABLISHES
    // (the false→true edge of [connected] in this tick):
    // a probe must never fire inside the connect/proof
    // window — build 2115's discipline is that the trace
    // channel belongs to the proofs until they land, and
    // a mid-bring-up trace call corrupts their order.
    final established = connected;
    if (established && !_wasConnected) {
      _lastProbeAt = now;
      _probeFailures = 0;
    }
    _wasConnected = established;
    unawaited(_maybeProbeDataPlane(now));
  }

  bool _wasConnected = false;

  DateTime? _lastTick;

  /// Build 2125 (audit A25-28 / P-33): the Dart re-probe's
  /// verdict — the core still claims the session while
  /// repeated trace probes through it fail. Surfaced on
  /// the engine pages; NEVER acted on by teardown (build
  /// 2115's lesson: a probe's say-so does not kill a
  /// session — the MASQUE trace gate tore down healthy
  /// tunnels exactly that way).
  bool dataPlaneStale = false;
  int _probeFailures = 0;
  DateTime? _lastProbeAt;
  bool _probeBusy = false;

  /// While the core reports connected, one trace through
  /// the tunnel per minute; two consecutive failures (or
  /// warp=off answers — traffic leaving direct) mark the
  /// data plane stale, and one success clears it. Up to
  /// 2124 demotion rested solely on the core's own log
  /// lines: a core that stopped emitting recognisable
  /// retry lines while its data plane died read healthy
  /// forever.
  Future<void> _maybeProbeDataPlane(DateTime now) async {
    if (!_engine.connected) {
      _probeFailures = 0;
      if (dataPlaneStale) {
        dataPlaneStale = false;
        notifyListeners();
      }
      return;
    }
    // Never during bring-up: the connect sequence's own
    // proofs own the trace channel until they finish
    // (build 2115), and a superseded connect must stop at
    // the proof it was in (build 2096, M22).
    if (connecting) return;
    if (_probeBusy) return;
    final last = _lastProbeAt;
    if (last != null && now.difference(last) < const Duration(seconds: 60)) {
      return;
    }
    _lastProbeAt = now;
    _probeBusy = true;
    try {
      final t = await AetherPlatform.trace(slot);
      final ok = t != null && (t['warp'] == 'on' || t['warp'] == 'plus');
      if (ok) {
        _probeFailures = 0;
        if (dataPlaneStale) {
          dataPlaneStale = false;
          notifyListeners();
        }
      } else if (++_probeFailures >= 2 && !dataPlaneStale) {
        dataPlaneStale = true;
        notifyListeners();
      }
    } catch (_) {
      // A probe error counts as a failed probe, never more.
      if (++_probeFailures >= 2 && !dataPlaneStale) {
        dataPlaneStale = true;
        notifyListeners();
      }
    } finally {
      _probeBusy = false;
    }
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
    if (_anyLive && _poller == null) {
      _poller = Timer.periodic(
        enginePollPeriod(foreground: _foreground),
        (_) => unawaited(refresh()),
      );
    } else if (!_anyLive && _poller != null) {
      _poller!.cancel();
      _poller = null;
      upRate = 0;
      downRate = 0;
    }
  }

  /// Connects the slot end to end (see the class doc). Throws a
  /// StateError carrying the engine's own words on failure.
  int _connectGen = 0;

  Future<void> connect() async {
    if (_busy) return;
    // Build 2095 (third-pass audit 2.1): disconnect() bumps
    // the generation; the connect re-checks it before the
    // final setTun — the proof waits noticed a dead engine
    // but nothing stopped a disconnect mid-proof from
    // being followed by the TUN coming up.
    final gen = ++_connectGen;
    final busyToken = Object();
    _busyToken = busyToken;
    _lastError = null;
    exitUnverified = false;
    notifyListeners();
    try {
      await stopOtherEngine?.call();
      if (gen != _connectGen) return;
      await refresh();
      // 1. Identity.
      if (!_engine.identity) {
        final outcome = await AetherPlatform.ensureIdentity(
          slot,
          options.protocol,
        );
        await refresh();
        if (gen != _connectGen) return;
        if (!_engine.identity) {
          throw StateError(
            outcome.isNotEmpty
                ? outcome
                : 'a WARP identity could not be made on this network',
          );
        }
      }
      // 2–4. The engine, proven. For MASQUE on 'auto' this
      // is the native carrier ladder (build 2083); every
      // other case runs the Dart-side flow.
      // Build 2129: mim rides the ladder too — both of its
      // hops are MASQUE on the one carrier.
      final ridesMasque =
          options.protocol == 'masque' ||
          options.protocol == 'gool' ||
          options.protocol == 'mim';
      if (!isWarp && ridesMasque && options.transport == 'auto') {
        // The ladder: one native call walks the rungs, each
        // a real engine run proven by the warp trace and the
        // data proof before any TUN exists, the winner
        // remembered per network. The Dart backstop
        // (masqueAutoConnectTimeout) mirrors the ladder's
        // own bound plus slack — the native side answers
        // first in every expected case; the backstop only
        // guards a wedged platform call, and the catch below
        // tears the engine down either way, so no state can
        // sit in "connecting" forever.
        final verdict = await AetherPlatform.connectMasque(
          slot,
          options,
        ).timeout(
          masqueAutoConnectTimeout(options.scan),
          onTimeout: () => null,
        );
        await refresh();
        // Build 2096 (audit M22): a disconnect that landed
        // during the ladder is not a ladder failure.
        if (gen != _connectGen) {
          await _teardownIfOwned(busyToken);
          return;
        }
        if (verdict == null || verdict['ok'] != true) {
          throw StateError(
            (verdict?['error'] as String?) ??
                'the engine did not connect in time',
          );
        }
        // Build 2116 (B5-1): a rung that carried data
        // without a trace verdict stamps the session
        // exit-unverified, exactly like the Dart flow's
        // silent-trace outcome.
        exitUnverified = verdict['exitUnverified'] == true;
      } else {
        // 2. The engine to its CONNECTED stage.
        final started = await AetherPlatform.start(slot, options);
        if (!started) {
          throw StateError(_engine.error.isNotEmpty
              ? _engine.error
              : 'the engine could not start');
        }
        await _awaitEngineConnected(gen);
        // 3. The data proof FIRST (build 2115; both slots —
        // MASQUE since build 2080, the WARP page since build
        // 2087, analysis B3): real transfers through the slot's
        // SOCKS, ralysnd's CfDataProbe rule — the TUN does not
        // exist until data has actually moved. It used to run
        // AFTER the trace gate, so a trace fetch that never
        // landed kept the stronger proof from ever running and
        // the connect died on the weaker evidence.
        await _awaitDataProof(gen);
        // 4. The WARP proof: the trace through the tunnel
        // verifies the exit — warp=on for BOTH slots (build
        // 2080). MASQUE used to fetch the trace here for the
        // exit card and never check it, so a session whose
        // core egressed direct still connected and showed the
        // Iranian exit as success. An answered warp=off is
        // still fatal inside the proof; a trace that never
        // lands is not (build 2115) — the data proof above
        // has already proven the tunnel, so the session
        // connects with its exit unverified.
        exitUnverified = !await _awaitWarpProof(gen);
      }
      // 5. The TUN.
      if (gen != _connectGen) {
        await _teardownIfOwned(busyToken);
        return;
      }
      // Build 2126 (audit A26-30): the TUN DNS is
      // family-guarded, like the plain-WireGuard leg
      // since build 2125 (A25-23) — up to 2125 the raw
      // value went to the builder unguarded, and an
      // IPv6-only DNS on an IPv6-off session filtered to
      // ZERO resolvers inside a "Connected" session.
      final guardedTunDns = wgPlainTunDnsGuarded(
        tunDns(),
        ipv6: tunIpv6(),
      );
      if (guardedTunDns.$2 != null) {
        dnsGuardNote?.call(guardedTunDns.$2!);
      }
      await AetherPlatform.setTun(
        on: true,
        name: displayName,
        socksPort: socksPort,
        engine: slot,
        mtu: tunnelMtu(),
        // Build 2125 (audit A25-15 / P-22): the user's own
        // DNS / IPv6 choices — see the tunDns/tunIpv6
        // callbacks. The platform defaults (1.1.1.1 / on)
        // were the silent behaviour up to 2124.
        dns: guardedTunDns.$1,
        ipv6: tunIpv6(),
        killSwitch: killSwitchEnabled(),
      );
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 400));
        if (gen != _connectGen) {
          await _teardownIfOwned(busyToken);
          return;
        }
        await refresh();
        if (tunRunning) {
          // Build 2116 (B5-7): persist the session's exit
          // stamp with the connect it belongs to, so a
          // restarted app re-stamps the adopted session.
          await _saveStamp();
          return;
        }
      }
      throw StateError('the VPN tunnel did not come up');
    } on _AetherSuperseded {
      // Build 2096 (audit M22): the user's disconnect won —
      // tear the engine down and return quietly; this is
      // not a connect failure and must not surface as one.
      await _teardownIfOwned(busyToken);
      await refresh();
      return;
    } catch (e) {
      _lastError = e is StateError ? e.message : '$e';
      await _teardownIfOwned(busyToken);
      await refresh();
      // Build 2116 (B5-3): when the engine refused the
      // stored identity itself, the failure names the cure
      // — a network-shaped retry loop helps nobody whose
      // certificate no longer matches its key.
      if (_engine.identityRefused &&
          !(_lastError ?? '').contains('Reset identity')) {
        _lastError =
            '$_lastError — the saved identity was refused; '
            'use Reset identity on this page to register a fresh one.';
      }
      rethrow;
    } finally {
      if (identical(_busyToken, busyToken)) _busyToken = null;
      _syncPoller();
      notifyListeners();
    }
  }

  Future<void> _awaitEngineConnected(int gen) async {
    final deadline = DateTime.now().add(const Duration(seconds: 120));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 600));
      // Build 2096 (audit M22): notice a superseding
      // disconnect within one poll tick, not at the end
      // of the whole proof chain.
      if (gen != _connectGen) throw const _AetherSuperseded();
      await refresh();
      if (_engine.connected) return;
      if (_engine.failed) {
        throw StateError(
          _engine.error.isNotEmpty
              ? _engine.error
              : 'the engine failed (${_engine.stageLabel})',
        );
      }
      if (!_engine.running) {
        throw StateError('the engine exited before connecting');
      }
    }
    throw StateError(
      'the engine did not connect in time'
      '${_engine.probeTopReason.isNotEmpty ? ' — most probes failed with: ${_engine.probeTopReason}' : ''}',
    );
  }

  /// The WARP proof: a Cloudflare trace through the tunnel,
  /// retried for the budget the ralysnd engine allows a fresh
  /// identity's first proof. Returns true when a trace lands
  /// and says warp=on/plus. A trace that lands and says
  /// warp=off throws — the exit is PROVEN not to be WARP, the
  /// exact failure build 2080's gate exists for. A trace that
  /// never lands at all returns false (build 2115): the data
  /// proof has already proven this tunnel carries real
  /// traffic, and the 2026-11-19 diagnosis showed the fetch
  /// itself failing on such a tunnel — the session connects
  /// with its exit unverified instead of being torn down
  /// over an unanswered check.
  Future<bool> _awaitWarpProof(int gen) async {
    final deadline = DateTime.now().add(warpProofBudget);
    var sawOff = false;
    while (DateTime.now().isBefore(deadline)) {
      if (gen != _connectGen) throw const _AetherSuperseded();
      final t = await AetherPlatform.trace(slot);
      if (t != null) {
        exitTrace = t;
        if (t['warp'] == 'on' || t['warp'] == 'plus') return true;
        if (t['warp'] == 'off') sawOff = true;
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    if (sawOff) {
      throw StateError(
        'the tunnel answered, but not through WARP (warp=off)',
      );
    }
    // No trace ever landed: refresh once so the native
    // side's recorded trace error is current for the exit
    // card, then let the connect proceed on the data proof.
    await refresh();
    return false;
  }

  /// The data proof (build 2080): bounded real transfers
  /// through the slot's SOCKS — HTTP 204, HTTPS 204, an
  /// exact-byte download, an echoed upload — run natively
  /// (the CfDataProbe port). Retried inside a budget because
  /// the core may still be settling its chosen gateway in the
  /// first seconds after CONNECTED; an engine that fails,
  /// exits, or loses its (demotion-aware) connected state
  /// ends the wait early. Throws in plain language: the
  /// caller tears the engine down and NO TUN is raised, so a
  /// hollow session can never present as connected. Since
  /// build 2115 this is the connect's FIRST proof and the
  /// only one whose failure tears the engine down.
  Future<void> _awaitDataProof(int gen) async {
    final deadline = DateTime.now().add(dataProofBudget);
    var detail = '';
    while (DateTime.now().isBefore(deadline)) {
      if (gen != _connectGen) throw const _AetherSuperseded();
      final verdict = await AetherPlatform.dataProbe(slot);
      if (verdict != null) {
        if (verdict['ok'] == true) return;
        detail = (verdict['detail'] as String?) ?? '';
      }
      await refresh();
      if (_engine.failed) {
        throw StateError(
          _engine.error.isNotEmpty
              ? _engine.error
              : 'the engine failed (${_engine.stageLabel})',
        );
      }
      if (!_engine.running) {
        throw StateError('the engine exited before its data could be proven');
      }
      await Future<void>.delayed(const Duration(seconds: 3));
    }
    throw StateError(
      'the engine answered, but real data did not pass through it'
      '${detail.isNotEmpty ? ' ($detail)' : ''}'
      ' — the connection was not started',
    );
  }


  /// Build 2098 (post-2097 audit M6): teardown gated on
  /// still owning this attempt's busy claim. connect()'s
  /// gen-mismatch and catch paths used to tear down
  /// unconditionally — when attempt A was superseded (a
  /// disconnect stole the claim, did its own teardown, and
  /// a reconnect B claimed it and started the engine), A's
  /// unwind stopped B's freshly started engine and the new
  /// connection dropped for no visible reason. While A
  /// still owns the claim, nothing else can have started
  /// (connect() refuses while busy), so the gate is exact:
  /// own teardown only for the attempt that still owns the
  /// session.
  Future<void> _teardownIfOwned(Object busyToken) async {
    if (identical(_busyToken, busyToken)) await _teardown();
  }

  Future<void> _teardown() async {
    try {
      await AetherPlatform.setTun(
        on: false,
        name: displayName,
        socksPort: socksPort,
        engine: slot,
        mtu: tunnelMtu(),
      );
    } catch (_) {}
    try {
      await AetherPlatform.stop(slot);
    } catch (_) {}
  }

  Future<void> disconnect() async {
    // Build 2095 (audit 2.1): cancel any in-flight connect.
    _connectGen++;
    // Build 2097 (post-2096 audit C4): steal the busy claim.
    final busyToken = Object();
    _busyToken = busyToken;
    notifyListeners();
    try {
      await _teardown();
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await refresh();
        // Build 2098 (verification F4): a connect in its TUN
        // bring-up can raise the TUN AFTER this disconnect's
        // first teardown was processed — the deferred rise
        // the connect's own wait loop exists for — and the
        // M6 ownership gate then refuses the connect's own
        // teardown, because this disconnect holds the claim.
        // The claim owner therefore re-issues teardown while
        // anything of ITS OWN is still up. Iteration 2 of
        // the verification loop scoped that "its own" twice
        // over, and both scopings are load-bearing:
        // - The TUN is SHARED (tunState reads the one
        //   XrayVpnService TUN): a foreign session's TUN —
        //   e.g. an Xray session resumed from its
        //   notification, which bypasses Dart arbitration
        //   entirely — is not this disconnect's to drop, and
        //   its presence alone must not keep the loop alive.
        //   Ours is the TUN carrying this slot's name.
        // - The claim can be STOLEN mid-poll: the shell's
        //   stop cascades call disconnect() precisely while
        //   one is already in flight. Once stolen, the
        //   stealer owns the session; a zombie poller still
        //   tearing down can kill the fresh session the
        //   stealer (or its successor) starts.
        final tunIsOurs = tunRunning && tunName == displayName;
        if (!_engine.running && !tunIsOurs) return;
        if (!identical(_busyToken, busyToken)) return;
        if (_engine.running && tunRunning && !tunIsOurs) {
          // Only the engine is ours to stop right now; the
          // TUN up belongs to a foreign session. (If our own
          // TUN rises late anyway, a later poll sees its
          // name and takes the full teardown.)
          await AetherPlatform.stop(slot);
        } else {
          await _teardown();
        }
      }
    } finally {
      if (identical(_busyToken, busyToken)) _busyToken = null;
      await refresh();
    }
  }

  /// Runs the engine proxy-only (no TUN) until it has scanned,
  /// chosen and validated an endpoint, then stops it — ralysnd's
  /// endpoint scan. The outcome (the engine's own choice) is
  /// kept in [lastScan]; the user may pin it for later connects.
  Future<void> scanEndpoints() async {
    if (_busy || tunRunning) {
      throw StateError('disconnect before scanning');
    }
    final busyToken = Object();
    _busyToken = busyToken;
    // Build 2097 (post-2096 audit C-L3): the generation is
    // captured HERE, at entry — build 2096 snapshotted it at
    // the wait, after the identity/start awaits, so a
    // disconnect landing in those phases bumped the gen
    // BEFORE the snapshot and the wait never noticed.
    final gen = _connectGen;
    _lastError = null;
    notifyListeners();
    try {
      await refresh();
      if (!_engine.identity) {
        final outcome = await AetherPlatform.ensureIdentity(
          slot,
          options.protocol,
        );
        await refresh();
        if (gen != _connectGen) throw const _AetherSuperseded();
        if (!_engine.identity) {
          throw StateError(
            outcome.isNotEmpty
                ? outcome
                : 'a WARP identity could not be made on this network',
          );
        }
      }
      final started = await AetherPlatform.start(
        slot,
        options.copyWith(clearPeer: true),
      );
      if (!started) throw StateError('the engine could not start');
      if (gen != _connectGen) throw const _AetherSuperseded();
      // Build 2096 (audit M22): the wait takes the scan's
      // generation — a disconnect during the scan ends it
      // via the on-clause below instead of waiting out
      // the budget against a dead engine.
      await _awaitEngineConnected(gen);
      lastScan = (
        server: _engine.server,
        rtt: _engine.rtt,
        at: DateTime.now(),
      );
      // Build 2095 (audit #57): the scan result persists —
      // the write rides the normal options save.
      await setOptions(options);
      exitTrace = await AetherPlatform.trace(slot);
    } on _AetherSuperseded {
      // Build 2096 (audit M22): superseded mid-scan — the
      // finally stops the engine; nothing to report.
      return;
    } finally {
      // Build 2097 (post-2096 audit L-g): stop the slot
      // only while this scan still owns the busy claim —
      // after a disconnect stole it (and a fresh connect
      // re-claimed and started the slot), an unconditional
      // stop here killed the fresh connect's engine.
      if (identical(_busyToken, busyToken)) {
        try {
          await AetherPlatform.stop(slot);
        } catch (_) {}
        _busyToken = null;
      }
      await refresh();
    }
  }

  /// Deletes the slot's identity (the next connect registers a
  /// fresh one). Refused silently while connected — the UI
  /// disables it then; ralysnd's engines delete under a stop.
  Future<void> resetIdentity() async {
    await AetherPlatform.resetIdentity(slot);
    exitTrace = null;
    exitUnverified = false;
    await refresh();
  }

  /// A fresh trace through the live tunnel (the exit card's
  /// refresh action).
  Future<void> refreshTrace() async {
    exitTrace = await AetherPlatform.trace(slot);
    // Build 2115: a trace that lands answers the exit
    // question the connect left open.
    if (exitTrace != null) {
      exitUnverified = false;
      await _saveStamp();
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _poller?.cancel();
    super.dispose();
  }
}
