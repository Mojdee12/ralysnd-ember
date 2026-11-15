// Build 2068 — crash capture: the recorder, the two 2067
// holes, the service nets, and the breadcrumb trail.
//
// Owner device verdict on 2067 (2026-11-14 ~22:44 Tehran):
// STILL crashes at the Psiphon tap, psiphon.log still empty.
// And ~22:52: ONLY Psiphon crashes — Xray connects fine on the
// same fresh install, so the shared consent/FGS/notification
// machinery the 2066 diagnosis ranked first is cleared; the
// fault is inside Psiphon's own start steps, and it leaves no
// trace in any log Ember writes. Two blind rounds failed
// because the death is invisible from inside the app: the 2067
// guards catch Exception only (a java.lang.Error walks
// through), askForNotifications() runs unguarded ahead of
// them, and a native abort runs no Java code at all.
//
// This build's primary job is evidence. A default
// uncaught-exception handler (CrashLog, installed by
// EmberApplication before any component runs) records every
// uncaught throwable to filesDir/crash.log and chains to the
// system handler, so behaviour is unchanged but no death is
// silent again; the two 2067 holes are closed at Throwable
// level with the caught fatals recorded the same way; the VPN
// services' onStartCommand nets write a caught start failure
// straight into the engine's own session log; and synchronous
// breadcrumbs mark every stage boundary of the Psiphon start
// path (with a coarse Xray trail as the healthy control), so
// the last breadcrumb in the owner's next paste names the
// dying step even if the death is a native abort.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/psiphon/psiphon_controller.dart';
import 'package:firefox_vpn/xray/xray_controller.dart';

String ktSrc(String rel) =>
    File('android/app/src/main/kotlin/com/ralysnd/ember/$rel')
        .readAsStringSync();

String dartSrc(String rel) => File('lib/$rel').readAsStringSync();

/// The source segment of one `when` branch in the method-call
/// handler: from its method literal to the next branch marker.
String branchOf(String source, String method, String nextMarker) {
  final start = source.indexOf('"$method" ->');
  expect(start, isNonNegative, reason: 'branch "$method" exists');
  final end = source.indexOf(nextMarker, start);
  expect(end, isNonNegative, reason: 'branch "$method" is bounded');
  return source.substring(start, end);
}

