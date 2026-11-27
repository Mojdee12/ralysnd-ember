/// The V2Ray settings section — Android build 2157's
/// _XraySection, ported wholesale (W3, full-parity build):
/// the whole settings surface of the Xray engine (routing,
/// DNS, sniffing, fragment, mux, the engine-feature gates,
/// RegionHop + URnetwork entries, backup/pairing, the Iran
/// panel) in the Map settings language. Windows keeps its
/// one extra card (the TUN capture choice) at the call site
/// in ember_settings.dart. The Android APK updater panel is
/// the one piece NOT ported: Windows updates ride the core's
/// own flow (Settings → About / map_settings' update check).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../aether/aether_controller.dart';
import '../../app_settings.dart';
import '../../core/android_core.dart';
import '../../features.dart';
import '../../l10n/app_localizations.dart';
import '../../openvpn/openvpn_controller.dart';
import '../../psiphon/psiphon_controller.dart';
import '../../platform.dart';
import '../../regionhop/regionhop_defaults.dart';
import '../../xray/config_builder.dart'
    show primaryResolver, dnsGroupMembers, resolverUnderTransport;
import '../../xray/config_mixins.dart';
import '../../xray/dns_hosts.dart';
import '../../xray/dns_presets.dart';
import '../../xray/hwid.dart';
import '../../xray/xray_controller.dart';
import '../../xray/xray_models.dart';
import '../../xray/xray_platform.dart';
import '../../xray/zapret_args.dart';
import 'daily_report_page.dart';
import 'ember_sync.dart';
import 'iran_pages_2147.dart';
import 'dns_presets_page.dart';
import 'dpi_lab_page.dart';
import 'ember_dialogs.dart';
import 'ember_format.dart';
import 'ember_theme.dart';
import 'map_widgets.dart';
import 'pairing.dart';
import 'regionhop_page.dart';
import 'senpai_page.dart';
import 'smart_groups_page.dart';
import 'sni_spoof_page.dart';
import 'traffic_history_page.dart';
import 'urnetwork_page.dart';
import 'wireguard_pages.dart';
import 'xray_logs_page.dart';

const _navChevron = Icon(
  // Build 2056 (audit Batch 9): the app is English LTR — the
  // forward chevron points right, not left.
  Icons.chevron_right_rounded,
  color: MapUi.faint,
  size: 20,
);

/// Build 2056 (audit A-H6): a pushed page in the Ember language —
/// a transparent bar with a real title over the map backdrop,
/// never the stock empty AppBar the "All settings" / "Language"
/// rows used to push.
Route<T> _emberPageRoute<T>(String title, Widget child) => MaterialPageRoute<T>(
  builder: (_) => Scaffold(
    backgroundColor: Ember.bg,
    appBar: AppBar(
      backgroundColor: Colors.transparent,
      elevation: 0,
      foregroundColor: Ember.text,
      title: Text(title, style: Ember.heading),
    ),
    // Build 2147 (strict-audit F1): the short, faint band.
    body: EmberBackground(bandShort: true, child: child),
  ),
);

/// The WireGuard engine's section (build 2056, audit A-H5): modes
/// 5 used to fall through to Mozilla's section, showing
/// connection-mode / smart-routing / DoH controls for an engine
/// that has none of those. The section shows the selected
/// WireGuard config and its real run mode (AmneziaWG vs plain),
/// and opens the configurations panel.

Widget _valueTrailing(String value) => MapValueChip(text: value);

/// Build 2074 (audit item 7): a value on a row that does NOT
/// act — the WireGuard "Engine" and WARP "Endpoint" rows have
/// no onTap, so the tappable-looking capsule lied about them.
/// Non-actionable values render as plain dim text instead.
Widget _plainValueTrailing(String value) => Text(
  value,
  style: const TextStyle(
    fontSize: Ember.fontSmall,
    fontWeight: FontWeight.w600,
    color: MapUi.dim,
  ),
  maxLines: 1,
  overflow: TextOverflow.ellipsis,
);

/// Build 2074 (audit item 16): a chip group as a full-width
/// row — label and subtitle on top, the chips in a Wrap below.
/// As a MapSettingRow trailing the same Wrap squeezed the
/// label to a sliver (mux / MTU / refresh groups).
class _ChipGroupRow extends StatelessWidget {
  const _ChipGroupRow({
    required this.label,
    this.subtitle,
    this.divider = true,
    required this.chips,
  });

  final String label;
  final String? subtitle;
  final bool divider;
  final List<Widget> chips;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: const TextStyle(
                fontSize: Ember.fontBody,
                fontWeight: FontWeight.w500,
                color: MapUi.text,
              ),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 2),
              Text(
                subtitle!,
                // Build 2092 (item 38): the micro-type
                // floor — 11 sp at dim.
                style: const TextStyle(
                  fontSize: Ember.fontMicro,
                  color: MapUi.dim,
                  height: 1.3,
                ),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            const SizedBox(height: 9),
            Wrap(spacing: 6, runSpacing: 6, children: chips),
          ],
        ),
      ),
      if (divider) const Divider(color: MapUi.line, height: 1, thickness: 1),
    ],
  );
}

/// The Psiphon engine's section: a summary card into the engine's
/// own settings page (mode, region, upstream proxy, transports) and
/// its log viewer.

class XraySection extends StatelessWidget {
  const XraySection({
    required this.xray,
    this.settings,
    this.openvpn,
    this.psiphon,
    this.warp,
    this.masque,
  });
  final XrayController xray;

  /// Build 2095 (V2Ray journey audit #15): the app settings,
  /// so the backup can carry them. Optional — without it the
  /// backup is configs-only, as before.
  final AppSettings? settings;

  /// Build 2116 (AB-05): the other engines' controllers,
  /// so this section's backup/restore and pairing flows
  /// carry their sections too. Optional, like [settings].
  final OpenVpnController? openvpn;
  final PsiphonController? psiphon;
  final AetherController? warp;
  final AetherController? masque;

  XraySettings get s => xray.settings;

  /// Build 2101 (settings-dns-2099-diagnosis.md, S1/S2): the
  /// section's ONE save path. XrayController.save() persists
  /// without notifying — deliberately, for its bulk internal
  /// writers — so a settings callback that only saved left the
  /// page showing the OLD value until navigation (the value
  /// WAS on disk; the toggle, chip or DNS row simply never
  /// rebuilt). Every callback in this section now saves
  /// through here, and the notify lands the new value on
  /// screen at once.
  Future<void> _saveSection() async {
    await xray.save();
    xray.notifySettingsChanged();
  }

