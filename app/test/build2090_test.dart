/// Build 2090 gates — the Psiphon bootstrap floor and the
/// visible core (the 2089 no-connect diagnosis).
///
/// Build 2089's sidecar ran and lived on the owner's phone
/// but never connected: the fork imported zero embedded
/// server entries and the remote-list download — the only
/// discovery path left — cannot complete on his network;
/// and the failure was invisible because the box's log
/// discarded the core's notices into files nothing read.
/// Pinned here:
///   1. The watchdog's record-only establishment decision
///      (evaluateEstablishment): fires once, only for a
///      running, returned, unconnected, unwedged attempt
///      past the bound; never before it; never when the
///      start call is still inside the provider (that is
///      the kill branch's territory).
///   2. The Kotlin wiring: the service extracts the
///      entries asset before the spawn and appends the
///      box's log tail at establishment failures; the box
///      core owns the asset path and the log tail.
///   3. The fork patch (engines/psiphonbox): both
///      ImportEmbeddedServerEntries call sites pass the
///      plumbed filename, the outbound option exists, and
///      notices log at Info.
///   4. The Dart surface: readLogs carries the sidecar's
///      own logs, and the connect timeout carries the
///      session log tail instead of standing bare.
/// What only the owner's phone can prove — a tunnel on
/// his network — is NOT claimed here; the host proof for
/// the entries mechanism itself (entries-only
/// establishment with every list URL blackholed, plus the
/// no-entries negative control) is recorded in
/// engines/psiphonbox/PROVENANCE.md.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/psiphon/psiphon_watchdog.dart';

String src(String rel) => File(rel).readAsStringSync();

