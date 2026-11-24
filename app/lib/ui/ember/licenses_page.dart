/// Open Source Licenses (build 2030): the engines Ember
/// embeds, their licenses, and — for the EmberWarp core —
/// the full AGPL-3.0 text and the source link the license
/// requires to stay reachable. The EmberWarp core is built
/// from patterniha/Aether at commit d58f9d5 (AGPL-3.0);
/// "Aether" is its authors' trademark, which is why the
/// engine carries Ember's own name everywhere in the app.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../../core/android_core.dart';
import 'ember_theme.dart';

const _aetherSourceUrl = 'https://github.com/patterniha/Aether';
const _psiphonSourceUrl = 'https://github.com/Psiphon-Labs/psiphon-tunnel-core';
const _senpaiSourceUrl = 'https://github.com/matinsenpai/senpaiscanner';
const _geoipSourceUrl = 'https://github.com/v2fly/geoip';
const _shiroSourceUrl = 'https://github.com/shirokhorshid/shirokhorshid-android';
const _xraySourceUrl = 'https://github.com/XTLS/Xray-core';
const _openVpnSourceUrl = 'https://github.com/OpenVPN/openvpn3';
const _dnsttSourceUrl = 'https://github.com/Mygod/dnstt';
const _wstunnelSourceUrl = 'https://github.com/erebe/wstunnel';
const _wgTunnelSourceUrl = 'https://github.com/wgtunnel/android';
const _wgTunnelCoreSourceUrl = 'https://github.com/wgtunnel/core';

