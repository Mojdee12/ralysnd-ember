/// Build 2087 gates — the owner-reported EmberWarp registration
/// failure (emberwarp-registration-diagnosis-2026-11-16.md,
/// analysis A1; device log 2026-11-16 02:26 Tehran, build 2084):
/// a V2Ray connect with the underlay set to Warp and NO saved
/// WARP identity failed four times in ~2 s. One root cause with
/// three amplifiers:
///   1. The native readiness wait made ONE greeting connect and
///      latched "error" on the first refusal — before the core
///      had even bound (registration round-trips precede the
///      bind) — so the 45 s budget was never spent.
///   2. The Dart wait broke on that first poll, and
///      provisioning stopped the core it had just started, so
///      the identity never landed.
///   3. The fallback walk re-ran the whole thing per group
///      member (1 + 3 = the four cycles in ~2 s).
/// Fixes pinned here:
///   1. Kotlin retries the greeting connect until the deadline.
///   2. The probe run gets the chain grace (150 s) on both
///      sides of the channel.
///   3. One provisioning attempt per connect episode.
/// What only the owner's phone can prove — a cold registration
/// now landing and the chained session starting against it —
/// is NOT claimed here.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/psiphon/psiphon_controller.dart';
import 'package:firefox_vpn/psiphon/psiphon_platform.dart';
import 'package:firefox_vpn/xray/warp_args.dart';
import 'package:firefox_vpn/xray/warp_platform.dart';
import 'package:firefox_vpn/xray/xray_controller.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

String _kt(String name) =>
    File('android/app/src/main/kotlin/com/ralysnd/ember/$name')
        .readAsStringSync();

String _dart(String path) => File('lib/$path').readAsStringSync();

int _occurrences(String haystack, String needle) =>
    haystack.split(needle).length - 1;

