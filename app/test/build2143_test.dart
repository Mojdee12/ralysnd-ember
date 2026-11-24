// Build 2143 — ONE leg (scope: build2143-progress.md):
// the RegionHop panel speaks HTTPS. The paired device
// tests after 2142 proved the carrier DPI-drops the
// plain-HTTP /tunnels-status exchange on the direct
// path (the browser failed too once Ember was
// disconnected), while every tunneled fetch passed. The
// server now serves TLS with a self-signed certificate
// for the panel host, so:
//  - the baked default URL is the https form;
//  - the client pins the panel's embedded PUBLIC
//    certificate — for the baked https endpoint ONLY
//    (https + the baked host + the baked port); every
//    other base URL builds the plain default client,
//    exactly as before, and there is no
//    badCertificateCallback anywhere;
//  - a stored copy of the OLD http baked default
//    migrates to the new https default in the page's
//    effective-value resolution; any other stored URL
//    is respected verbatim.
// Tests reference the baked values only through the
// RegionHopDefaults constants, never as literals (the
// 2141 discipline).

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/regionhop/regionhop_client.dart';
import 'package:firefox_vpn/regionhop/regionhop_defaults.dart';
import 'package:firefox_vpn/ui/ember/regionhop_page.dart';
import 'package:firefox_vpn/xray/xray_controller.dart';

String _src(String rel) => File('lib/$rel').readAsStringSync();

const _statusPayload = '''
[
  {"Name":"de","Region":"DE - Germany","SocksPort":19000,
   "Status":"active","StatusClass":"active",
   "ExitIP":"","ExitRegion":"DE - Germany","ExitFlagURL":""}
]
''';

/// A minimal fake panel on loopback http (the
/// build2139/2141 precedent) — it exercises the DEFAULT
/// (unpinned) client path the factory must keep using
/// for every non-baked URL.
class _FakePanel {
  HttpServer? _server;

  String get base => 'http://127.0.0.1:${_server!.port}/p';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen(_handle);
  }

  Future<void> stop() async => _server?.close(force: true);

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    final path = req.uri.path;
    if (path == '/p/login' && req.method == 'GET') {
      res.statusCode = 200;
      res.write('<html><body>login</body></html>');
    } else if (path == '/p/login' && req.method == 'POST') {
      final body = await utf8.decoder.bind(req).join();
      if (body.contains('password=right')) {
        res.statusCode = 303;
        res.headers.set('location', '/p/');
        res.headers.set('set-cookie', 'psi_session=tok.en; Path=/; HttpOnly');
      } else {
        res.statusCode = 200;
        res.write('<html><body>login</body></html>');
      }
    } else if (path == '/p/tunnels-status') {
      final cookie = req.headers.value('cookie') ?? '';
      if (!cookie.contains('psi_session=')) {
        res.statusCode = 303;
        res.headers.set('location', '/p/login');
      } else {
        res.statusCode = 200;
        res.headers.contentType = ContentType.json;
        res.write(_statusPayload);
      }
    } else {
      res.statusCode = 404;
    }
    await res.close();
  }
}

