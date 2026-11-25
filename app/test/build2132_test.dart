// Build 2132 — the private-server re-registration hotfix.
//
// Build 2131's device verdict: the first Private connect
// (build 2130) had registered the owner's server with the
// gomobile core, and the core PERSISTS managed servers.
// Every later Private connect re-ran the registration and
// radiance refused the duplicate — "server \"<tag>\"
// already exists" — which Ember treated as a fatal
// registration failure and aborted the connect. But a
// stored entry under OUR tag is exactly the state the
// pinned connect needs: "already exists" for our tag is
// success, not failure.
//
// The fix is one function: LanternVpnService.registerPrivate
// now swallows that one verdict — whether it arrives as
// the synchronous addPrivateServer throw or as an async
// listener error event — and proceeds to publish ok|<tag>.
// Every other failure keeps its 2131 behavior verbatim.
// The bridge dex is untouched (byte-identical to 2131).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String read(String rel) => File(rel).readAsStringSync();

void main() {
  final kt = read(
    'android/app/src/main/kotlin/com/ralysnd/ember/LanternVpnService.kt',
  );
  final controller = read('lib/lantern/lantern_controller.dart');
  final pages = read('lib/ui/ember/lantern_pages.dart');
  final pubspec = read('pubspec.yaml');

  final regAt = kt.indexOf('private fun registerPrivate(');
  final regBody = kt.substring(regAt, regAt + 4200);

  group('the synchronous throw is no longer fatal for our own tag', () {
    test('registerPrivate wraps the bridge add in try/catch', () {
      expect(regBody, contains('try {'));
      expect(
        regBody,
        contains('bridge.addPrivateServer(ip, port.toString(), token, tag)'),
      );
      expect(regBody, contains('} catch (e: Throwable) {'));
    });

    test('a non-matching throwable is rethrown untouched', () {
      expect(
        regBody,
        contains('if (!isAlreadyRegistered(e, tag)) throw e'),
      );
    });

    test('the matcher needs BOTH "already exists" AND our tag', () {
      expect(kt, contains('text.contains("already exists")'));
      expect(kt, contains('text.contains(tag)'));
      expect(kt, contains('tag.isNotEmpty()'));
    });

    test('the throwable overload walks the whole cause chain', () {
      final at = kt.indexOf('private fun isAlreadyRegistered(e: Throwable');
      expect(at, greaterThanOrEqualTo(0));
      final body = kt.substring(at, at + 600);
      expect(body, contains('cur = cur.cause'));
      expect(body, contains('chain.append('));
    });
  });

  group('the async listener error event gets the same exemption', () {
    test('the error| branch checks already-registered before failing', () {
      final at = regBody.indexOf('if (event.startsWith("error|"))');
      expect(at, greaterThanOrEqualTo(0));
      final branch = regBody.substring(at, at + 800);
      expect(
        branch,
        contains(
          'if (isAlreadyRegistered(event.removePrefix("error|"), tag))',
        ),
      );
      // The exemption breaks to the ok|<tag> publish below;
      // the real-failure publish stays after it.
      expect(branch, contains('break'));
      expect(
        branch,
        contains('"error|Your server could not be added: "'),
      );
      expect(
        branch.indexOf('isAlreadyRegistered(event.removePrefix'),
        lessThan(branch.indexOf('"error|Your server could not be added: "')),
      );
    });
  });

  group('no other privateResult path changed', () {
    test('the ACTION_ADD_PRIVATE catch still surfaces real throws', () {
      expect(
        kt,
        contains('"error|Adding your private server failed: "'),
      );
    });

    test('registerPrivate still publishes ok|<tag> on success', () {
      expect(regBody, contains('LanternStateStore.privateResult = "ok|\$tag"'));
    });

    test('the idempotency rationale is recorded in a comment', () {
      expect(regBody, contains('PERSISTS private servers'));
      expect(regBody, contains('idempotent by intent'));
    });
  });

  group('LEG 2 — the picker guarantees the private row', () {
    final at = controller.indexOf('List<LanternServer> get pickerServers');
    final body = controller.substring(at, at + 1400);

    test('pickerServers starts from the core list', () {
      expect(at, greaterThanOrEqualTo(0));
      expect(body, contains('final servers = _state.serverList;'));
    });

    test('no synthesis when no key is saved', () {
      expect(body, contains('if (privateKey.trim().isEmpty) return servers;'));
      expect(body, contains('if (tag.isEmpty) return servers;'));
    });

    test('dedupes when the core list already carries the tag', () {
      expect(
        body,
        contains('if (servers.any((s) => s.tag == tag)) return servers;'),
      );
    });

    test('synthesizes the VIP row from the saved key identity', () {
      expect(body, contains('tag: tag,'));
      expect(body, contains('country: privateCountry,'));
      expect(body, contains('countryCode: privateCode,'));
      expect(body, contains('isLantern: false,'));
    });

    test('the Servers view rows come from pickerServers', () {
      expect(pages, contains('final servers = lantern.pickerServers;'));
      expect(pages.contains('final servers = state.serverList;'), isFalse);
    });

    test('the picker count presents the merged count on synthesis', () {
      expect(
        pages,
        contains('servers.length > state.serverList.length '
            '? servers.length : state.servers'),
      );
    });
  });

  test('pubspec is build 2132', () {
    expect(pubspec, contains('version: 2.2.0+2150'));
  });
}
