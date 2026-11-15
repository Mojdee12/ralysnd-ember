/// Build 2045 gates, host side: keep local profile edits across
/// subscription refresh (feature-watch 2026-11-08, NekoBox 1.4.2)
/// — a rename in the editor used to write into the profile's name,
/// and the next subscription refresh recreated the profile from
/// the link, wiping the rename. The rename is now the user's own
/// label, stored apart from the provider's name: the server list,
/// the home card and the sort show the label, the share link and
/// the country grouping keep the server name, and the refresh
/// carry block keeps the label. These tests pin the Dart side of
/// the contract: storage (defaults, round-trip, old stores,
/// corrupt stored values), the display-name rule, the controller
/// sort and duplicate rules, and the no-leak rule (the label never
/// reaches the emitted core config or a share link — the link
/// keeps the server name as its remark). The refresh carry-over
/// line (updateSubscription keeps the label) rides the existing
/// carry block next to the star and is verified by inspection —
/// updateSubscription needs a live subscription fetch, so no host
/// test can drive it. The editor split itself (the Name field
/// writes the label for subscription profiles) is UI and is not
/// host-testable without a device, so the tests pin the state the
/// editor reads and writes.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/xray/config_builder.dart';
import 'package:firefox_vpn/xray/profile_codec.dart';
import 'package:firefox_vpn/xray/xray_controller.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

Map<String, dynamic> decode(String json) =>
    jsonDecode(json) as Map<String, dynamic>;

Profile vless(
  String id,
  String address, {
  String? localName,
  String subscriptionId = '',
}) => Profile(
  id: id,
  protocol: Protocol.vless,
  name: id,
  address: address,
  port: 443,
  uuidOrPassword: '00000000-0000-4000-8000-000000000000',
  security: 'tls',
  sni: address,
  localName: localName ?? '',
  subscriptionId: subscriptionId,
);

void main() {
  group('Local-name storage (build 2045)', () {
    test('a new profile has no label and shows the server name', () {
      final p = vless('a', 'a.example.com');
      expect(p.localName, isEmpty);
      expect(p.displayName, 'a');
    });

    test('a label wins over the server name for display', () {
      final p = vless('a', 'a.example.com', localName: 'My fast one');
      expect(p.displayName, 'My fast one');
      expect(p.name, 'a');
    });

    test('round-trip keeps the label and the server name apart', () {
      final back = Profile.fromJson(
        vless('a', 'a.example.com', localName: 'My fast one').toJson(),
      );
      expect(back.localName, 'My fast one');
      expect(back.name, 'a');
      expect(back.displayName, 'My fast one');
    });

    test('an old store without the key reads no label', () {
      final j = vless('a', 'a.example.com').toJson()..remove('localName');
      final back = Profile.fromJson(j);
      expect(back.localName, isEmpty);
      expect(back.displayName, 'a');
    });

    test('a non-string stored value reads no label, never throws', () {
      for (final bad in [1, true, <String>['x']]) {
        final j = vless('a', 'a.example.com').toJson()..['localName'] = bad;
        expect(Profile.fromJson(j).localName, isEmpty);
      }
    });

    test('copy() preserves the label', () {
      final c = vless('a', 'a.example.com', localName: 'My fast one').copy();
      expect(c.localName, 'My fast one');
      expect(c.displayName, 'My fast one');
    });
  });

  group('Local-name controller state (build 2045)', () {
    test('sort by name sorts by the name the user sees', () {
      final c = XrayController();
      c.profiles = [
        vless('z-server', 'z.example.com'),
        vless('a-server', 'a.example.com', localName: 'Zulu'),
        vless('m-server', 'm.example.com', localName: 'Alpha'),
      ];
      c.sortProfilesByName();
      expect(
        c.profiles.map((p) => p.displayName),
        ['Alpha', 'Zulu', 'z-server'],
      );
    });

    test(
      'a duplicate takes the shown name as its own and is born '
      'with no label; the original keeps its label',
      () async {
        final c = XrayController();
        final a = vless(
          'a',
          'a.example.com',
          localName: 'My fast one',
          subscriptionId: 's1',
        );
        c.profiles = [a];
        await c.duplicateProfile(a);
        expect(c.profiles.length, 2);
        expect(a.localName, 'My fast one');
        final copy = c.profiles.firstWhere((p) => p.id != 'a');
        expect(copy.name, 'My fast one (2)');
        expect(copy.localName, isEmpty);
        expect(copy.displayName, 'My fast one (2)');
        expect(copy.subscriptionId, isEmpty);
      },
    );

    test('a duplicate of an unlabelled profile names itself from '
        'the server name', () async {
      final c = XrayController();
      final a = vless('a', 'a.example.com');
      c.profiles = [a];
      await c.duplicateProfile(a);
      final copy = c.profiles.firstWhere((p) => p.id != 'a');
      expect(copy.name, 'a (2)');
      expect(copy.localName, isEmpty);
    });
  });

  group('The label never leaks (build 2045)', () {
    test('a labelled profile emits a core config with no label key', () {
      final cfg = decode(
        buildTunnelConfig(
          vless('a', 'a.example.com', localName: 'My fast one'),
          XraySettings(),
        ),
      );
      expect(jsonEncode(cfg).contains('localName'), isFalse);
      expect(jsonEncode(cfg).contains('My fast one'), isFalse);
    });

    test('a labelled profile shares a link with the server name '
        'as its remark, not the label', () {
      final link = profileToLink(
        vless('a', 'a.example.com', localName: 'My fast one'),
      );
      expect(link.contains('localName'), isFalse);
      expect(link.contains('My fast one'), isFalse);
      expect(link.contains('#a'), isTrue);
    });
  });
}
