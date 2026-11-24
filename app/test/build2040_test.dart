/// Build 2040 gates, host side: AmneziaWG run-mode (Iran-priority
/// queue item 2h) — a profile that carries Jc/Jmin/Jmax/S1/S2/
/// H1–H4 runs on a dedicated AmneziaWG engine instead of plain
/// WireGuard through Xray.
///
/// Build 2104 rewrite: the engine is WG Tunnel's backend now,
/// and the Dart side of the contract is the canonical .conf
/// hand-off (wgConfFromProfile) — the tests below pin that
/// text. The 2040–2103 contract (the buildAwgUapi settings
/// string and the parseAwgStatus handshake figures) is
/// DELETED with the bridge it fed: its status fixture even
/// codified the standing bug — a UAPI dump keyed
/// `latest_handshake=`, a key no device emits, which is why
/// the handshake age was permanently -1 and working tunnels
/// were torn down as "never answered". The replacement state
/// path (backend-computed handshake age, display only) is
/// pinned in build2104_test.dart. The native engine itself
/// (device bring-up, socket protect, handshake against a
/// real peer) is proven on the device, as always; there is
/// no emulator on this VM.
import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/xray/wg_conf.dart';
import 'package:firefox_vpn/xray/xray_controller.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

Profile awgProfile({
  String address = '203.0.113.7',
  int port = 51820,
  String preSharedKey = '',
  int keepAlive = 0,
}) => Profile(
  id: 'awg1',
  protocol: Protocol.wireguard,
  name: 'awg1',
  address: address,
  port: port,
  secretKey: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
  peerPublicKey: 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=',
  preSharedKey: preSharedKey,
  localAddress: '10.66.66.2/32',
  mtu: 1280,
  keepAlive: keepAlive,
  awgJc: '5',
  awgJmin: '50',
  awgJmax: '1000',
  awgS1: '76',
  awgS2: '111',
  awgH1: '1662463973',
  awgH2: '1890747356',
  awgH3: '1954657229',
  awgH4: '1301181033',
);

void main() {
  group('AmneziaWG .conf hand-off (queue 2h; build 2104 form)', () {
    test('a full AWG profile serializes every field the engine needs', () {
      final conf = wgConfFromProfile(awgProfile(keepAlive: 25));
      // Keys ride in base64, the .conf form the WG Tunnel
      // parser consumes (the 2040–2103 UAPI hand-off hexed
      // them for the old bridge; that layer is deleted).
      expect(
        conf,
        contains(
          'PrivateKey = '
          'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\n',
        ),
      );
      expect(
        conf,
        contains(
          'PublicKey = '
          'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=\n',
        ),
      );
      expect(conf, contains('Address = 10.66.66.2/32\n'));
      expect(conf, contains('Endpoint = 203.0.113.7:51820\n'));
      expect(conf, contains('PersistentKeepalive = 25\n'));
      expect(conf, contains('Jc = 5\n'));
      expect(conf, contains('Jmin = 50\n'));
      expect(conf, contains('Jmax = 1000\n'));
      expect(conf, contains('S1 = 76\n'));
      expect(conf, contains('S2 = 111\n'));
      expect(conf, contains('H1 = 1662463973\n'));
      expect(conf, contains('H2 = 1890747356\n'));
      expect(conf, contains('H3 = 1954657229\n'));
      expect(conf, contains('H4 = 1301181033\n'));
      // The Amnezia parameters are interface keys: they sit
      // in [Interface], before the [Peer] block — the .conf
      // form of the 2086 device-key placement rule.
      expect(conf.indexOf('Jc ='), lessThan(conf.indexOf('[Peer]')));
      expect(conf.indexOf('H4 ='), lessThan(conf.indexOf('[Peer]')));
      expect(
        conf.indexOf('PrivateKey ='),
        lessThan(conf.indexOf('PublicKey =')),
      );
    });

    test('optional fields are omitted when the config did not carry them', () {
      final conf = wgConfFromProfile(awgProfile());
      expect(conf, isNot(contains('PresharedKey')));
      expect(conf, isNot(contains('PersistentKeepalive')));
    });

    test('a pre-shared key is sent when the peer carries one', () {
      final conf = wgConfFromProfile(
        awgProfile(
          preSharedKey: 'CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC=',
        ),
      );
      expect(
        conf,
        contains(
          'PresharedKey = '
          'CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC=\n',
        ),
      );
    });

    test('an IPv6 endpoint is bracketed, as .conf requires', () {
      final conf = wgConfFromProfile(awgProfile(address: '2001:db8::1'));
      expect(conf, contains('Endpoint = [2001:db8::1]:51820\n'));
    });

    test('a plain WireGuard profile sends no obfuscation fields', () {
      final plain = Profile(
        id: 'wg1',
        protocol: Protocol.wireguard,
        name: 'wg1',
        address: '203.0.113.7',
        port: 51820,
        secretKey: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
        peerPublicKey: 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=',
      );
      expect(plain.hasAmneziaParams, isFalse);
      final conf = wgConfFromProfile(plain);
      expect(conf, isNot(contains('Jc =')));
      expect(conf, isNot(contains('H1 =')));
      expect(conf, contains('Endpoint = 203.0.113.7:51820\n'));
    });
  });

  group('Seamless switch eligibility with an AWG session (queue 2h)', () {
    test('an AWG session may not rotate: there is no Xray core to respawn', () {
      expect(
        XrayController.seamlessSwitchAllowed(
          running: true,
          warpSession: false,
          underlay: 'none',
          awgSession: true,
        ),
        isFalse,
      );
    });

    test('a plain running Xray session may still rotate', () {
      expect(
        XrayController.seamlessSwitchAllowed(
          running: true,
          warpSession: false,
          underlay: 'none',
        ),
        isTrue,
      );
    });
  });
}