  Future<void> _save(BuildContext context) async {
    await _saveSection();
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context).savedNote)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: xray,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MapSettingsPanel(
            title: l.connectionSection,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 7),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l.routingPreset,
                      style: const TextStyle(
                        fontSize: Ember.fontBody,
                        fontWeight: FontWeight.w500,
                        color: MapUi.text,
                      ),
                    ),
                    const SizedBox(height: 9),
                    Wrap(
                      spacing: 7,
                      runSpacing: 7,
                      children: [
                        for (final preset in RoutingPreset.values)
                          EmberChip(
                            label: switch (preset) {
                              RoutingPreset.global => l.presetGlobal,
                              RoutingPreset.bypassLan => l.presetBypassLan,
                              RoutingPreset.bypassIran => l.presetBypassIran,
                              RoutingPreset.bypassChina => 'Bypass China',
                              RoutingPreset.directAll => l.presetDirectAll,
                            },
                            selected: s.routingPreset == preset,
                            onTap: () async {
                              s.routingPreset = preset;
                              await _saveSection();
                            },
                          ),
                      ],
                    ),
                    const SizedBox(height: 13),
                    Text(
                      l.domainStrategy,
                      style: const TextStyle(
                        fontSize: Ember.fontBody,
                        fontWeight: FontWeight.w500,
                        color: MapUi.text,
                      ),
                    ),
                    const SizedBox(height: 9),
                    EmberSegmented<String>(
                      // Batch 5 (fidelity rollout, pro7-routing
                      // sample): the routing mode segmented is
                      // the sample's FLAT form — tracked text,
                      // the chosen one orange over a 2 px bar,
                      // no tray. Same options, values and save.
                      flat: true,
                      value: s.domainStrategy,
                      // Build 2145 (UI-review fix A11): the
                      // LABELS are plain words a first-time user
                      // can parse; the VALUES stay the exact
                      // config strings the core expects. (The
                      // verb forms — "Resolve if no match" —
                      // overflow the equal-width segment cells
                      // at phone widths; the section's own
                      // title carries the verb's context.)
                      options: [
                        ('IPIfNonMatch', 'If no match', null),
                        ('AsIs', 'As is', null),
                        ('IPOnDemand', 'On demand', null),
                      ],
                      onChanged: (v) async {
                        s.domainStrategy = v;
                        await _saveSection();
                      },
                    ),
                  ],
                ),
              ),
              const Divider(color: MapUi.line, height: 1, thickness: 1),
              MapSettingRow(
                label: l.enableUdp,
                // Build 2118: last row of the Connection panel
                // after the split below — no divider under it.
                divider: false,
                trailing: MapToggle(
                  value: s.enableUdp,
                  onChanged: (v) async {
                    s.enableUdp = v;
                    await _saveSection();
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          // Build 2118 (appearance fix round): the Connection
          // panel carried ~19 rows and read as one monolithic
          // card next to the samples' compact grouped cards.
          // It splits into three panels — grouping only: every
          // row keeps its place in the order, its control and
          // its callback. The two new titles are hardcoded
          // strings, like this section's own hardcoded row
          // labels ('Sniff HTTP', 'Fallback groups') — no new
          // l10n keys.
          MapSettingsPanel(
            title: 'Sniffing',
            children: [
              MapSettingRow(
                label: l.sniffing,
                trailing: MapToggle(
                  value: s.sniffing,
                  onChanged: (v) async {
                    s.sniffing = v;
                    await _saveSection();
                  },
                ),
              ),
              // Build 2095 (V2Ray journey audit #22): the
              // per-protocol sniffing set — the builder
              // hardcoded http+tls+quic into destOverride.
              MapSettingRow(
                label: 'Sniff HTTP',
                subtitle: 'Destination override for HTTP traffic',
                trailing: MapToggle(
                  value: s.sniffHttp,
                  onChanged: !s.sniffing
                      ? null
                      : (v) async {
                          s.sniffHttp = v;
                          await _saveSection();
                        },
                ),
              ),
              MapSettingRow(
                label: 'Sniff TLS',
                subtitle: 'Destination override for TLS (SNI)',
                trailing: MapToggle(
                  value: s.sniffTls,
                  onChanged: !s.sniffing
                      ? null
                      : (v) async {
                          s.sniffTls = v;
                          await _saveSection();
                        },
                ),
              ),
              MapSettingRow(
                label: 'Sniff QUIC',
                subtitle: 'Destination override for QUIC traffic',
                trailing: MapToggle(
                  value: s.sniffQuic,
                  onChanged: !s.sniffing
                      ? null
                      : (v) async {
                          s.sniffQuic = v;
                          await _saveSection();
                        },
                ),
              ),
              // Build 2108 (Block QUIC toggle, feature-watch
              // 2026-11-18): a routing rule, not a sniffing
              // knob — it is NOT gated on [s.sniffing], and it
              // applies at the next connect. Covers the
              // V2Ray/Xray path only; the Settings copy says so
              // in the model doc, and the row subtitle keeps the
              // mechanism honest (UDP/443 → TCP fallback).
              MapSettingRow(
                // Build 2116 (B13-10, 2108-L2): the rule drops
                // ALL UDP/443, not only QUIC — the label and
                // subtitle say so instead of implying a
                // QUIC-only filter. Behaviour unchanged.
                label: 'Block QUIC (all UDP/443)',
                subtitle:
                    'Drops every UDP packet to port 443, QUIC '
                    'or not, so apps fall back to TCP. V2Ray '
                    'sessions only — it does not cover '
                    'DNS-over-QUIC, which resolves on the local '
                    'endpoint (build 2125, audit A25-35).',
                // Build 2118: last row of the Sniffing panel
                // after the split — no divider under it.
                divider: false,
                trailing: MapToggle(
                  value: s.blockQuic,
                  onChanged: (v) async {
                    s.blockQuic = v;
                    await _saveSection();
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          // Build 2118: the third panel of the split (see the
          // Sniffing panel above) — everything the Connection
          // panel carried after the sniffing set.
          MapSettingsPanel(
            title: 'Advanced',
            children: [
              // Build 2126 (feature pick 3): the ShadowTLS
              // fronting switch. Off (the default), a
              // Shadowsocks profile whose link carries a
              // shadow-tls plugin connects on the Xray core
              // WITHOUT the plugin, exactly as in 2125; on,
              // the sing-box engine serves it with the TLS
              // front applied. Applies at the next connect.
              // Build 2127 (H2): the Sudoku engine switch.
              // Off (the default), a Sudoku profile refuses
              // at connect in plain words and nothing else
              // changes; on, the Sudoku engine (Hiddify's
              // sing-box fork, its own binary) serves it.
              MapSettingRow(
                label: 'Sudoku (Hiddify engine)',
                subtitle:
                    'Serves Sudoku profiles through the '
                    'bundled Sudoku engine. Sudoku exists '
                    'only in Hiddify\'s sing-box fork, so it '
                    'rides its own engine binary. Off: a '
                    'Sudoku profile will not connect.',
                trailing: MapToggle(
                  value: s.sudokuEnabled,
                  onChanged: (v) async {
                    s.sudokuEnabled = v;
                    await _saveSection();
                  },
                ),
              ),
              // Build 2139 (leg 1): the RegionHop switch.
              // Off (the default), the app never contacts
              // the regionhop panel and no RegionHop entry
              // exists; on, the entry below opens the page.
              // The toggle itself makes no network calls.
              MapSettingRow(
                label: 'RegionHop (server Psiphon exits)',
                subtitle:
                    'Your own server\u2019s Psiphon exits, '
                    'managed from its panel and reached '
                    'through authenticated relays on the '
                    'same box. Off: the app never contacts '
                    'the panel.',
                trailing: MapToggle(
                  value: s.regionHopEnabled,
                  onChanged: (v) async {
                    s.regionHopEnabled = v;
                    await _saveSection();
                  },
                ),
              ),
              if (s.regionHopEnabled)
                MapSettingRow(
                  label: 'RegionHop',
                  subtitle: s.regionHopPanelUrl.isEmpty
                      ? 'Set up the panel connection'
                      : 'Panel locations, exits and connect',
                  trailing: _navChevron,
                  onTap: () => openRegionHop(context, xray),
                ),
              // Build 2154: the URnetwork source's entry.
              // No enable toggle: the source holds nothing
              // and contacts nothing until an account is
              // added on its page (the account-less source
              // is inert, which is the default-off law's
              // shape for a keyed source — as the sync
              // token's is).
              MapSettingRow(
                label: 'URnetwork',
                subtitle: xray.urAccounts.isEmpty
                    ? 'Residential exits — add an account'
                    : 'Accounts, hosted proxies and balances',
                trailing: _navChevron,
                onTap: () => openUrNetwork(context, xray),
              ),
              MapSettingRow(
                label: 'ShadowTLS fronting (Shadowsocks)',
                subtitle:
                    'Serves Shadowsocks configs whose link '
                    'carries a shadow-tls plugin through the '
                    'sing-box engine, with the TLS front '
                    'applied (TCP only — ShadowTLS cannot '
                    'relay UDP). Off: those configs connect '
                    'without the plugin, as before.',
                trailing: MapToggle(
                  value: s.shadowTlsFronting,
                  onChanged: (v) async {
                    s.shadowTlsFronting = v;
                    await _saveSection();
                  },
                ),
              ),
              // Build 2126 (D1).
              MapSettingRow(
                label: 'Gecko packet sizes (Hysteria2)',
                subtitle:
                    'Applies the packet-size band a gecko '
                    'config carries in its link (gecko '
                    'min/max packet size) through the '
                    'sing-box engine. Off: gecko configs '
                    'connect without the size band, as '
                    'before.',
                trailing: MapToggle(
                  value: s.geckoPacketSizes,
                  onChanged: (v) async {
                    s.geckoPacketSizes = v;
                    await _saveSection();
                  },
                ),
              ),
              // Build 2126 (D6).
              MapSettingRow(
                label: 'Noise decoy (Hysteria2)',
                subtitle:
                    'Sends random decoy packets on the '
                    'Hysteria2 socket just before the real '
                    'handshake, so a filter\'s first read '
                    'is noise. Off: no decoy packets, as '
                    'before.',
                trailing: MapToggle(
                  value: s.hy2NoiseDecoy,
                  onChanged: (v) async {
                    s.hy2NoiseDecoy = v;
                    await _saveSection();
                  },
                ),
              ),
              // Build 2126 (D8).
              MapSettingRow(
                label: 'TLS fragmentation (sing-box engine)',
                subtitle:
                    'Splits the TLS hello across fragments '
                    'on handshakes the sing-box engine '
                    'terminates (TUIC, AnyTLS, Snell, Naive '
                    'and diverted configs). Off: those '
                    'hellos travel whole, as before.',
                trailing: MapToggle(
                  value: s.sidecarTlsFragment,
                  onChanged: (v) async {
                    s.sidecarTlsFragment = v;
                    await _saveSection();
                  },
                ),
              ),
              // Build 2127 (H3): per-route SNI spoofing.
              MapSettingRow(
                label: 'SNI spoofing (sing-box engine)',
                subtitle:
                    'For the domains in your rules, the '
                    'sing-box engine shows a filter a fake '
                    'TLS hello with a decoy name before the '
                    'real handshake. Off: no fake hellos, '
                    'as before.',
                trailing: MapToggle(
                  value: s.sniSpoofEnabled,
                  onChanged: (v) async {
                    s.sniSpoofEnabled = v;
                    await _saveSection();
                  },
                ),
              ),
              if (s.sniSpoofEnabled)
                MapSettingRow(
                  label: 'SNI spoofing rules',
                  subtitle:
                      '${s.sniSpoofRules.length} rule'
                      '${s.sniSpoofRules.length == 1 ? '' : 's'}',
                  trailing: _navChevron,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => SniSpoofPage(xray: xray),
                    ),
                  ),
                ),
              // Batch 5 (fidelity rollout, pro7-dns sample):
              // the FakeDNS row moves to the DNS panel — the
              // sample's OPTIONS block groups it with the
              // providers; the row, its toggle and its save
              // path are unchanged (a grouping move, the
              // build-2118 panel-split precedent).
              MapSettingRow(
                label: l.ipv6Route,
                trailing: MapToggle(
                  value: s.ipv6Route,
                  onChanged: (v) async {
                    s.ipv6Route = v;
                    await _saveSection();
                  },
                ),
              ),
              MapSettingRow(
                label: l.mux,
                // Build 2095 (V2Ray journey audit #27, second
                // half): the row names the protocols mux
                // applies to — it used to read as global.
                subtitle:
                    '${l.muxSub} Applies to VLESS, VMess, Trojan '
                    'and Shadowsocks configs.',
                trailing: MapToggle(
                  value: s.muxEnabled,
                  onChanged: (v) async {
                    s.muxEnabled = v;
                    await _saveSection();
                  },
                ),
              ),
              // Mux concurrency (build 2060, grouped sweep): the
              // stream count lived in the model with no UI row —
              // now a chip row, shown with the mux toggle.
              if (s.muxEnabled) ...[
                _ChipGroupRow(
                  label: 'Mux concurrency',
                  subtitle: 'Concurrent streams per connection',
                  chips: [
                    for (final n in const [1, 2, 4, 8, 16])
                      EmberChip(
                        label: '$n',
                        compact: true,
                        selected: s.muxConcurrency == n,
                        onTap: () async {
                          s.muxConcurrency = n;
                          await _saveSection();
                        },
                      ),
                  ],
                ),
              ],
              // Test All parallelism (build 2032): how many
              // throwaway cores the funnel's real stage runs at
              // once. Higher is faster and heavier.
              _ChipGroupRow(
                label: 'Test All parallelism',
                subtitle: 'Cores testing at once',
                chips: [
                  for (final n in const [2, 4, 6, 8])
                    EmberChip(
                      label: '$n',
                      compact: true,
                      selected: s.testAllConcurrency == n,
                      onTap: () async {
                        s.testAllConcurrency = n;
                        await _saveSection();
                      },
                    ),
                ],
              ),
              // Delay test timeout (build 2109, feature-watch
              // 2026-11-12, FlClash 0.9.2): how long one test
              // request waits for an answer — the single test,
              // Test All, the DPI Lab probes and the sandbox
              // test. 8s is the value every build ≤2108 used,
              // so a store that never set it behaves exactly as
              // before; shorter fails slow configs faster,
              // longer gives them more time to answer.
              _ChipGroupRow(
                label: 'Delay test timeout',
                subtitle: 'How long each test request waits for an answer',
                chips: [
                  for (final n in const [3, 5, 8, 10, 15, 20])
                    EmberChip(
                      label: '${n}s',
                      compact: true,
                      selected: s.delayTestTimeoutSec == n,
                      onTap: () async {
                        s.delayTestTimeoutSec = n;
                        await _saveSection();
                      },
                    ),
                ],
              ),
              MapSettingRow(
                label: l.fragment,
                subtitle: l.fragmentSub,
                trailing: MapToggle(
                  value: s.fragmentEnabled,
                  onChanged: (v) async {
                    s.fragmentEnabled = v;
                    await _saveSection();
                  },
                ),
              ),
              // Build 2126 (D2): shown with the fragment
              // toggle it modifies.
              if (s.fragmentEnabled)
                MapSettingRow(
                  label: 'Fragment via FinalMask',
                  subtitle:
                      'Applies the fragment split inside the '
                      'connection (FinalMask) instead of '
                      'through a chained dialer — the newer '
                      'core mechanism. Off: the chained '
                      'dialer, as before.',
                  trailing: MapToggle(
                    value: s.fragmentViaFinalmask,
                    onChanged: (v) async {
                      s.fragmentViaFinalmask = v;
                      await _saveSection();
                    },
                  ),
                ),
              // Fragment knobs (build 2060, grouped sweep): packets,
              // length and interval lived in the model with no UI
              // row — now chip rows, shown with the fragment toggle.
              if (s.fragmentEnabled) ...[
                _ChipGroupRow(
                  label: 'Fragment packets',
                  subtitle: 'Which packets to split',
                  chips: [
                    for (final p in const ['tlshello', '1-1', '1-3', '1-5'])
                      EmberChip(
                        label: p,
                        compact: true,
                        selected: s.fragmentPackets == p,
                        onTap: () async {
                          s.fragmentPackets = p;
                          await _saveSection();
                        },
                      ),
                  ],
                ),
                _ChipGroupRow(
                  label: 'Fragment length',
                  subtitle: 'Split length in bytes',
                  chips: [
                    for (final n in const [50, 100, 200, 500])
                      EmberChip(
                        label: '$n',
                        compact: true,
                        selected: s.fragmentLength == n,
                        onTap: () async {
                          s.fragmentLength = n;
                          await _saveSection();
                        },
                      ),
                  ],
                ),
                _ChipGroupRow(
                  label: 'Fragment interval',
                  subtitle: 'Delay between fragments (ms)',
                  chips: [
                    for (final n in const [10, 20, 50, 100])
                      EmberChip(
                        label: '$n',
                        compact: true,
                        selected: s.fragmentInterval == n,
                        onTap: () async {
                          s.fragmentInterval = n;
                          await _saveSection();
                        },
                      ),
                  ],
                ),
              ],
              // Build 2136 (item 8): randomized fragment
              // geometry — the fragment chain's fixed cuts
              // become ranges around the values above.
              MapSettingRow(
                label: 'Randomized fragment geometry',
                subtitle:
                    'The fragment length and interval above '
                    'become ranges (half to double); the core '
                    'picks a fresh cut per connection. Off: '
                    'the fixed values are used, as before.',
                trailing: MapToggle(
                  value: s.fragmentRandomGeometry,
                  onChanged: (v) async {
                    s.fragmentRandomGeometry = v;
                    await _saveSection();
                  },
                ),
              ),
              // Stage A (build 2026) + group semantics (build
              // 2035): fallback groups, ON by default — with it
              // off, the engine behaves exactly as in 2025.
              // Build 2087: the subtitle says what the switch
              // still governs — a manual connect no longer
              // walks (it tries exactly the picked config), so
              // the group move is for sessions that die.
              MapSettingRow(
                label: 'Fallback groups',
                subtitle: 'If a connected config dies, move to the next in its group automatically — a manual connect always tries exactly the config you picked',
                divider: false,
                trailing: MapToggle(
                  value: s.adaptiveFailover,
                  onChanged: (v) async {
                    s.adaptiveFailover = v;
                    await _saveSection();
                  },
                ),
              ),
              // Build 2136 (item 14): auto-fastest group.
              MapSettingRow(
                label: 'Auto-fastest group',
                subtitle:
                    'A connect starts from the fastest tested '
                    'member of the config\'s group instead of '
                    'the tapped one; failover still walks the '
                    'group if it fails. Off: the tapped config '
                    'starts, as before.',
                trailing: MapToggle(
                  value: s.autoFastestGroup,
                  onChanged: (v) async {
                    s.autoFastestGroup = v;
                    await _saveSection();
                  },
                ),
              ),
              // Build 2136 (item 1): stop on sleep.
              MapSettingRow(
                label: 'Stop VPN when the screen turns off',
                subtitle:
                    'Disconnects the running engine when the '
                    'device sleeps, instead of holding the '
                    'tunnel overnight. Acts while the app '
                    'process is alive. Off: sleep behaviour '
                    'is unchanged.',
                trailing: MapToggle(
                  value: s.stopVpnOnSleep,
                  onChanged: (v) async {
                    s.stopVpnOnSleep = v;
                    await _saveSection();
                  },
                ),
              ),
              // Build 2095 (feature 2): the stall
              // watchdog's user control. The watchdog
              // detects a frozen tunnel (traffic up,
              // nothing back, probes failing) and escalates
              // — shapes first, then the group failover.
              MapSettingRow(
                label: 'Stall watchdog',
                subtitle: 'If the tunnel freezes, switch shapes and then configs automatically',
                trailing: MapToggle(
                  value: s.stallWatchdog,
                  onChanged: (v) async {
                    s.stallWatchdog = v;
                    await _saveSection();
                  },
                ),
              ),
              // Build 2151 (item D): the connected-but-
              // blocked alert — when a session is adopted
              // but its background data-plane proof never
              // lands, the journal says so plainly instead
              // of leaving dead traffic to be discovered.
              // DEFAULT ON by the owner's explicit order
              // (2026-11-26) — the one exception to the
              // features law's default-off rule.
              MapSettingRow(
                label: 'Connected-but-blocked alert',
                subtitle: 'Journal a plain warning when a connected session carries no traffic',
                trailing: MapToggle(
                  value: s.blockedAlert,
                  onChanged: (v) async {
                    s.blockedAlert = v;
                    await _saveSection();
                  },
                ),
              ),
              // Build 2155 (the 2153 bridge swap): the
              // V2Ray path's TUN bridge. Hev
              // (hev-socks5-tunnel) forwards packets
              // without terminating TCP in a userspace
              // stack; Legacy tunlink is the pre-2155
              // gVisor subprocess, kept as the on-device
              // A/B fallback. Applies at the next connect,
              // like every session argument.
              _ChipGroupRow(
                label: 'Tunnel bridge',
                subtitle: 'How tunnel packets reach the V2Ray core. Hev is the new bridge; Legacy tunlink is the pre-2155 one. Applies at next connect.',
                chips: [
                  EmberChip(
                    label: 'Hev',
                    compact: true,
                    selected: s.v2rayBridge != 'tunlink',
                    onTap: () async {
                      s.v2rayBridge = 'hev';
                      await _saveSection();
                    },
                  ),
                  EmberChip(
                    label: 'Legacy tunlink',
                    compact: true,
                    selected: s.v2rayBridge == 'tunlink',
                    onTap: () async {
                      s.v2rayBridge = 'tunlink';
                      await _saveSection();
                    },
                  ),
                ],
              ),
              // Build 2157 (feature pick 4): the ByeDPI
              // desync hop — the DPI Lab's zap strategies
              // (ciadpi) as a hand-picked chain hop in front
              // of the proxy, no Lab run needed. DEFAULT
              // OFF (the features law); the pick applies at
              // the next connect, like the bridge above.
              _ChipGroupRow(
                label: 'ByeDPI desync hop',
                subtitle: 'Dial through the ByeDPI desync proxy in front of the proxy server — the DPI Lab\u2019s zap strategies, picked by hand. Applies at next connect.',
                chips: [
                  EmberChip(
                    label: 'Off',
                    compact: true,
                    selected: s.byedpiHop.isEmpty,
                    onTap: () => xray.setByedpiHop(''),
                  ),
                  for (final id in zapretCandidateIds)
                    EmberChip(
                      label: zapretStrategyLabels[id]!,
                      compact: true,
                      selected: s.byedpiHop == id,
                      onTap: () => xray.setByedpiHop(id),
                    ),
                ],
              ),
              // Smart dial racing (build 2075, feature item 5):
              // when the picked config fails, the next group
              // members' endpoints are probed in parallel and
              // the first that answers is tried first, instead
              // of one slow timeout after another.
              MapSettingRow(
                label: 'Smart dial racing',
                subtitle: 'Race the fallback group\'s endpoints in parallel and dial the first that answers',
                divider: false,
                trailing: MapToggle(
                  value: s.smartDialRacing,
                  onChanged: (v) async {
                    s.smartDialRacing = v;
                    await _saveSection();
                    xray.notifySettingsChanged();
                  },
                ),
              ),
              // Country exclusion (build 2075, feature item
              // 16): automatic picks — the fallback walk and
              // keep-fastest pruning — skip configs whose
              // observed exit country is listed. A manual tap
              // still connects any config.
              _ListRow(
                label: 'Excluded exit countries',
                values: s.excludedCountries,
                onChanged: (v) async {
                  s.excludedCountries = v
                      .map((e) => e.trim().toUpperCase())
                      .where((e) => e.length == 2)
                      .toList();
                  await _saveSection();
                  xray.notifySettingsChanged();
                },
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(
                  'ISO country codes (e.g. IR, CN, RU). Automatic selection skips configs that exit there; tapping one yourself still connects it.',
                  style: Ember.caption,
                ),
              ),
              // Routing by network type (build 2075, feature
              // item 26): the active routing preset follows
              // the transport; a running tunnel keeps the
              // preset it started with.
              MapSettingRow(
                label: 'Routing by network type',
                subtitle: 'Use a different routing preset on Wi-Fi and on mobile data',
                divider: false,
                trailing: MapToggle(
                  value: s.routingByNetwork,
                  onChanged: (v) async {
                    s.routingByNetwork = v;
                    await _saveSection();
                    xray.notifySettingsChanged();
                  },
                ),
              ),
              if (s.routingByNetwork) ...[
                _ChipGroupRow(
                  label: 'On Wi-Fi',
                  subtitle: 'Routing preset for Wi-Fi networks',
                  chips: [
                    for (final preset in RoutingPreset.values)
                      EmberChip(
                        label: switch (preset) {
                          RoutingPreset.global => 'Global',
                          RoutingPreset.bypassLan => 'Bypass LAN',
                          RoutingPreset.bypassIran => 'Bypass Iran',
                          RoutingPreset.bypassChina => 'Bypass China',
                          RoutingPreset.directAll => 'Direct all',
                        },
                        compact: true,
                        selected: s.routingPresetWifi == preset,
                        onTap: () async {
                          s.routingPresetWifi = preset;
                          await _saveSection();
                          xray.notifySettingsChanged();
                        },
                      ),
                  ],
                ),
                _ChipGroupRow(
                  label: 'On mobile data',
                  subtitle: 'Routing preset for mobile networks',
                  divider: false,
                  chips: [
                    for (final preset in RoutingPreset.values)
                      EmberChip(
                        label: switch (preset) {
                          RoutingPreset.global => 'Global',
                          RoutingPreset.bypassLan => 'Bypass LAN',
                          RoutingPreset.bypassIran => 'Bypass Iran',
                          RoutingPreset.bypassChina => 'Bypass China',
                          RoutingPreset.directAll => 'Direct all',
                        },
                        compact: true,
                        selected: s.routingPresetMobile == preset,
                        onTap: () async {
                          s.routingPresetMobile = preset;
                          await _saveSection();
                          xray.notifySettingsChanged();
                        },
                      ),
                  ],
                ),
              ],
              // Multi-peer WireGuard (build 2075, feature item
              // 27): a .conf with several peers connects with
              // all of them in the outbound, not just the one
              // peer this profile carries.
              MapSettingRow(
                label: 'Use all peers of a WireGuard config',
                subtitle: 'When a .conf file has several peers, connect with every peer in it',
                divider: false,
                trailing: MapToggle(
                  value: s.wgUseAllPeers,
                  onChanged: (v) async {
                    s.wgUseAllPeers = v;
                    await _saveSection();
                    xray.notifySettingsChanged();
                  },
                ),
              ),
              // Auto-reconnect (build 2042, feature-watch
              // 2026-11-12): a tunnel the carrier kills comes
              // back by itself after a short wait, a bounded
              // number of times; a manual disconnect never
              // reconnects. Not a kill-switch on its own: while
              // the app waits, the tunnel is down and traffic is
              // direct until the reconnect lands — unless the
              // kill switch below is on, which holds the dead
              // tunnel as a blackhole while it waits (2063).
              MapSettingRow(
                label: 'Auto-reconnect',
                subtitle: 'If the tunnel drops by itself, reconnect automatically. A manual disconnect never reconnects.',
                divider: false,
                trailing: MapToggle(
                  value: s.autoReconnect,
                  onChanged: (v) async {
                    s.autoReconnect = v;
                    await _saveSection();
                    // The delay/attempts rows below appear or hide
                    // with this toggle, so the section must rebuild
                    // at once (save() alone does not notify).
                    xray.notifySettingsChanged();
                  },
                ),
              ),
              if (s.autoReconnect) ...[
                _ChipGroupRow(
                  label: 'Reconnect delay',
                  subtitle: 'Wait between the drop and the next try',
                  chips: [
                    for (final n in const [5, 10, 20, 30])
                      EmberChip(
                        label: '${n}s',
                        compact: true,
                        selected: s.reconnectDelaySeconds == n,
                        onTap: () async {
                          s.reconnectDelaySeconds = n;
                          await _saveSection();
                          xray.notifySettingsChanged();
                        },
                      ),
                  ],
                ),
                _ChipGroupRow(
                  label: 'Reconnect attempts',
                  subtitle: 'Tries before giving up and waiting for you',
                  divider: false,
                  chips: [
                    for (final n in const [3, 5, 10])
                      EmberChip(
                        label: '$n',
                        compact: true,
                        selected: s.reconnectMaxAttempts == n,
                        onTap: () async {
                          s.reconnectMaxAttempts = n;
                          await _saveSection();
                          xray.notifySettingsChanged();
                        },
                      ),
                  ],
                ),
              ],
              const Divider(color: MapUi.line, height: 1),
              // Kill switch (build 2063, feature queue #3):
              // while the V2Ray or WARP tunnel is down — a drop,
              // or a reconnect wait — all traffic is blocked
              // instead of going direct. Off by default; applies
              // at next connect. Build 2125 (audit A25-04)
              // extended the hold to the Psiphon, Lantern and
              // OpenVPN engines; build 2127 (H4) covers the
              // last two: Mozilla (the service keeps a dup of
              // the TUN fd, so the interface survives the
              // core as a blackhole) and AmneziaWG (the
              // library's own lockdown). If Android itself
              // kills the app, only Android's Always-on VPN
              // can block — this switch cannot.
              MapSettingRow(
                label: 'Kill switch',
                subtitle: 'Block all traffic while the tunnel is down, including the auto-reconnect wait.',
                trailing: MapToggle(
                  value: s.killSwitch,
                  onChanged: (v) async {
                    s.killSwitch = v;
                    await _saveSection();
                    // Build 2127 (H4): the Mozilla engine
                    // reads the same switch through its
                    // AndroidCore mirror.
                    AndroidCore.killSwitch.value = v;
                    // The caption below appears or hides with
                    // this toggle, so the section must rebuild
                    // at once (save() alone does not notify).
                    xray.notifySettingsChanged();
                  },
                ),
              ),
              if (s.killSwitch)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    'While on, a dropped or failed tunnel blocks all traffic until it reconnects or you disconnect. This covers every engine: V2Ray/WARP, Psiphon, Lantern, OpenVPN, Mozilla, AmneziaWG and URnetwork.',
                    style: Ember.caption,
                  ),
                ),
              const Divider(color: MapUi.line, height: 1),
              // TLS fingerprint rotation (build 2065, item 13):
              // each new connect of a profile whose fingerprint
              // field is empty takes the next browser fingerprint
              // from the rotation set. A profile with its own
              // fingerprint is never overridden.
              MapSettingRow(
                label: 'Rotate TLS fingerprint',
                subtitle: 'A different browser fingerprint (Chrome, Firefox, Safari, iOS) on each new connection, for configs that do not set their own',
                trailing: MapToggle(
                  value: s.rotateTlsFingerprint,
                  onChanged: (v) async {
                    s.rotateTlsFingerprint = v;
                    await _saveSection();
                    xray.notifySettingsChanged();
                  },
                ),
              ),
              // Scheduled subscription health (build 2065, item
              // 12): an in-app schedule — while the app runs, the
              // real delay test re-runs at most once per interval,
              // never while a tunnel is up. Off by default
              // (battery). A background WorkManager job was NOT
              // used: androidx.work is not in the offline build
              // cache, and an unshipped dependency helps no one;
              // see BUILD-LOG 2065.
              MapSettingRow(
                label: 'Scheduled config health test',
                subtitle: 'Re-test every config with the real delay test on a schedule while the app runs',
                trailing: MapToggle(
                  value: s.subHealthEnabled,
                  onChanged: (v) async {
                    s.subHealthEnabled = v;
                    await _saveSection();
                    xray.notifySettingsChanged();
                  },
                ),
              ),
              if (s.subHealthEnabled)
                _ChipGroupRow(
                  label: 'Health test interval',
                  subtitle: 'How often the scheduled test may run',
                  divider: false,
                  chips: [
                    for (final n in const [6, 12, 24])
                      EmberChip(
                        label: '${n}h',
                        compact: true,
                        selected: s.subHealthIntervalHours == n,
                        onTap: () async {
                          s.subHealthIntervalHours = n;
                          await _saveSection();
                          xray.notifySettingsChanged();
                        },
                      ),
                  ],
                ),
              const Divider(color: MapUi.line, height: 1),
              // Config mixins (build 2043): the user's own JSON
              // object, merged into the tunnel config at the end
              // of every build — an advanced escape hatch for
              // core options the app has no toggle for (a log
              // level, an extra routing rule, a policy tweak).
              // Empty means no mixins: exactly the old config.
              _MixinsRow(
                mixinsText: s.configMixins,
                onChanged: (v) async {
                  s.configMixins = v;
                  await _saveSection();
                },
              ),
            ],
          ),
          const SizedBox(height: 14),
          MapSettingsPanel(
            title: l.dnsSection,
            children: [
              // Build 2101 (settings-dns-2099-diagnosis.md,
              // S2): the panel never said WHEN a DNS change
              // takes effect — the config is built fresh at
              // connect, so a mid-session edit silently waited
              // for the next connect and read as "doesn't
              // apply". The LAN-sharing panel's wording, here
              // too.
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  'Applies at next connect.',
                  style: Ember.caption,
                ),
              ),
              _TextRow(
                label: l.remoteDns,
                initial: s.remoteDns,
                onSubmit: (v) async {
                  if (v.isNotEmpty) s.remoteDns = v;
                  await _save(context);
                },
              ),
              // Resolver presets (build 2030): the "+one"
              // schemes are the patched core's one-connection-
              // per-query DoH — a fresh connection per query
              // leaves no long-lived DoH session for a filter
              // to freeze.
              // Batch 5 (fidelity rollout, pro7-dns sample):
              // the presets are provider ROWS now, not chips —
              // name, the URL verbatim as the caption, and a
              // flat SELECTED pill on the row whose URL the
              // field currently holds; the tap and the save
              // are the chip's own. The sample's 'Default'
              // row has no separate counterpart: the app's
              // model is the one URL field above, whose
              // shipped default is the Cloudflare DoH value
              // (build 2111) — that row carries SELECTED
              // whenever the value is untouched.
              for (final (label, url) in const [
                ('Google DoH', 'https://dns.google/dns-query'),
                ('Google DoH +one', 'https+one://dns.google/dns-query'),
                ('Cloudflare DoH', 'https://cloudflare-dns.com/dns-query'),
                (
                  'Cloudflare +one',
                  'https+one://cloudflare-dns.com/dns-query',
                ),
                ('Quad9 DoH', 'https://dns.quad9.net/dns-query'),
              ])
                _DnsProviderRow(
                  label: label,
                  url: url,
                  selected: s.remoteDns == url,
                  onTap: () async {
                    s.remoteDns = url;
                    await _saveSection();
                  },
                ),
              // Build 2149 (expansion 5): the full preset
              // catalogue — the rows above are the three
              // DoH providers the panel has always carried;
              // the picker page holds the whole curated set
              // (Global + the Iranian anti-sanctions
              // resolvers). A tap there fills this field and
              // saves; opening and leaving it changes
              // nothing, and no default moves.
              MapSettingRow(
                label: 'All DNS presets',
                subtitle: 'Global and Iranian resolvers — fills the remote DNS field',
                trailing: _navChevron,
                onTap: () async {
                  final picked = await Navigator.of(context).push<String>(
                    MaterialPageRoute(
                      builder: (_) => DnsPresetsPage(
                        target: DnsPresetTarget.remote,
                        currentValue: s.remoteDns,
                        xray: xray,
                      ),
                    ),
                  );
                  if (picked != null && picked.isNotEmpty) {
                    s.remoteDns = picked;
                    await _saveSection();
                  }
                },
              ),
              // Resolver transport (build 2032): DoH, or DoQ —
              // DNS-over-QUIC to the same provider — but the core
              // dispatches only quic+local (build 2053, audit
              // F-H4), which is local egress: the query leaves
              // the device directly, not through the tunnel. TCP
              // (build 2037, Iran-priority queue 2e) asks the same
              // provider over plain DNS on TCP port 53 at its
              // pinned IP — no hostname, no SNI, and UDP
              // poisoning cannot touch it. The chain line under
              // it is the config's real resolution order:
              // primary, then the group or the fallback when
              // enabled, each mapped through the same transport.
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 7,
                      runSpacing: 7,
                      children: [
                        EmberChip(
                          label: 'DoH',
                          selected: s.remoteDnsProto == 'doh',
                          onTap: () async {
                            s.remoteDnsProto = 'doh';
                            await _saveSection();
                          },
                        ),
                        EmberChip(
                          label: 'DoQ (QUIC, direct)',
                          selected: s.remoteDnsProto == 'doq',
                          onTap: () async {
                            s.remoteDnsProto = 'doq';
                            await _saveSection();
                          },
                        ),
                        EmberChip(
                          label: 'TCP (port 53)',
                          selected: s.remoteDnsProto == 'tcp',
                          onTap: () async {
                            s.remoteDnsProto = 'tcp';
                            await _saveSection();
                          },
                        ),
                        // DNSCrypt (build 2075, feature item 7):
                        // the local dnscrypt-proxy sidecar is
                        // the resolver — encrypted DNSCrypt /
                        // DoH to a pinned public set, run by
                        // the app while the tunnel is up.
                        EmberChip(
                          label: 'DNSCrypt',
                          selected: s.remoteDnsProto == 'dnscrypt',
                          onTap: () async {
                            s.remoteDnsProto = 'dnscrypt';
                            await _saveSection();
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 7),
                    Text(
                      'Resolution order: ${primaryResolver(s)}'
                      '${s.dnsGroup
                          ? ' → group: ${dnsGroupMembers.map((m) => resolverUnderTransport(m, s.remoteDnsProto)).join(' → ')}'
                          : s.dnsFallback
                          ? ' → ${resolverUnderTransport(s.fallbackDns.trim(), s.remoteDnsProto)}'
                          : ''}'
                      // Build 2056 named the 2049 built-in
                      // fallback here when it rode the default
                      // shape; build 2101 removes that fallback
                      // (owner order 2026-11-18 — v2rayNG's
                      // shape carries none), so the line names
                      // only what the config really holds.
                      // Build 2053 (audit F-H4): the core speaks
                      // ONLY quic+local for DoQ, and +local is
                      // local egress — the query leaves the device
                      // directly, not through the tunnel — so the
                      // "never the local one" line must not be
                      // claimed for DoQ.
                      '${s.remoteDnsProto == 'doq'
                          ? ' • DoQ is local-egress: its queries leave the device directly, not through the tunnel'
                          : s.remoteDnsProto == 'dnscrypt'
                          ? ' • DNSCrypt runs through the app\'s local dnscrypt-proxy (127.0.0.1:20530); its signed resolver list downloads on first use'
                          : ' • server names resolve through the provider DNS, never the local one'}',
                      style: Ember.caption,
                    ),
                  ],
                ),
              ),
              const Divider(color: MapUi.line, height: 1),
              _TextRow(
                label: l.localDns,
                initial: s.localDns,
                onSubmit: (v) async {
                  if (v.isNotEmpty) s.localDns = v;
                  await _save(context);
                },
              ),
              // Build 2116 (B9-3, re-verified): this field
              // is NOT the V2Ray core's DNS — the generated
              // config derives that from the remote DNS
              // above. It is the tunnel-interface DNS for
              // WireGuard, Lantern and Psiphon, and the row
              // says so instead of implying otherwise.
              Padding(
                padding: const EdgeInsets.only(top: 6, bottom: 2),
                child: Text(
                  'Applies to WireGuard, Lantern and Psiphon '
                  'tunnels. The V2Ray core uses the remote DNS '
                  'above.',
                  style: Ember.caption,
                ),
              ),
              // Build 2149 (expansion 5): the same catalogue
              // for the local field — a tap fills it with the
              // preset's first address.
              MapSettingRow(
                label: 'Local DNS presets',
                subtitle: 'Global and Iranian resolvers — fills the local DNS field',
                trailing: _navChevron,
                onTap: () async {
                  final picked = await Navigator.of(context).push<String>(
                    MaterialPageRoute(
                      builder: (_) => DnsPresetsPage(
                        target: DnsPresetTarget.local,
                        currentValue: s.localDns,
                        xray: xray,
                      ),
                    ),
                  );
                  if (picked != null && picked.isNotEmpty) {
                    s.localDns = picked;
                    await _saveSection();
                  }
                },
              ),
              const Divider(color: MapUi.line, height: 1),
              // Ad-block preset (build 2030): the tunnel's
              // remote resolver becomes AdGuard's filtering
              // DoH — ads and trackers fail at resolution.
              MapSettingRow(
                label: 'Block ads & trackers',
                subtitle: 'Resolve through AdGuard’s filtering DNS',
                trailing: MapToggle(
                  value: s.adBlockDoh,
                  onChanged: (v) async {
                    s.adBlockDoh = v;
                    await _saveSection();
                  },
                ),
              ),
              const Divider(color: MapUi.line, height: 1),
              // DNS group (build 2033): the primary plus the
              // well-known encrypted resolvers, worked in
              // order by the core — the resolver that answers
              // is the one that sticks, and every member is
              // encrypted, so a poisoned local answer never
              // enters. Supersedes the single fallback below
              // while on (the builder says so too).
              MapSettingRow(
                label: 'DNS group',
                subtitle: 'Google, Cloudflare and Quad9 asked in turn; the working one sticks',
                trailing: MapToggle(
                  value: s.dnsGroup,
                  onChanged: (v) async {
                    s.dnsGroup = v;
                    await _saveSection();
                  },
                ),
              ),
              const Divider(color: MapUi.line, height: 1),
              // DNS cache off (build 2075, feature item 23 —
              // the part of the DNS control pack the core
              // honestly supports: its DNS section has a real
              // disableCache field. Optimistic caching and
              // per-resolver timeouts have no field in the
              // core's DNS schema and are not offered.)
              MapSettingRow(
                label: 'Disable DNS cache',
                subtitle: 'The core re-resolves every name instead of serving its cache',
                trailing: MapToggle(
                  value: s.dnsCacheDisabled,
                  onChanged: (v) async {
                    s.dnsCacheDisabled = v;
                    await _saveSection();
                  },
                ),
              ),
              const Divider(color: MapUi.line, height: 1),
              // DNS fallback policy (build 2030): a second
              // resolver that answers only when the primary
              // fails to resolve — it never overrides the
              // ad-block filter's answers.
              MapSettingRow(
                label: 'DNS fallback',
                subtitle: 'Used only when the main resolver fails',
                trailing: MapToggle(
                  value: s.dnsFallback,
                  onChanged: (v) async {
                    s.dnsFallback = v;
                    await _saveSection();
                  },
                ),
              ),
              if (s.dnsFallback) ...[
                const Divider(color: MapUi.line, height: 1),
                _TextRow(
                  label: 'Fallback DNS',
                  initial: s.fallbackDns,
                  onSubmit: (v) async {
                    if (v.isNotEmpty) s.fallbackDns = v;
                    await _save(context);
                  },
                ),
              ],
              const Divider(color: MapUi.line, height: 1),
              // Batch 5 (fidelity rollout, pro7-dns sample):
              // FakeDNS lives here now — the sample's DNS
              // OPTIONS block (its row moved from the Advanced
              // panel; same toggle, same save path).
              MapSettingRow(
                label: l.fakeDns,
                trailing: MapToggle(
                  value: s.fakeDns,
                  onChanged: (v) async {
                    s.fakeDns = v;
                    await _saveSection();
                  },
                ),
              ),
              const Divider(color: MapUi.line, height: 1),
              // Custom DNS hosts (build 2041): the user's own
              // name → IP map, answered by the tunnel's DNS
              // before any resolver is asked — pin a name to a
              // known-good IP when the local network's DNS lies
              // about it (a poisoned answer for a subscription
              // host, a provider's SNI name, or a local name
              // like wg.home).
              _HostsRow(
                hosts: s.customDnsHosts,
                onChanged: (v) async {
                  s.customDnsHosts = v;
                  await _saveSection();
                },
              ),
              const Divider(color: MapUi.line, height: 1),
              _TextRow(
                label: l.socksPort,
                initial: '${s.socksPort}',
                numeric: true,
                onSubmit: (v) async {
                  final port = int.tryParse(v);
                  // Build 2057 (audit F-M2): the pair is validated
                  // together — a port that collides with another
                  // engine, with the HTTP port, or with the stats
                  // port (SOCKS + 5000) is refused here with the
                  // named reason instead of breaking every connect
                  // with a generic start failure.
                  final problem = port == null
                      ? 'Enter a port number.'
                      : validateXrayPorts(
                          socksPort: port,
                          httpPort: s.httpPort,
                        );
                  if (problem != null) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(problem),
                          duration: const Duration(seconds: 6),
                        ),
                      );
                    }
                    return;
                  }
                  s.socksPort = port!;
                  await _save(context);
                },
              ),
              const Divider(color: MapUi.line, height: 1),
              _TextRow(
                label: l.httpPort,
                initial: '${s.httpPort}',
                numeric: true,
                onSubmit: (v) async {
                  final port = int.tryParse(v);
                  final problem = port == null
                      ? 'Enter a port number.'
                      : validateXrayPorts(
                          socksPort: s.socksPort,
                          httpPort: port,
                        );
                  if (problem != null) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(problem),
                          duration: const Duration(seconds: 6),
                        ),
                      );
                    }
                    return;
                  }
                  s.httpPort = port!;
                  await _save(context);
                },
              ),
            ],
          ),
          const SizedBox(height: 14),
          // LAN sharing (build 2062, feature queue #2): share
          // the V2Ray tunnel as a SOCKS5/HTTP proxy on the local
          // network, with optional username/password auth. Off
          // by default; everything here applies at next connect.
          MapSettingsPanel(
            title: 'LAN sharing',
            children: [
              MapSettingRow(
                label: 'Share on local network',
                subtitle: 'Other devices on your Wi-Fi can use this tunnel as a proxy. Applies at next connect.',
                trailing: MapToggle(
                  value: s.lanShareEnabled,
                  onChanged: (v) async {
                    s.lanShareEnabled = v;
                    await _saveSection();
                  },
                ),
              ),
              if (s.lanShareEnabled) ...[
                const Divider(color: MapUi.line, height: 1),
                _LanShareAddresses(
                  socksPort: s.socksPort,
                  httpPort: s.httpPort,
                ),
                const Divider(color: MapUi.line, height: 1),
                MapSettingRow(
                  label: 'Require username and password',
                  subtitle: 'Other devices must log in to use the tunnel',
                  trailing: MapToggle(
                    value: s.lanShareAuth,
                    onChanged: (v) async {
                      s.lanShareAuth = v;
                      await _saveSection();
                    },
                  ),
                ),
                if (s.lanShareAuth) ...[
                  const Divider(color: MapUi.line, height: 1),
                  _TextRow(
                    label: 'Username',
                    initial: s.lanShareUser,
                    onSubmit: (v) async {
                      if (v.isEmpty) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Enter a username.'),
                              duration: Duration(seconds: 6),
                            ),
                          );
                        }
                        return;
                      }
                      s.lanShareUser = v;
                      await _save(context);
                    },
                  ),
                  const Divider(color: MapUi.line, height: 1),
                  _TextRow(
                    label: 'Password',
                    initial: s.lanSharePass,
                    obscure: true,
                    onSubmit: (v) async {
                      if (v.isEmpty) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Enter a password.'),
                              duration: Duration(seconds: 6),
                            ),
                          );
                        }
                        return;
                      }
                      s.lanSharePass = v;
                      await _save(context);
                    },
                  ),
                ],
                if (!s.lanShareAuth)
                  Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      'Anyone on your Wi-Fi can use the tunnel.',
                      style: Ember.caption,
                    ),
                  ),
                if (s.lanShareAuth && !s.lanShareAuthReady)
                  Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      'Enter a username and password — until then the shared proxy has no login.',
                      style: Ember.caption,
                    ),
                  ),
              ],
            ],
          ),
          const SizedBox(height: 14),
          // Local proxy (build 2075, feature items 17 + 24):
          // a dedicated browser port, and an optional login on
          // the loopback proxy inbounds.
          MapSettingsPanel(
            title: 'Local proxy',
            children: [
              MapSettingRow(
                label: 'Dedicated browser port',
                subtitle:
                    'A fixed HTTP proxy on 127.0.0.1:${s.browserPort} while connected. Point your browser at it yourself — nothing is configured for you.',
                trailing: MapToggle(
                  value: s.browserPortEnabled,
                  onChanged: (v) async {
                    s.browserPortEnabled = v;
                    await _saveSection();
                  },
                ),
              ),
              if (s.browserPortEnabled) ...[
                const Divider(color: MapUi.line, height: 1),
                _TextRow(
                  label: 'Browser port',
                  initial: '${s.browserPort}',
                  numeric: true,
                  onSubmit: (v) async {
                    final port = int.tryParse(v);
                    if (port == null || port < 1024 || port > 65535) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'Enter a port between 1024 and 65535.',
                            ),
                            duration: Duration(seconds: 6),
                          ),
                        );
                      }
                      return;
                    }
                    s.browserPort = port;
                    await _save(context);
                  },
                ),
              ],
              const Divider(color: MapUi.line, height: 1),
              MapSettingRow(
                label: 'Require a login on this device',
                subtitle: 'The local SOCKS and HTTP proxies ask for a username and password. The LAN sharing login above stays separate.',
                trailing: MapToggle(
                  value: s.localProxyAuth,
                  onChanged: (v) async {
                    s.localProxyAuth = v;
                    await _saveSection();
                  },
                ),
              ),
              if (s.localProxyAuth) ...[
                const Divider(color: MapUi.line, height: 1),
                _TextRow(
                  label: 'Username',
                  initial: s.localProxyUser,
                  onSubmit: (v) async {
                    s.localProxyUser = v;
                    await _save(context);
                  },
                ),
                const Divider(color: MapUi.line, height: 1),
                _TextRow(
                  label: 'Password',
                  initial: s.localProxyPass,
                  obscure: true,
                  onSubmit: (v) async {
                    s.localProxyPass = v;
                    await _save(context);
                  },
                ),
                if (!s.localProxyAuthReady)
                  Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      'Enter a username and password — until then the local proxies have no login.',
                      style: Ember.caption,
                    ),
                  ),
              ],
            ],
          ),
          const SizedBox(height: 14),
          MapSettingsPanel(
            title: l.customRules,
            children: [
              _ListRow(
                label: l.directDomains,
                values: s.customDirectDomains,
                onChanged: (v) async {
                  s.customDirectDomains = v;
                  await _saveSection();
                },
              ),
              const Divider(color: MapUi.line, height: 1),
              _ListRow(
                label: l.directIps,
                values: s.customDirectIps,
                onChanged: (v) async {
                  s.customDirectIps = v;
                  await _saveSection();
                },
              ),
              const Divider(color: MapUi.line, height: 1),
              _ListRow(
                label: l.blockDomains,
                values: s.customBlockDomains,
                onChanged: (v) async {
                  s.customBlockDomains = v;
                  await _saveSection();
                },
              ),
              const Divider(color: MapUi.line, height: 1),
              _ListRow(
                label: l.proxyDomains,
                values: s.customProxyDomains,
                onChanged: (v) async {
                  s.customProxyDomains = v;
                  await _saveSection();
                },
              ),
            ],
          ),
          const SizedBox(height: 14),
          MapSettingsPanel(
            title: l.subscriptionsTitle,
            children: [
              MapSettingRow(
                label: l.updateOnLaunch,
                trailing: MapToggle(
                  value: s.subUpdateOnLaunch,
                  onChanged: (v) async {
                    s.subUpdateOnLaunch = v;
                    await _saveSection();
                  },
                ),
              ),
              // Subscription refresh period (build 2060, grouped
              // sweep): the hours value lived in the model with no
              // UI row — now a chip row in the Subscriptions panel.
              _ChipGroupRow(
                label: 'Subscription refresh',
                subtitle: 'Hours between automatic subscription updates',
                chips: [
                  for (final n in const [6, 12, 24, 48, 72])
                    EmberChip(
                      label: '${n}h',
                      compact: true,
                      selected: s.subAutoUpdateHours == n,
                      onTap: () async {
                        s.subAutoUpdateHours = n;
                        await _saveSection();
                      },
                    ),
                ],
              ),
              // Build 2134 (leg 2): the automatic per-device
              // HWID switch — default OFF; while off, fetches
              // send exactly build 2133's headers.
              MapSettingRow(
                label: 'Device HWID header',
                subtitle:
                    'Send this device\'s stable ID (x-hwid) '
                    'when fetching subscriptions — some panels '
                    'require it',
                trailing: MapToggle(
                  value: s.subHwidEnabled,
                  onChanged: (v) async {
                    s.subHwidEnabled = v;
                    if (v && s.deviceHwid.isEmpty) {
                      s.deviceHwid = generateDeviceHwid();
                    }
                    await _saveSection();
                  },
                ),
              ),
              if (s.subHwidEnabled) ...[
                MapSettingRow(
                  label: 'Device ID',
                  subtitle: s.deviceHwid.isEmpty
                      ? 'Created on the next fetch'
                      : s.deviceHwid,
                  trailing: const Icon(
                    Icons.copy_rounded,
                    size: 18,
                    color: MapUi.dim,
                  ),
                  onTap: s.deviceHwid.isEmpty
                      ? null
                      : () async {
                          await Clipboard.setData(
                            ClipboardData(text: s.deviceHwid),
                          );
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Device ID copied'),
                              ),
                            );
                          }
                        },
                ),
                MapSettingRow(
                  label: 'Regenerate device ID',
                  subtitle: 'Panels will see a new device',
                  trailing: const Icon(
                    Icons.refresh_rounded,
                    size: 18,
                    color: MapUi.dim,
                  ),
                  onTap: () async {
                    s.deviceHwid = generateDeviceHwid();
                    await _saveSection();
                  },
                ),
              ],
              MapSettingRow(
                label: l.backupData,
                trailing: _navChevron,
                onTap: () => _showBackup(context),
              ),
              MapSettingRow(
                label: l.restoreData,
                trailing: _navChevron,
                onTap: () => _showRestore(context),
              ),
              MapSettingRow(
                label: l.coreLogs,
                trailing: _navChevron,
                divider: false,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => XrayLogsPage(xray: xray)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          // Build 2105: the build's three V2Ray features, each
          // behind its own default-OFF switch (the standing
          // rule). Off, none of them records, groups, or
          // resolves anything, and the config list and the
          // connect path are exactly the pre-2105 ones.
          MapSettingsPanel(
            title: 'Traffic & groups',
            children: [
              MapSettingRow(
                label: 'Traffic history',
                subtitle:
                    'Record each config\'s traffic by the hour, '
                    'for the chart below',
                trailing: MapToggle(
                  value: s.trafficHistoryEnabled,
                  onChanged: (v) async {
                    s.trafficHistoryEnabled = v;
                    await _saveSection();
                  },
                ),
              ),
              if (s.trafficHistoryEnabled)
                MapSettingRow(
                  label: 'Traffic chart',
                  subtitle: 'What each config moved, by the hour',
                  trailing: _navChevron,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => TrafficHistoryPage(xray: xray),
                    ),
                  ),
                ),
              MapSettingRow(
                label: 'Smart groups',
                subtitle:
                    'Gather configs into groups by your own rules '
                    '(protocol, name, latency, …)',
                trailing: MapToggle(
                  value: s.smartGroupsEnabled,
                  onChanged: (v) async {
                    s.smartGroupsEnabled = v;
                    await _saveSection();
                  },
                ),
              ),
              if (s.smartGroupsEnabled)
                MapSettingRow(
                  label: 'Smart group rules',
                  subtitle:
                      '${s.smartGroupRules.length} rule'
                      '${s.smartGroupRules.length == 1 ? '' : 's'}',
                  trailing: _navChevron,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => SmartGroupsPage(xray: xray),
                    ),
                  ),
                ),
              MapSettingRow(
                label: 'Provider DNS for servers',
                subtitle:
                    'Resolve a subscription\'s server names '
                    'through the DNS set on that subscription '
                    '(in its editor), not the network\'s resolver',
                trailing: MapToggle(
                  value: s.providerDnsEnabled,
                  onChanged: (v) async {
                    s.providerDnsEnabled = v;
                    await _saveSection();
                  },
                ),
                divider: false,
              ),
            ],
          ),
          const SizedBox(height: 14),
          // Build 2107: the DPI Strategy Lab, behind its own
          // default-OFF switch (the standing rule). Off, no
          // connect path consults the Lab's per-network memory
          // and no failed connect offers it.
          MapSettingsPanel(
            title: 'DPI Strategy Lab',
            children: [
              MapSettingRow(
                label: 'DPI Strategy Lab',
                subtitle:
                    'Test which evasion strategy carries '
                    'traffic on this network, remember the '
                    'winner per network, and dial it first '
                    'there',
                trailing: MapToggle(
                  value: s.dpiLabEnabled,
                  onChanged: (v) async {
                    s.dpiLabEnabled = v;
                    await _saveSection();
                  },
                ),
                divider: s.dpiLabEnabled,
              ),
              if (s.dpiLabEnabled)
                MapSettingRow(
                  label: 'Open the Strategy Lab',
                  subtitle: 'Run discovery, see remembered networks',
                  trailing: _navChevron,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => DpiLabPage(xray: xray),
                    ),
                  ),
                  divider: true,
                ),
              // Build 2129 (Leg 3): the Senpai scanner,
              // inside the Lab section behind its own
              // default-OFF switch (on top of the Lab's).
              if (s.dpiLabEnabled)
                MapSettingRow(
                  label: 'Senpai scanner',
                  subtitle:
                      'Discover working endpoints with the '
                      'SenPaiScanner engine; import the top '
                      'results as profiles',
                  trailing: MapToggle(
                    value: s.senpaiEnabled,
                    onChanged: (v) async {
                      s.senpaiEnabled = v;
                      await _saveSection();
                    },
                  ),
                  divider: s.senpaiEnabled,
                ),
              if (s.dpiLabEnabled && s.senpaiEnabled)
                MapSettingRow(
                  label: 'Open the Senpai scanner',
                  subtitle: 'Scan, resume, import top results',
                  trailing: _navChevron,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => SenpaiPage(xray: xray),
                    ),
                  ),
                  divider: false,
                ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _showBackup(BuildContext context) async {
    final l = AppLocalizations.of(context);
    // Build 2092 (item 29): the dialog opens at once and
    // shows its progress — the export used to run invisibly
    // before anything appeared.
    // Build 2095 (V2Ray journey audit #15): the app
    // settings ride the backup (secrets stripped by the
    // controller) — a restore used to carry configs only.
    final future = xray.exportBackup(
      appSettingsJson: settings?.toJson(),
      // Build 2116 (AB-05): the other engines' sections
      // ride the settings-page backup too.
      engineSections: buildEngineSections(
        openvpn: openvpn,
        psiphon: psiphon,
        warp: warp,
        masque: masque,
      ),
    );
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        // Build 2074 (audit item 25): scrollable content — the
        // unbounded backup JSON pushed the actions off-screen
        // on short/landscape screens.
        scrollable: true,
        // Batch 5 (fidelity rollout): the dialog surface
        // takes the app's own panel colour instead of the
        // stock Material grey, so the surface reads as part
        // of the app (the pro7-backup composition sits on
        // the same near-black ground).
        backgroundColor: MapUi.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: Text(l.backupData, style: Ember.heading),
        content: SizedBox(
          width: double.maxFinite,
          child: FutureBuilder<String?>(
            future: future,
            builder: (context, snap) {
              // Build 2098 (post-2097 audit M11): the export
              // refuses (completes with null) while the store
              // is protected — say so instead of spinning
              // forever on the progress indicator.
              if (snap.connectionState == ConnectionState.done &&
                  !snap.hasData) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Text(
                    xray.storeError ?? 'The backup could not be created.',
                    style: const TextStyle(color: Ember.dim, fontSize: Ember.fontBody),
                  ),
                );
              }
              if (!snap.hasData) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Center(
                    child: CircularProgressIndicator(color: Ember.orange),
                  ),
                );
              }
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Batch 5 (fidelity rollout, pro7-backup
                  // sample): the dialog opens in the sample's
                  // composition — the file as a monospace line
                  // (its real generated size), the contents as
                  // hairline count rows from the live store,
                  // then the export as the slim hairline pill.
                  // GAPs recorded, not filled: the app keeps
                  // no last-local-backup stamp (the sample's
                  // LAST BACKUP hero date) and the local
                  // backup has no encrypt option (encryption
                  // is the GitHub sync seal's, with its
                  // password) — neither is invented here.
                  Text(
                    'ember-backup.json · '
                    '${latDigits('${(utf8.encode(snap.data!).length / 1024).round()}')} KB',
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: Ember.fontSmall,
                      color: MapUi.dim,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Profiles inside',
                          style: TextStyle(
                            fontSize: Ember.fontBody,
                            color: MapUi.text,
                          ),
                        ),
                      ),
                      Text(
                        latDigits('${xray.profiles.length}'),
                        style: const TextStyle(
                          fontSize: Ember.fontBody,
                          fontWeight: FontWeight.w600,
                          color: MapUi.text,
                        ),
                      ),
                    ],
                  ),
                  const Divider(color: MapUi.line, height: 18, thickness: 1),
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Subscriptions inside',
                          style: TextStyle(
                            fontSize: Ember.fontBody,
                            color: MapUi.text,
                          ),
                        ),
                      ),
                      Text(
                        latDigits('${xray.subscriptions.length}'),
                        style: const TextStyle(
                          fontSize: Ember.fontBody,
                          fontWeight: FontWeight.w600,
                          color: MapUi.text,
                        ),
                      ),
                    ],
                  ),
                  const Divider(color: MapUi.line, height: 18, thickness: 1),
                  const SizedBox(height: 4),
                  // The export itself (build 2095, journey
                  // audit #19/#20: the backup leaves as a FILE
                  // or through the share sheet) — as the
                  // sample's slim pill; the handler is the
                  // retired action's own, unchanged.
                  Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: () async {
                        final saved = await XrayPlatform.saveTextFile(
                          'ember-backup.json',
                          snap.data!,
                        );
                        // Build 2098 (verification V-5): null
                        // means another save dialog is already
                        // open — it will report for itself, so
                        // this tap closes nothing and says
                        // nothing.
                        if (saved == null) return;
                        if (dialogContext.mounted) {
                          Navigator.of(dialogContext).pop();
                        }
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                saved
                                    ? 'Backup saved to a file'
                                    : 'Save cancelled',
                              ),
                            ),
                          );
                        }
                      },
                      borderRadius: BorderRadius.circular(999),
                      child: Container(
                        height: 46,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: MapUi.card,
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(color: MapUi.lineStrong),
                        ),
                        child: const Text(
                          'Save to file',
                          style: TextStyle(
                            fontSize: Ember.fontBody,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1.6,
                            color: MapUi.text,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  SelectableText(
                    snap.data!,
                    textDirection: TextDirection.ltr,
                    // Build 2092 (item 38): the data text meets
                    // the 11 sp floor (was 10.5).
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: Ember.fontSmall,
                      color: Ember.dim,
                    ),
                  ),
                  const SizedBox(height: 12),
                  // Build 2119 (audit F-12): the Sync page's
                  // honest never-travels note rides the
                  // backup dialog too — up to 2118 this
                  // surface showed the data with no word
                  // about what is NOT in it.
                  const Text(
                    'What never travels in this backup: OpenVPN '
                    'usernames and passwords (they stay in this '
                    'device\'s own vault), your Mozilla account, '
                    'pass and core settings, Aether identity and '
                    'scan results, the Lantern server list, '
                    'the selected '
                    'OpenVPN profile, traffic history, the '
                    'battery log and the GitHub token.',
                    style: TextStyle(color: Ember.dim, fontSize: Ember.fontSmall),
                  ),
                ],
              );
            },
          ),
        ),
        actions: [
          // Build 2095 (V2Ray journey audit #19/#20): the
          // backup leaves as a FILE or through the share
          // sheet, not only as clipboard text.
          // Batch 5: 'Save to file' moved into the content
          // as the slim export pill (same handler); the
          // actions keep Share / Copy / Transfer / Close.
          FutureBuilder<String?>(
            future: future,
            builder: (context, snap) => TextButton(
              onPressed: !snap.hasData
                  ? null
                  : () async {
                      await XrayPlatform.shareText(
                        snap.data!,
                        title: 'Ember backup',
                      );
                      if (dialogContext.mounted) {
                        Navigator.of(dialogContext).pop();
                      }
                    },
              child: const Text('Share'),
            ),
          ),
          FutureBuilder<String?>(
            future: future,
            // Batch 5: the copy action wears the dialog's
            // tracked text-action form, not the gradient
            // EmberButton; label and handler unchanged.
            builder: (context, snap) => TextButton(
              onPressed: !snap.hasData
                  ? null
                  : () async {
                      // Build 2095 (audit 5-4): a whole
                      // backup is a secret — self-clearing.
                      await copySensitive(snap.data!);
                      if (dialogContext.mounted) {
                        Navigator.of(dialogContext).pop();
                      }
                    },
              child: Text(
                l.copyLink,
                style: const TextStyle(
                  color: Ember.orange,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2,
                ),
              ),
            ),
          ),
          // Build 2095 (feature 15): device pairing —
          // the same backup, sealed into scannable codes.
          if (settings != null)
            TextButton(
              onPressed: () {
                Navigator.of(dialogContext).pop();
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => PairingExportPage(
                      xray: xray,
                      settings: settings!,
                      openvpn: openvpn,
                      psiphon: psiphon,
                      warp: warp,
                      masque: masque,
                    ),
                  ),
                );
              },
              child: const Text('Transfer to another device'),
            ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(
              l.closeAction,
              style: const TextStyle(color: Ember.dim),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showRestore(BuildContext context) async {
    final l = AppLocalizations.of(context);
    final controller = TextEditingController();
    // Build 2092 (items 29/61): the Restore action disables
    // while the import runs (a second tap used to start a
    // double import), and the field's controller is
    // disposed when the dialog closes.
    var busy = false;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          // Build 2074 (audit item 25): scrollable content.
          scrollable: true,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          title: Text(l.restoreData, style: Ember.heading),
          content: TextField(
            controller: controller,
            minLines: 5,
            maxLines: 9,
            textDirection: TextDirection.ltr,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: Ember.fontMicro,
              color: Ember.text,
            ),
            decoration: emberField(context, '{…}'),
          ),
          actions: [
            // Build 2095 (feature 15): receive a pairing
            // transfer by scanning its codes.
            if (settings != null)
              TextButton(
                onPressed: busy
                    ? null
                    : () {
                        Navigator.of(dialogContext).pop();
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => PairingImportPage(
                              xray: xray,
                              settings: settings!,
                              openvpn: openvpn,
                              psiphon: psiphon,
                              warp: warp,
                              masque: masque,
                            ),
                          ),
                        );
                      },
                child: const Text('Receive from another device'),
              ),
            TextButton(
              onPressed: busy ? null : () => Navigator.of(dialogContext).pop(),
              child: Text(
                l.closeAction,
                style: const TextStyle(color: Ember.dim),
              ),
            ),
            EmberButton(
              label: busy ? 'Restoring…' : l.restoreData,
              onTap: busy
                  ? null
                  : () async {
                      setDialogState(() => busy = true);
                      final result = await xray.importBackup(controller.text);
                      if (dialogContext.mounted) {
                        Navigator.of(dialogContext).pop();
                      }
                      // Build 2095 (audit #15): the backup's
                      // app settings land on the live object
                      // (the sync token and lock PIN never
                      // ride a backup, so both survive).
                      // Build 2098 (L11): the settings half
                      // can now refuse (unreadable store) —
                      // that is a failed restore, reported
                      // as one, not an uncaught error.
                      var settingsFailed = false;
                      if (result?.appSettingsJson != null &&
                          settings != null) {
                        try {
                          await settings!.applyRestoredSettings(
                            result!.appSettingsJson!,
                          );
                        } catch (_) {
                          settingsFailed = true;
                        }
                      }
                      // Build 2116 (AB-05): the backup's
                      // engine sections land on their
                      // controllers too. Build 2125
                      // (A25-07): sections that could not
                      // be applied are named in the result.
                      var engineFailures = const <String>[];
                      if (result?.engineSections != null) {
                        engineFailures = await applyEngineSections(
                          result!.engineSections!,
                          openvpn: openvpn,
                          psiphon: psiphon,
                          warp: warp,
                          masque: masque,
                        );
                      }
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            // Build 2095 (V2Ray journey audit
                            // #10): a restore that skipped
                            // damaged entries SAYS so — it used
                            // to report plain success while
                            // configs vanished.
                            content: Text(
                              result == null || settingsFailed
                                  ? l.restoreFailed
                                  : result.skipped > 0
                                  ? '${l.restoreOk} ${result.skipped} damaged '
                                        '${result.skipped == 1 ? 'entry was' : 'entries were'} '
                                        'skipped.'
                                        // Build 2095 (audit 4a-3):
                                        // transform notes ride along.
                                        '${result.notes.isEmpty ? '' : ' ${result.notes.join(' ')}'}'
                                        // Build 2125 (A25-07):
                                        // unapplied engine
                                        // sections are named.
                                        '${engineFailures.isEmpty ? '' : ' These sections could not be applied: ${engineFailures.join(', ')}.'}'
                                  : result.notes.isNotEmpty
                                  ? '${l.restoreOk} ${result.notes.join(' ')}'
                                        '${engineFailures.isEmpty ? '' : ' These sections could not be applied: ${engineFailures.join(', ')}.'}'
                                  : engineFailures.isNotEmpty
                                  ? '${l.restoreOk} These sections could not be applied: ${engineFailures.join(', ')}.'
                                  : l.restoreOk,
                            ),
                          ),
                        );
                      }
                    },
            ),
          ],
        ),
      ),
    );
    controller.dispose();
  }
}

