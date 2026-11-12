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
const _xraySourceUrl = 'https://github.com/XTLS/Xray-core';
const _openVpnSourceUrl = 'https://github.com/OpenVPN/openvpn3';
const _kumihoSourceUrl = 'https://github.com/benyamin-git/Kumiho';
const _warpPlusSourceUrl = 'https://github.com/bepass-org/warp-plus';
const _openVpnCommunityUrl = 'https://github.com/OpenVPN/openvpn';
const _inAppWebViewUrl =
    'https://github.com/pichillilorenzo/flutter_inappwebview';

class LicensesPage extends StatelessWidget {
  const LicensesPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Ember.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Ember.text,
        title: Text('Open Source Licenses', style: Ember.heading),
      ),
      body: EmberBackground(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 6, 18, 24),
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
                ('Read the AGPL-3.0 text', () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const _AgplTextPage(),
                    ),
                  );
                }),
                ('Source: patterniha/Aether', () {
                  unawaited(AndroidCore.openUrl(_aetherSourceUrl));
                }),
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
                ('Source: XTLS/Xray-core', () {
                  unawaited(AndroidCore.openUrl(_xraySourceUrl));
                }),
              ],
            ),
            _entry(
              context,
              title: 'OpenVPN3 core',
              license: 'Mozilla Public License 2.0',
              body: 'The OpenVPN engine’s protocol core.',
              links: [
                ('Source: OpenVPN/openvpn3', () {
                  unawaited(AndroidCore.openUrl(_openVpnSourceUrl));
                }),
              ],
            ),
            _entry(
              context,
              title: 'Kumiho (Mozilla sign-in)',
              license: 'MIT',
              body:
                  'The Mozilla engine’s browser sign-in follows '
                  'the Kumiho client’s contract — the Firefox for '
                  'Android OAuth client, PKCE, and the success-'
                  'redirect handoff — re-implemented in Ember’s '
                  'own core (build 2034).',
              links: [
                ('Source: benyamin-git/Kumiho', () {
                  unawaited(AndroidCore.openUrl(_kumihoSourceUrl));
                }),
              ],
            ),
            _entry(
              context,
              title: 'warp-plus (Windows WARP+)',
              license: 'MIT',
              body:
                  'The Windows WARP+ engine runs the warp-plus '
                  'sidecar by bepass-org.',
              links: [
                ('Source: bepass-org/warp-plus', () {
                  unawaited(AndroidCore.openUrl(_warpPlusSourceUrl));
                }),
              ],
            ),
            _entry(
              context,
              title: 'OpenVPN (Windows sidecar)',
              license: 'GNU GPL-2.0',
              body:
                  'On Windows the OpenVPN engine drives the '
                  'official openvpn.exe from the OpenVPN '
                  'community project.',
              links: [
                ('Source: OpenVPN/openvpn', () {
                  unawaited(AndroidCore.openUrl(_openVpnCommunityUrl));
                }),
              ],
            ),
            _entry(
              context,
              title: 'Wintun',
              license: 'Wintun license',
              body:
                  'The Windows TUN driver DLL, shipped '
                  'unmodified from the official Wintun '
                  'distribution (wintun.net).',
              links: const [],
            ),
            _entry(
              context,
              title: 'flutter_inappwebview (Windows sign-in)',
              license: 'MIT',
              body:
                  'The embedded WebView2 view the Windows '
                  'Mozilla browser sign-in runs in.',
              links: [
                ('Source: flutter_inappwebview', () {
                  unawaited(AndroidCore.openUrl(_inAppWebViewUrl));
                }),
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
                  style: Ember.heading.copyWith(fontSize: 14.5),
                ),
              ),
              EmberChip(label: license),
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

/// The full AGPL-3.0 text, from the bundled asset.
class _AgplTextPage extends StatelessWidget {
  const _AgplTextPage();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Ember.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Ember.text,
        title: Text('GNU AGPL-3.0', style: Ember.heading),
      ),
      body: FutureBuilder<String>(
        future: rootBundle.loadString('assets/licenses/agpl-3.0.txt'),
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(
              child: CircularProgressIndicator(color: Ember.orange),
            );
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(18, 6, 18, 24),
            children: [
              SelectableText(
                snap.data!,
                style: Ember.caption.copyWith(height: 1.5),
              ),
            ],
          );
        },
      ),
    );
  }
}
