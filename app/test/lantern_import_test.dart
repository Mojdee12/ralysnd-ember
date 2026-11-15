import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:firefox_vpn/xray/lantern_import.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

/// A connect-config body in the documented lantern-server-manager
/// shape (sing-box client config; the Shadowsocks outbound is the
/// tunnel). Values are fixtures, not live credentials.
const _connectConfig = '''
{
  "log": {"level": "info"},
  "outbounds": [
    {
      "type": "shadowsocks",
      "tag": "proxy",
      "server": "203.0.113.7",
      "server_port": 8388,
      "method": "chacha20-ietf-poly1305",
      "password": "fixture-password-123"
    },
    {"type": "direct", "tag": "direct"}
  ],
  "route": {"final": "proxy"}
}
''';

const _seLink =
    'https://lantern.io/private-server?ip=13.53.234.228&port=8080'
    '&token=aaa.bbb.ccc&name=Viahamed-SE&exp=1793640027'
    '&alias=IranUnlocked-SE';

void main() {
  group('parseLanternPrivateServerLink', () {
    test('https form with all params', () {
      final link = parseLanternPrivateServerLink(_seLink);
      expect(link, isNotNull);
      expect(link!.ip, '13.53.234.228');
      expect(link.port, 8080);
      expect(link.token, 'aaa.bbb.ccc');
      expect(link.name, 'Viahamed-SE');
      expect(link.alias, 'IranUnlocked-SE');
      expect(link.displayName, 'IranUnlocked-SE');
      expect(
        link.connectConfigUri.toString(),
        'https://13.53.234.228:8080/api/v1/connect-config?token=aaa.bbb.ccc',
      );
    });

    test('lantern:// form', () {
      final link = parseLanternPrivateServerLink(
        'lantern://private-server?ip=45.136.5.250&port=8080&token=t.o.k&name=Viahamed-TR',
      );
      expect(link, isNotNull);
      expect(link!.ip, '45.136.5.250');
      expect(link.displayName, 'Viahamed-TR');
    });

    test('lantern// form (canonical access key)', () {
      final link = parseLanternPrivateServerLink(
        'lantern//private-server?ip=45.136.5.250&port=8080&token=t.o.k',
      );
      expect(link, isNotNull);
      expect(link!.ip, '45.136.5.250');
      expect(link.displayName, 'Lantern 45.136.5.250');
    });

    test('port defaults to 8080 when absent', () {
      final link = parseLanternPrivateServerLink(
        'https://lantern.io/private-server?ip=192.0.2.1&token=t.o.k',
      );
      expect(link!.port, 8080);
    });

    test('missing token is rejected', () {
      expect(
        parseLanternPrivateServerLink(
          'https://lantern.io/private-server?ip=192.0.2.1&port=8080',
        ),
        isNull,
      );
    });

    test('missing ip is rejected', () {
      expect(
        parseLanternPrivateServerLink(
          'https://lantern.io/private-server?port=8080&token=t.o.k',
        ),
        isNull,
      );
    });

    test('non-numeric port is rejected', () {
      expect(
        parseLanternPrivateServerLink(
          'https://lantern.io/private-server?ip=192.0.2.1&port=abc&token=t.o.k',
        ),
        isNull,
      );
    });

    test('unrelated URLs and share links are not Lantern links', () {
      expect(
        parseLanternPrivateServerLink(
          'https://example.com/private-server?ip=192.0.2.1&token=t.o.k',
        ),
        isNull,
      );
      expect(
        parseLanternPrivateServerLink('ss://YWVzLTI1Ni1nY206cHc@h:8388#x'),
        isNull,
      );
      expect(
        parseLanternPrivateServerLink('https://lantern.io/download'),
        isNull,
      );
    });
  });

  group('findLanternPrivateServerLink', () {
    test('finds a link inside a pasted channel post', () {
      const post = '''
📢 Private servers for Lantern
📍 Sweden server:
$_seLink
⚙ If it does not import, ask us
''';
      final link = findLanternPrivateServerLink(post);
      expect(link, isNotNull);
      expect(link!.alias, 'IranUnlocked-SE');
      expect(containsLanternPrivateServerLink(post), isTrue);
    });

    test('no link in ordinary text', () {
      expect(findLanternPrivateServerLink('just some text'), isNull);
      expect(containsLanternPrivateServerLink('vless://x@y:443#n'), isFalse);
    });
  });

  group('profileFromConnectConfig', () {
    test('maps the Shadowsocks outbound to a profile', () {
      final profile = profileFromConnectConfig(
        _connectConfig,
        fallbackName: 'IranUnlocked-SE',
      );
      expect(profile.protocol, Protocol.shadowsocks);
      expect(profile.name, 'IranUnlocked-SE');
      expect(profile.address, '203.0.113.7');
      expect(profile.port, 8388);
      expect(profile.method, 'chacha20-ietf-poly1305');
      expect(profile.uuidOrPassword, 'fixture-password-123');
    });

    test('skips non-Shadowsocks outbounds before it', () {
      const body = '{"outbounds":['
          '{"type":"wireguard","tag":"wg","address":["10.0.0.2/32"]},'
          '{"type":"shadowsocks","server":"198.51.100.9",'
          '"server_port":443,"method":"aes-256-gcm","password":"pw"}]}';
      final profile = profileFromConnectConfig(body, fallbackName: 'X');
      expect(profile.address, '198.51.100.9');
      expect(profile.method, 'aes-256-gcm');
    });

    test('no Shadowsocks outbound is a clear error', () {
      const body = '{"outbounds":['
          '{"type":"wireguard","tag":"wg","address":["10.0.0.2/32"]}]}';
      expect(
        () => profileFromConnectConfig(body, fallbackName: 'X'),
        throwsA(
          isA<LanternImportException>()
              .having((e) => e.message, 'message', contains('Shadowsocks')),
        ),
      );
    });

    test('incomplete Shadowsocks outbound is a clear error', () {
      const body = '{"outbounds":['
          '{"type":"shadowsocks","server":"198.51.100.9",'
          '"server_port":443,"method":"aes-256-gcm"}]}';
      expect(
        () => profileFromConnectConfig(body, fallbackName: 'X'),
        throwsA(
          isA<LanternImportException>()
              .having((e) => e.message, 'message', contains('incomplete')),
        ),
      );
    });

    test('invalid JSON is a clear error', () {
      expect(
        () => profileFromConnectConfig('<html>no</html>', fallbackName: 'X'),
        throwsA(isA<LanternImportException>()),
      );
    });
  });

  group('fetchLanternPrivateServerProfile', () {
    final link = parseLanternPrivateServerLink(_seLink)!;

    test('200 maps to a profile named from the alias', () async {
      final profile = await fetchLanternPrivateServerProfile(
        link,
        get: (url) async {
          expect(url.host, '13.53.234.228');
          expect(url.queryParameters['token'], 'aaa.bbb.ccc');
          return (statusCode: 200, body: _connectConfig);
        },
      );
      expect(profile.name, 'IranUnlocked-SE');
      expect(profile.address, '203.0.113.7');
    });

    test('401 explains the token was rejected', () async {
      await expectLater(
        fetchLanternPrivateServerProfile(
          link,
          get: (url) async => (statusCode: 401, body: 'Unauthorized\n'),
        ),
        throwsA(
          isA<LanternImportException>()
              .having((e) => e.message, 'message', contains('token')),
        ),
      );
    });

    test('500 is reported with its status', () async {
      await expectLater(
        fetchLanternPrivateServerProfile(
          link,
          get: (url) async => (statusCode: 500, body: 'boom'),
        ),
        throwsA(
          isA<LanternImportException>()
              .having((e) => e.message, 'message', contains('HTTP 500')),
        ),
      );
    });

    test('socket failures become a reachability message', () async {
      await expectLater(
        fetchLanternPrivateServerProfile(
          link,
          get: (url) async => throw const SocketException('unreachable'),
        ),
        throwsA(
          isA<LanternImportException>()
              .having((e) => e.message, 'message', contains('Could not reach')),
        ),
      );
    });

    test('timeouts become a timed-out message', () async {
      await expectLater(
        fetchLanternPrivateServerProfile(
          link,
          get: (url) async => throw TimeoutException('slow'),
        ),
        throwsA(
          isA<LanternImportException>()
              .having((e) => e.message, 'message', contains('did not answer')),
        ),
      );
    });
  });
}
