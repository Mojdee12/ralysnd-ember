// Build 2070 — fix round 1 from the full review
// (full-review-2026-11-15.md §9 items 1, 3, 5; §5.1, §4 row 7,
// §3.4). Owner's order: fix all the app's problems under the
// standing no-regression rule — nothing that works may break.
// Psiphon is parked by his order and untouched by this build.
//
// Item 1 (§5.1, the Psiphon crash class): the 2067–2068
// hardening covered the synchronous start handoffs, Psiphon's
// async body, and the Xray/Lantern onStartCommand wrappers —
// but the same escape shape survived in Mozilla's CoreService
// (no catch in onStartCommand at all, Exception-only around
// the gomobile calls, a raw-exception Toast), in the async
// start bodies of Xray (four variants + the rotate thread),
// Lantern (worker body) and OpenVPN (no outer net at all, its
// worker catch Exception-only). Every one of those paths now
// catches Throwable and records into crash.log (and the
// engine's own log where one exists at that point), failing
// gracefully through the same teardown the Exception path
// always ran. MainActivity's Mozilla branch also moved onto
// the shared startVpnGuarded (review §9 item 1), now that
// CoreService.turnOn records-and-rethrows instead of
// completing the channel result itself. The nets only ADD
// capture+record: the success path of every start is byte-for-
// byte the old behaviour, which is what these pins hold.
//
// Item 3 (§4 row 7): the VLESS parser no longer manufactures
// a 'chrome' fingerprint for tls/reality links without an fp
// parameter (the fill made every imported profile read as
// user-pinned, so the shipped uTLS rotation could never apply
// to it), and a one-time migration clears the stored fill —
// scoped to exactly the population the parser could have
// filled — so rotation reaches the existing library too.
//
// Item 5 (§3.4): engine-start snackbars no longer show raw
// exception text (the detail goes to the diagnostics journal /
// lastError / logs instead); the Xray log viewer gains the
// Copy-All button it was missing; the Lantern viewer gains
// the crash.log section its service has written to since
// 2068; and Clear on every log viewer now empties every file
// that viewer displays, the shared crash.log included.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/lantern/lantern_controller.dart';
import 'package:firefox_vpn/psiphon/psiphon_controller.dart';
import 'package:firefox_vpn/xray/config_builder.dart';
import 'package:firefox_vpn/xray/link_parser.dart';
import 'package:firefox_vpn/xray/xray_controller.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

String ktSrc(String rel) =>
    File('android/app/src/main/kotlin/com/ralysnd/ember/$rel')
        .readAsStringSync();

String dartSrc(String rel) => File('lib/$rel').readAsStringSync();

/// The source from one marker to the next.
String segmentOf(String source, String from, String to) {
  final start = source.indexOf(from);
  expect(start, isNonNegative, reason: '"$from" exists');
  final end = source.indexOf(to, start);
  expect(end, isNonNegative, reason: '"$to" bounds "$from"');
  return source.substring(start, end);
}