/// LAN sharing addresses (build 2062, feature queue #2): the
/// SOCKS5 and HTTP proxy URLs other devices on the local
/// network use, from this device's LAN address. Long-press (or
/// the copy button) copies a URL; with no Wi-Fi address there
/// is nothing to share yet.
class _LanShareAddresses extends StatefulWidget {
  const _LanShareAddresses({required this.socksPort, required this.httpPort});

  final int socksPort;
  final int httpPort;

  @override
  State<_LanShareAddresses> createState() => _LanShareAddressesState();
}

class _LanShareAddressesState extends State<_LanShareAddresses> {
  String? _address;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    // Build 2092 (item 60): a throwing lookup used to leave
    // "Finding the local address…" up forever — the error
    // lands in the same done state as a null address.
    lanAddress()
        .then((a) {
          if (mounted) {
            setState(() {
              _address = a;
              _done = true;
            });
          }
        })
        .catchError((_) {
          if (mounted) setState(() => _done = true);
          return null;
        });
  }

  @override
  Widget build(BuildContext context) {
    if (!_done) {
      return Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Text('Finding the local address…', style: Ember.caption),
      );
    }
    final address = _address;
    if (address == null) {
      return Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Text(
          'Connect to Wi-Fi to see the address.',
          style: Ember.caption,
        ),
      );
    }
    return Column(
      children: [
        _LanAddressRow(
          label: 'SOCKS5',
          url: 'socks5://$address:${latDigits(widget.socksPort)}',
        ),
        _LanAddressRow(
          label: 'HTTP',
          url: 'http://$address:${latDigits(widget.httpPort)}',
        ),
      ],
    );
  }
}

