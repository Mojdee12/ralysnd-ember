/// The automation pages (build 2065): the cross-engine fallback
/// chain editor (item 5), the auto-connect triggers page
/// (item 14) and the filtering probe panel (item 6) — all in the
/// Map Control language, all wired to the persisted settings.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../app_settings.dart';
import '../../net/filtering_probe.dart';
import 'ember_format.dart';
import 'ember_theme.dart';
import 'map_widgets.dart';

/// The engine names the chain editor shows, by mode number.
String emberEngineLabel(int m) => switch (m) {
  0 => 'Mozilla',
  1 => 'V2Ray',
  2 => 'Psiphon',
  3 => 'Lantern',
  4 => 'OpenVPN',
  5 => 'WireGuard',
  6 => 'WARP',
  7 => 'MASQUE',
  _ => 'Engine $m',
};

Widget _pageShell(String title, Widget child) => Scaffold(
  backgroundColor: Ember.bg,
  appBar: AppBar(
    backgroundColor: Colors.transparent,
    elevation: 0,
    foregroundColor: Ember.text,
    title: Text(title, style: Ember.heading),
  ),
  body: EmberBackground(child: child),
);

// ------------------------------------------------------------ chain

/// The fallback chain editor (item 5): the master switch, the
/// ordered engine list with up/down controls, and membership
/// chips for every engine.
class FallbackChainPage extends StatefulWidget {
  const FallbackChainPage({super.key, required this.settings});
  final AppSettings settings;

  @override
  State<FallbackChainPage> createState() => _FallbackChainPageState();
}

class _FallbackChainPageState extends State<FallbackChainPage> {
  AppSettings get s => widget.settings;

  void _move(int index, int delta) {
    final chain = [...s.fallbackChain];
    final target = index + delta;
    if (target < 0 || target >= chain.length) return;
    final m = chain.removeAt(index);
    chain.insert(target, m);
    s.update(fallbackChain: chain);
    setState(() {});
  }