class LicensesPage extends StatelessWidget {
  const LicensesPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Ember.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Ember.text,
        title: Text('Open Source Licenses', style: Ember.heading),
      ),
      body: EmberBackground(
        child: ListView(
          padding: EdgeInsets.fromLTRB(18, MediaQuery.of(context).padding.top + kToolbarHeight + 6, 18, 24),
          children: [
            _entry(
              context,
              title: 'EmberWarp core',
              license: 'GNU AGPL-3.0',
              body:
                  'The WARP engine is built from the Aether '
                  'client by patterniha (source at commit '
                  'd58f9d5), renamed as its trademark policy '
                  'requires. Under the AGPL, the complete '
                  'corresponding source is available at the '
                  'link below, and the full license text ships '
                  'with the app.',
              links: [
                (
                  'Read the AGPL-3.0 text',
                  () {
                    Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const _AgplTextPage()),
                    );
                  },
                ),
                (
                  'Source: patterniha/Aether',
                  () {
                    unawaited(AndroidCore.openUrl(_aetherSourceUrl));
                  },
                ),
              ],
            ),
            _entry(
              context,
              title: 'Psiphon core',
              license: 'GNU GPL-3.0',
              body:
                  'The Psiphon engine\u2019s tunnel core '
                  '(psiphon-tunnel-core, by Psiphon Inc. and '
                  'contributors), run through its Android '
                  'host library.',
              links: [
                (
                  'Read the GPL-3.0 text',
                  () {
                    Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const _GplTextPage()),
                    );
                  },
                ),
                (
                  'Source: Psiphon-Labs/psiphon-tunnel-core',
                  () {
                    unawaited(AndroidCore.openUrl(_psiphonSourceUrl));
                  },
                ),
              ],
            ),
            _entry(
              context,
              title: 'Shirokhorshid bootstrap',
              license: 'GNU GPL-3.0-or-later',
              // Build 2129 (Leg 2): the optional Shiro
              // bootstrap (Psiphon settings, default OFF)
              // adopts the public partner bootstrap
              // published with the Shirokhorshid Android
              // release — its identity set, its embedded
              // server list (whose lineage also credits
              // MehrON\u2019s public list) and its fronting
              // overrides.
              body:
                  'The optional Shiro bootstrap in Psiphon '
                  'settings: the public partner bootstrap '
                  'from the Shirokhorshid project '
                  '(Shirokhorshid/MehrON) — identity set, '
                  'embedded server list and fronting '
                  'overrides, used only when the toggle is '
                  'on.',
              links: [
                (
                  'Read the GPL-3.0 text',
                  () {
                    Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const _GplTextPage()),
                    );
                  },
                ),
                (
                  'Source: shirokhorshid/shirokhorshid-android',
                  () {
                    unawaited(AndroidCore.openUrl(_shiroSourceUrl));
                  },
                ),
              ],
            ),
            _entry(
              context,
              title: 'SenPaiScanner',
              license: 'MIT',
              // Build 2129 (Leg 3): the vendored scanner
              // binary in the DPI Lab, with its MIT text
              // bundled (assets/licenses/senpai-mit.txt).
              body:
                  'The Senpai endpoint scanner in the DPI '
                  'Lab, by matinsenpai and contributors — '
                  'the binary ships unmodified from the '
                  'LML release, under the MIT License.',
              links: [
                (
                  'Read the MIT text',
                  () {
                    Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const _SenpaiMitTextPage()),
                    );
                  },
                ),
                (
                  'Source: matinsenpai/senpaiscanner',
                  () {
                    unawaited(AndroidCore.openUrl(_senpaiSourceUrl));
                  },
                ),
              ],
            ),
            _entry(
              context,
              title: 'Offline country data (v2fly/geoip)',
              license: 'CC BY-SA 4.0',
              // Build 2129 (Leg 6): the offline IP→country
              // range tables behind the exit-country
              // fallback, adapted from v2fly/geoip release
              // 202610050438 (which in turn credits DB-IP,
              // CC BY 4.0). The notice and the full
              // CC BY-SA 4.0 text ship as assets.
              body:
                  'The offline country tables the app '
                  'consults when an exit lookup cannot name '
                  'a country: adapted from the v2fly/geoip '
                  'release 202610050438 — country ranges '
                  'converted to sorted, merged IP ranges, '
                  'with private, test and unspecified '
                  'groups omitted. The v2fly project also '
                  'credits free IP geolocation data by '
                  'DB-IP (CC BY 4.0).',
              links: [
                (
                  'Read the data notice',
                  () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const _GeoIpNoticeTextPage(),
                      ),
                    );
                  },
                ),
                (
                  'Read the CC BY-SA 4.0 text',
                  () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const _GeoIpLicenseTextPage(),
                      ),
                    );
                  },
                ),
                (
                  'Source: v2fly/geoip',
                  () {
                    unawaited(AndroidCore.openUrl(_geoipSourceUrl));
                  },
                ),
              ],
            ),
            _entry(
              context,
              title: 'Xray core (patched)',
              license: 'Mozilla Public License 2.0',
              body:
                  'The V2Ray engine, with the dialMode / '
                  'Finalmask / +one patches from the '
                  'patterniha fork of XTLS/Xray-core.',
              links: [
                (
                  'Source: XTLS/Xray-core',
                  () {
                    unawaited(AndroidCore.openUrl(_xraySourceUrl));
                  },
                ),
              ],
            ),
            _entry(
              context,
              title: 'OpenVPN3 core',
              // Build 2095 (whole-app journey audit, §9
              // minor): OpenVPN3 is AGPL-3.0 — it was
              // mislabelled MPL 2.0 here.
              license: 'GNU Affero General Public License 3.0',
              body: 'The OpenVPN engine’s protocol core.',
              links: [
                (
                  'Source: OpenVPN/openvpn3',
                  () {
                    unawaited(AndroidCore.openUrl(_openVpnSourceUrl));
                  },
                ),
              ],
            ),
            _entry(
              context,
              title: 'dnstt client',
              license: 'Public domain (CC0)',
              body:
                  'The DNSTT underlay\u2019s tunnel client, by '
                  'David Fifield and contributors — DNS tunnel '
                  'transport for the V2Ray chain.',
              links: [
                (
                  'Source: Mygod/dnstt',
                  () {
                    unawaited(AndroidCore.openUrl(_dnsttSourceUrl));
                  },
                ),
              ],
            ),
            _entry(
              context,
              title: 'wstunnel client',
              license: 'MIT',
              body:
                  'The WireGuard-over-WebSocket forwarder, by '
                  'erebe and contributors.',
              links: [
                (
                  'Source: erebe/wstunnel',
                  () {
                    unawaited(AndroidCore.openUrl(_wstunnelSourceUrl));
                  },
                ),
              ],
            ),
            _entry(
              context,
              title: 'WG Tunnel backend',
              license: 'MIT',
              // Build 2104: the AmneziaWG engine IS WG
              // Tunnel's backend (com.wgtunnel:backend,
              // backend-android-jni and parser, version
              // 1.10.1), by Zane Schepke and contributors.
              // The core's NOTICE file carries five
              // third-party entries; the three that apply to
              // the Android backend Ember ships are
              // summarized in the body: its tunnel
              // library builds on amneziawg-go (MIT), its
              // config parser embeds a Curve25519
              // implementation (Apache-2.0), and the backend
              // links hev-socks5-tunnel (MIT) for its proxy
              // mode (verification iteration 2, L4 — the hev
              // notice was initially missed). The remaining
              // two entries are Tailscale BSD-3-Clause
              // portions for the core's desktop (Windows /
              // macOS) firewall and router components, which
              // the Android artifacts do not contain
              // (iteration 3, L5).
              body:
                  'The AmneziaWG engine: the tunnel backend, '
                  'its Android JNI bridge and its config '
                  'parser, from the WG Tunnel project by '
                  'Zane Schepke and contributors. Its tunnel '
                  'library is built on amneziawg-go by the '
                  'Amnezia VPN team (MIT License), its '
                  'config parser embeds a Curve25519 '
                  'implementation (Apache License 2.0), and '
                  'the backend links hev-socks5-tunnel, '
                  'Copyright (c) hev and contributors '
                  '(MIT License), per the core\u2019s NOTICE '
                  'file.',
              links: [
                (
                  'Source: wgtunnel/android',
                  () {
                    unawaited(AndroidCore.openUrl(_wgTunnelSourceUrl));
                  },
                ),
                (
                  'Source: wgtunnel/core',
                  () {
                    unawaited(
                      AndroidCore.openUrl(_wgTunnelCoreSourceUrl),
                    );
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _entry(
    BuildContext context, {
    required String title,
    required String license,
    required String body,
    required List<(String, VoidCallback)> links,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: Ember.heading.copyWith(fontSize: Ember.fontTitle),
                ),
              ),
              // Build 2074 (audit item 7): the license name is
              // not tappable, so it is plain text — the chip
              // shape is reserved for the tappable Source
              // links below, which it used to imitate exactly.
              Text(
                license,
                style: const TextStyle(
                  fontSize: Ember.fontSmall,
                  fontWeight: FontWeight.w600,
                  color: Ember.dim,
                ),
                textAlign: TextAlign.end,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(body, style: Ember.dimStyle),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final (label, onTap) in links)
                EmberChip(label: label, onTap: onTap),
            ],
          ),
        ],
      ),
    ),
  );
}