class _LanAddressRow extends StatelessWidget {
  const _LanAddressRow({required this.label, required this.url});

  final String label;
  final String url;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 7),
    child: Row(
      children: [
        SizedBox(width: 64, child: Text(label, style: Ember.body)),
        Expanded(child: SelectableText(url, style: Ember.body)),
        IconButton(
          icon: const Icon(Icons.copy_rounded, color: MapUi.faint, size: 18),
          tooltip: 'Copy',
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: url));
            if (context.mounted) {
              ScaffoldMessenger.of(context)
                  .showSnackBar(const SnackBar(content: Text('Copied.')));
            }
          },
        ),
      ],
    ),
  );
}

/// One editable text value row (label + current value, tap to edit).
/// Batch 5 (fidelity rollout, pro7-dns sample): one DNS
/// provider row — the preset's name, its URL verbatim as a
/// monospace caption, and the flat SELECTED pill when the
/// remote-DNS field currently holds this URL. A hairline
/// under every row; the whole row is the tap target (the
/// retired preset chip's own callback).
class _DnsProviderRow extends StatelessWidget {
  const _DnsProviderRow({
    required this.label,
    required this.url,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String url;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              label,
                              style: const TextStyle(
                                fontSize: Ember.fontTitle,
                                fontWeight: FontWeight.w500,
                                color: MapUi.text,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (selected) ...[
                            const SizedBox(width: 9),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: Ember.orange,
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: const Text(
                                'SELECTED',
                                style: TextStyle(
                                  fontSize: Ember.fontMicro,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 0.8,
                                  color: Color(0xFF1A1206),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        url,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: Ember.fontSmall,
                          color: MapUi.dim,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const Divider(color: MapUi.line, height: 1, thickness: 1),
      ],
    );
  }
}

class _TextRow extends StatelessWidget {
  const _TextRow({
    required this.label,
    required this.initial,
    required this.onSubmit,
    this.numeric = false,
    // Build 2062 (LAN sharing): the password row hides its
    // value — obscured in the dialog AND masked in the row
    // chip, so the password is never on screen in plain text.
    this.obscure = false,
  });
  final String label;
  final String initial;
  final Future<void> Function(String) onSubmit;
  final bool numeric;
  final bool obscure;

  @override
  Widget build(BuildContext context) => InkWell(
    borderRadius: BorderRadius.circular(14),
    onTap: () async {
      final l = AppLocalizations.of(context);
      final controller = TextEditingController(text: initial);
      final value = await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          // Build 2074 (audit item 25): scrollable content.
          scrollable: true,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          title: Text(label, style: Ember.heading),
          content: TextField(
            controller: controller,
            autofocus: true,
            obscureText: obscure,
            textDirection: TextDirection.ltr,
            keyboardType: numeric ? TextInputType.number : TextInputType.url,
            style: Ember.body,
            decoration: emberField(context, initial),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(
                l.closeAction,
                style: const TextStyle(color: Ember.dim),
              ),
            ),
            EmberButton(
              label: l.saveAction,
              onTap: () =>
                  Navigator.of(dialogContext).pop(controller.text.trim()),
            ),
          ],
        ),
      );
      // Build 2092 (item 61): the dialog's controller is
      // disposed once the dialog has closed.
      controller.dispose();
      if (value != null) await onSubmit(value);
    },
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 13),
      child: Row(
        children: [
          Expanded(child: Text(label, style: Ember.body)),
          Flexible(
            child: MapValueChip(
              // Build 2074 (audit item 26): a fixed-length mask
              // — '•' * length disclosed the exact password
              // length on the settings screen.
              text: obscure
                  ? (initial.isEmpty ? '' : '••••••••')
                  : initial.length > 40
                  ? '${initial.substring(0, 40)}…'
                  : initial,
            ),
          ),
          const SizedBox(width: 6),
          const Icon(Icons.chevron_right_rounded, color: MapUi.faint, size: 18),
        ],
      ),
    ),
  );
}

