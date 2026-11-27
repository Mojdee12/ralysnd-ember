/// Build 2095 (feature 4 — custom multi-hop chain builder):
/// hop 1 is an underlay engine, hop 2 is one of the user's
/// configs, saved as a reusable [ChainEntry]. The chain
/// machinery (build 2065) supports exactly the underlay
/// engines in [chainUnderlays] (OLCRTC added in build
/// 2134); a config can NOT be an underlay — the builder
/// refuses that shape instead of silently degrading it.

import 'package:flutter/material.dart';

import '../../app_settings.dart';
import '../../xray/wstunnel_args.dart';
import '../../xray/xray_controller.dart';
import '../../xray/xray_models.dart';
import 'ember_theme.dart';
import 'map_widgets.dart';

/// The underlay engines the chain machinery supports.
const chainUnderlays = ['warp', 'psiphon', 'dnstt', 'olcrtc'];

const chainUnderlayLabels = {
  'warp': 'EmberWarp (WARP)',
  'psiphon': 'Psiphon',
  'dnstt': 'DNSTT (DNS tunnel)',
  'olcrtc': 'OLCRTC (video-call tunnel)',
};

/// Validates a would-be chain entry against the profile
/// pool. Returns a plain refusal sentence, or null when
/// the combination is one the cores actually support.
String? validateChainEntry({
  required String name,
  required String underlay,
  required String profileId,
  required List<Profile> profiles,
  bool wgWstunnelEnabled = false,
  String wgWstunnelUrl = '',
  bool shadowTlsFronting = false,
}) {
  if (name.trim().isEmpty) return 'Give the chain a name.';
  if (!chainUnderlays.contains(underlay)) {
    return 'The first hop must be an engine (EmberWarp, Psiphon, '
        'DNSTT or OLCRTC) — a config cannot carry another config '
        'in this machinery.';
  }
  final exit = profiles.where((p) => p.id == profileId).firstOrNull;
  if (exit == null) return 'Pick the exit config.';
  // Build 2096 (post-2095 audit M18): a sidecar-served
  // exit (TUIC, Snell, Naive, Mieru, Hysteria…) cannot
  // ride the chain — at connect the underlay is skipped
  // for sidecar profiles and the session runs un-chained
  // while the UI said "Chain applied". Refuse it here,
  // at save time and at apply time.
  // Build 2126: a ShadowTLS-diverted Shadowsocks exit (a
  // shadow-tls plugin + the fronting setting on) is
  // sidecar-served too — the same refusal, for the same
  // reason.
  if (exit.servedBySidecar ||
      (shadowTlsFronting && exit.shadowTlsPlugin != null)) {
    return 'That config is served by the sidecar core — a chain '
        'underlay cannot carry it. Pick a config the Xray core '
        'serves directly.';
  }
  // Build 2123 (C-4(i), psiphon-chain-fix-plan §4): the
  // Psiphon underlay's stock SOCKS proxy cannot carry UDP
  // for the core — BPB had to write its own udpgw SOCKS
  // server for exactly this — so a UDP-dependent exit
  // chained over Psiphon would connect and then silently
  // drop its traffic. Refuse the shapes that cannot work
  // at all: a WireGuard exit (a UDP-only protocol) and
  // QUIC / KCP transports (UDP carriers). TCP-carrying
  // profiles are unaffected — including Shadowsocks,
  // whose UDP relay is optional.
  if (underlay == 'psiphon' &&
      (exit.protocol == Protocol.wireguard ||
          exit.network == 'quic' ||
          exit.network == 'kcp')) {
    return 'That config depends on UDP (WireGuard / QUIC / KCP) — '
        'the Psiphon hop cannot carry UDP, so the chain would '
        'connect and then silently drop its traffic.';
  }
  // Build 2096 (post-2095 audit L5): the wstunnel gate
  // turns on THIS config actually being a wstunnel
  // endpoint (a ws/wss address) with the feature on —
  // build 2095 refused every WireGuard exit whenever a
  // wstunnel URL was merely configured.
  // Build 2097 (post-2096 audit L5-residual): the operand
  // is the SETTINGS URL, not the exit's address — at
  // connect, the wstunnel stacking is driven by
  // settings.wgWstunnel + settings.wgWstunnelUrl for ANY
  // WireGuard exit (xray_controller's wgWstunnelOn), so
  // the 2096 gate both refused exits connect would never
  // stack (a wss-addressed exit with no wstunnel URL
  // configured) and allowed exits connect WOULD stack
  // (a plain endpoint with a wstunnel URL configured).
  if (exit.protocol == Protocol.wireguard &&
      wgWstunnelEnabled &&
      isWstunnelUrl(wgWstunnelUrl)) {
    return 'That WireGuard config already tunnels over a websocket '
        '(wstunnel) — stacking the underlay under it is not supported.';
  }
  return null;
}

class ChainBuilderPage extends StatefulWidget {
  const ChainBuilderPage({super.key, required this.xray, required this.settings});

  final XrayController xray;
  final AppSettings settings;

  @override
  State<ChainBuilderPage> createState() => _ChainBuilderPageState();
}