void main() {
  group('watchdog establishment decision (build 2090)', () {
    final t0 = DateTime(2026, 11, 16, 6, 0, 0);

    PsiphonWatchdog armed() => PsiphonWatchdog()..arm(t0);

    bool eval(
      PsiphonWatchdog w,
      Duration age, {
      bool running = true,
      bool connected = false,
      bool wedged = false,
      bool startReturned = true,
    }) =>
        w.evaluateEstablishment(
          now: t0.add(age),
          running: running,
          connected: connected,
          wedged: wedged,
          startReturned: startReturned,
        );

    test('fires once at the bound for a running, returned, '
        'unconnected attempt', () {
      final w = armed();
      expect(eval(w, const Duration(seconds: 59)), isFalse);
      expect(eval(w, const Duration(seconds: 60)), isTrue);
      // Once only.
      expect(eval(w, const Duration(seconds: 61)), isFalse);
      expect(eval(w, const Duration(minutes: 5)), isFalse);
    });

    test('never fires before the bound', () {
      final w = armed();
      expect(eval(w, Duration.zero), isFalse);
      expect(eval(w, const Duration(seconds: 30)), isFalse);
    });

    test('never fires while the start call is still inside '
        'the provider', () {
      final w = armed();
      expect(
        eval(w, const Duration(minutes: 5), startReturned: false),
        isFalse,
      );
    });

    test('never fires for a connected, wedged, or stopped '
        'attempt', () {
      expect(
        eval(armed(), const Duration(minutes: 5), connected: true),
        isFalse,
      );
      expect(
        eval(armed(), const Duration(minutes: 5), wedged: true),
        isFalse,
      );
      expect(
        eval(armed(), const Duration(minutes: 5), running: false),
        isFalse,
      );
    });

    test('a fresh arm resets the once-only dump', () {
      final w = armed();
      expect(eval(w, const Duration(seconds: 60)), isTrue);
      w.arm(t0.add(const Duration(minutes: 10)));
      expect(
        eval(w, const Duration(minutes: 10, seconds: 60)),
        isTrue,
      );
    });

    test('the record-only branch does not consume the kill '
        'decision', () {
      final w = armed();
      expect(eval(w, const Duration(seconds: 60)), isTrue);
      // The firing decision still has its own say on a
      // start that never returns.
      expect(
        w.evaluate(
          now: t0.add(const Duration(seconds: 61)),
          running: true,
          connected: false,
          wedged: false,
          startReturned: false,
        ),
        isTrue,
      );
    });
  });

  group('Kotlin wiring (build 2090)', () {
    final svc = src(
      'android/app/src/main/kotlin/com/ralysnd/ember/PsiphonVpnService.kt',
    );
    final box = src(
      'android/app/src/main/kotlin/com/ralysnd/ember/PsiphonBoxCore.kt',
    );

    test('the service loads the entries before the library '
        'call (build 2091: the AAR is the provider again)', () {
      // Build 2091: there is no spawn and no extraction to a
      // file — the entries are the MLM asset, loaded as a
      // string and handed to startTunneling. The order still
      // matters: load first, call second.
      expect(
        svc.contains('PsiphonBoxCore.extractEmbeddedEntries'),
        isFalse,
      );
      expect(svc.contains('val serverEntries = loadEntries()'), isTrue);
      expect(
        svc.contains('tunnel.startTunneling(serverEntries)'),
        isTrue,
      );
      expect(
        svc.indexOf('loadEntries()'),
        lessThan(svc.indexOf('tunnel.startTunneling(serverEntries)')),
      );
    });

    test('the box core owns the asset path and the log tail', () {
      expect(
        box.contains(
          'flutter_assets/assets/psiphon/embedded_servers.txt',
        ),
        isTrue,
      );
      expect(box.contains('fun extractEmbeddedEntries'), isTrue);
      expect(box.contains('fun logTail'), isTrue);
      expect(box.contains('psiphonbox-stdout.log'), isTrue);
    });

    test('establishment failures carry the ladder evidence '
        '(build 2091: no box to append)', () {
      // Build 2091: appendBoxEvidence is gone with the box.
      // The evidence is the ladder's own record: the service
      // logs the failure with its reason (failAndStop) and
      // the Dart side dumps the session log tail on the
      // connect timeout (pinned in the Dart group below).
      expect(svc.contains('appendBoxEvidence('), isFalse);
      expect(
        svc.contains('private fun failAndStop(reason: String)'),
        isTrue,
      );
      expect(svc.contains('logLine("psiphon failed: \$reason")'), isTrue);
      expect(svc.contains('no tunnel within'), isFalse);
      expect(svc.contains('CONNECT_WAIT_MS'), isFalse);
    });
  });

  group('the fork patch (build 2090)', () {
    final fork = src(
      '../../engines/psiphonbox/src/protocol/psiphon/psiphon.go',
    );
    final forkOutbound = src(
      '../../engines/psiphonbox/src/protocol/psiphon/outbound.go',
    );
    final forkOption = src(
      '../../engines/psiphonbox/src/option/psiphon.go',
    );

    test('both import call sites pass the plumbed filename', () {
      expect(
        'ImportEmbeddedServerEntries(p.ctx, p.config, p.embeddedServerEntriesFile, "")'
            .allMatches(fork)
            .length,
        1,
      );
      expect(
        'ImportEmbeddedServerEntries(ctx, p.config, p.embeddedServerEntriesFile, "")'
            .allMatches(fork)
            .length,
        1,
      );
      expect(fork.contains('ImportEmbeddedServerEntries(p.ctx, p.config, "", "")'),
          isFalse);
    });

    test('the option exists and NewOutbound plumbs it', () {
      expect(
        forkOption.contains('json:"embedded_server_entries_file,omitempty"'),
        isTrue,
      );
      expect(
        forkOutbound.contains(
          'psiphon.embeddedServerEntriesFile = options.EmbeddedServerEntriesFile',
        ),
        isTrue,
      );
    });

    test('notices log at Info, not Debug', () {
      expect(fork.contains('p.logger.Info(fmt.Sprint("Notice '), isTrue);
      expect(fork.contains('p.logger.Debug(fmt.Sprint("Notice '), isFalse);
    });
  });

  group('the Dart evidence surface (build 2090)', () {
    final controller = src('lib/psiphon/psiphon_controller.dart');

    test('readLogs carries the session log, not the sidecar '
        'logs (build 2091)', () {
      expect(controller.contains("'psiphonbox-stdout.log'"), isFalse);
      expect(controller.contains("'psiphonbox-stderr.log'"), isFalse);
      expect(controller.contains("'psiphon.log'"), isTrue);
    });

    test('the connect timeout carries the session log tail', () {
      expect(
        controller.contains("connect-timeout — the Psiphon log tail:"),
        isTrue,
      );
    });

    test('the establishment dump writes to crash.log', () {
      expect(
        controller.contains('_maybeDumpEstablishmentEvidence'),
        isTrue,
      );
      expect(controller.contains('psiphon establishment evidence'),
          isTrue);
    });
  });
}