/// One editable list row (comma/newline-separated values).
class _ListRow extends StatelessWidget {
  const _ListRow({
    required this.label,
    required this.values,
    required this.onChanged,
  });
  final String label;
  final List<String> values;
  final Future<void> Function(List<String>) onChanged;

  @override
  Widget build(BuildContext context) => InkWell(
    borderRadius: BorderRadius.circular(14),
    onTap: () async {
      final l = AppLocalizations.of(context);
      final controller = TextEditingController(text: values.join('\n'));
      final text = await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          // Build 2074 (audit item 25): scrollable content.
          scrollable: true,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          title: Text(label, style: Ember.heading),
          content: TextField(
            controller: controller,
            autofocus: true,
            minLines: 4,
            maxLines: 8,
            textDirection: TextDirection.ltr,
            style: Ember.body,
            decoration: emberField(context, 'example.com'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(
                l.closeAction,
                style: const TextStyle(color: Ember.dim),
              ),
            ),
            EmberButton(
              label: l.saveAction,
              onTap: () => Navigator.of(dialogContext).pop(controller.text),
            ),
          ],
        ),
      );
      // Build 2092 (item 61): dispose the dialog's
      // controller once the dialog has closed.
      controller.dispose();
      if (text != null) {
        await onChanged(
          text
              .split(RegExp(r'[\n,]'))
              .map((e) => e.trim())
              .where((e) => e.isNotEmpty)
              .toList(),
        );
      }
    },
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 13),
      child: Row(
        children: [
          Expanded(child: Text(label, style: Ember.body)),
          MapValueChip(text: latDigits(values.length)),
        ],
      ),
    ),
  );
}