  void _toggleMember(int m) {
    final chain = [...s.fallbackChain];
    if (chain.contains(m)) {
      // Build 2074 (audit item 7): never an empty chain — and
      // say so, instead of the tap silently doing nothing.
      if (chain.length <= 1) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('At least one engine must stay in the chain.'),
          ),
        );
        return;
      }
      chain.remove(m);
    } else {
      chain.add(m);
    }
    s.update(fallbackChain: chain);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return _pageShell(
      'Fallback chain',
      ListView(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 24),
        children: [
          MapSettingsPanel(
            title: 'Cross-engine fallback',
            children: [
              MapSettingRow(
                label: 'Fallback chain',
                subtitle: 'When the selected engine cannot connect, try the next engine in this order automatically',
                divider: false,
                trailing: MapToggle(
                  value: s.fallbackChainEnabled,
                  onChanged: (v) {
                    s.update(fallbackChainEnabled: v);
                    setState(() {});
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              'The chain only advances when a connect FAILS. A '
              'tunnel that connects and later drops is handled by '
              'auto-reconnect and the kill switch, not by the '
              'chain. Each engine gets its own bounded try; the '
              'run stops at the first engine that connects.',
              style: Ember.caption,
            ),
          ),
          const SizedBox(height: 14),
          MapSettingsPanel(
            title: 'Order',
            children: [
              for (var i = 0; i < s.fallbackChain.length; i++)
                MapSettingRow(
                  label:
                      '${latDigits(i + 1)}. ${emberEngineLabel(s.fallbackChain[i])}',
                  divider: i < s.fallbackChain.length - 1,
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.arrow_upward, size: 18),
                        color: MapUi.faint,
                        onPressed: i == 0 ? null : () => _move(i, -1),
                      ),
                      IconButton(
                        icon: const Icon(Icons.arrow_downward, size: 18),
                        color: MapUi.faint,
                        onPressed: i == s.fallbackChain.length - 1
                            ? null
                            : () => _move(i, 1),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 14),
          MapSettingsPanel(
            title: 'Engines in the chain',
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Wrap(
                  spacing: 7,
                  runSpacing: 7,
                  children: [
                    for (var m = 0; m <= 7; m++)
                      EmberChip(
                        label: emberEngineLabel(m),
                        selected: s.fallbackChain.contains(m),
                        onTap: () => _toggleMember(m),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------- auto-connect

/// The auto-connect triggers page (item 14): one master switch
/// (default off), the three triggers, and the trusted Wi-Fi
/// exclusion list. Android cannot start a VPN service from the
/// background at boot, so the boot trigger honestly means: the
/// app connects the next time it runs after a boot, when a boot
/// is still pending.
class AutoConnectPage extends StatefulWidget {
  const AutoConnectPage({super.key, required this.settings});
  final AppSettings settings;

  @override
  State<AutoConnectPage> createState() => _AutoConnectPageState();
}

class _AutoConnectPageState extends State<AutoConnectPage> {
  AppSettings get s => widget.settings;
  final _ssid = TextEditingController();

  @override
  void dispose() {
    _ssid.dispose();
    super.dispose();
  }

  void _addTrusted() {
    final v = _ssid.text.trim();
    if (v.isEmpty || s.trustedSsids.contains(v)) return;
    s.update(trustedSsids: [...s.trustedSsids, v]);
    _ssid.clear();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return _pageShell(
      'Auto-connect',
      ListView(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 24),
        children: [
          // Build 2074 (audit items 7 + 26): the panel is
          // retitled "Triggers" — its first row already reads
          // "Auto-connect" (the master switch), and the page
          // itself is titled "Auto-connect". While the master
          // is off the three trigger rows are greyed and their
          // toggles disabled: they cannot fire, so they must
          // not look live — their stored values still show.
          MapSettingsPanel(
            title: 'Triggers',
            children: [
              MapSettingRow(
                label: 'Auto-connect',
                subtitle: 'Connect by itself when a trigger fires below',
                trailing: MapToggle(
                  value: s.emberAutoConnect,
                  onChanged: (v) {
                    s.update(emberAutoConnect: v);
                    setState(() {});
                  },
                ),
              ),
              Opacity(
                opacity: s.emberAutoConnect ? 1 : 0.45,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    MapSettingRow(
                      label: 'After a reboot',
                      subtitle: 'Connects when the app next runs after the phone restarts (Android cannot start a VPN before that)',
                      trailing: MapToggle(
                        value: s.autoConnectOnBoot,
                        onChanged: s.emberAutoConnect
                            ? (v) {
                                s.update(autoConnectOnBoot: v);
                                setState(() {});
                              }
                            : null,
                      ),
                    ),
                    MapSettingRow(
                      label: 'On untrusted Wi-Fi',
                      subtitle: 'A Wi-Fi network not in the trusted list below counts as untrusted; a network whose name Android does not expose counts as untrusted too',
                      trailing: MapToggle(
                        value: s.autoConnectOnUntrustedWifi,
                        onChanged: s.emberAutoConnect
                            ? (v) {
                                s.update(autoConnectOnUntrustedWifi: v);
                                setState(() {});
                              }
                            : null,
                      ),
                    ),
                    MapSettingRow(
                      label: 'On network change',
                      subtitle: 'When the phone moves to a different network and nothing is connected',
                      divider: false,
                      trailing: MapToggle(
                        value: s.autoConnectOnNetworkChange,
                        onChanged: s.emberAutoConnect
                            ? (v) {
                                s.update(autoConnectOnNetworkChange: v);
                                setState(() {});
                              }
                            : null,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          MapSettingsPanel(
            title: 'Trusted Wi-Fi networks',
            children: [
              for (var i = 0; i < s.trustedSsids.length; i++)
                MapSettingRow(
                  label: s.trustedSsids[i],
                  trailing: IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    color: MapUi.faint,
                    onPressed: () {
                      final next = [...s.trustedSsids]..removeAt(i);
                      s.update(trustedSsids: next);
                      setState(() {});
                    },
                  ),
                ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _ssid,
                        style: Ember.body,
                        decoration: emberField(context, 'Wi-Fi name (SSID)'),
                        onSubmitted: (_) => _addTrusted(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    EmberButton(label: 'Add', onTap: _addTrusted),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------- probe

/// The filtering probe panel (item 6): runs the read-only checks
/// and lists plain verdicts.
class FilteringProbePage extends StatefulWidget {
  const FilteringProbePage({super.key});

  @override
  State<FilteringProbePage> createState() => _FilteringProbePageState();
}

class _FilteringProbePageState extends State<FilteringProbePage> {
  bool _running = false;
  List<ProbeCheck> _checks = const [];

  Future<void> _run() async {
    setState(() {
      _running = true;
      _checks = const [];
    });
    // Build 2074 (audit item 9): try/finally — a throwing
    // probe used to wedge the button on "Running…" forever.
    try {
      final checks = await runFilteringProbe();
      if (mounted) {
        setState(() => _checks = checks);
      }
    } finally {
      if (mounted) {
        setState(() => _running = false);
      }
    }
  }

  Color _verdictColor(String v) => switch (v) {
    // Build 2074 (audit item 15): the palette green, not the
    // one-off 0xFF7BD88F.
    'OK' || 'Present' => Ember.green,
    'Blocked' || 'Different' => Ember.orange,
    _ => MapUi.faint,
  };

  @override
  Widget build(BuildContext context) {
    return _pageShell(
      'Filtering probe',
      ListView(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 24),
        children: [
          MapGlass(
            luminous: true,
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Measures how this network treats traffic: UDP, '
                  'DNS answers, TLS names (SNI) and IPv6. Read-only '
                  '— nothing is changed.',
                  style: Ember.caption,
                ),
                const SizedBox(height: 12),
                EmberButton(
                  label: _running ? 'Running…' : 'Run checks',
                  onTap: _running ? null : _run,
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          if (_checks.isNotEmpty)
            MapSettingsPanel(
              title: 'Results',
              children: [
                for (var i = 0; i < _checks.length; i++)
                  MapSettingRow(
                    label: _checks[i].name,
                    subtitle: _checks[i].detail,
                    divider: i < _checks.length - 1,
                    trailing: Text(
                      _checks[i].verdict,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: _verdictColor(_checks[i].verdict),
                      ),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}