/// The source from one marker to the next.
String segmentOf(String source, String from, String to) {
  final start = source.indexOf(from);
  expect(start, isNonNegative, reason: '"$from" exists');
  final end = source.indexOf(to, start);
  expect(end, isNonNegative, reason: '"$to" bounds "$from"');
  return source.substring(start, end);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final mainActivity = ktSrc('MainActivity.kt');
  final crashLog = ktSrc('CrashLog.kt');
  final psiphonService = ktSrc('PsiphonVpnService.kt');
  final xrayService = ktSrc('XrayVpnService.kt');
  final lanternService = ktSrc('LanternVpnService.kt');

  group('the crash recorder: installed first, chained, bounded', () {
    test('CrashLog carries the handler, the chain, and the bound', () {
      expect(crashLog.contains('setDefaultUncaughtExceptionHandler'), isTrue);
      // The replaced handler is chained to, so the system's
      // behaviour (its crash record, the process death) is
      // unchanged — only the silence ends.
      expect(
        crashLog.contains('previous.uncaughtException(thread, throwable)'),
        isTrue,
      );
      expect(crashLog.contains('const val FILE_NAME = "crash.log"'), isTrue);
      // Bounded: ~256 KB, rotated to .old by plain file IO.
      expect(crashLog.contains('256L * 1024L'), isTrue);
      expect(crashLog.contains('file.renameTo(old)'), isTrue);
      expect(crashLog.contains('FileOutputStream(file, true)'), isTrue);
      // The record shape: pure formatter + bounded append.
      expect(crashLog.contains('fun formatRecord('), isTrue);
      expect(crashLog.contains('fun appendBounded('), isTrue);
      expect(crashLog.contains('==== ember crash record ===='), isTrue);
      expect(crashLog.contains('throwable.printStackTrace(printer)'), isTrue);
      // Install is idempotent, so no component can double-wrap
      // the chain.
      expect(crashLog.contains('if (installed) return'), isTrue);
    });

    test('the Application installs it before any component, and '
        'MainActivity confirms it', () {
      final app = ktSrc('EmberApplication.kt');
      expect(app.contains('class EmberApplication : Application()'), isTrue);
      expect(app.contains('override fun attachBaseContext'), isTrue);
      expect(app.contains('CrashLog.install(base)'), isTrue);
      expect(app.contains('CrashLog.install(this)'), isTrue);
      final manifest =
          File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
      expect(manifest.contains('android:name=".EmberApplication"'), isTrue);
      final onCreate = segmentOf(
        mainActivity,
        'override fun onCreate(savedInstanceState: Bundle?)',
        'override fun onConfigurationChanged',
      );
      expect(onCreate.contains('CrashLog.install(this)'), isTrue);
    });
  });

  group('2067 hole 1: the start guards caught only Exception — a '
      'java.lang.Error walked through', () {
    test('startVpnGuarded catches Throwable and records it', () {
      final guard = segmentOf(
        mainActivity,
        'fun startVpnGuarded(',
        'fun runDeferredVpnStart(',
      );
      expect(guard.contains('catch (e: Throwable)'), isTrue);
      expect(guard.contains('catch (e: Exception)'), isFalse);
      expect(guard.contains('CrashLog.append(this, "startVpnGuarded", e)'),
          isTrue);
      // The refusal contract the Dart side surfaces is unchanged.
      expect(guard.contains('"vpn_start_refused"'), isTrue);
    });

    test('runDeferredVpnStart catches Throwable and records it', () {
      final deferred = segmentOf(
        mainActivity,
        'fun runDeferredVpnStart(',
        'override fun onActivityResult',
      );
      expect(deferred.contains('catch (e: Throwable)'), isTrue);
      expect(deferred.contains('catch (e: Exception)'), isFalse);
      expect(
        deferred.contains('CrashLog.append(this, "runDeferredVpnStart", e)'),
        isTrue,
      );
    });
  });

  group('2067 hole 2: askForNotifications ran unguarded ahead of '
      'the guard, first executing exactly at the fatal tap', () {
    test('askForNotifications is guarded at Throwable level and '
        'still asks', () {
      final ask = segmentOf(
        mainActivity,
        'fun askForNotifications()',
        // It is the file's last function.
        '\n}\n',
      );
      expect(ask.contains('try {'), isTrue);
      expect(ask.contains('catch (e: Throwable)'), isTrue);
      expect(
        ask.contains('CrashLog.append(this, "askForNotifications", e)'),
        isTrue,
      );
      expect(ask.contains('requestPermissions('), isTrue);
      expect(ask.contains('POST_NOTIFICATIONS'), isTrue);
    });
  });

  group('service nets: a caught start failure writes itself into '
      'the engine log and stops the service', () {
    test('PsiphonVpnService ACTION_START is netted into '
        'psiphon.log + crash.log', () {
      final branch = segmentOf(
        psiphonService,
        'ACTION_START -> {',
        'else -> {',
      );
      expect(branch.contains('catch (e: Throwable)'), isTrue);
      expect(branch.contains('CrashLog.appendToFile('), isTrue);
      expect(branch.contains('File(workDir(this), "psiphon.log")'), isTrue);
      expect(
        branch.contains(
            'CrashLog.append(this, "PsiphonVpnService.onStartCommand", e)'),
        isTrue,
      );
      expect(branch.contains('stopSelf()'), isTrue);
      expect(branch.contains('return START_NOT_STICKY'), isTrue);
      // The net wraps the foreground start itself.
      expect(branch.contains('startInForeground()'), isTrue);
    });

    test('XrayVpnService onStartCommand is netted into xray.log '
        '+ crash.log', () {
      expect(xrayService.contains('fun onStartCommandGuarded('), isTrue);
      final net = segmentOf(
        xrayService,
        'override fun onStartCommand(',
        'fun onStartCommandGuarded(',
      );
      expect(net.contains('catch (e: Throwable)'), isTrue);
      expect(net.contains('File(workDir(this), "xray.log")'), isTrue);
      expect(
        net.contains('CrashLog.append(this, "XrayVpnService.onStartCommand", e)'),
        isTrue,
      );
      expect(net.contains('stopSelf()'), isTrue);
    });

    test('LanternVpnService onStartCommand is netted into '
        'crash.log', () {
      expect(lanternService.contains('fun onStartCommandGuarded('), isTrue);
      final net = segmentOf(
        lanternService,
        'override fun onStartCommand(',
        'fun onStartCommandGuarded(',
      );
      expect(net.contains('catch (e: Throwable)'), isTrue);
      expect(
        net.contains('CrashLog.append(this, "LanternVpnService.onStartCommand", e)'),
        isTrue,
      );
      expect(net.contains('stopSelf()'), isTrue);
    });
  });

  group('breadcrumbs: the last line before a death names the '
      'dying step', () {
    test('the breadcrumb writer is one synchronous bounded line',
        () {
      expect(crashLog.contains('fun breadcrumb('), isTrue);
      expect(crashLog.contains('fun formatBreadcrumb('), isTrue);
      expect(crashLog.contains('[breadcrumb]'), isTrue);
    });

    test('every Psiphon stage boundary in the handler carries '
        'its marker, in path order', () {
      final branch =
          branchOf(mainActivity, 'psiphonSetOn', '"psiphonStop"');
      const tags = [
        'psiphon:handler-entered',
        'psiphon:notifications-returned',
        'psiphon:start-invoked',
        'psiphon:start-returned',
      ];
      var at = -1;
      for (final tag in tags) {
        final next = branch.indexOf(tag);
        expect(next, greaterThan(at), reason: '$tag in path order');
        at = next;
      }
      // Step 3 rides through the guard's opt-in prefix.
      expect(branch.contains('breadcrumbPrefix = "psiphon"'), isTrue);
    });

    test('the guard drops the prepare breadcrumb for the named '
        'caller only', () {
      final guard = segmentOf(
        mainActivity,
        'fun startVpnGuarded(',
        'fun runDeferredVpnStart(',
      );
      expect(guard.contains('breadcrumbPrefix: String? = null'), isTrue);
      expect(guard.contains(':prepare-returned '), isTrue);
      expect(guard.contains('consent=intent'), isTrue);
      expect(guard.contains('consent=not-needed'), isTrue);
    });

    test('the deferred path is breadcrumbed: receipt with the '
        'resultCode, and the invoked/returned pair', () {
      final receipt = segmentOf(
        mainActivity,
        'if (requestCode != VPN_REQUEST) return',
        'pendingOpenVpnOn?.let',
      );
      expect(
        receipt.contains('vpn:onActivityResult resultCode='),
        isTrue,
      );
      final deferred = segmentOf(
        mainActivity,
        'fun runDeferredVpnStart(',
        'override fun onActivityResult',
      );
      expect(deferred.contains('vpn:deferred-start-invoked'), isTrue);
      expect(deferred.contains('vpn:deferred-start-returned'), isTrue);
    });

    test('the Psiphon service steps are breadcrumbed', () {
      for (final tag in [
        'psiphon:service-onCreate',
        'psiphon:onStartCommand-start',
        'psiphon:startInForeground-returned',
        'psiphon:startTunnel-entered',
        'psiphon:openLog-completed',
      ]) {
        expect(psiphonService.contains(tag), isTrue, reason: tag);
      }
      // The final step sits at the END of openLog — it only
      // lands when the session log is actually open.
      final openLog = segmentOf(
        psiphonService,
        'private fun openLog',
        'private fun logLine',
      );
      expect(openLog.contains('psiphon:openLog-completed'), isTrue);
      expect(
        openLog.indexOf('psiphon:openLog-completed'),
        greaterThan(openLog.indexOf('psiphon session')),
      );
    });

    test('the Xray control trail is complete: handler, start, '
        'service, tunnel', () {
      final branch = branchOf(mainActivity, 'xraySetOn', '"xrayStop"');
      expect(branch.contains('xray:handler-entered'), isTrue);
      expect(branch.contains('xray:start-invoked'), isTrue);
      expect(xrayService.contains('xray:onStartCommand-start'), isTrue);
      expect(xrayService.contains('xray:startTunnel-entered'), isTrue);
    });
  });

  group('viewers: crash.log is a section in both log viewers', () {
    test('both readLogs loops include crash.log from filesDir',
        () {
      final psiphon = dartSrc('psiphon/psiphon_controller.dart');
      expect(
        psiphon.contains("'psiphon.log', 'tunlink.log', 'crash.log'"),
        isTrue,
      );
      expect(psiphon.contains("dir.parent.path"), isTrue);
      final xray = dartSrc('xray/xray_controller.dart');
      expect(
        xray.contains("'xray.log', 'tunlink.log', 'crash.log'"),
        isTrue,
      );
      expect(xray.contains("dir.parent.path"), isTrue);
    });

    group('behaviour (real files, mocked dataDir)', () {
      late Directory tmp;
      late PsiphonController psiphon;
      late XrayController xray;

      setUp(() async {
        tmp = await Directory.systemTemp.createTemp('ember2068');
        final filesDir = Directory('${tmp.path}/files');
        await Directory('${filesDir.path}/core').create(recursive: true);
        await Directory('${filesDir.path}/psiphon').create(recursive: true);
        await Directory('${filesDir.path}/xray').create(recursive: true);
        await File('${filesDir.path}/psiphon/psiphon.log')
            .writeAsString('PSIPHON-SESSION-LINE\n');
        await File('${filesDir.path}/xray/xray.log')
            .writeAsString('XRAY-LINE\n');
        await File('${filesDir.path}/crash.log').writeAsString(
          '2026-11-14 22:52:01.000 +0330 [breadcrumb] '
          'psiphon:start-invoked\n'
          '==== ember crash record ====\n'
          'throwable: java.lang.ExceptionInInitializerError: x\n',
        );
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
        psiphon = PsiphonController();
        xray = XrayController();
      });

      tearDown(() async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
          const MethodChannel('app/android'),
          null,
        );
        psiphon.dispose();
        xray.dispose();
        await tmp.delete(recursive: true);
      });

      test('the Psiphon viewer shows the crash.log section with '
          'its content', () async {
        final out = await psiphon.readLogs();
        expect(out, contains('—— psiphon.log ——'));
        expect(out, contains('PSIPHON-SESSION-LINE'));
        expect(out, contains('—— crash.log ——'));
        expect(out, contains('psiphon:start-invoked'));
        expect(out, contains('ExceptionInInitializerError'));
        // The never-written bridge file still reads as (empty).
        expect(out, contains('—— tunlink.log ——'));
        expect(out, contains('(empty)'));
        // crash.log comes last: the newest evidence ends the page.
        expect(
          out.indexOf('—— crash.log ——'),
          greaterThan(out.indexOf('—— tunlink.log ——')),
        );
      });

      test('the Xray viewer shows the same crash.log section',
          () async {
        final out = await xray.readLogs();
        expect(out, contains('—— xray.log ——'));
        expect(out, contains('XRAY-LINE'));
        expect(out, contains('—— crash.log ——'));
        expect(out, contains('psiphon:start-invoked'));
      });
    });
  });
}
