import 'package:firefox_vpn/openvpn/openvpn_models.dart';
import 'package:flutter_test/flutter_test.dart';

/// Build 2025: the .ovpn parser, the cipher normalization and
/// the unsupported-directive surfacing. Build 2028 removed
/// the bundled-TunnelBear index group with the bundle itself;
/// the parse-level contract that remains is the generic
/// imported profile and its per-profile credential key.
void main() {
  group('OvpnProfile.parse', () {
    test('reads remotes, proto, auth and tls-auth', () {
      final p = OvpnProfile.parse(
        id: 'x',
        name: 'Test',
        text: '''
client
dev tun
proto udp
remote vpn.example.com 1194 udp
remote backup.example.com 443 tcp
auth-user-pass
key-direction 1
<tls-auth>
-----BEGIN OpenVPN Static key V1-----
abcd
-----END OpenVPN Static key V1-----
</tls-auth>
<ca>
-----BEGIN CERTIFICATE-----
abcd
-----END CERTIFICATE-----
</ca>
''',
      );
      expect(p.remotes, hasLength(2));
      expect(p.remotes.first.host, 'vpn.example.com');
      expect(p.remotes.first.port, 1194);
      expect(p.remotes[1].proto, 'tcp');
      expect(p.proto, 'udp');
      expect(p.needsAuth, isTrue);
      expect(p.hasInlineCredentials, isFalse);
      expect(p.authenticatedControl, isTrue);
      expect(p.unsupported, isEmpty);
    });

    test('defaults the remote port and proto', () {
      final p = OvpnProfile.parse(
        id: 'x',
        name: 'T',
        text: 'client\nremote host.example\n',
      );
      expect(p.remotes.single.port, 1194);
      expect(p.proto, 'udp');
      expect(p.needsAuth, isFalse);
    });

    test('inline credentials are detected and satisfy auth', () {
      final p = OvpnProfile.parse(
        id: 'x',
        name: 'T',
        text: '''
client
remote h.example 1194
<auth-user-pass>
user1
pass1
</auth-user-pass>
''',
      );
      expect(p.needsAuth, isTrue);
      expect(p.hasInlineCredentials, isTrue);
    });

    test('unsupported directives are named, not dropped', () {
      final p = OvpnProfile.parse(
        id: 'x',
        name: 'T',
        text: '''
client
remote h.example 1194
up /etc/openvpn/up.sh
ca ca.crt
auth-user-pass secrets.txt
''',
      );
      expect(p.unsupported, contains('up'));
      expect(p.unsupported.join(' '), contains('ca file'));
      expect(p.unsupported.join(' '), contains('auth-user-pass file'));
    });

    test('an inlined CA clears the external-file flag', () {
      final p = OvpnProfile.parse(
        id: 'x',
        name: 'T',
        text: '''
client
remote h.example 1194
ca ca.crt
<ca>
-----BEGIN CERTIFICATE-----
abcd
-----END CERTIFICATE-----
</ca>
''',
      );
      expect(p.unsupported.join(' '), isNot(contains('ca file')));
    });
  });

  group('normalizeConfig', () {
    test('adds cipher from data-ciphers when cipher is absent', () {
      final out = normalizeConfig(
        'client\ndata-ciphers AES-256-GCM:AES-128-GCM\n',
      );
      expect(out, contains('cipher AES-256-GCM'));
    });

    test('leaves a profile with a cipher line untouched', () {
      const text = 'client\ncipher AES-128-GCM\ndata-ciphers AES-256-GCM\n';
      expect(normalizeConfig(text), text);
    });

    test('leaves a profile without data-ciphers untouched', () {
      const text = 'client\nremote h.example 1194\n';
      expect(normalizeConfig(text), text);
    });

    // Build 2029A (device-proven 2026-11-04): the legacy
    // directive is why the owner's TunnelBear profiles failed
    // with "bad ns-cert-type in leaf certificate"; his
    // one-line hand edit to remote-cert-tls connected.
    test('maps ns-cert-type server to remote-cert-tls server', () {
      final out = normalizeConfig('client\nns-cert-type server\n');
      expect(out, contains('remote-cert-tls server'));
      expect(out, isNot(contains('ns-cert-type')));
    });

    test('maps ns-cert-type client to remote-cert-tls client', () {
      final out = normalizeConfig('client\nns-cert-type client\n');
      expect(out, contains('remote-cert-tls client'));
      expect(out, isNot(contains('ns-cert-type')));
    });

    test('drops the legacy line when remote-cert-tls already exists', () {
      final out = normalizeConfig(
        'client\nremote-cert-tls server\nns-cert-type server\n',
      );
      expect(out, contains('remote-cert-tls server'));
      expect('remote-cert-tls'.allMatches(out), hasLength(1));
      expect(out, isNot(contains('ns-cert-type')));
    });

    test('ns-cert-type normalization composes with the cipher rule', () {
      final out = normalizeConfig(
        'client\nns-cert-type server\ndata-ciphers AES-256-GCM\n',
      );
      expect(out, contains('remote-cert-tls server'));
      expect(out, contains('cipher AES-256-GCM'));
    });

    test('a commented ns-cert-type line is left alone', () {
      const text = 'client\n# ns-cert-type server\n';
      expect(normalizeConfig(text), text);
    });
  });

  group('inline credentials (build 2029A)', () {
    const withBlock = '''
client
remote h.example 1194
<auth-user-pass>
myuser
mypass
</auth-user-pass>
<ca>
-----BEGIN CERTIFICATE-----
abcd
-----END CERTIFICATE-----
</ca>
''';

    test('the pair is extracted from the block', () {
      final pair = inlineCredentialsOf(withBlock);
      expect(pair, isNotNull);
      expect(pair!.user, 'myuser');
      expect(pair.pass, 'mypass');
    });

    test('no block means no pair', () {
      expect(inlineCredentialsOf('client\nauth-user-pass\n'), isNull);
    });

    test('stripping leaves the bare directive and no secrets', () {
      final out = stripInlineCredentials(withBlock);
      expect(out, contains('auth-user-pass'));
      expect(out, isNot(contains('myuser')));
      expect(out, isNot(contains('mypass')));
      expect(out, isNot(contains('<auth-user-pass>')));
      final p = OvpnProfile.parse(id: 'x', name: 'T', text: out);
      expect(p.needsAuth, isTrue);
      expect(p.hasInlineCredentials, isFalse);
    });
  });

  group('ovpnContentId (build 2029A)', () {
    test('is stable for identical content', () {
      const text = 'client\nremote h.example 1194\n';
      expect(ovpnContentId(text), ovpnContentId(text));
    });

    test('differs when the content differs', () {
      expect(
        ovpnContentId('client\nremote a.example 1194\n'),
        isNot(ovpnContentId('client\nremote b.example 1194\n')),
      );
    });

    test('is normalization-insensitive for the legacy directive', () {
      // The hand-edited and the raw form of the same profile
      // normalize to the same text, hence the same id — the
      // re-import lands on the existing profile and its vault
      // entry instead of orphaning both.
      final raw = normalizeConfig('client\nns-cert-type server\n');
      final edited = normalizeConfig('client\nremote-cert-tls server\n');
      expect(ovpnContentId(raw), ovpnContentId(edited));
    });
  });

  group('generic imported profile (build 2028)', () {
    // The TunnelBear bundle is gone (owner's ruling: a plain
    // client). What remains at parse level: an imported-style
    // profile carries its OWN id as its vault key — there is
    // no shared account entry anymore.
    test('an imported profile keys its credentials by its own id', () {
      const text = '''
client
dev tun
proto udp
remote vpn.example.com 1194
auth-user-pass
<ca>
-----BEGIN CERTIFICATE-----
MIIBszCCAVmgAwIBAgIUUVWvpAaBfLnDpIO+fKcvkPq+DdAwCgYIKoZIzj0EAwIw
-----END CERTIFICATE-----
</ca>
''';
      final p = OvpnProfile.parse(
        id: 'user-123',
        name: 'Mine',
        text: text,
        credKey: 'user-123',
      );
      expect(p.credKey, 'user-123');
      expect(p.needsAuth, isTrue);
      expect(p.hasInlineCredentials, isFalse);
      expect(p.remotes.single.host, 'vpn.example.com');
    });

    test('a stored profile round-trips with credKey = its id', () {
      const text = 'client\ndev tun\nremote h.example 443 tcp\nauth-user-pass\n';
      final p = OvpnProfile.fromJson({
        'id': 'user-9',
        'name': 'Stored',
        'config': text,
      });
      expect(p.id, 'user-9');
      expect(p.credKey, 'user-9');
      expect(p.needsAuth, isTrue);
    });
  });
}