void main() {
  group('(c) the baked default is the https endpoint', () {
    test('the baked URL is https, on the baked host and port', () {
      final uri = Uri.parse(RegionHopDefaults.panelUrl);
      expect(uri.scheme, 'https');
      expect(uri.port, 25000);
      expect(uri.host, isNotEmpty);
      // The legacy constant keeps the pre-2143 scheme —
      // it is the migration's comparison target only.
      final legacy = Uri.parse(RegionHopDefaults.legacyPanelUrl);
      expect(legacy.scheme, 'http');
      expect(legacy.host, uri.host);
      expect(legacy.port, uri.port);
      expect(legacy.path, uri.path);
    });

    test('the embedded certificate is a well-formed PEM '
        'that a SecurityContext accepts', () {
      final pem = RegionHopDefaults.panelCertificatePem;
      expect(pem, startsWith('-----BEGIN CERTIFICATE-----'));
      expect(pem.trimRight(), endsWith('-----END CERTIFICATE-----'));
      // Loading it must not throw: a malformed PEM would
      // break every pinned client at first use.
      final context = SecurityContext()
        ..setTrustedCertificatesBytes(utf8.encode(pem));
      expect(context, isNotNull);
    });
  });

  group('(a) the pinned context is selected for the baked '
      'endpoint only', () {
    test('the baked https URL pins; the context is built '
        'once and cached', () {
      expect(regionHopUsesPinnedContext(RegionHopDefaults.panelUrl), isTrue);
      final first = regionHopSecurityContextFor(RegionHopDefaults.panelUrl);
      expect(first, isNotNull);
      final second = regionHopSecurityContextFor(RegionHopDefaults.panelUrl);
      expect(identical(first, second), isTrue);
    });

    test('http URLs never pin — the legacy default and a '
        'loopback fake stay on the default client', () {
      expect(
        regionHopUsesPinnedContext(RegionHopDefaults.legacyPanelUrl),
        isFalse,
      );
      expect(
        regionHopSecurityContextFor(RegionHopDefaults.legacyPanelUrl),
        isNull,
      );
      expect(regionHopUsesPinnedContext('http://127.0.0.1:54321/p'), isFalse);
      expect(regionHopSecurityContextFor('http://127.0.0.1:54321/p'), isNull);
    });

    test('https on any other host or port never pins', () {
      final otherPort = RegionHopDefaults.panelUrl.replaceFirst(
        ':25000',
        ':25001',
      );
      expect(regionHopUsesPinnedContext(otherPort), isFalse);
      expect(regionHopSecurityContextFor(otherPort), isNull);
      expect(
        regionHopUsesPinnedContext('https://example.com:25000/p'),
        isFalse,
      );
      expect(
        regionHopSecurityContextFor('https://example.com:25000/p'),
        isNull,
      );
      // The baked host over https but on the default
      // https port is not the baked endpoint either.
      final noPort = RegionHopDefaults.panelUrl.replaceFirst(':25000', '');
      expect(regionHopUsesPinnedContext(noPort), isFalse);
    });

    test('the factory builds a client on both paths', () {
      final pinned = regionHopHttpClientFor(RegionHopDefaults.panelUrl);
      pinned.close(force: true);
      final plain = regionHopHttpClientFor('http://127.0.0.1:54321/p');
      plain.close(force: true);
    });

    test('the loopback fake panel still works end to end '
        'through the default path', () async {
      final savedOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      final panel = _FakePanel();
      await panel.start();
      try {
        final client = RegionHopClient(
          panelUrl: panel.base,
          password: 'right',
          statusRetryDelay: const Duration(milliseconds: 10),
        );
        final rows = await client.fetchStatus();
        expect(rows, hasLength(1));
        expect(rows.single.name, 'de');
      } finally {
        await panel.stop();
        HttpOverrides.global = savedOverrides;
      }
    });
  });

  group('(b) the legacy stored URL migrates', () {
    test('the legacy default, with or without its '
        'trailing slash, resolves to the https default', () {
      expect(
        regionHopEffectivePanelUrl(RegionHopDefaults.legacyPanelUrl),
        RegionHopDefaults.panelUrl,
      );
      final noSlash = RegionHopDefaults.legacyPanelUrl.substring(
        0,
        RegionHopDefaults.legacyPanelUrl.length - 1,
      );
      expect(regionHopEffectivePanelUrl(noSlash), RegionHopDefaults.panelUrl);
      // Surrounding whitespace is trimmed before the
      // comparison.
      expect(
        regionHopEffectivePanelUrl('  ${RegionHopDefaults.legacyPanelUrl} '),
        RegionHopDefaults.panelUrl,
      );
    });

    test('any other stored URL is respected verbatim', () {
      expect(
        regionHopEffectivePanelUrl('http://stored.invalid/prefix'),
        'http://stored.invalid/prefix',
      );
      expect(
        regionHopEffectivePanelUrl('https://panel.example.org:8443/abc/'),
        'https://panel.example.org:8443/abc/',
      );
      // Even the new https default itself passes through
      // unchanged (it is not the legacy value).
      expect(
        regionHopEffectivePanelUrl(RegionHopDefaults.panelUrl),
        RegionHopDefaults.panelUrl,
      );
    });

    test('an empty stored URL falls back to the baked '
        'https default', () {
      expect(regionHopEffectivePanelUrl(''), RegionHopDefaults.panelUrl);
    });

    testWidgets('the form displays the https URL when the '
        'stored URL is the legacy default', (tester) async {
      final xray = XrayController();
      xray.settings.regionHopPanelUrl = RegionHopDefaults.legacyPanelUrl;
      await tester.pumpWidget(MaterialApp(home: RegionHopPage(xray: xray)));
      await tester.pump();
      final fields = tester
          .widgetList<TextField>(find.byType(TextField))
          .toList();
      expect(fields, hasLength(3));
      expect(fields[0].controller!.text, RegionHopDefaults.panelUrl);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the form keeps an unrelated stored URL '
        'verbatim', (tester) async {
      final xray = XrayController();
      xray.settings.regionHopPanelUrl = 'http://stored.invalid/prefix';
      await tester.pumpWidget(MaterialApp(home: RegionHopPage(xray: xray)));
      await tester.pump();
      final fields = tester
          .widgetList<TextField>(find.byType(TextField))
          .toList();
      expect(fields[0].controller!.text, 'http://stored.invalid/prefix');
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('source pins', () {
    test('the client pins via a trusted-certificates '
        'context and never a bad-certificate callback', () {
      final client = _src('regionhop/regionhop_client.dart');
      expect(client, contains('setTrustedCertificatesBytes'));
      expect(client, contains('RegionHopDefaults.panelCertificatePem'));
      expect(client, contains('regionHopHttpClientFor(_base)'));
      // No bad-certificate callback is ever INSTALLED
      // (the file's header comment names the property
      // only to say so — the pin targets its use: an
      // assignment or a named argument).
      expect(
        RegExp(r'badCertificateCallback\s*[=:]').hasMatch(client),
        isFalse,
      );
      // The defaults stay the only home of the values.
      final defaults = _src('regionhop/regionhop_defaults.dart');
      expect(defaults, contains('panelCertificatePem'));
      expect(defaults, contains('legacyPanelUrl'));
    });

    test('the page resolves its URL through the migration', () {
      final page = _src('ui/ember/regionhop_page.dart');
      expect(page, contains('regionHopEffectivePanelUrl('));
      expect(page, contains('RegionHopDefaults.legacyPanelUrl'));
      expect(page, contains('RegionHopDefaults.panelUrl'));
    });

    test('pubspec is 2.2.0+2148', () {
      expect(
        File('pubspec.yaml').readAsStringSync(),
        contains('version: 2.2.0+2148'),
      );
    });
  });
}
