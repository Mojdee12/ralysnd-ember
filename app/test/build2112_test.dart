// Build 2112 — FIX-ONLY: the Mozilla session pool.
//
// The owner proved on-device (2026-11-18) that Arman VPN —
// the same Mozilla network — opens everything while Ember's
// Mozilla connects but fails many sites. The diagnosis
// (mozilla-sites-diagnosis.md) and fix plan
// (mozilla-fix-plan.md) found the mechanical cause:
// proxy.upstream_connections shipped at 1, the Kumiho core's
// DESKTOP default — the whole phone funnels through ONE
// Mozilla H2 session whose stream ceiling the server sets;
// saturation waits and single-session rebuild churn follow
// while the tunnel shows connected. Cause #1 (the 2105
// transport left on HTTP/1.1) was ruled out by the owner
// on-device; cause #3 (selection.json TTL) is NOT in this
// build — it is gated on his Recommended-location retest.
//
// The fix, the whole scope (fix A of the plan): raise the
// pool to 4 on both layers — (1) the core's Default(), for
// new data dirs; (2) a one-time app pin mirroring the 2024
// transport pin, because an existing install's saved core
// config.json already holds 1 and Load keeps a stored value.
// The core's >1 pool machinery already exists, is tested in
// Go, and round-robins on the Android TUN path (empty client
// key). Nothing else in the Mozilla session path changes:
// no tracker thresholds, no StrictMaxConcurrentStreams, no
// backoffs, no keepalive, no selection TTL.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/app_settings.dart';

String dartSrc(String rel) => File('lib/$rel').readAsStringSync();

String coreSrc(String rel) => File('../core/$rel').readAsStringSync();

void main() {
  group('core Default — the pool ships at 4', () {
    test('config.go Default() carries UpstreamConnections 4, never 1', () {
      final src = coreSrc('internal/config/config.go');
      final at = src.indexOf('func Default() Config');
      expect(at, isNot(-1));
      final body = src.substring(at, at + 1200);
      expect(body, contains('UpstreamConnections: 4,'));
      expect(src, isNot(contains('UpstreamConnections: 1,')));
    });
  });

  group('the one-time pin — AppSettings flag', () {
    test('defaults off and persists through toJson/update', () {
      final s = AppSettings();
      expect(s.upstreamConnectionsPinned, isFalse);
      expect(s.toJson()['upstream_connections_pinned'], isFalse);
      s.update(upstreamConnectionsPinned: true);
      expect(s.upstreamConnectionsPinned, isTrue);
      expect(s.toJson()['upstream_connections_pinned'], isTrue);
    });

    test('the flag round-trips beside transportPinned in the source', () {
      final src = dartSrc('app_settings.dart');
      expect(
        src,
        contains(
          "upstreamConnectionsPinned = j['upstream_connections_pinned'] == true;",
        ),
      );
      expect(
        src,
        contains("'upstream_connections_pinned': upstreamConnectionsPinned,"),
      );
      // The field is declared next to the flag it mirrors.
      final flagAt = src.indexOf('bool transportPinned = false;');
      final newAt = src.indexOf('bool upstreamConnectionsPinned = false;');
      expect(flagAt, isNot(-1));
      expect(newAt, greaterThan(flagAt));
      expect(newAt - flagAt, lessThan(1200));
    });
  });

  group('the one-time pin — the shell writer', () {
    final src = dartSrc('ui/ember/ember_shell.dart');

    test('writes proxy.upstream_connections = 4 through editSettings', () {
      expect(src, contains('_applyUpstreamConnectionsDefault'));
      expect(src, contains("proxy['upstream_connections'] = 4;"));
    });

    test('is gated by its flag and defers while the engine runs', () {
      final at = src.indexOf(
        'Future<void> _applyUpstreamConnectionsDefault()',
      );
      expect(at, isNot(-1));
      final body = src.substring(at, at + 2600);
      expect(
        body,
        contains('widget.settings.upstreamConnectionsPinned'),
      );
      // The transport pin's discipline: a running tunnel (or a
      // core that never answered) leaves the flag unset so a
      // later launch tries again.
      expect(body, contains('status.state.phase == Phase.running'));
      expect(body, contains('_upstreamConnectionsApplied = false;'));
    });

    test('the flag write lands after the frame (2057 F-H10 discipline)',
        () {
      final at = src.indexOf('upstreamConnectionsPinned: true');
      expect(at, isNot(-1));
      final window = src.substring((at - 600).clamp(0, src.length), at);
      expect(window, contains('addPostFrameCallback'));
    });

    test('runs after the transport pin, never concurrently with it', () {
      // editSettings is a read-modify-write over the core's
      // settings document; two one-time pins editing it at
      // once could each write back a copy missing the other's
      // change. The launch call chains the pool pin behind
      // the transport pin.
      final at = src.indexOf('_applyTransportDefault().then(');
      expect(at, isNot(-1));
      final window = src.substring(at, at + 200);
      expect(window, contains('_applyUpstreamConnectionsDefault()'));
    });
  });

  group('version', () {
    test('pubspec is 2.2.0+2119', () {
      expect(
        File('pubspec.yaml').readAsStringSync(),
        contains('version: 2.2.0+2157'),
      );
    });
  });
}
