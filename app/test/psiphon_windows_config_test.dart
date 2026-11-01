/// The Windows Psiphon backend's ConsoleClient config must stay key
/// for key identical to the Android engine's buildConfig
/// (PsiphonVpnService.kt) with the same bootstrap values
/// (PsiphonConstants.kt) — the network only accepts the real set.
/// The long opaque values are pinned by length and endpoints so a
/// transcription slip fails here instead of on a user's machine.
import 'package:flutter_test/flutter_test.dart';
import 'package:firefox_vpn/psiphon/psiphon_bootstrap.dart';
import 'package:firefox_vpn/psiphon/psiphon_platform_windows.dart';

void main() {
  test('config keys match the Android buildConfig exactly', () {
    final cfg = buildPsiphonConfig(
      dataRoot: 'D',
      region: '',
      upstream: '',
      protocols: const [],
    );
    expect(cfg.keys.toSet(), {
      'ClientVersion',
      'PropagationChannelId',
      'SponsorId',
      'RemoteServerListSignaturePublicKey',
      'ServerEntrySignaturePublicKey',
      'AdditionalParameters',
      'DataRootDirectory',
      'LocalSocksProxyPort',
      'LocalHttpProxyPort',
      'EmitDiagnosticNotices',
      'EmitBytesTransferred',
      'EgressRegion',
    });
    expect(cfg['DataRootDirectory'], 'D');
    expect(cfg['LocalSocksProxyPort'], 11808);
    expect(cfg['LocalHttpProxyPort'], 11809);
    expect(cfg['EmitDiagnosticNotices'], isTrue);
    expect(cfg['EmitBytesTransferred'], isTrue);
    expect(cfg['EgressRegion'], '');
  });

  test('optional keys appear only when set, as on Android', () {
    final cfg = buildPsiphonConfig(
      dataRoot: 'D',
      region: 'DE',
      upstream: 'socks5://127.0.0.1:8080',
      protocols: const ['OSSH'],
    );
    expect(cfg['EgressRegion'], 'DE');
    expect(cfg['UpstreamProxyURL'], 'socks5://127.0.0.1:8080');
    expect(cfg['LimitTunnelProtocols'], ['OSSH']);
  });

  test('bootstrap values are the pinned Android set', () {
    expect(PsiphonBootstrap.clientVersion, '509');
    expect(PsiphonBootstrap.propagationChannelId, '92AACC5BABE0944C');
    expect(PsiphonBootstrap.sponsorId, '40001BC527D3D099');
    expect(
      PsiphonBootstrap.serverEntrySignaturePublicKey,
      'sHuUVTWaRyh5pZwy4UguSgkwmBe0EHtJJkoF5WrxmvA=',
    );
    final rsl = PsiphonBootstrap.remoteServerListSignaturePublicKey;
    expect(rsl.length, 732);
    expect(rsl, startsWith('MIICIDANBgkqhkiG9w0BAQEFAAOCAg0AMIICCAKCAgEA'));
    expect(rsl, endsWith('CAQM='));
    final ap = PsiphonBootstrap.additionalParameters;
    expect(ap.length, 10684);
    expect(ap, startsWith('TKN/tcAoxI6pU82Fl9kflMyP6T3JrH3ZwJjUS22vIJoN7lUU'));
  });
}
