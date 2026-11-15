/// Build 2044 gates, host side: Favorite / starred configs
/// (feature-watch 2026-11-08, AmneziaVPN 5.1.0.6) — star the
/// configs used daily and find them in a Favorites section at
/// the top of the server list. Verified honest before building:
/// no starring exists anywhere in the app (grep for
/// favorite|starred|isStarred across app/lib is empty), so this
/// is new state, not a second copy of something. These tests pin
/// the Dart side of the contract: storage (defaults, round-trip,
/// old stores, corrupt stored values), the controller toggle and
/// favorites list, the duplicate rule (a copy is born unstarred),
/// and the no-leak rule (the star never reaches the emitted core
/// config or a share link). The refresh carry-over line
/// (updateSubscription keeps the star) rides the existing carry
/// block and is verified by inspection — updateSubscription needs
/// a live subscription fetch, so no host test can drive it.
///
/// The Favorites section itself is UI (a _Group in
/// ember_servers.dart, shown above the subscription groups when
/// any visible profile is starred, skipped under By-country
/// grouping); the widget tree is not host-testable without a
/// device, so the tests pin the state the UI reads.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/xray/config_builder.dart';
import 'package:firefox_vpn/xray/profile_codec.dart';
import 'package:firefox_vpn/xray/xray_controller.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

Map<String, dynamic> decode(String json) =>
    jsonDecode(json) as Map<String, dynamic>;

Profile vless(String id, String address, {bool starred = false}) => Profile(
  id: id,
  protocol: Protocol.vless,
  name: id,
  address: address,
  port: 443,
  uuidOrPassword: '00000000-0000-4000-8000-000000000000',
  security: 'tls',
  sni: address,
  starred: starred,
);

void main() {
  group('Starred storage (build 2044)', () {
    test('a new profile is unstarred', () {
      expect(vless('a', 'a.example.com').starred, isFalse);
    });

    test('round-trip keeps a star', () {
      final back = Profile.fromJson(
        vless('a', 'a.example.com', starred: true).toJson(),
      );
      expect(back.starred, isTrue);
      expect(back.name, 'a');
    });

    test('an old store without the key reads unstarred', () {
      final j = vless('a', 'a.example.com').toJson()..remove('starred');
      expect(Profile.fromJson(j).starred, isFalse);
    });

    test('a non-bool stored value reads unstarred, never throws', () {
      for (final bad in ['yes', 1, 0, <String>['x']]) {
        final j = vless('a', 'a.example.com').toJson()..['starred'] = bad;
        expect(Profile.fromJson(j).starred, isFalse);
      }
    });

    test('copy() preserves the star', () {
      final c = vless('a', 'a.example.com', starred: true).copy();
      expect(c.starred, isTrue);
      expect(c.id, 'a');
    });
  });

  group('Starred controller state (build 2044)', () {
    test('toggleStarred flips twice and persists in memory', () async {
      final c = XrayController();
      final a = vless('a', 'a.example.com');
      c.profiles = [a];
      await c.toggleStarred(a);
      expect(a.starred, isTrue);
      expect(c.starredProfiles.map((p) => p.id), ['a']);
      await c.toggleStarred(a);
      expect(a.starred, isFalse);
      expect(c.starredProfiles, isEmpty);
    });

    test('starredProfiles keeps list order and only starred ones', () {
      final c = XrayController();
      c.profiles = [
        vless('a', 'a.example.com', starred: true),
        vless('b', 'b.example.com'),
        vless('c', 'c.example.com', starred: true),
      ];
      expect(c.starredProfiles.map((p) => p.id), ['a', 'c']);
    });

    test('a duplicate is born unstarred; the original keeps its star',
        () async {
      final c = XrayController();
      final a = vless('a', 'a.example.com', starred: true);
      c.profiles = [a];
      await c.duplicateProfile(a);
      expect(c.profiles.length, 2);
      expect(a.starred, isTrue);
      final copy = c.profiles.firstWhere((p) => p.id != 'a');
      expect(copy.starred, isFalse);
      expect(copy.name, 'a (2)');
    });
  });

  group('The star never leaks (build 2044)', () {
    test('a starred profile emits a core config with no starred key', () {
      final cfg = decode(
        buildTunnelConfig(
          vless('a', 'a.example.com', starred: true),
          XraySettings(),
        ),
      );
      expect(jsonEncode(cfg).contains('starred'), isFalse);
    });

    test('a starred profile shares a link with no star in it', () {
      final link = profileToLink(vless('a', 'a.example.com', starred: true));
      expect(link.contains('starred'), isFalse);
      expect(link.contains('#a'), isTrue);
    });
  });
}
