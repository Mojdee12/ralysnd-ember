/// Build 2035 gates, host side: fallback groups (Iran-priority
/// queue item 2a). The ordering is pure (fallback_groups.dart) so
/// it is tested here without a core or a device; the watcher and
/// the connect-time walk consume exactly these functions, and the
/// servers page reads the same group members the controller
/// exposes.

import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/xray/fallback_groups.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

Profile _p(
  String id, {
  String sub = '',
  int delay = -1,
  bool failed = false,
  Protocol protocol = Protocol.vless,
}) => Profile(
  id: id,
  name: id,
  protocol: protocol,
  address: 'example.com',
  subscriptionId: sub,
  delayMs: delay,
  delayFailed: failed,
);

void main() {
  group('fallback group membership', () {
    test('a subscription is a group; hand-added profiles are one group', () {
      final a = _p('a', sub: 's1');
      final b = _p('b', sub: 's1');
      final c = _p('c', sub: 's2');
      final loose1 = _p('l1');
      final loose2 = _p('l2');
      final all = [a, b, c, loose1, loose2];
      expect(fallbackGroupMembersOf(all, a).map((p) => p.id), ['a', 'b']);
      expect(fallbackGroupMembersOf(all, loose1).map((p) => p.id), [
        'l1',
        'l2',
      ]);
    });

    test('members order tested by delay, then untested', () {
      final slow = _p('slow', sub: 's1', delay: 400);
      final fast = _p('fast', sub: 's1', delay: 90);
      final untested = _p('new', sub: 's1');
      final all = [slow, untested, fast];
      expect(fallbackGroupMembersOf(all, slow).map((p) => p.id), [
        'fast',
        'slow',
        'new',
      ]);
    });
  });

  group('fallback order', () {
    test('group first, then the rest; current excluded', () {
      final current = _p('cur', sub: 's1', delay: 100);
      final groupSlow = _p('gs', sub: 's1', delay: 300);
      final groupFast = _p('gf', sub: 's1', delay: 50);
      final otherFast = _p('of', sub: 's2', delay: 10);
      final all = [otherFast, current, groupSlow, groupFast];
      expect(fallbackOrder(all: all, current: current).map((p) => p.id), [
        'gf',
        'gs',
        'of',
      ]);
    });

    test('untested members are last-resort candidates, not excluded', () {
      final current = _p('cur', sub: 's1', delay: 100);
      final untested = _p('new', sub: 's1');
      final all = [current, untested];
      expect(fallbackOrder(all: all, current: current).map((p) => p.id), [
        'new',
      ]);
    });

    // Build 2075 pin update: this test used to expect the
    // TUIC member skipped as "unsupported" — since 2075 the
    // sing-box sidecar serves TUIC, so it IS an eligible
    // fallback member (untested, so it sorts last). Build
    // 2089 pin update: the same now holds for AnyTLS — the
    // sidecar serves it too, so it joins the untested tail
    // after TUIC in list order. No parsed protocol is
    // unserved anymore; what this test still proves is that
    // cooling-down members are skipped.
    test(
      'cooling-down members are skipped; every parsed protocol is eligible',
      () {
        final current = _p('cur', sub: 's1', delay: 100);
        final tuic = _p('tuic', sub: 's1', protocol: Protocol.tuic);
        final anytls = _p('any', sub: 's1', protocol: Protocol.anytls);
        final cooled = _p('cool', sub: 's1', delay: 20);
        final ok = _p('ok', sub: 's1', delay: 200);
        final all = [tuic, anytls, cooled, ok, current];
        expect(
          fallbackOrder(
            all: all,
            current: current,
            coolingDownIds: {'cool'},
          ).map((p) => p.id),
          ['ok', 'tuic', 'any'],
        );
      },
    );

    test('a delay-failed member still counts as untested last resort', () {
      final current = _p('cur', sub: 's1', delay: 100);
      final failed = _p('bad', sub: 's1', failed: true);
      final all = [current, failed];
      expect(fallbackOrder(all: all, current: current).map((p) => p.id), [
        'bad',
      ]);
    });

    test('empty when nothing else is eligible', () {
      final current = _p('cur', sub: 's1', delay: 100);
      expect(fallbackOrder(all: [current], current: current), isEmpty);
    });
  });

  group('fallback groups setting', () {
    test('OFF by default for a fresh install (build 2114)', () {
      // Build 2114 (defaults reset): adaptiveFailover is an
      // Ember extra — default OFF, v2rayNG parity.
      expect(XraySettings().adaptiveFailover, isFalse);
      expect(XraySettings.fromJson({}).adaptiveFailover, isFalse);
    });

    test('a stored value, on or off, is always respected', () {
      expect(
        XraySettings.fromJson({'adaptiveFailover': false}).adaptiveFailover,
        isFalse,
      );
      // Build 2114: a stored ON in a PRE-reset store is the
      // shipped default and migrates off once (build2114
      // test pins that); a store that has had the reset
      // respects the value it carries.
      expect(
        XraySettings.fromJson({
          'adaptiveFailover': true,
          'defaultsReset2114': true,
        }).adaptiveFailover,
        isTrue,
      );
      final roundTrip = XraySettings.fromJson(
        XraySettings.fromJson({'adaptiveFailover': false}).toJson(),
      ).adaptiveFailover;
      expect(roundTrip, isFalse);
    });

    test('the cooldown is ten minutes', () {
      expect(fallbackCooldown, const Duration(minutes: 10));
    });
  });
}