/// The source segment of one `when` branch in the method-call
/// handler: from its method literal to the next branch marker.
String branchOf(String source, String method, String nextMarker) {
  final start = source.indexOf('"$method" ->');
  expect(start, isNonNegative, reason: 'branch "$method" exists');
  final end = source.indexOf(nextMarker, start);
  expect(end, isNonNegative, reason: 'branch "$method" is bounded');
  return source.substring(start, end);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final coreService = ktSrc('CoreService.kt');
  final xrayService = ktSrc('XrayVpnService.kt');
  final lanternService = ktSrc('LanternVpnService.kt');
  final openVpnService = ktSrc('OpenVpnService.kt');
  final mainActivity = ktSrc('MainActivity.kt');

  group('item 1 — Throwable nets: Mozilla (CoreService)', () {
    test('onStartCommand is a Throwable net over a guarded body', () {
      final net = segmentOf(
        coreService,
        'override fun onStartCommand',
        'private fun onStartCommandGuarded',
      );
      expect(net.contains('catch (e: Throwable)'), isTrue);
      expect(
        net.contains('CrashLog.append(this, "CoreService.onStartCommand", e)'),
        isTrue,
      );
      expect(net.contains('START_NOT_STICKY'), isTrue);
      expect(net.contains('onStartCommandGuarded(intent, flags, startId)'),
          isTrue);
    });

    test('startTunnel catches Throwable, records, and the raw '
        'Toast is gone from the whole service', () {
      final body = segmentOf(
        coreService,
        'private fun startTunnel',
        'private fun applyApps',
      );
      expect(body.contains('catch (e: Throwable)'), isTrue);
      expect(
        body.contains('CrashLog.append(this, "CoreService.startTunnel", e)'),
        isTrue,
      );
      // The raw-exception Toast was the owner's screen showing
      // a gomobile error verbatim; the service may not Toast
      // anymore (the word survives only in comments).
      expect(coreService.contains('Toast.makeText'), isFalse);
      expect(coreService.contains('android.widget.Toast'), isFalse);
    });

    test('turnOn records and rethrows; startCore records at '
        'Throwable level', () {
      final turnOn = segmentOf(
        coreService,
        'fun turnOn(context: Context)',
        'fun turnOff(context: Context)',
      );
      expect(
        turnOn.contains('CrashLog.append(context, "CoreService.turnOn", e)'),
        isTrue,
      );
      expect(turnOn.contains('throw e'), isTrue);
      final startCore = segmentOf(
        coreService,
        'fun startCore(context: Context, on: Boolean)',
        'private fun importFromComputer',
      );
      expect(startCore.contains('catch (e: Throwable)'), isTrue);
      expect(
        startCore.contains('"CoreService.startCore"'),
        isTrue,
      );
    });

    test('MainActivity routes the Mozilla branch through '
        'startVpnGuarded with a parked start slot', () {
      final branch = branchOf(mainActivity, 'setOn', '"isRunning"');
      expect(branch.contains('startVpnGuarded('), isTrue);
      expect(
        branch.contains('start = { CoreService.turnOn(this) }'),
        isTrue,
      );
      expect(mainActivity.contains('private var pendingOnStart'), isTrue);
      // The deferred start runs behind the shared guard, and
      // the old self-replying helper (and its "start_failed"
      // channel code) is gone.
      expect(
        mainActivity.contains('runDeferredVpnStart(result, start)'),
        isTrue,
      );
      expect(mainActivity.contains('fun turnOn(result'), isFalse);
      expect(
        mainActivity.contains('result.error("start_failed"'),
        isFalse,
      );
    });
  });

  group('item 1 — Throwable nets: Xray async bodies', () {
    test('all four worker dispatch sites route escapes through '
        'startFailed', () {
      for (final name in [
        'startTunnel',
        'startWarpTunnel',
        'startSocksTunnel',
      ]) {
        expect(
          xrayService.contains('startFailed("XrayVpnService.$name", e)'),
          isTrue,
          reason: '$name dispatch is netted',
        );
      }
      // Build 2100 (W-WG2, named reason): startAwgTunnel moved
      // to AwgVpnService.kt — its dispatch is netted there, with
      // the new service's name in the tag.
      // Build 2104: the AWG engine is WgTunnelEngine now — no
      // service, no worker dispatch: the start is one coroutine
      // body whose own Throwable net (pinned in the next test)
      // is the whole dispatch story.
      final engine = ktSrc('WgTunnelEngine.kt');
      expect(
        engine.contains('CrashLog.append(appContext, "WgTunnelEngine.start", e)'),
        isTrue,
        reason: 'the engine start records escapes to crash.log',
      );
    });

    test('all four start bodies catch Throwable and record', () {
      for (final (logLine, label) in [
        ('the V2Ray tunnel did not start', 'startTunnel'),
        ('the WARP tunnel did not start', 'startWarpTunnel'),
        ('the SOCKS-engine tunnel did not start', 'startSocksTunnel'),
      ]) {
        final at = xrayService.indexOf(logLine);
        expect(at, isNonNegative, reason: '$logLine exists');
        final window = xrayService.substring(
          at - 1200 < 0 ? 0 : at - 1200,
          at,
        );
        expect(
          window.contains('catch (e: Throwable)'),
          isTrue,
          reason: '$label outer catch is Throwable',
        );
        expect(
          window.contains(
            'CrashLog.append(this, "XrayVpnService.$label", e)',
          ),
          isTrue,
          reason: '$label records to crash.log',
        );
      }
      // Build 2100 (W-WG2, named reason): the AWG start body
      // moved to AwgVpnService.kt — same Throwable net, new
      // service name in the tag.
      // Build 2104: the start body is WgTunnelEngine.start's
      // coroutine — the net and the crash.log record live
      // there now, under the engine's name.
      final engine = ktSrc('WgTunnelEngine.kt');
      expect(
        engine.contains('catch (e: Throwable)'),
        isTrue,
        reason: 'the engine start body catch is Throwable',
      );
      expect(
        engine.contains(
          'CrashLog.append(appContext, "WgTunnelEngine.start", e)',
        ),
        isTrue,
        reason: 'the engine start records to crash.log',
      );
    });

    test('startFailed records into xray.log and crash.log, then '
        'fails under its own guard', () {
      final helper = segmentOf(
        xrayService,
        'private fun startFailed(',
        // Build 2095 (third-pass audit 3-1): fail() gained
        // a reason parameter — the segment needle follows.
        'private fun fail(reason: String = "")',
      );
      expect(helper.contains('CrashLog.appendToFile'), isTrue);
      expect(helper.contains('"xray.log"'), isTrue);
      expect(helper.contains('CrashLog.append(this, where, e)'), isTrue);
      expect(helper.contains('fail()'), isTrue);
      expect(helper.contains('catch (e2: Throwable)'), isTrue);
    });

    test('the rotate thread is netted and rotateCore catches '
        'Throwable', () {
      final dispatch = segmentOf(
        xrayService,
        'ACTION_ROTATE ->',
        'ACTION_START ->',
      );
      expect(dispatch.contains('catch (e: Throwable)'), isTrue);
      expect(
        dispatch.contains('"XrayVpnService.rotateCore"'),
        isTrue,
      );
      final body = segmentOf(
        xrayService,
        'private fun rotateCore(',
        'private fun isValidConfigJson',
      );
      expect(body.contains('catch (e: Throwable)'), isTrue);
      expect(
        body.contains('CrashLog.append(this, "XrayVpnService.rotateCore", e)'),
        isTrue,
      );
    });
  });

  group('item 1 — Throwable nets: Lantern + OpenVPN', () {
    test('Lantern worker body catches Throwable and records', () {
      final body = segmentOf(
        lanternService,
        'private fun onStartCommandGuarded',
        'private fun startTunnel',
      );
      expect(body.contains('catch (e: Throwable)'), isTrue);
      expect(
        body.contains('"LanternVpnService.startTunnel"'),
        isTrue,
      );
    });

    test('OpenVpnService gained the onStartCommand net and a '
        'Throwable worker catch', () {
      final net = segmentOf(
        openVpnService,
        'override fun onStartCommand',
        'private fun onStartCommandGuarded',
      );
      expect(net.contains('catch (e: Throwable)'), isTrue);
      expect(
        net.contains('CrashLog.append(this, "OpenVpnService.onStartCommand", e)'),
        isTrue,
      );
      // The service's own unbuffered trail gets a mark too —
      // openvpn.log may not exist yet at this point.
      expect(net.contains('OpenVpnTrace.mark'), isTrue);
      final body = segmentOf(
        openVpnService,
        'private fun onStartCommandGuarded',
        'private fun startTunnel',
      );
      expect(body.contains('catch (e: Throwable)'), isTrue);
      expect(
        body.contains('"OpenVpnService.startTunnel"'),
        isTrue,
      );
    });

    test('the parked Psiphon engine is untouched: its 2068/2069 '
        'machinery stands as shipped', () {
      final psiphon = ktSrc('PsiphonVpnService.kt');
      expect(psiphon.contains('psiphon:openLog-completed'), isTrue);
      expect(psiphon.contains('override fun loadLibrary'), isFalse);
    });
  });

  group('item 3 — uTLS rotation reaches imported profiles', () {
    const tlsLink =
        'vless://11111111-1111-1111-1111-111111111111@example.com:443'
        '?security=tls&sni=example.com#T';
    const realityLink =
        'vless://11111111-1111-1111-1111-111111111111@example.com:443'
        '?security=reality&sni=example.com'
        '&pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&sid=abcd#R';

    test('the parser leaves an absent fp empty (tls + reality)', () {
      expect(parseLink(tlsLink)!.fingerprint, '');
      expect(parseLink(realityLink)!.fingerprint, '');
      // And the fill is gone from the source, not just bypassed.
      expect(
        dartSrc('xray/link_parser.dart')
            .contains("p.fingerprint = 'chrome'"),
        isFalse,
      );
    });

    test('the parser keeps an explicit fp verbatim', () {
      const fpLink =
          'vless://11111111-1111-1111-1111-111111111111@example.com:443'
          '?security=tls&sni=example.com&fp=firefox#T';
      expect(parseLink(fpLink)!.fingerprint, 'firefox');
      // An explicit fp=chrome also stays at parse time — only
      // the one-time migration touches STORED profiles, so a
      // link the owner deliberately shares with fp=chrome
      // imports exactly as written.
      const fpChromeLink =
          'vless://11111111-1111-1111-1111-111111111111@example.com:443'
          '?security=tls&sni=example.com&fp=chrome#T';
      expect(parseLink(fpChromeLink)!.fingerprint, 'chrome');
    });

    test('rotation applies to a freshly imported VLESS profile',
        () {
      final p = parseLink(tlsLink)!;
      final s = XraySettings()
        ..rotateTlsFingerprint = true
        ..tlsFingerprintIndex = 1;
      final cfg = jsonDecode(buildTunnelConfig(p, s))
          as Map<String, dynamic>;
      final out = (cfg['outbounds'] as List).first
          as Map<String, dynamic>;
      final tls = (out['streamSettings']
          as Map<String, dynamic>)['tlsSettings'] as Map<String, dynamic>;
      expect(tls['fingerprint'], 'firefox');
    });

    test('a user-set fingerprint is never rotated', () {
      final p = parseLink(tlsLink)!..fingerprint = 'safari';
      final s = XraySettings()
        ..rotateTlsFingerprint = true
        ..tlsFingerprintIndex = 1;
      expect(effectiveFingerprint(p, s, rotationIndex: 1), 'safari');
      final cfg = jsonDecode(buildTunnelConfig(p, s))
          as Map<String, dynamic>;
      final out = (cfg['outbounds'] as List).first
          as Map<String, dynamic>;
      final tls = (out['streamSettings']
          as Map<String, dynamic>)['tlsSettings'] as Map<String, dynamic>;
      expect(tls['fingerprint'], 'safari');
    });

    test('the migration clears exactly the parser-filled '
        'population', () {
      // SUPERSEDED by build 2149 (diagnosis D4): the
      // clearing is retired — stored data cannot
      // distinguish an explicit fp=chrome from the old
      // parser fill, and the explicit population was the
      // one being hurt (DPI-killed on strict networks).
      // From 2149 the migration clears NOTHING and every
      // stored fingerprint is left as-is.
      Profile prof(Protocol protocol, String security, String fp) =>
          Profile(
            id: 'x',
            protocol: protocol,
            address: 'example.com',
            port: 443,
            uuidOrPassword: 'u',
            security: security,
            fingerprint: fp,
          );
      final profiles = [
        prof(Protocol.vless, 'tls', 'chrome'),
        prof(Protocol.vless, 'reality', 'chrome'),
        prof(Protocol.vless, 'tls', 'firefox'),
        prof(Protocol.vless, 'tls', ''),
        prof(Protocol.trojan, 'tls', 'chrome'),
        prof(Protocol.vless, '', 'chrome'),
      ];
      final cleared = clearParserDefaultFingerprints(profiles);
      expect(cleared, 0);
      expect(profiles[0].fingerprint, 'chrome');
      expect(profiles[1].fingerprint, 'chrome');
      expect(profiles[2].fingerprint, 'firefox');
      expect(profiles[3].fingerprint, '');
      expect(profiles[4].fingerprint, 'chrome');
      expect(profiles[5].fingerprint, 'chrome');
    });

    test('the migration flag round-trips through settings JSON',
        () {
      final fresh = XraySettings();
      expect(fresh.fingerprintDefaultMigrated, isFalse);
      final stored = XraySettings.fromJson(
        (jsonDecode(jsonEncode(fresh.toJson())) as Map)
            .cast<String, dynamic>(),
      );
      expect(stored.fingerprintDefaultMigrated, isFalse);
      fresh.fingerprintDefaultMigrated = true;
      final stored2 = XraySettings.fromJson(
        (jsonDecode(jsonEncode(fresh.toJson())) as Map)
            .cast<String, dynamic>(),
      );
      expect(stored2.fingerprintDefaultMigrated, isTrue);
    });
  });

  group('item 5 — diagnostics + error surfaces', () {
    test('no engine-start surface shows a raw exception anymore',
        () {
      for (final rel in [
        'ui/ember/ember_shell.dart',
        'ui/ember/profile_editor.dart',
        'ui/ember/wireguard_pages.dart',
        'ui/ember/aether_pages.dart',
      ]) {
        expect(
          dartSrc(rel).contains(r"Text('$e')"),
          isFalse,
          reason: '$rel has no raw-exception snackbar',
        );
      }
    });

    test('the Xray log viewer has Copy All', () {
      final page = dartSrc('ui/ember/xray_logs_page.dart');
      // PIN UPDATED by build 2119 (audit F-20): the copy
      // rides the self-clearing clipboard helper now —
      // the raw Clipboard.setData call this pin used to
      // require was the finding. The intent stands: the
      // viewer copies its whole text on one tap.
      expect(page.contains('copySensitive(text)'), isTrue);
      expect(page.contains('l.copyAll'), isTrue);
      expect(page.contains('l.logsCopied'), isTrue);
    });

    test('viewer file semantics: Lantern shows crash.log; every '
        'Clear empties what its viewer displays', () {
      final lantern = dartSrc('lantern/lantern_controller.dart');
      final lanternRead = segmentOf(
        lantern,
        'Future<String> readLogs()',
        'Future<void> clearLogs()',
      );
      expect(lanternRead.contains('crash.log'), isTrue);
      final lanternClear = segmentOf(
        lantern,
        'Future<void> clearLogs()',
        '@override',
      );
      expect(lanternClear.contains('crash.log'), isTrue);

      final xray = dartSrc('xray/xray_controller.dart');
      final xrayClear = segmentOf(
        xray,
        'Future<void> clearLogs()',
        '\n}\n',
      );
      expect(xrayClear.contains("'diagnostics.log'"), isTrue);
      expect(xrayClear.contains('crash.log'), isTrue);

      final psiphon = dartSrc('psiphon/psiphon_controller.dart');
      final psiphonClear = segmentOf(
        psiphon,
        'Future<void> clearLogs()',
        '\n}\n',
      );
      expect(psiphonClear.contains('crash.log'), isTrue);
    });

    group('behaviour (real files, mocked dataDir)', () {
      late Directory tmp;
      late XrayController xray;
      late PsiphonController psiphon;
      late LanternController lantern;

      setUp(() async {
        tmp = await Directory.systemTemp.createTemp('ember2070');
        final filesDir = Directory('${tmp.path}/files');
        await Directory('${filesDir.path}/core').create(recursive: true);
        await Directory('${filesDir.path}/xray').create(recursive: true);
        await Directory('${filesDir.path}/psiphon')
            .create(recursive: true);
        await Directory('${filesDir.path}/lantern')
            .create(recursive: true);
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
          const MethodChannel('app/android'),
          (call) async {
            if (call.method == 'dataDir') {
              return '${filesDir.path}/core';
            }
            return null;
          },
        );
        xray = XrayController();
        psiphon = PsiphonController();
        lantern = LanternController();
      });

      tearDown(() async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
          const MethodChannel('app/android'),
          null,
        );
        xray.dispose();
        psiphon.dispose();
        lantern.dispose();
        await tmp.delete(recursive: true);
      });

      test('the Lantern viewer renders the crash.log section '
          'with its content', () async {
        final filesDir = Directory('${tmp.path}/files');
        await File('${filesDir.path}/crash.log').writeAsString(
          '==== ember crash record ====\n'
          'throwable: java.lang.ExceptionInInitializerError: x\n',
        );
        final out = await lantern.readLogs();
        expect(out, contains('══ crash.log ══'));
        expect(out, contains('ExceptionInInitializerError'));
        // crash.log comes last in this viewer too.
        expect(
          out.indexOf('══ crash.log ══'),
          greaterThan(out.indexOf('══ tunlink.log ══')),
        );
      });

      test('the Lantern viewer reads a missing crash.log as '
          '(none yet)', () async {
        final out = await lantern.readLogs();
        final section =
            out.substring(out.indexOf('══ crash.log ══'));
        expect(section, contains('(none yet)'));
      });

      test('Xray Clear empties diagnostics, both core logs and '
          'the shared crash.log', () async {
        final filesDir = Directory('${tmp.path}/files');
        final files = [
          File('${filesDir.path}/xray/diagnostics.log'),
          File('${filesDir.path}/xray/xray.log'),
          File('${filesDir.path}/xray/tunlink.log'),
          File('${filesDir.path}/crash.log'),
        ];
        for (final f in files) {
          await f.writeAsString('SENTINEL\n');
        }
        await xray.clearLogs();
        for (final f in files) {
          expect(await f.readAsString(), '', reason: '${f.path} cleared');
        }
      });

      test('Psiphon Clear empties the shared crash.log too',
          () async {
        final filesDir = Directory('${tmp.path}/files');
        final crash = File('${filesDir.path}/crash.log');
        await crash.writeAsString('SENTINEL\n');
        await File('${filesDir.path}/psiphon/psiphon.log')
            .writeAsString('SENTINEL\n');
        await psiphon.clearLogs();
        expect(await crash.readAsString(), '');
        expect(
          await File('${filesDir.path}/psiphon/psiphon.log')
              .readAsString(),
          '',
        );
      });

      test('Lantern Clear deletes its own logs and empties the '
          'shared crash.log', () async {
        // Build 2129: the engine's own logs are the gomobile
        // core's logDir files (filesDir/lantern/logs/*) — the
        // CLI era's lantern-stdout.log / tunlink.log are gone.
        final filesDir = Directory('${tmp.path}/files');
        final own = File('${filesDir.path}/lantern/logs/core.log');
        await own.create(recursive: true);
        await own.writeAsString('SENTINEL\n');
        final crash = File('${filesDir.path}/crash.log');
        await crash.writeAsString('SENTINEL\n');
        await lantern.clearLogs();
        expect(await own.exists(), isFalse);
        expect(await crash.readAsString(), '');
      });
    });
  });
}
