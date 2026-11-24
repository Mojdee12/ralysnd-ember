/// The EmberWarp core's command line (build 2030), built
/// from the warp profile after the patterniha/Aether spawn
/// contract (RE dossier §2.3/§7):
///
/// - protocol + scan + ip are ALWAYS passed: with any of them
///   missing the core prompts interactively on stdin, and a
///   subprocess must never wait on a prompt (its stdin is
///   /dev/null on the native side).
/// - The listen socket is always the session port in session
///   mode; probe/renewal runs pass the probe port.
/// - MASQUE over HTTP/2 is the default transport (dossier
///   Q5): --h2 + --fragment; H3 is the profile's explicit
///   alternative and scans stay H2-shaped.
/// - ECH, when on, resolves through an ENCRYPTED resolver —
///   never the core's plain-UDP default (the dossier's ECH
///   resolver rule).

import 'xray_models.dart';

/// The EmberWarp session SOCKS port (dossier Q6).
const int warpSessionPort = 20850;

/// The chain mode's inline exit port: Xray listens here and
/// the warp core's whole egress goes through it (the exit-node
/// freedom outbound on the Xray side carries the profile's
/// finalMask/dialMode).
const int warpExitPort = 20851;

/// Probe / renewal runs listen here instead of the session port.
const int warpProbePort = 20853;

/// The exit port paired with a probe run.
const int warpProbeExitPort = 20854;

/// The encrypted resolver used for ECH lookups when the
/// profile does not name one.
const String warpDefaultEchDns = 'https://cloudflare-dns.com/dns-query';

/// Builds the core's argv. [upstream] is the chain mode's
/// exit listener URL (socks5://127.0.0.1:20851); empty in
/// standalone mode, where the core dials directly.
List<String> buildWarpArgs(
  WarpProfile w, {
  int port = warpSessionPort,
  String upstream = '',
}) {
  final args = <String>[
    '--bind', '127.0.0.1:$port',
    '--protocol', w.protocol,
    '--scan', w.scan,
    '--ip', w.ipVersion,
  ];
  // Build 2129: mim is MASQUE-family here too — both hops
  // ride the one carrier, so the SNI / H2 / fragment / obfs
  // shape is the masque shape.
  final masqueFamily =
      w.protocol == 'masque' || w.protocol == 'gool' || w.protocol == 'mim';
  if (masqueFamily) {
    args.addAll(['--masque-sni', w.masqueSni]);
    if (w.transport == 'h2') {
      args.add('--h2');
      if (w.fragment) args.add('--fragment');
    }
    if (w.obfuscation != 'auto') {
      args.addAll(['--obfs', w.obfuscation]);
    }
  }
  if (w.dns.isNotEmpty) args.addAll(['--dns', w.dns]);
  if (w.exitLoc.isNotEmpty) args.addAll(['--exit-loc', w.exitLoc]);
  if (w.peer.isNotEmpty) args.addAll(['--peer', w.peer]);
  if (upstream.isNotEmpty) args.addAll(['--upstream', upstream]);
  if (w.ech) {
    args.addAll([
      '--ech', 'auto',
      '--ech-dns', w.echDns.isNotEmpty ? w.echDns : warpDefaultEchDns,
    ]);
  }
  return args;
}

/// The --register kind for an explicit identity renewal of
/// this profile: the protocol whose identity the session
/// needs (gool registers its own composed identity).
String warpRegisterKind(WarpProfile w) => w.protocol;

/// The well-known public WARP endpoints (build 2065, item 10):
/// Cloudflare's published WireGuard gateway addresses on the
/// standard port. Offered as one-tap pins in the EmberWarp settings;
/// an empty peer hands the gateway search to the core's own
/// scan.
const kKnownWarpEndpoints = <String>[
  '162.159.192.1:2408',
  '162.159.193.1:2408',
  '162.159.195.1:2408',
  '188.114.96.1:2408',
  '188.114.97.1:2408',
];
