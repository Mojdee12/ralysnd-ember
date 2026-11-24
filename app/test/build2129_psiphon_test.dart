/// Build 2129, Leg 2 gates — the Psiphon Shiro bootstrap.
///
/// The owner's standing law: every new feature DEFAULT OFF,
/// and with the new options off the behaviour is the 2128
/// behaviour. Pinned here:
///   1. The settings: shiroBootstrap + strongMode default
///      OFF, survive the JSON round-trip, and read OFF from
///      a store that predates them.
///   2. The OFF shape in Kotlin: the config builder selects
///      the MLM identity set when the toggle is off (the
///      else-branch of every selection), the entries hand-off
///      reads the 493-line asset, AggressiveEstablishment is
///      emitted only under the strong-mode guard, and the
///      Shiro shaping flags only inside the Shiro block.
///   3. The ON shape: the whole Shiro set exists as one
///      block in PsiphonConstants (identity + URL lists +
///      trust anchors), the entries asset is the LML
///      extract's server_list.dat byte-for-byte (2,434 hex
///      lines, 27 regions), and the fronting-overrides asset
///      is bundled.
///   4. The plumbing: Dart settings -> platform channel ->
///      MainActivity -> service extras, every hop defaulting
///      to false.
///   5. The credit: Shirokhorshid/MehrON on the licences
///      page, GPL-3.0-or-later.
///
/// No bootstrap VALUES are asserted anywhere in this file —
/// the identity is pinned by shape (field presence, set
/// selection, asset hashes), never by quoting a value.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/psiphon/psiphon_controller.dart';
import 'package:firefox_vpn/xray/sha256.dart';

String src(String rel) => File(rel).readAsStringSync();
String kotlinSrc(String name) => src(
      'android/app/src/main/kotlin/com/ralysnd/ember/$name',
    );
String dartSrc(String rel) => File('lib/$rel').readAsStringSync();

List<int> hexDecode(String hex) => List<int>.generate(
      hex.length ~/ 2,
      (i) => int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16),
    );

