/// W2 (full-parity build): ovpn:// links on Windows —
/// Android build 2157's parser contract, plus the Windows
/// delivery pins (installer protocol registration, the
/// runner's pending-link handoff, the shell's intake
/// registration, the paste/scan intercepts).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:firefox_vpn/openvpn/ovpn_link.dart';

const _ovpnFixture = '''
client
dev tun
proto udp
remote vpn.example.net 1194
resolv-retry infinite
nobind
<ca>
-----BEGIN CERTIFICATE-----
MIIFIXTURE
-----END CERTIFICATE-----
</ca>
''';

String src(String rel) => File(rel).readAsStringSync();

void main() {
  group('ovpn:// links — the 2157 parser contract', () {
    test('the scheme gate', () {
      expect(isOvpnLink('ovpn://abc'), isTrue);
      expect(isOvpnLink('openvpn://import-profile/https://x'), isTrue);
      expect(isOvpnLink('OVPN://abc'), isTrue);
      expect(isOvpnLink('vless://abc'), isFalse);
      expect(isOvpnLink('https://example.net/p.ovpn'), isFalse);
    });

    test('the profile-text gate', () {
      expect(isOvpnProfileText(_ovpnFixture), isTrue);
      expect(
        isOvpnProfileText('[Interface]\nPrivateKey = x\n[Peer]\n'),
        isFalse,
      );
      expect(isOvpnProfileText('just some words'), isFalse);
    });

    test('a base64 payload link decodes to the profile', () {
      final b64 = base64Encode(utf8.encode(_ovpnFixture));
      final payload = parseOvpnLink('ovpn://$b64');
      expect(payload, isA<OvpnLinkText>());
      expect((payload! as OvpnLinkText).text, _ovpnFixture);
      expect(payload.name, '');
    });

    test('a base64 payload link carries its #name', () {
      final b64 = base64Encode(utf8.encode(_ovpnFixture));
      final payload = parseOvpnLink('ovpn://$b64#My%20Server');
      expect(payload, isA<OvpnLinkText>());
      expect(payload!.name, 'My Server');
    });

    test('a URL-encoded payload link decodes', () {
      final encoded = Uri.encodeComponent(_ovpnFixture);
      final payload = parseOvpnLink('ovpn://$encoded');
      expect(payload, isA<OvpnLinkText>());
      expect((payload! as OvpnLinkText).text, _ovpnFixture);
    });

    test('the official import-profile form is a fetch', () {
      final payload = parseOvpnLink(
        'openvpn://import-profile/https://as.example.net/rest/'
        'GetProfileViaToken?token=<redacted>#Work',
      );
      expect(payload, isA<OvpnLinkFetch>());
      final fetch = payload! as OvpnLinkFetch;
      expect(
        fetch.url,
        'https://as.example.net/rest/GetProfileViaToken?token=<redacted>',
      );
      expect(fetch.name, 'Work');
    });

    test('the import-profile ?url= form is a fetch', () {
      final inner = Uri.encodeComponent('https://vpn.example.net/p.ovpn');
      final payload = parseOvpnLink('ovpn://import-profile?url=$inner');
      expect(payload, isA<OvpnLinkFetch>());
      expect((payload! as OvpnLinkFetch).url, 'https://vpn.example.net/p.ovpn');
    });

    test('a bare profile URL under the scheme is a fetch', () {
      final payload = parseOvpnLink('ovpn://https://example.net/p.ovpn');
      expect(payload, isA<OvpnLinkFetch>());
      expect((payload! as OvpnLinkFetch).url, 'https://example.net/p.ovpn');
    });

    test('cleartext and garbage are refused', () {
      expect(
        parseOvpnLink('openvpn://import-profile/http://x.example.net/p'),
        isNull,
      );
      expect(parseOvpnLink('ovpn://'), isNull);
      expect(parseOvpnLink('ovpn://not-a-profile'), isNull);
      expect(parseOvpnLink('vless://uuid@example.net:443'), isNull);
    });
  });

  group('ovpn:// links — the Windows delivery pins', () {
    test('the installer registers both protocols per-user', () {
      final iss = src('windows/installer/firefox-vpn.iss');
      expect(iss, contains('Software\\Classes\\ovpn'));
      expect(iss, contains('Software\\Classes\\openvpn'));
      expect(iss, contains('"URL Protocol"'));
      expect(iss, contains('uninsdeletekey'));
    });

    test('the runner leaves a second instance link for the shell', () {
      final cpp = src('windows/runner/main.cpp');
      expect(cpp, contains('pending-link.txt'));
      expect(cpp, contains('"ovpn://"'));
      expect(cpp, contains('"openvpn://"'));
    });

    test('the shell serves the intake seam and drains pending links', () {
      final shell = src('lib/ui/ember/ember_shell.dart');
      expect(shell, contains('OvpnLinkIntake.handler = _importOvpnLink'));
      expect(shell, contains('PendingLink.take()'));
      expect(shell, contains('fetchOvpnProfileText(url)'));
      expect(shell, contains('_openvpn.importProfile(name, text)'));
    });

    test('the paste sheet and the scanner intercept ovpn links', () {
      final qr = src('lib/ui/ember/qr_pages.dart');
      expect('isOvpnLink('.allMatches(qr).length, greaterThanOrEqualTo(2));
      expect(qr, contains('OvpnLinkIntake.handle'));
    });

    test('main stashes its own activation arguments', () {
      final main = src('lib/main.dart');
      expect(main, contains('PendingLink.looksLikeLink(arg)'));
      expect(main, contains('PendingLink.stash'));
    });
  });
}