/// The v2fly/geoip data notice, from the bundled asset
/// (build 2129, Leg 6).
class _GeoIpNoticeTextPage extends StatefulWidget {
  const _GeoIpNoticeTextPage();

  @override
  State<_GeoIpNoticeTextPage> createState() => _GeoIpNoticeTextPageState();
}

class _GeoIpNoticeTextPageState extends State<_GeoIpNoticeTextPage> {
  late final Future<String> _text = rootBundle.loadString(
    'assets/licenses/geoip-notice.txt',
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Ember.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Ember.text,
        title: Text('GeoIP data notice', style: Ember.heading),
      ),
      body: EmberBackground(
        child: FutureBuilder<String>(
          future: _text,
          builder: (context, snap) {
            if (snap.hasError) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Text(
                    'The notice text could not be loaded.',
                    style: Ember.dimStyle,
                    textAlign: TextAlign.center,
                  ),
                ),
              );
            }
            if (!snap.hasData) {
              return const Center(
                child: CircularProgressIndicator(color: Ember.orange),
              );
            }
            return ListView(
              padding: EdgeInsets.fromLTRB(18, MediaQuery.of(context).padding.top + kToolbarHeight + 6, 18, 24),
              children: [
                SelectableText(
                  snap.data!,
                  style: Ember.dimStyle.copyWith(height: 1.5),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// The full CC BY-SA 4.0 text for the offline country
/// data, from the bundled asset (build 2129, Leg 6).
class _GeoIpLicenseTextPage extends StatefulWidget {
  const _GeoIpLicenseTextPage();

  @override
  State<_GeoIpLicenseTextPage> createState() => _GeoIpLicenseTextPageState();
}

class _GeoIpLicenseTextPageState extends State<_GeoIpLicenseTextPage> {
  late final Future<String> _text = rootBundle.loadString(
    'assets/licenses/geoip-cc-by-sa-4.0.txt',
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Ember.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Ember.text,
        title: Text('CC BY-SA 4.0', style: Ember.heading),
      ),
      body: EmberBackground(
        child: FutureBuilder<String>(
          future: _text,
          builder: (context, snap) {
            if (snap.hasError) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Text(
                    'The license text could not be loaded.',
                    style: Ember.dimStyle,
                    textAlign: TextAlign.center,
                  ),
                ),
              );
            }
            if (!snap.hasData) {
              return const Center(
                child: CircularProgressIndicator(color: Ember.orange),
              );
            }
            return ListView(
              padding: EdgeInsets.fromLTRB(18, MediaQuery.of(context).padding.top + kToolbarHeight + 6, 18, 24),
              children: [
                SelectableText(
                  snap.data!,
                  style: Ember.dimStyle.copyWith(height: 1.5),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// The SenPaiScanner MIT text, from the bundled asset
/// (build 2129, Leg 3).
class _SenpaiMitTextPage extends StatefulWidget {
  const _SenpaiMitTextPage();

  @override
  State<_SenpaiMitTextPage> createState() => _SenpaiMitTextPageState();
}

class _SenpaiMitTextPageState extends State<_SenpaiMitTextPage> {
  late final Future<String> _text = rootBundle.loadString(
    'assets/licenses/senpai-mit.txt',
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Ember.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Ember.text,
        title: Text('MIT License', style: Ember.heading),
      ),
      body: EmberBackground(
        child: FutureBuilder<String>(
          future: _text,
          builder: (context, snap) {
            if (snap.hasError) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Text(
                    'The license text could not be loaded.',
                    style: Ember.dimStyle,
                    textAlign: TextAlign.center,
                  ),
                ),
              );
            }
            if (!snap.hasData) {
              return const Center(
                child: CircularProgressIndicator(color: Ember.orange),
              );
            }
            return ListView(
              padding: EdgeInsets.fromLTRB(18, MediaQuery.of(context).padding.top + kToolbarHeight + 6, 18, 24),
              children: [
                SelectableText(
                  snap.data!,
                  style: Ember.dimStyle.copyWith(height: 1.5),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// The full GPL-3.0 text, from the bundled asset (build
/// 2129: the Psiphon core and the Shirokhorshid bootstrap).
class _GplTextPage extends StatefulWidget {
  const _GplTextPage();

  @override
  State<_GplTextPage> createState() => _GplTextPageState();
}

class _GplTextPageState extends State<_GplTextPage> {
  late final Future<String> _text = rootBundle.loadString(
    'assets/licenses/gpl-3.0.txt',
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Ember.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Ember.text,
        title: Text('GNU GPL-3.0', style: Ember.heading),
      ),
      body: EmberBackground(
        child: FutureBuilder<String>(
          future: _text,
          builder: (context, snap) {
            if (snap.hasError) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Text(
                    'The license text could not be loaded.',
                    style: Ember.dimStyle,
                    textAlign: TextAlign.center,
                  ),
                ),
              );
            }
            if (!snap.hasData) {
              return const Center(
                child: CircularProgressIndicator(color: Ember.orange),
              );
            }
            return ListView(
              padding: EdgeInsets.fromLTRB(18, MediaQuery.of(context).padding.top + kToolbarHeight + 6, 18, 24),
              children: [
                SelectableText(
                  snap.data!,
                  style: Ember.dimStyle.copyWith(height: 1.5),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// The full AGPL-3.0 text, from the bundled asset.
class _AgplTextPage extends StatefulWidget {
  const _AgplTextPage();

  @override
  State<_AgplTextPage> createState() => _AgplTextPageState();
}

class _AgplTextPageState extends State<_AgplTextPage> {
  // Build 2074 (audit item 9): the future is hoisted into
  // state — created in build() it restarted on every rebuild,
  // and with only hasData checked a failed asset spun the
  // spinner forever instead of showing an error state.
  late final Future<String> _text = rootBundle.loadString(
    'assets/licenses/agpl-3.0.txt',
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Ember.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Ember.text,
        title: Text('GNU AGPL-3.0', style: Ember.heading),
      ),
      // Build 2092 (item 55): the page sits on the shared
      // Ember background like the other pushed pages.
      body: EmberBackground(
        child: FutureBuilder<String>(
          future: _text,
          builder: (context, snap) {
            if (snap.hasError) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Text(
                    'The license text could not be loaded.',
                    style: Ember.dimStyle,
                    textAlign: TextAlign.center,
                  ),
                ),
              );
            }
            if (!snap.hasData) {
              return const Center(
                child: CircularProgressIndicator(color: Ember.orange),
              );
            }
            return ListView(
              padding: EdgeInsets.fromLTRB(18, MediaQuery.of(context).padding.top + kToolbarHeight + 6, 18, 24),
              children: [
                SelectableText(
                  snap.data!,
                  // Build 2092 (item 55): body-size text
                  // for the full license text (was caption).
                  style: Ember.dimStyle.copyWith(height: 1.5),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