/// Custom DNS hosts (build 2041): the user's own name → IP map.
/// Same row-and-dialog language as [_ListRow] — a count chip on
/// the row, an Ember-surface dialog with one `name = IP` per
/// line. A line that fails validation is never saved silently:
/// the dialog stays open and names the offending lines, so a
/// typo cannot vanish into a half-written map.
class _HostsRow extends StatelessWidget {
  const _HostsRow({required this.hosts, required this.onChanged});
  final Map<String, String> hosts;
  final Future<void> Function(Map<String, String>) onChanged;

  @override
  Widget build(BuildContext context) => InkWell(
    borderRadius: BorderRadius.circular(14),
    onTap: () async {
      final l = AppLocalizations.of(context);
      final controller = TextEditingController(text: dnsHostsText(hosts));
      final saved = await showDialog<Map<String, String>>(
        context: context,
        builder: (dialogContext) {
          // Lives outside the StatefulBuilder's builder so a
          // rebuild after setDialogState keeps the error text.
          String? error;
          return StatefulBuilder(
            builder: (dialogContext, setDialogState) => AlertDialog(
              // Build 2074 (audit item 25): scrollable content.
              scrollable: true,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
              title: Text('Custom DNS hosts', style: Ember.heading),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'One per line: name = IP. Answered by the tunnel’s '
                    'DNS before any resolver is asked.',
                    style: Ember.caption,
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: controller,
                    autofocus: true,
                    minLines: 4,
                    maxLines: 8,
                    textDirection: TextDirection.ltr,
                    style: Ember.body,
                    decoration: emberField(context, 'example.com = 1.2.3.4'),
                  ),
                  if (error != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      error!,
                      style: Ember.caption.copyWith(color: Ember.red),
                    ),
                  ],
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: Text(
                    l.closeAction,
                    style: const TextStyle(color: Ember.dim),
                  ),
                ),
                EmberButton(
                  label: l.saveAction,
                  onTap: () {
                    final parsed = parseDnsHostsText(controller.text);
                    if (parsed.invalidLines.isNotEmpty) {
                      setDialogState(() {
                        error =
                            'Check these lines: ${parsed.invalidLines.take(3).join(', ')}';
                      });
                      return;
                    }
                    Navigator.of(dialogContext).pop(parsed.entries);
                  },
                ),
              ],
            ),
          );
        },
      );
      // Build 2092 (item 61): dispose the dialog's
      // controller once the dialog has closed.
      controller.dispose();
      if (saved != null) await onChanged(saved);
    },
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 13),
      child: Row(
        children: [
          Expanded(child: Text('Custom DNS hosts', style: Ember.body)),
          MapValueChip(text: latDigits(hosts.length)),
        ],
      ),
    ),
  );
}

