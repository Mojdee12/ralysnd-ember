/// Build 2040 gates, host side: AmneziaWG run-mode (Iran-priority
/// queue item 2h) — a profile that carries Jc/Jmin/Jmax/S1/S2/
/// H1–H4 now runs on a dedicated AmneziaWG userspace engine
/// (libwg-go.so from amneziawg-go) instead of plain WireGuard
/// through Xray. These tests pin the DART side of the contract:
/// the UAPI settings string the native bridge feeds the device,
/// and the handshake/transfer figures that prove the obfuscated
/// tunnel carries traffic. The native engine itself (device
/// bring-up, socket protect, handshake against a real peer) is
/// proven on the device, as always; there is no emulator on
/// this VM.
import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/xray/awg_uapi.dart';
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
  group('AmneziaWG UAPI settings (queue 2h)', () {
    test('a full AWG profile serializes every field the device needs', () {
      final uapi = buildAwgUapi(awgProfile(keepAlive: 25));
      // Build 2050 (audit C-1): keys are serialized as 64-char
      // lowercase HEX — the only form amneziawg-go's IpcSet
      // parser accepts. The 2040 expectations asserted the
      // stored base64 verbatim, codifying the bug that made
      // every AWG start fail; the goldens below are the hex
      // decodings of the fixture keys.
      expect(
        uapi,
        contains(
          'private_key='
          '0000000000000000000000000000000000000000000000000000000000000000\n',
        ),
      );
      expect(
        uapi,
        contains(
          'public_key='
          '0410410410410410410410410410410410410410410410410410410410410410\n',
        ),
      );
      expect(uapi, contains('endpoint=203.0.113.7:51820\n'));
      expect(uapi, contains('allowed_ip=0.0.0.0/0\n'));
      expect(uapi, contains('allowed_ip=::/0\n'));
      expect(uapi, contains('persistent_keepalive_interval=25\n'));
      expect(uapi, contains('jc=5\n'));
      expect(uapi, contains('jmin=50\n'));
      expect(uapi, contains('jmax=1000\n'));
      expect(uapi, contains('s1=76\n'));
      expect(uapi, contains('s2=111\n'));
      expect(uapi, contains('h1=1662463973\n'));
      expect(uapi, contains('h2=1890747356\n'));
      expect(uapi, contains('h3=1954657229\n'));
      expect(uapi, contains('h4=1301181033\n'));
      // The private key goes first: UAPI peer fields belong to
      // the most recently named public key, and the device key
      // must precede the peer block.
      expect(uapi.indexOf('private_key='), lessThan(uapi.indexOf('public_key=')));
      expect(uapi.indexOf('public_key='), lessThan(uapi.indexOf('endpoint=')));
    });

    test('optional fields are omitted when the config did not carry them', () {
      final uapi = buildAwgUapi(awgProfile());
      expect(uapi, isNot(contains('preshared_key=')));
      expect(uapi, isNot(contains('persistent_keepalive_interval=')));
    });

    test('a pre-shared key is sent when the peer carries one', () {
      final uapi = buildAwgUapi(awgProfile(preSharedKey: 'CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC='));
      expect(
        uapi,
        contains(
          'preshared_key='
          '0820820820820820820820820820820820820820820820820820820820820820\n',
        ),
      );
    });

    test('an IPv6 endpoint is bracketed, as UAPI requires', () {
      final uapi = buildAwgUapi(awgProfile(address: '2001:db8::1'));
      expect(uapi, contains('endpoint=[2001:db8::1]:51820\n'));
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
      final uapi = buildAwgUapi(plain);
      expect(uapi, isNot(contains('jc=')));
      expect(uapi, isNot(contains('h1=')));
      expect(uapi, contains('endpoint=203.0.113.7:51820\n'));
    });
  });

  group('AmneziaWG status parsing (queue 2h)', () {
    const dump =
        'private_key=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\n'
        'listen_port=51820\n'
        'public_key=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=\n'
        'preshared_key=0000000000000000000000000000000000000000000000000000000000000000\n'
        'endpoint=203.0.113.7:51820\n'
        'allowed_ip=0.0.0.0/0\n'
        'latest_handshake=1792000000\n'
        'transfer_rx=123456\n'
        'transfer_tx=7890\n'
        'persistent_keepalive_interval=25\n';

    test('a fresh handshake and transfer counters parse out', () {
      // now = handshake + 37 s.
      final status = parseAwgStatus(dump, nowMs: 1792000037000);
      expect(status.hasHandshake, isTrue);
      expect(status.handshakeAgeSec, 37);
      expect(status.rxBytes, 123456);
      expect(status.txBytes, 7890);
    });

    test('a peer that never answered reports no handshake', () {
      final silent = dump.replaceAll('latest_handshake=1792000000\n', 'latest_handshake=0\n');
      final status = parseAwgStatus(silent, nowMs: 1792000037000);
      expect(status.hasHandshake, isFalse);
      expect(status.handshakeAgeSec, -1);
      // The counters still parse: zero traffic is a fact, not an error.
      expect(status.rxBytes, 123456);
    });

    test('a dump with no peer is never', () {
      final status = parseAwgStatus('errno=0\n', nowMs: 1792000037000);
      expect(status, AwgStatus.never);
      expect(status.hasHandshake, isFalse);
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