void main() {
  group('settings defaults (build 2129 leg 2)', () {
    test('shiroBootstrap and strongMode default OFF', () {
      final s = PsiphonSettings();
      expect(s.shiroBootstrap, isFalse);
      expect(s.strongMode, isFalse);
    });

    test('a pre-2129 store reads both OFF', () {
      final s = PsiphonSettings.fromJson(const {});
      expect(s.shiroBootstrap, isFalse);
      expect(s.strongMode, isFalse);
    });

    test('both survive the JSON round-trip when set', () {
      final s = PsiphonSettings()
        ..shiroBootstrap = true
        ..strongMode = true;
      final restored = PsiphonSettings.fromJson(s.toJson());
      expect(restored.shiroBootstrap, isTrue);
      expect(restored.strongMode, isTrue);
    });

    test('wrong-typed stored values degrade to OFF', () {
      final s = PsiphonSettings.fromJson(const {
        'shiroBootstrap': 'yes',
        'strongMode': 1,
      });
      expect(s.shiroBootstrap, isFalse);
      expect(s.strongMode, isFalse);
    });
  });

  group('the Shiro set is one block (PsiphonConstants)', () {
    final constants = kotlinSrc('PsiphonConstants.kt');

    test('every Shiro identity field exists', () {
      for (final name in [
        'SHIRO_CLIENT_VERSION',
        'SHIRO_PROPAGATION_CHANNEL_ID',
        'SHIRO_SPONSOR_ID',
        'SHIRO_REMOTE_SERVER_LIST_SIGNATURE_PUBLIC_KEY',
        'SHIRO_SERVER_ENTRY_SIGNATURE_PUBLIC_KEY',
        'SHIRO_EXCHANGE_OBFUSCATION_KEY',
        'SHIRO_REMOTE_SERVER_LIST_URLS',
        'SHIRO_OBFUSCATED_SERVER_LIST_ROOT_URLS',
        'SHIRO_SERVER_ENTRIES_ASSET',
        'SHIRO_FRONTING_ASSET',
        'SHIRO_USE_INDISTINGUISHABLE_TLS',
        'SHIRO_FRONTED_MEEK_CDN_SCAN_USE_BUILT_IN_SPEC',
        'SHIRO_TUNNEL_POOL_SIZE',
      ]) {
        expect(constants.contains(name), isTrue, reason: name);
      }
    });

    test('the MLM set is untouched beside it', () {
      // The OFF path's set: same constant names as 2128.
      for (final name in [
        'CLIENT_VERSION',
        'PROPAGATION_CHANNEL_ID',
        'SPONSOR_ID',
        'REMOTE_SERVER_LIST_URLS',
        'OBFUSCATED_SERVER_LIST_ROOT_URLS',
        'SERVER_ENTRIES_ASSET',
      ]) {
        // 'val NAME' (the two URL lists are plain vals, the
        // rest const vals — both contain this substring, and
        // the SHIRO_ names cannot false-match it).
        expect(constants.contains('val $name'), isTrue, reason: name);
      }
      expect(
        constants.contains(
          '"flutter_assets/assets/psiphon/server_entries.txt"',
        ),
        isTrue,
      );
      expect(
        constants.contains(
          '"flutter_assets/assets/psiphon/server_list_shiro.dat"',
        ),
        isTrue,
      );
    });
  });

  group('config builder selection (PsiphonVpnService)', () {
    final service = kotlinSrc('PsiphonVpnService.kt');

    test('OFF selects the MLM set in every selection', () {
      // Each identity value is an if/else whose else-branch
      // is the 2128 constant — the OFF path cannot drift.
      for (final pair in [
        'else PsiphonConstants.PROPAGATION_CHANNEL_ID',
        'else PsiphonConstants.SPONSOR_ID',
        'else PsiphonConstants.CLIENT_VERSION',
        'else PsiphonConstants.REMOTE_SERVER_LIST_URLS',
        'else PsiphonConstants.OBFUSCATED_SERVER_LIST_ROOT_URLS',
        'else PsiphonConstants.REMOTE_SERVER_LIST_SIGNATURE_PUBLIC_KEY',
        'else PsiphonConstants.SERVER_ENTRY_SIGNATURE_PUBLIC_KEY',
        'else PsiphonConstants.EXCHANGE_OBFUSCATION_KEY',
      ]) {
        expect(service.contains(pair), isTrue, reason: pair);
      }
      expect(
        service.contains(
          'if (inShiroBootstrap) PsiphonConstants.SHIRO_SERVER_ENTRIES_ASSET',
        ),
        isTrue,
      );
      expect(
        service.contains('else PsiphonConstants.SERVER_ENTRIES_ASSET'),
        isTrue,
      );
    });

    test('strong mode emits AggressiveEstablishment only '
        'under its guard, once', () {
      expect(
        'put("AggressiveEstablishment"'.allMatches(service).length,
        1,
      );
      final at = service.indexOf('put("AggressiveEstablishment", true)');
      expect(
        service
            .substring(0, at)
            .endsWith('if (inStrongMode) {\n                '),
        isTrue,
      );
    });

    test('the Shiro shaping flags are emitted only inside '
        'the Shiro block', () {
      for (final key in [
        'UseIndistinguishableTLS',
        'FrontedMeekCDNScanUseBuiltInSpec',
        'TunnelPoolSize',
      ]) {
        expect('put("$key"'.allMatches(service).length, 1, reason: key);
      }
      final at = service.indexOf('put("UseIndistinguishableTLS"');
      expect(
        service.substring(0, at).endsWith('if (shiro) {\n                '),
        isTrue,
      );
    });

    test('the fronting overrides map only IP literals to '
        'the Akamai provider CIDRs', () {
      expect(service.contains('shiroPreresolvedCidrs()'), isTrue);
      expect(
        service.contains('PsiphonConstants.FRONTING_PROVIDER_AKAMAI'),
        isTrue,
      );
      // The helper refuses to run at all when the toggle
      // is off — rungs A and E see an empty map.
      final helperAt = service.indexOf('private fun shiroPreresolvedCidrs()');
      expect(
        service
            .substring(helperAt, helperAt + 400)
            .contains('if (!inShiroBootstrap) return emptyMap()'),
        isTrue,
      );
    });

    test('both toggles default false at every Kotlin hop', () {
      expect(
        service.contains(
          'intent.getBooleanExtra(EXTRA_SHIRO_BOOTSTRAP, false)',
        ),
        isTrue,
      );
      expect(
        service.contains(
          'intent.getBooleanExtra(EXTRA_STRONG_MODE, false)',
        ),
        isTrue,
      );
      expect(service.contains('shiroBootstrap: Boolean = false'), isTrue);
      expect(service.contains('strongMode: Boolean = false'), isTrue);
    });
  });

  group('the Shiro entries asset', () {
    test('byte-identical to the LML extract server_list.dat', () {
      final bytes = File('assets/psiphon/server_list_shiro.dat')
          .readAsBytesSync();
      expect(bytes.length, 6550986);
      expect(
        sha256Hex(bytes),
        '4c83073e597426f81e6efff81c11d350135d7a5560c7498eefa79aac020addf3',
      );
    });

    test('2,434 hex lines, every one decodes to the shared '
        'prefix + a ServerEntry JSON, 27 regions', () {
      final lines = File('assets/psiphon/server_list_shiro.dat')
          .readAsLinesSync()
          .where((l) => l.trim().isNotEmpty)
          .toList();
      expect(lines.length, 2434);
      final regions = <String>{};
      for (final line in lines) {
        final trimmed = line.trim();
        expect(RegExp(r'^[0-9a-f]+$').hasMatch(trimmed), isTrue);
        final decoded = utf8.decode(hexDecode(trimmed));
        expect(decoded.startsWith('0 0 0 0 '), isTrue);
        final entry =
            jsonDecode(decoded.substring(decoded.indexOf('{')))
                as Map<String, dynamic>;
        expect(entry.containsKey('region'), isTrue);
        expect(entry.containsKey('signature'), isTrue);
        regions.add(entry['region'] as String);
      }
      expect(regions.length, 27);
    });

    test('the MLM asset keeps its 493 lines (OFF floor)', () {
      final lines = File('assets/psiphon/server_entries.txt')
          .readAsLinesSync()
          .where((l) => l.trim().isNotEmpty)
          .toList();
      expect(lines.length, 493);
    });

    test('the fronting-overrides asset is bundled', () {
      final specs = jsonDecode(
        File('assets/psiphon/shiro_fronting_default.json')
            .readAsStringSync(),
      ) as List<dynamic>;
      expect(specs.length, 11);
    });
  });

  group('plumbing (Dart side)', () {
    test('platform setOn carries both flags, defaulted OFF', () {
      final platform = dartSrc('psiphon/psiphon_platform.dart');
      expect(platform.contains('bool shiroBootstrap = false'), isTrue);
      expect(platform.contains('bool strongMode = false'), isTrue);
      expect(
        platform.contains("'shiroBootstrap': shiroBootstrap"),
        isTrue,
      );
      expect(platform.contains("'strongMode': strongMode"), isTrue);
    });

    test('the controller passes the settings through', () {
      final controller = dartSrc('psiphon/psiphon_controller.dart');
      expect(
        controller.contains('shiroBootstrap: settings.shiroBootstrap'),
        isTrue,
      );
      expect(
        controller.contains('strongMode: settings.strongMode'),
        isTrue,
      );
    });

    test('MainActivity threads both, defaulting false', () {
      final main = kotlinSrc('MainActivity.kt');
      expect(
        main.contains('call.argument<Boolean>("shiroBootstrap") ?: false'),
        isTrue,
      );
      expect(
        main.contains('call.argument<Boolean>("strongMode") ?: false'),
        isTrue,
      );
    });

    test('the settings page offers both toggles', () {
      final pages = dartSrc('ui/ember/psiphon_pages.dart');
      expect(pages.contains("label: 'Shiro bootstrap'"), isTrue);
      expect(pages.contains("label: 'Strong mode'"), isTrue);
      expect(pages.contains('s.shiroBootstrap = v'), isTrue);
      expect(pages.contains('s.strongMode = v'), isTrue);
    });
  });

  group('credit', () {
    test('Shirokhorshid/MehrON credited, GPL-3.0-or-later', () {
      final page = dartSrc('ui/ember/licenses_page.dart');
      expect(page.contains('Shirokhorshid bootstrap'), isTrue);
      expect(page.contains('GNU GPL-3.0-or-later'), isTrue);
      expect(page.contains('MehrON'), isTrue);
      expect(
        File('assets/licenses/gpl-3.0.txt').existsSync(),
        isTrue,
      );
    });
  });
}