/// Config mixins (build 2043): the user's own JSON object, merged
/// into the tunnel config at the end of every build. Same
/// row-and-dialog language as [_HostsRow] — a chip on the row, an
/// Ember-surface dialog with a multiline JSON field. Text that is
/// not a JSON object is never saved silently: the dialog stays
/// open and names the error, so a typo cannot vanish into a
/// half-written config. Clearing the field removes the mixins
/// entirely (the old config, byte for byte).
class _MixinsRow extends StatelessWidget {
  const _MixinsRow({required this.mixinsText, required this.onChanged});
  final String mixinsText;
  final Future<void> Function(String) onChanged;

  @override
  Widget build(BuildContext context) {
    final keyCount = parseConfigMixins(mixinsText).mixins?.length ?? 0;
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () async {
        final l = AppLocalizations.of(context);
        final controller = TextEditingController(text: mixinsText);
        final saved = await showDialog<String>(
          context: context,
          builder: (dialogContext) {
            // Lives outside the StatefulBuilder's builder so a
            // rebuild after setDialogState keeps the error text.
            String? error;
            return StatefulBuilder(
              builder: (dialogContext, setDialogState) => AlertDialog(
                // Build 2074 (audit item 25): scrollable content.
                scrollable: true,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24),
                ),
                title: Text('Config mixins', style: Ember.heading),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Your own JSON, merged into the tunnel config '
                      'last. Maps merge, lists are added, other '
                      'values replace. Applies at next connect.',
                      style: Ember.caption,
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: controller,
                      autofocus: true,
                      minLines: 6,
                      maxLines: 10,
                      textDirection: TextDirection.ltr,
                      style: Ember.body,
                      decoration: emberField(
                        context,
                        '{"log": {"loglevel": "info"}}',
                      ),
                    ),
                    if (error != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        error!,
                        style: Ember.caption.copyWith(color: Ember.red),
                      ),
                    ],
                  ],
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(dialogContext).pop(),
                    child: Text(
                      l.closeAction,
                      style: const TextStyle(color: Ember.dim),
                    ),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(dialogContext).pop(''),
                    child: const Text(
                      'Clear',
                      style: TextStyle(color: Ember.dim),
                    ),
                  ),
                  EmberButton(
                    label: l.saveAction,
                    onTap: () {
                      final parsed = parseConfigMixins(controller.text);
                      if (parsed.error != null) {
                        setDialogState(() {
                          error = parsed.error;
                        });
                        return;
                      }
                      Navigator.of(dialogContext).pop(controller.text);
                    },
                  ),
                ],
              ),
            );
          },
        );
        // Build 2092 (item 61): dispose the dialog's
        // controller once the dialog has closed.
        controller.dispose();
        if (saved != null) await onChanged(saved);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 13),
        child: Row(
          children: [
            Expanded(child: Text('Config mixins', style: Ember.body)),
            MapValueChip(
              text: keyCount == 0 ? 'Off' : '${latDigits(keyCount)} keys',
            ),
          ],
        ),
      ),
    );
  }
}