/// The text of one function in a source file: from [start]
/// up to (not including) the next occurrence of [end].
String _region(String src, String start, String end) {
  final a = src.indexOf(start);
  expect(a, greaterThanOrEqualTo(0), reason: '$start is present');
  final b = src.indexOf(end, a);
  expect(b, greaterThan(a), reason: '$end follows $start');
  return src.substring(a, b);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the greeting connect retries until the deadline (Kotlin)', () {
    late String core;
    late String readiness;

    setUp(() {
      core = _kt('EmberWarpCore.kt');
      readiness = _region(
        core,
        'private fun watchReadiness(',
        'private fun watchLog(',
      );
    });

    test('a refused connect is retried, not latched as an error', () {
      expect(readiness, contains('while (greeted == null)'));
      expect(readiness, contains('candidate.connect('));
      expect(readiness, contains('greeted = candidate'));
      expect(readiness, contains('if (!p.isAlive) break'));
      expect(
        readiness,
        contains('System.currentTimeMillis() >= deadline'),
      );
      expect(readiness, contains('Thread.sleep(250)'));
      // The connect attempt's catch closes the dead candidate
      // and waits — it latches NO stage. The old single attempt
      // set stage = "error" here, within milliseconds of the
      // spawn, before the core had bound.
      final attempt = _region(
        readiness,
        'candidate.connect(',
        'val s = greeted',
      );
      expect(attempt, contains('candidate.close()'));
      expect(attempt, isNot(contains('stage =')));
    });

    test('exactly one greeting is ever written', () {
      expect(
        _occurrences(
          core,
          'getOutputStream().write(byteArrayOf(5, 1, 0))',
        ),
        1,
        reason: 'a refused connect sends nothing, so the retry '
            'cannot queue dead greetings ahead of the real one',
      );
    });

    test('error latches only on process death or deadline expiry', () {
      final noListener = _region(
        readiness,
        'val s = greeted',
        '} catch (e: Exception) {',
      );
      expect(
        noListener,
        contains('stage = if (renewNeeded) "refused" else "error"'),
      );
      expect(
        noListener,
        contains('"the EmberWarp core did not answer in time"'),
      );
      expect(
        noListener,
        contains('"the EmberWarp core stopped before it was ready"'),
      );
    });

    test('start takes a greeting-wait override, defaulting per run', () {
      final start = _region(
        core,
        '    fun start(',
        'private fun watchReadiness(',
      );
      expect(start, contains('greetingWaitMs: Long? = null,'));
      expect(
        start,
        contains('greetingWaitMs\n                    '
            '?: if (chainedRun) CHAIN_GREETING_WAIT_MS\n'
            '                    else GREETING_WAIT_MS,'),
      );
    });
  });

  group('the probe run gets the chain grace on both sides (channel)', () {
    test('MainActivity forwards the greeting-wait override', () {
      final main = _kt('MainActivity.kt');
      final warpStart = _region(main, '"warpStart" -> {', '"warpStop" -> {');
      expect(
        warpStart,
        contains('call.argument<Int>("greetingWaitMs")'),
      );
      expect(warpStart, contains('greetingWaitMs?.toLong(),'));
    });

    test('WarpPlatform.start sends the override only when given', () async {
      Map<String, dynamic>? seen;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('app/android'),
            (call) async {
              if (call.method == 'warpStart') {
                seen = Map<String, dynamic>.from(call.arguments as Map);
                return true;
              }
              return null;
            },
          );
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('app/android'),
              null,
            );
      });
      await WarpPlatform.start(
        ['--bind', '127.0.0.1:$warpProbePort'],
        port: warpProbePort,
        greetingWaitMs: 150000,
      );
      expect(seen?['greetingWaitMs'], 150000);
      expect(seen?['port'], warpProbePort);
      await WarpPlatform.start(['--bind', '127.0.0.1:20850']);
      expect(seen?.containsKey('greetingWaitMs'), isFalse);
    });

    test('_awaitWarpReady forwards the native budget', () {
      final dart = _dart('xray/xray_controller.dart');
      final wait = _region(
        dart,
        'Future<bool> _awaitWarpReady(',
        'Future<void> connectWarp() async',
      );
      expect(wait, contains('greetingWaitMs: nativeWait?.inMilliseconds,'));
    });

    test('provisioning passes 150 s to both waits', () {
      final dart = _dart('xray/xray_controller.dart');
      final provision = _region(
        dart,
        'Future<void> _provisionWarpIdentityForChain() async {',
        'Future<bool> _awaitWarpReady(',
      );
      expect(
        provision,
        contains('wait: const Duration(seconds: 150),'),
      );
      expect(
        provision,
        contains('nativeWait: const Duration(seconds: 150),'),
      );
      expect(provision, contains('port: warpProbePort,'));
    });
  });

  group('one provisioning attempt per connect episode (Dart)', () {
    late XrayController c;
    late List<Map<String, dynamic>> warpStarts;
    var warpStops = 0;

    Map<String, dynamic> warpState({String stage = 'idle'}) => {
      'available': true,
      'running': false,
      'ready': false,
      'stage': stage,
      'identityPresent': false,
      'renewNeeded': false,
      'error': '',
      'logTail': '',
    };

    setUp(() {
      warpStarts = [];
      warpStops = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('app/android'),
            (call) async {
              switch (call.method) {
                case 'warpState':
                  // No identity is saved; after the spawn the
                  // core reports a latched error, exactly what
                  // the old native code did on the first
                  // refused greeting connect.
                  return warpState(
                    stage: warpStarts.isEmpty ? 'idle' : 'error',
                  );
                case 'warpStart':
                  warpStarts.add(
                    Map<String, dynamic>.from(call.arguments as Map),
                  );
                  return true;
                case 'warpStop':
                  warpStops++;
                  return null;
                default:
                  return null;
              }
            },
          );
      c = XrayController();
    });

    tearDown(() {
      c.testEndHandoverCountdown();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('app/android'),
            null,
          );
      c.dispose();
    });

    test('a failed registration throws once and is remembered', () async {
      await expectLater(
        c.testProvisionWarpIdentityForChain(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'underlay-failed',
          ),
        ),
      );
      expect(c.testWarpProvisionFailed, isTrue);
      expect(warpStarts, hasLength(1));
      expect(warpStops, 1);
    });

    test('the probe run passes the chain grace on both sides', () async {
      await expectLater(
        c.testProvisionWarpIdentityForChain(),
        throwsA(isA<StateError>()),
      );
      final start = warpStarts.single;
      expect(start['port'], warpProbePort);
      expect(start['greetingWaitMs'], 150000);
      final args = (start['args'] as List).cast<String>();
      expect(args, isNot(contains('--upstream')));
    });

    test('the fallback walk gets no second core start', () async {
      await expectLater(
        c.testProvisionWarpIdentityForChain(),
        throwsA(isA<StateError>()),
      );
      expect(warpStarts, hasLength(1));
      expect(warpStops, 1);
      // The repeat call throws before any spawn: no second
      // start, no second stop, one failure in the journal.
      await expectLater(
        c.testProvisionWarpIdentityForChain(),
        throwsA(isA<StateError>()),
      );
      expect(warpStarts, hasLength(1));
      expect(warpStops, 1);
      expect(c.testWarpProvisionFailed, isTrue);
    });

    test('the flag clears at each episode entry', () {
      final dart = _dart('xray/xray_controller.dart');
      // Build 2099 (pin repair, reason named): the region end
      // marker names disconnect's start; build 2098's I2-A3
      // gave disconnect a {consumeChainExit} parameter, so the
      // pre-2099 marker 'Future<void> disconnect() async' no
      // longer exists in the source — the pin was stale in the
      // shipped 2098 tree, not broken by 2099.
      final connect = _region(
        dart,
        'Future<void> connect({bool groupWalk = false}) async {',
        'Future<void> disconnect({',
      );
      expect(connect, contains('_warpProvisionFailed = false;'));
      final wg = _region(
        dart,
        'Future<void> connectWireGuardWithFallback(Profile first) async {',
        'Future<void> connect({bool groupWalk = false}) async {',
      );
      expect(wg, contains('_warpProvisionFailed = false;'));
    });
  });

  group('no-silent-removal — the other budgets are unchanged', () {
    test('direct and chained greeting budgets stand', () {
      final core = _kt('EmberWarpCore.kt');
      expect(core, contains('GREETING_WAIT_MS = 45_000L'));
      expect(core, contains('CHAIN_GREETING_WAIT_MS = 150_000L'));
      final dart = _dart('xray/xray_controller.dart');
      final wait = _region(
        dart,
        'Future<bool> _awaitWarpReady(',
        'Future<void> connectWarp() async',
      );
      expect(
        wait,
        contains('Duration wait = const Duration(seconds: 90),'),
      );
      expect(wait, contains('Duration? nativeWait,'));
      // The Dart wait still breaks on a latched error — now
      // correct, because the native side latches it only on
      // process death or deadline expiry.
      expect(wait, contains("if (!s.running || s.stage == 'error') break;"));
    });
  });

  group('A2 — a notification stop is a full user stop', () {
    test('the service marks ACTION_STOP synchronously', () {
      final svc = _kt('XrayVpnService.kt');
      final stop = _region(svc, 'ACTION_STOP ->', 'ACTION_START ->');
      expect(stop, contains('userStopped = true'));
      expect(svc, contains('var userStopped = false'));
      // Every start action clears it again.
      expect(svc, contains('-> userStopped = false'));
    });

    test('the flag reaches the Dart poll and cancels the expectation', () {
      final main = _kt('MainActivity.kt');
      expect(main, contains('"userStopped" to XrayVpnService.userStopped'));
      final platform = _dart('xray/xray_platform.dart');
      expect(platform, contains('final bool userStopped'));
      final ctl = _dart('xray/xray_controller.dart');
      final poll = _region(
        ctl,
        'Future<void> _pollTick() async',
        'The adaptive failover watcher',
      );
      expect(poll, contains('sample.userStopped'));
      expect(poll, contains('_cancelReconnect();'));
      expect(poll, contains('_expectRunning = false;'));
    });
  });

  group('A4 — the About page points at this project', () {
    test('githubRepo is the Ralysnd Ember repo', () {
      final info = _dart('app_info.dart');
      expect(info, contains("const githubRepo = 'Mojdee12/ralysnd-ember';"));
      expect(info, isNot(contains('armanlife/firefox-vpn-client')));
    });
  });

  group('A5 — the dead cleartext fallbacks are removed, not widened', () {
    test('no ip-api.com URL remains in the native sources', () {
      final tester = _kt('XrayTester.kt');
      final ovpn = _kt('OpenVpnService.kt');
      expect(tester, isNot(contains('http://ip-api.com/json')));
      expect(ovpn, isNot(contains('http://ip-api.com/json')));
      // The HTTPS primaries are untouched.
      expect(tester, contains('https://www.cloudflare.com/cdn-cgi/trace'));
      expect(ovpn, contains('https://www.cloudflare.com/cdn-cgi/trace'));
    });

    test('the cleartext config still names only the probe hosts', () {
      final xml = File(
        'android/app/src/main/res/xml/network_security_config.xml',
      ).readAsStringSync();
      expect(_occurrences(xml, 'cleartextTrafficPermitted="true"'), 1);
      expect(xml, contains('www.gstatic.com'));
      expect(xml, contains('connectivitycheck.gstatic.com'));
      expect(xml, contains('cleartextTrafficPermitted="false"'));
    });
  });

  group('B3 — the WARP slot proves data like the MASQUE slot', () {
    test('the data proof is unconditional in connect()', () {
      final aether = _dart('aether/aether_controller.dart');
      final connect = _region(
        aether,
        'Future<void> connect() async',
        // Aether's disconnect keeps its parameterless shape —
        // only the XRAY controller's disconnect gained the
        // {consumeChainExit} parameter (see the pin repair
        // note in the episode-flag test above).
        'Future<void> disconnect() async',
      );
      // PIN UPDATED by build 2096 (post-2095 audit M22):
      // the proof waits take the connect generation.
      expect(connect, contains('await _awaitWarpProof(gen);'));
      expect(connect, contains('await _awaitDataProof(gen);'));
      expect(connect, isNot(contains('if (!isWarp)')));
      // The proof still precedes the TUN.
      expect(
        connect.indexOf('await _awaitDataProof(gen);'),
        lessThan(connect.indexOf('AetherPlatform.setTun')),
      );
    });
  });

  group('selection — a tap is never stomped or silently walked', () {
    Profile member(String id, String name, {int delay = 0}) => Profile(
          id: id,
          protocol: Protocol.vless,
          name: name,
          address: '127.0.0.1',
          port: 1,
          uuidOrPassword: '11111111-1111-1111-1111-111111111111',
          subscriptionId: 'sub1',
        )..delayMs = delay;

    test('preselect guards: user choice and live sessions win', () {
      final ctl = _dart('xray/xray_controller.dart');
      final preselect = _region(
        ctl,
        'bool preselectForNetwork(String networkKey)',
        'Future<bool> maybeRunScheduledHealth()',
      );
      expect(preselect, contains('if (_userChoseSelection) return false;'));
      expect(preselect, contains('state.running ||'));
      expect(preselect, contains('_connectedProfileId.isNotEmpty'));
      // It sets the field directly — never select(), which can
      // switch a live session.
      expect(preselect, isNot(contains('select(winner)')));
      final select = _region(ctl, 'void select(Profile p)', 'void sortProfilesByDelay()');
      expect(select, contains('_userChoseSelection = true;'));
    });

    test('a user choice beats the remembered network winner', () {
      final c = XrayController();
      final a = member('a', 'Picked');
      final b = member('b', 'Measured', delay: 40);
      c.profiles = [a, b];
      c.settings.lastProfileByNetwork['wifi:home'] = 'b';
      c.select(a);
      expect(c.preselectForNetwork('wifi:home'), isFalse);
      expect(c.selectedProfileId, 'a');
    });

    test('cold-start preselect still applies the winner', () {
      final c = XrayController();
      final a = member('a', 'Picked');
      final b = member('b', 'Measured', delay: 40);
      c.profiles = [a, b];
      c.settings.lastProfileByNetwork['wifi:home'] = 'b';
      expect(c.preselectForNetwork('wifi:home'), isTrue);
      expect(c.selectedProfileId, 'b');
    });

    test('a manual connect tries only the picked member', () async {
      final c = XrayController();
      final a = member('a', 'Picked');
      final b = member('b', 'Measured', delay: 40);
      c.profiles = [a, b];
      c.select(a);
      try {
        await c.connect().timeout(const Duration(seconds: 30));
      } catch (_) {
        // No device here: the picked member's own attempt
        // fails on the missing platform — that failure is the
        // point; what matters is what did NOT happen next.
      }
      expect(c.selectedProfileId, 'a');
      expect(c.settings.fallbackFailedAtMs, isEmpty);
    });

    test('an explicit group walk still walks', () async {
      final c = XrayController();
      // Build 2114: adaptive failover defaults OFF now
      // (defaults reset) and the walk is gated on it — the
      // setup turns it on; the walk mechanism is unchanged.
      c.settings.adaptiveFailover = true;
      final a = member('a', 'Picked');
      final b = member('b', 'Measured', delay: 40);
      c.profiles = [a, b];
      c.select(a);
      try {
        await c
            .connect(groupWalk: true)
            .timeout(const Duration(seconds: 30));
      } catch (_) {
        // Both members fail on the missing platform.
      }
      // The walk marked the picked member failed and moved on
      // to the measured one — the behaviour a manual connect
      // must never show.
      expect(c.settings.fallbackFailedAtMs.containsKey('a'), isTrue);
      expect(c.selectedProfileId, 'b');
    });

    test('only the reconnect path opts into the walk', () {
      final ctl = _dart('xray/xray_controller.dart');
      expect(ctl, contains('Future<void> connect({bool groupWalk = false})'));
      expect(
        ctl,
        contains('if (!allowGroupWalk || !settings.adaptiveFailover) rethrow;'),
      );
      final reconnect = _region(
        ctl,
        'Future<void> _attemptReconnect(int gen) async {',
        'void _noteRetryFailed()',
      );
      expect(reconnect, contains('await connect(groupWalk: true);'));
    });
  });

  group('Psiphon F1-F3 — the wedge discipline', () {
    final svc = _kt('PsiphonVpnService.kt');

    // Build 2089: the wedge F1-F3 guarded was a call INTO an
    // in-process library (startTunneling never returning).
    // That library is gone — the provider is a sidecar
    // process — so the in-process half of the discipline
    // (the start watchdog, the thread dump, the bounded
    // stop, the single-use process) is REMOVED with it, and
    // what survives is pinned in its new shape below: the
    // heartbeat, the fresh start thread, the published
    // startReturned discriminator (now bracketing the
    // sidecar spawn), and the external watchdog's contract.
    test('F1: the heartbeat is kept, wired to the start '
        'attempt', () {
      expect(svc, contains('psiphon:heartbeat'));
      expect(svc, contains('HEARTBEAT_MS = 2000L'));
      expect(svc, contains('startInFlight = true'));
      // The in-process wedge machinery is gone with the
      // library it watched.
      expect(svc.contains('WEDGE_MS'), isFalse);
      expect(svc.contains('psiphon:start-wedged'), isFalse);
      expect(svc.contains('Thread.getAllStackTraces()'), isFalse);
      expect(svc.contains('watchCoreStart'), isFalse);
      // Build 2091: the library is BACK, so the call the
      // discriminator brackets is startTunneling again —
      // pinned in the next test, not absent here.
      expect(svc.contains('startTunneling'), isTrue);
    });

    test('the startReturned discriminator brackets the '
        'library call again (build 2091 retarget)', () {
      final start = _region(
        svc,
        'private fun startPsiphonTunnel()',
        'private fun rungSeconds',
      );
      expect(start, contains('startReturned = false'));
      expect(start, contains('tunnel.startTunneling(serverEntries)'));
      expect(start, contains('startReturned = true'));
      expect(
        start.indexOf('startReturned = false'),
        lessThan(start.indexOf('tunnel.startTunneling(serverEntries)')),
      );
      expect(
        start.indexOf('tunnel.startTunneling(serverEntries)'),
        lessThan(start.indexOf('startReturned = true')),
      );
    });

    test('F3: the start runs on the single worker; the stop '
        'runs detached; the watch has its own thread '
        '(build 2091, watch re-pointed by build 2124)', () {
      // Build 2091: the library is back, so the start is a
      // library call again — on the single worker (MLM's
      // runOnWorker serialization), never on a fresh thread
      // per attempt. The stop is the detached one now, on
      // the "psiphon-stop" thread, so a wedged stop cannot
      // freeze the worker.
      //
      // Build 2124 SUPERSESSION (recorded, not silent): this
      // test used to pin "the worker keeps the watch" —
      // watchBridge's session-long loop queued on the worker.
      // Device evidence 2026-11-20 (build 2123) proved that
      // shape fatal: the loop occupies the single worker for
      // the whole session, so the quality gate queued behind
      // it in onConnected never ran, routing never activated
      // and a library-connected tunnel never registered. The
      // watch now runs on its own daemon thread; the worker
      // keeps only the ladder moves it serializes.
      expect(svc.contains('"psiphon-start"'), isFalse);
      expect(svc.contains('"psiphon-stop"'), isTrue);
      expect(svc.contains('worker.execute { startTunnel() }'), isTrue);
      final watch = _region(
        svc,
        'private fun watchBridge()',
        'private fun trackUnderlyingNetwork',
      );
      expect(watch, isNot(contains('worker.execute')));
      expect(watch, contains('"psiphon-bridge-watch"'));
      expect(watch, contains('Thread.sleep(5000)'));
    });

    test('F3: the process is NOT single-use any more — a '
        'subprocess stop cannot wedge the host', () {
      expect(svc.contains('stopCoreBounded'), isFalse);
      expect(svc.contains('STOP_BOUND_MS'), isFalse);
      expect(svc.contains('Process.killProcess(Process.myPid())'),
          isFalse);
      // stopTunnel still publishes the stop before the
      // teardown lands (the F3 ordering that mattered).
      final stop = _region(
        svc,
        'private fun stopTunnel()',
        'private fun stopProcesses',
      );
      expect(
        stop.indexOf('running = false'),
        lessThan(stop.indexOf('stopProcesses()')),
      );
    });

    test('F2: the data-root wipe is gone with the AAR data '
        'root it cleaned', () {
      // The wipe's target was the library's data root,
      // accumulated across AAR builds. The sidecar's data
      // lives in filesDir/psiphonbox (PsiphonBoxCore's
      // work dir), created fresh by build 2089; the old
      // psiphon work dir keeps only logs and the published
      // state, so there is nothing to wipe.
      expect(svc.contains('wipeDataRootOnce'), isFalse);
      expect(svc.contains('data_root_wipe_2087.marker'), isFalse);
      final box = _kt('PsiphonBoxCore.kt');
      expect(box, contains('dirName = "psiphonbox"'));
    });

    test('the wedge is published and the parse tolerates a torn file', () {
      expect(svc, contains('.put("wedged", wedged)'));
      expect(svc, contains('internal fun parsePublishedState'));
      expect(svc, contains('"wedged" to false'));
      expect(svc, contains('"wedged" to json.optBoolean("wedged", false)'));
      // A new start clears the record.
      expect(svc, contains('wedged = false'));
    });
  });

  group('Psiphon — the Dart side fails fast on the wedge', () {
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('app/android'), null);
    });

    void mockChannel(Object? Function(String method) respond) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('app/android'),
              (call) async {
        return respond(call.method);
      });
    }

    test('the platform state parses the wedge flag', () async {
      mockChannel((method) {
        if (method == 'psiphonState') {
          return {
            'running': false,
            'connected': false,
            'vpnMode': true,
            'sinceMs': 0,
            'up': 0,
            'down': 0,
            'region': '',
            'clientAddress': '',
            'regions': <String>[],
            'method': '',
            'wedged': true,
          };
        }
        return null;
      });
      final s = await PsiphonPlatform.state();
      expect(s.wedged, isTrue);
      expect(s.running, isFalse);
    });

    test('a missing state reads as stopped, never wedged', () async {
      mockChannel((_) => null);
      final s = await PsiphonPlatform.state();
      expect(s.running, isFalse);
      expect(s.wedged, isFalse);
    });

    test('connect throws the wedge code promptly, in plain words',
        () async {
      mockChannel((method) {
        if (method == 'psiphonState') {
          return {
            'running': true,
            'connected': false,
            'vpnMode': true,
            'sinceMs': 1,
            'up': 0,
            'down': 0,
            'region': '',
            'clientAddress': '',
            'regions': <String>[],
            'method': '',
            'wedged': true,
          };
        }
        return null;
      });
      final c = PsiphonController();
      // A fresh edge stamp skips the pre-connect edge refresh.
      c.settings.edgesTestedAtMs =
          DateTime.now().millisecondsSinceEpoch;
      await expectLater(
        c.connect().timeout(const Duration(seconds: 10)),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'start-wedged',
          ),
        ),
      );
      expect(c.lastError, contains('got stuck while starting'));
      expect(c.connecting, isFalse);
    });
  });

  group('A3 — the phone-shell tests are un-quarantined', () {
    test('widget_test.dart carries no skipped tests', () {
      final src = File('test/widget_test.dart').readAsStringSync();
      expect(_occurrences(src, 'skip: true'), 0);
      expect(src, contains('a phone gets Home and Settings'));
      expect(src, contains('a phone in Persian lays the settings out'));
      expect(src, contains('a phone turns the whole proxy on and off'));
      expect(src, contains('a phone says connecting until a test passes'));
    });

    test('the Mozilla core logs are reachable in the Ember shell', () {
      final settings = _dart('ui/ember/ember_settings.dart');
      expect(settings, contains('LogsPage(core: widget.core)'));
    });
  });
}