class _ChainBuilderPageState extends State<ChainBuilderPage> {
  final _name = TextEditingController();
  String _underlay = 'warp';
  String? _profileId;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _snack(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  void _save() {
    final refusal = validateChainEntry(
      name: _name.text,
      underlay: _underlay,
      profileId: _profileId ?? '',
      profiles: widget.xray.profiles,
      wgWstunnelEnabled: widget.xray.settings.wgWstunnel,
      wgWstunnelUrl: widget.xray.settings.wgWstunnelUrl,
      shadowTlsFronting: widget.xray.settings.shadowTlsFronting,
    );
    if (refusal != null) {
      _snack(refusal);
      return;
    }
    widget.settings.update(
      chains: [
        ...widget.settings.chains,
        ChainEntry(
          name: _name.text.trim(),
          underlay: _underlay,
          profileId: _profileId!,
        ),
      ],
    );
    _name.clear();
    setState(() {});
    _snack('Chain saved');
  }

  Future<void> _apply(ChainEntry c) async {
    final exit =
        widget.xray.profiles.where((p) => p.id == c.profileId).firstOrNull;
    if (exit == null) {
      _snack('The exit config no longer exists — delete this chain.');
      return;
    }
    // Build 2096 (post-2095 audit L5/M18): Apply
    // re-validates — a chain saved before a rule existed
    // (or whose exit changed kind since) is refused
    // here too, not silently applied.
    final refusal = validateChainEntry(
      name: c.name,
      underlay: c.underlay,
      profileId: c.profileId,
      profiles: widget.xray.profiles,
      wgWstunnelEnabled: widget.xray.settings.wgWstunnel,
      wgWstunnelUrl: widget.xray.settings.wgWstunnelUrl,
      shadowTlsFronting: widget.xray.settings.shadowTlsFronting,
    );
    if (refusal != null) {
      _snack(refusal);
      return;
    }
    final live = widget.xray.state.running;
    await widget.xray.setUnderlay(c.underlay);
    // Build 2097 (post-2096 audit N3): on a live session
    // the exit selection is DEFERRED to the session's end
    // (the controller consumes pendingChainExitId in
    // disconnect()) — build 2096 selected immediately,
    // which re-pointed the selection under the running
    // session while the message below claimed the session
    // was untouched.
    if (live) {
      widget.xray.pendingChainExitId = exit.id;
    } else {
      widget.xray.select(exit);
    }
    if (mounted) {
      // Build 2096 (post-2095 audit L6): the underlay
      // shapes the NEXT session — on a live session the
      // message says so instead of implying the running
      // tunnel is now chained.
      _snack(
        live
            ? 'Chain applied for the next session — the running '
                'session is not chained. Reconnect to use it.'
            : 'Chain applied: ${chainUnderlayLabels[c.underlay]} under '
                '${exit.name} — connect from Home.',
      );
    }
  }

  void _delete(ChainEntry c) {
    widget.settings.update(
      chains: widget.settings.chains.where((e) => e != c).toList(),
    );
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final profiles = widget.xray.profiles;
    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Ember.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Ember.text,
        title: Text('Custom chains', style: Ember.heading),
      ),
      body: EmberBackground(child: ListView(
        padding: EdgeInsets.fromLTRB(16, MediaQuery.of(context).padding.top + kToolbarHeight + 8, 16, 24),
        children: [
          Text(
            'A chain sends your traffic through an underlay engine '
            'first, then out of the exit config. The first hop must '
            'be an engine — the cores cannot stack one config under '
            'another.',
            style: Ember.body,
          ),
          const SizedBox(height: 14),
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('New chain', style: Ember.heading.copyWith(fontSize: Ember.fontTitle)),
                const SizedBox(height: 10),
                TextField(
                  controller: _name,
                  style: Ember.body,
                  // Build 2116 (AP-08): the shared field.
                  decoration: emberField(context, 'Chain name'),
                ),
                const SizedBox(height: 12),
                Text('First hop (underlay engine)', style: Ember.caption),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final u in chainUnderlays)
                      EmberChip(
                        label: chainUnderlayLabels[u]!,
                        selected: _underlay == u,
                        onTap: () => setState(() => _underlay = u),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                Text('Exit config', style: Ember.caption),
                const SizedBox(height: 6),
                DropdownButton<String>(
                  value: _profileId,
                  isExpanded: true,
                  hint: Text('Pick a config', style: Ember.body),
                  items: [
                    for (final p in profiles)
                      DropdownMenuItem(
                        value: p.id,
                        child: Text(
                          p.name,
                          style: Ember.body,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (v) => setState(() => _profileId = v),
                ),
                const SizedBox(height: 12),
                EmberButton(label: 'Save chain', onTap: _save),
              ],
            ),
          ),
          const SizedBox(height: 14),
          if (widget.settings.chains.isEmpty)
            // Build 2116 (AP-19): the shared empty state.
            const EmberEmpty(
              icon: Icons.link_outlined,
              text: 'No saved chains yet.',
            )
          else
            for (final c in widget.settings.chains) ...[
              GlassCard(
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(c.name, style: Ember.heading.copyWith(fontSize: Ember.fontBody)),
                          Text(
                            '${chainUnderlayLabels[c.underlay] ?? c.underlay} → '
                            '${profiles.where((p) => p.id == c.profileId).firstOrNull?.name ?? '(config gone)'}',
                            style: Ember.caption,
                          ),
                        ],
                      ),
                    ),
                    MapActionPill(
                      label: 'Apply',
                      icon: Icons.play_arrow_rounded,
                      onTap: () => _apply(c),
                    ),
                    const SizedBox(width: 6),
                    IconButton(
                      tooltip: 'Delete chain',
                      icon: const Icon(Icons.delete_outline_rounded,
                          color: Ember.red, size: 20),
                      onPressed: () => _delete(c),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
            ],
        ],
      )),
    );
  }
}