/// Build 2095 (whole-app journey audit #61): choose which
/// connections-view columns show. Writes the same
/// AppSettings.hiddenConnectionColumns the connections view
/// itself edits.
Future<void> _pickConnectionColumns(
  BuildContext context,
  AppSettings settings,
) async {
  const columns = [
    ('time', 'Time'),
    ('destination', 'Destination'),
    ('route', 'Route'),
    ('inbound', 'Inbound'),
    ('protocol', 'Protocol'),
    ('traffic', 'Traffic'),
    ('duration', 'Duration'),
  ];
  final hidden = {...settings.hiddenConnectionColumns};
  final saved = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      title: Text('Connection columns', style: Ember.heading),
      content: StatefulBuilder(
        builder: (context, setLocal) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (key, label) in columns)
              CheckboxListTile(
                value: !hidden.contains(key),
                onChanged: (v) => setLocal(() {
                  if (v ?? true) {
                    hidden.remove(key);
                  } else {
                    hidden.add(key);
                  }
                }),
                title: Text(label, style: Ember.body),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
                dense: true,
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Cancel', style: TextStyle(color: Ember.dim)),
        ),
        EmberButton(
          label: 'Save',
          onTap: () => Navigator.of(dialogContext).pop(true),
        ),
      ],
    ),
  );
  if (saved ?? false) {
    settings.update(hiddenConnectionColumns: hidden);
  }
}

/// Build 2147: the Iran-features panel. Every toggle is a
/// DEFAULT-OFF gate on XraySettings; the panel is the one
/// place they are all reachable from. Saving goes through
/// the controller's public save + notify, like every other
/// section.
class IranFeatures2147Panel extends StatefulWidget {
  const IranFeatures2147Panel({required this.xray});
  final XrayController xray;
  @override
  State<IranFeatures2147Panel> createState() =>
      IranFeatures2147PanelState();
}

class IranFeatures2147PanelState
    extends State<IranFeatures2147Panel> {
  bool _sweeping = false;
  String _sweepNote = '';

  XraySettings get s => widget.xray.settings;

  Future<void> _save() async {
    await widget.xray.save();
    widget.xray.notifySettingsChanged();
    if (mounted) setState(() {});
  }

  Future<void> _editInt(
    String title,
    int current,
    void Function(int) apply,
  ) async {
    final controller = TextEditingController(text: '$current');
    final value = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Number'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('CANCEL'),
          ),
          TextButton(
            onPressed: () => Navigator.of(
              context,
            ).pop(int.tryParse(controller.text.trim())),
            child: const Text('SAVE'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value != null) {
      apply(value);
      await _save();
    }
  }

  MapSettingRow _toggle(
    String label,
    String subtitle,
    bool value,
    void Function(bool) apply,
  ) {
    return MapSettingRow(
      label: label,
      subtitle: subtitle,
      trailing: MapToggle(
        value: value,
        onChanged: (v) async {
          apply(v);
          await _save();
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final xray = widget.xray;
    return MapSettingsPanel(
      title: 'Iran features (2147)',
      children: [
        _toggle(
          'Fetch via tunnel',
          'Subscription refreshes, the app update check and '
              'RegionHop panel calls ride the running tunnel '
              'instead of the open network',
          s.fetchViaTunnel,
          (v) => s.fetchViaTunnel = v,
        ),
        _toggle(
          'Auto MTU discovery',
          s.autoMtuFound > 0
              ? 'Probes the path before connecting and uses '
                    'the largest MTU that answers — last found '
                    '${s.autoMtuFound}'
              : 'Probes the path before connecting and uses '
                    'the largest MTU that answers',
          s.autoMtu,
          (v) => s.autoMtu = v,
        ),
        _toggle(
          'DPI Lab racing',
          'Probes Lab candidates four at a time instead of '
              'one by one — faster, and the cores contend',
          s.dpiLabRacing,
          (v) => s.dpiLabRacing = v,
        ),
        _toggle(
          'SSH engine',
          'Serves ssh:// configs through the sidecar (TCP '
              'only). Off: an SSH config refuses in plain words',
          s.sidecarSshEnabled,
          (v) => s.sidecarSshEnabled = v,
        ),
        _toggle(
          'Stall failover',
          'When the downlink stops moving, move the session '
              'to the next config in its group instead of only '
              'changing shape',
          s.stallFailover,
          (v) => s.stallFailover = v,
        ),
        MapSettingRow(
          label: 'Stall failover window',
          subtitle: '${s.stallFailoverSeconds} seconds without '
              'downlink before the move',
          trailing: _navChevron,
          onTap: () => _editInt(
            'Stall failover window (seconds)',
            s.stallFailoverSeconds,
            (v) => s.stallFailoverSeconds = v < 5 ? 5 : v,
          ),
        ),
        _toggle(
          'Exit monitor',
          'Re-checks the exit every minute while connected '
              'and journals a mid-session exit move',
          s.exitMonitorEnabled,
          (v) => s.exitMonitorEnabled = v,
        ),
        _toggle(
          'Scheduled tests',
          'Delay-tests the starred configs on an interval '
              'so dead favourites are visible before you need '
              'them',
          s.scheduledTests,
          (v) => s.scheduledTests = v,
        ),
        MapSettingRow(
          label: 'Scheduled test interval',
          subtitle: 'Every ${s.scheduledTestIntervalMin} minutes',
          trailing: _navChevron,
          onTap: () => _editInt(
            'Scheduled test interval (minutes)',
            s.scheduledTestIntervalMin,
            (v) => s.scheduledTestIntervalMin = v < 5 ? 5 : v,
          ),
        ),
        _toggle(
          'Import safety filter',
          'Names unsupported protocols at import and warns '
              'about local endpoints and tracker-shaped link '
              'payloads. Warns — never blocks',
          s.importSafetyFilter,
          (v) => s.importSafetyFilter = v,
        ),
        _toggle(
          'Quarantine',
          'A config that fails 3 times on this network is '
              'badged and skipped by automatic picks until '
              'restored',
          s.quarantineEnabled,
          (v) => s.quarantineEnabled = v,
        ),
        MapSettingRow(
          label: 'Quarantine list',
          subtitle: xray.quarantinedProfiles.isEmpty
              ? 'Nothing quarantined'
              : '${xray.quarantinedProfiles.length} config(s) cut — '
                    'restore them here',
          trailing: _navChevron,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => QuarantinePage2147(xray: xray),
            ),
          ),
        ),
        _toggle(
          'Ping sweep & auto-cut',
          'Sweeps a delay test over every config (hourly '
              'while on); configs that keep not answering are '
              'cut to the quarantine list — restorable, never '
              'deleted',
          s.pingSweepEnabled,
          (v) => s.pingSweepEnabled = v,
        ),
        MapSettingRow(
          label: 'Sweep cut threshold',
          subtitle: 'Cut after ${s.pingSweepFailStrikes} '
              'consecutive unanswered sweeps',
          trailing: _navChevron,
          onTap: () => _editInt(
            'Sweep cut threshold (sweeps)',
            s.pingSweepFailStrikes,
            (v) => s.pingSweepFailStrikes = v < 1 ? 1 : v,
          ),
        ),
        MapSettingRow(
          label: 'Run ping sweep now',
          subtitle: _sweeping
              ? 'Sweeping…'
              : _sweepNote.isEmpty
              ? 'Delay-tests every config once, right now'
              : _sweepNote,
          trailing: _navChevron,
          onTap: _sweeping
              ? null
              : () async {
                  setState(() => _sweeping = true);
                  final r = await xray.runPingSweep();
                  if (mounted) {
                    setState(() {
                      _sweeping = false;
                      _sweepNote =
                          '${r.tested} tested · ${r.answered} '
                          'answered · ${r.cut} cut';
                    });
                  }
                },
        ),
        _toggle(
          'Whitelist SNI scan',
          'Enables the scan page: real TLS handshakes to '
              'candidate fronts, ranked by answer time',
          s.sniScanEnabled,
          (v) => s.sniScanEnabled = v,
        ),
        if (s.sniScanEnabled)
          MapSettingRow(
            label: 'Run SNI scan',
            subtitle: 'Finds which fronts this network lets '
                'through',
            trailing: _navChevron,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const SniScanPage2147(),
              ),
            ),
          ),
        MapSettingRow(
          label: 'Guided diagnosis',
          subtitle: 'DNS → TCP → TLS → first request, with '
              'the remedy for the first failed rung',
          divider: false,
          trailing: _navChevron,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => DiagnosisPage2147(xray: xray),
            ),
          ),
        ),
      ],
    );
  }
}
