/// The Windows AmneziaWG hand-off (W2): the .conf text the
/// tunnel service is installed from must carry Android's own
/// transformations (build 2102 C1/C2, build 2116 B3-1) and
/// nothing else — the Amnezia parameters ride verbatim — and
/// the UAPI dump parse must read the keys the service emits.
import 'package:flutter_test/flutter_test.dart';
import 'package:firefox_vpn/xray/xray_platform_windows.dart';

void main() {
  const conf = '''
[Interface]
PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
Address = 10.2.0.2/32
DNS = 10.2.0.1
Jc = 5
Jmin = 40
Jmax = 70
S1 = 90
S2 = 95
H1 = 1234567890
H2 = 1234567891
H3 = 1234567892
H4 = 1234567893

[Peer]
PublicKey = BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=
Endpoint = 203.0.113.7:51820
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
''';

  test('DNS is replaced, the profile MTU stands, peers untouched', () {
    final out = buildAwgServiceConfig(
      conf,
      dns: '1.1.1.1, 8.8.8.8',
      ipv4: true,
      ipv6: true,
      mtu: 1400,
    );
    expect(out, contains('DNS = 1.1.1.1, 8.8.8.8'));
    expect(out, isNot(contains('DNS = 10.2.0.1')));
    // The profile carries no MTU: the Settings fallback lands.
    expect(out, contains('MTU = 1400'));
    // Amnezia parameters ride verbatim.
    expect(out, contains('Jc = 5'));
    expect(out, contains('H4 = 1234567893'));
    // A peer with its own AllowedIPs is never rewritten.
    expect(out, contains('AllowedIPs = 0.0.0.0/0, ::/0'));
  });

  test('a peer without AllowedIPs gets the family-gated default', () {
    const bare = '''
[Interface]
PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
Address = 10.2.0.2/32

[Peer]
PublicKey = BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=
Endpoint = 203.0.113.7:51820
''';
    final v6only = buildAwgServiceConfig(
      bare,
      dns: '',
      ipv4: false,
      ipv6: true,
      mtu: 0,
    );
    expect(v6only, contains('AllowedIPs = ::/0'));
    expect(v6only, isNot(contains('0.0.0.0/0')));
    final both = buildAwgServiceConfig(
      bare,
      dns: '',
      ipv4: true,
      ipv6: true,
      mtu: 0,
    );
    expect(both, contains('AllowedIPs = 0.0.0.0/0, ::/0'));
    // No DNS argument: no DNS line is invented.
    expect(both, isNot(contains('DNS =')));
    // mtu 0: no MTU line is invented.
    expect(both, isNot(contains('MTU =')));
  });

  test('the profile MTU wins over the Settings fallback', () {
    final out = buildAwgServiceConfig(
      '[Interface]\nPrivateKey = AAAA\nMTU = 1280\n',
      dns: '',
      ipv4: true,
      ipv6: false,
      mtu: 1500,
    );
    expect(out, contains('MTU = 1280'));
    expect(out, isNot(contains('MTU = 1500')));
  });

  test('tunnel names are service-safe', () {
    expect(awgTunnelNameFor('Warp Scout (test)'), 'Warp_Scout__test');
    expect(awgTunnelNameFor(''), 'ember');
    expect(awgTunnelNameFor('a' * 60).length, 40);
    expect(awgTunnelNameFor('my.conf'), 'my.conf');
  });

  test('UAPI dumps parse to the newest handshake and summed bytes', () {
    const dump = '''
public_key=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=
latest_handshake_time_sec=1700000100
rx_bytes=1000
tx_bytes=2000
public_key=CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC=
latest_handshake_time_sec=1700000200
rx_bytes=3000
tx_bytes=4000
errno=0
''';
    final f = parseAwgUapiDump(dump, nowSec: 1700000260)!;
    expect(f.handshakeAgeSec, 60);
    expect(f.rxBytes, 4000);
    expect(f.txBytes, 6000);
    // The v1 key reads the same way.
    final v1 = parseAwgUapiDump(
      'public_key=BB=\nlast_handshake_time_sec=100\nrx_bytes=1\ntx_bytes=2\n',
      nowSec: 130,
    )!;
    expect(v1.handshakeAgeSec, 30);
    // No peer, no figures; a silent peer has no age.
    expect(parseAwgUapiDump('errno=0\n'), isNull);
    final silent = parseAwgUapiDump(
      'public_key=BB=\nlatest_handshake_time_sec=0\nrx_bytes=0\ntx_bytes=0\n',
      nowSec: 130,
    )!;
    expect(silent.handshakeAgeSec, -1);
  });
}
