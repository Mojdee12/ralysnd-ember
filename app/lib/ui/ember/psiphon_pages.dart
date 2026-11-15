/// The Psiphon engine's pages: the exit-region list (also the
/// Servers tab's content in this mode), the settings page (mode,
/// region, upstream proxy, transports, logs), and the no-account
/// page shown on the Accounts tab — Psiphon needs no account.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../../psiphon/psiphon_controller.dart';
import '../../psiphon/psiphon_platform.dart';
import '../../psiphon/psiphon_strategy.dart';
import '../../xray/exit_info.dart';
import 'ember_format.dart';
import 'ember_theme.dart';
import 'map_widgets.dart';

String regionName(String code) => englishCountryNames[code] ?? code;

/// The Psiphon exit-region panel, Map Control edition: one
/// glass panel with the caps header and the two-column region
/// pill grid (sample 3) — radius-10 pills, centred text only,
/// the selected one in an orange gradient tint with a check.
/// Used inline on the home page (there [compact]: ~68% wide,
/// at most four pill rows tall with an internal scroll, so the
/// map actors keep the upper canvas) and as the Servers-tab
/// view; picking a region while the tunnel is up takes effect
/// on the next connect, exactly as before.
class PsiphonRegionsPanel extends StatelessWidget {
  const PsiphonRegionsPanel({
    super.key,
    required this.psiphon,
    this.onClose,
    this.compact = false,
  });

  final PsiphonController psiphon;
  final VoidCallback? onClose;
  final bool compact;

  void _pick(String code) {
    // setRegion restarts a running tunnel on the new exit
    // country (build 2033) — the pick is never a dead tap.
    unawaited(psiphon.setRegion(code));
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final selected = psiphon.settings.region;
    Widget pill(String code, String label) {
      final on = selected == code;
      return InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => _pick(code),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          decoration: BoxDecoration(
            gradient: on
                ? LinearGradient(
                    colors: [
                      Ember.orange.withValues(alpha: 0.24),
                      Ember.orange.withValues(alpha: 0.10),
                    ],
                  )
                : null,
            color: on ? null : Colors.white.withValues(alpha: 0.045),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: on
                  // Build 2074 (audit item 5): the selected pill
                  // wears the one Ember.orange, not an off-palette
                  // hardcode.
                  ? Ember.orange
                  // 2023 polish (Gemini round-3 audit): the
                  // frosted slate the samples give unselected
                  // pills, not the old faint white.
                  : const Color(0x665E82A8),
              width: on ? 1.4 : 1,
            ),
            boxShadow: on
                ? [
                    BoxShadow(
                      color: Ember.orange.withValues(alpha: 0.22),
                      blurRadius: 10,
                      spreadRadius: -1,
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (on) ...[
                const Icon(Icons.check_rounded, size: 14, color: Ember.orange),
                const SizedBox(width: 4),
              ],
              Flexible(
                child: Text(
                  label,
                  style: TextStyle(
                    color: on ? Ember.orange : MapUi.body,
                    // 2025 (Gemini audit v5, item 4): 13 -> 11.5 so
                    // the long region names ("Automatic", "United
                    // Kingdom") stop truncating in the pill.
                    fontSize: 11.5,
                    fontWeight: on ? FontWeight.w700 : FontWeight.w500,
                  ),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ),
            ],
          ),
        ),
      );
    }

    final cells = <Widget>[
      pill('', l.psiphonRegionAuto),
      for (final code in psiphon.regionChoices) pill(code, regionName(code)),
    ];
    final grid = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < cells.length; i += 2)
          Padding(
            padding: EdgeInsets.only(top: i == 0 ? 0 : 8),
            child: Row(
              children: [
                Expanded(child: cells[i]),
                const SizedBox(width: 8),
                Expanded(
                  child: i + 1 < cells.length
                      ? cells[i + 1]
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          ),
      ],
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MapGlass(
          luminous: true,
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              MapPanelHeader(title: 'Exit Region', onClose: onClose),
              const SizedBox(height: 12),
              // Build 2074 (audit item 26): no nested scroll —
              // the compact panel used to cap itself at 180dp
              // with its own SingleChildScrollView inside the
              // page ListView, and the two drags fought. The
              // grid now lays out in full and the page scrolls
              // it; the old "more regions below" cue (build
              // 2056) went with the cap it described.
              grid,
            ],
          ),
        ),
        // 2024 (Gemini audit v4, item 6): the static next-connect
        // helper line that used to sit under this card is gone —
        // it floated over the map dots and Sample 3 has no such
        // line. The takes-effect-on-next-connect behavior itself
        // is unchanged.
      ],
    );
  }
}

/// The exit-region view (the Servers tab's content in Psiphon
/// mode, and pushed from the settings page).
class PsiphonRegionsView extends StatelessWidget {
  const PsiphonRegionsView({super.key, required this.psiphon, this.onClose});

  final PsiphonController psiphon;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: psiphon,
      builder: (context, _) {
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          children: [PsiphonRegionsPanel(psiphon: psiphon, onClose: onClose)],
        );
      },
    );
  }
}

/// The Accounts tab in Psiphon mode: there is no account — a status
/// card and the session's numbers instead.
class PsiphonAboutView extends StatelessWidget {
  const PsiphonAboutView({super.key, required this.psiphon});

  final PsiphonController psiphon;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: psiphon,
      builder: (context, _) {
        final state = psiphon.state;
        final exit = psiphon.exitInfo;
        return ListView(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
          children: [
            Center(child: Text(l.navAccounts, style: Ember.title)),
            Center(child: Text('Psiphon', style: Ember.caption)),
            const SizedBox(height: 16),
            // Build 2074 (audit item 5): MapGlass directly, not
            // the legacy GlassCard — the padding is the old
            // GlassCard default, spelled out.
            MapGlass(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  const Icon(Icons.person_off_rounded, color: Ember.dim),
                  const SizedBox(width: 10),
                  Expanded(child: Text(l.psiphonNoAccount, style: Ember.body)),
                ],
              ),
            ),
            const SizedBox(height: 12),
            MapGlass(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 9,
                        height: 9,
                        decoration: BoxDecoration(
                          color: state.connected
                              ? Ember.green
                              : state.running
                              ? Ember.amber
                              : Ember.faint,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        state.connected
                            ? l.statusConnected
                            : state.running
                            ? l.stateConnecting
                            : l.statusDisconnected,
                        style: Ember.heading,
                      ),
                    ],
                  ),
                  if (state.region.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      '${l.psiphonExitRegion}: ${regionName(state.region)}',
                      style: Ember.body,
                    ),
                  ],
                  if (exit != null) ...[
                    const SizedBox(height: 6),
                    Text(exit.line, style: Ember.body),
                  ],
                  if (state.upBytes > 0 || state.downBytes > 0) ...[
                    const SizedBox(height: 6),
                    Directionality(
                      textDirection: TextDirection.ltr,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.arrow_downward_rounded,
                            size: 14,
                            color: Ember.dim,
                          ),
                          const SizedBox(width: 3),
                          Text(fmtBytes(state.downBytes), style: Ember.body),
                          const SizedBox(width: 10),
                          const Icon(
                            Icons.arrow_upward_rounded,
                            size: 14,
                            color: Ember.dim,
                          ),
                          const SizedBox(width: 3),
                          Text(fmtBytes(state.upBytes), style: Ember.body),
                        ],
                      ),
                    ),
                  ],
                  if (!state.vpnMode && state.running) ...[
                    const SizedBox(height: 8),
                    Text(
                      'SOCKS 127.0.0.1:${PsiphonPlatform.socksPort} · '
                      'HTTP 127.0.0.1:${PsiphonPlatform.httpPort}',
                      style: Ember.caption,
                    ),
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// All of the Psiphon engine's settings on one page.
class PsiphonSettingsPage extends StatefulWidget {
  const PsiphonSettingsPage({super.key, required this.psiphon});

  final PsiphonController psiphon;

  @override
  State<PsiphonSettingsPage> createState() => _PsiphonSettingsPageState();
}

class _PsiphonSettingsPageState extends State<PsiphonSettingsPage> {
  late final TextEditingController _upstream = TextEditingController(
    text: widget.psiphon.settings.upstream,
  );

  PsiphonController get psiphon => widget.psiphon;

  @override
  void dispose() {
    _saveUpstream();
    _upstream.dispose();
    super.dispose();
  }

  void _saveUpstream() {
    final value = _upstream.text.trim();
    if (value == psiphon.settings.upstream) return;
    final next = PsiphonSettings.fromJson(psiphon.settings.toJson());
    next.upstream = value;
    unawaited(psiphon.updateSettings(next));
  }

  Future<void> _edit<T>(
    T value,
    void Function(PsiphonSettings, T) apply,
  ) async {
    final next = PsiphonSettings.fromJson(psiphon.settings.toJson());
    apply(next, value);
    await psiphon.updateSettings(next);
    if (mounted) setState(() {});
  }

  String _edgesSummary(PsiphonSettings settings) {
    final ranked = rankCdnEdges(settings.cdnEdges);
    final best = ranked.where((e) => e.lastOk && e.lastMs != null).toList();
    // Build 2074 (audit item 27): displayed numbers route
    // through latDigits().
    if (best.isNotEmpty) return '${latDigits(best.first.lastMs!)} ms';
    return '${latDigits(settings.cdnEdges.length)} edges';
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final settings = psiphon.settings;
    return Scaffold(
      backgroundColor: Ember.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Ember.text,
        title: Text('Psiphon', style: Ember.heading),
      ),
      body: EmberBackground(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 18),
          children: [
            Text(l.psiphonConnectionMode, style: Ember.heading),
            const SizedBox(height: 10),
            EmberSegmented<bool>(
              value: settings.vpnMode,
              onChanged: (v) => _edit(v, (s, v) => s.vpnMode = v),
              options: [
                (true, l.psiphonVpnMode, Icons.vpn_lock_rounded),
                (false, l.psiphonProxyOnly, Icons.swap_horiz_rounded),
              ],
            ),
            const SizedBox(height: 18),
            MapGlass(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Column(
                children: [
                  _SettingsRow(
                    icon: Icons.public_rounded,
                    label: l.region,
                    value: settings.region.isEmpty
                        ? l.psiphonRegionAuto
                        : regionName(settings.region),
                    onTap: () async {
                      await Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => Scaffold(
                            backgroundColor: Ember.bg,
                            appBar: AppBar(
                              backgroundColor: Colors.transparent,
                              elevation: 0,
                              foregroundColor: Ember.text,
                              title: Text(l.region, style: Ember.heading),
                            ),
                            body: EmberBackground(
                              child: PsiphonRegionsView(psiphon: psiphon),
                            ),
                          ),
                        ),
                      );
                      if (mounted) setState(() {});
                    },
                  ),
                  const Divider(color: Ember.line, height: 1),
                  _SettingsRow(
                    icon: Icons.tune_rounded,
                    label: l.psiphonTransports,
                    value: settings.protocols.isEmpty
                        ? l.psiphonTransportsAuto
                        : latDigits(settings.protocols.length),
                    onTap: () async {
                      await Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) =>
                              PsiphonTransportsPage(psiphon: psiphon),
                        ),
                      );
                      if (mounted) setState(() {});
                    },
                  ),
                  const Divider(color: Ember.line, height: 1),
                  _SettingsRow(
                    icon: Icons.receipt_long_rounded,
                    label: l.psiphonLogs,
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => PsiphonLogsPage(psiphon: psiphon),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            // Build 2065: the strategy pack — method ladder, CDN
            // edges, and the fork-core toggles.
            Text('Connection strategy', style: Ember.heading),
            const SizedBox(height: 10),
            MapGlass(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Column(
                children: [
                  _SettingsRow(
                    icon: Icons.route_rounded,
                    label: 'Connection method',
                    value: psiphonMethodName(settings.method),
                    onTap: () async {
                      await Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => PsiphonMethodPage(psiphon: psiphon),
                        ),
                      );
                      if (mounted) setState(() {});
                    },
                  ),
                  const Divider(color: Ember.line, height: 1),
                  _SettingsRow(
                    icon: Icons.cloud_rounded,
                    label: 'CDN edges',
                    value: _edgesSummary(settings),
                    onTap: () async {
                      await Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => PsiphonEdgesPage(psiphon: psiphon),
                        ),
                      );
                      if (mounted) setState(() {});
                    },
                  ),
                  const Divider(color: Ember.line, height: 1),
                  _SwitchRow(
                    icon: Icons.dns_rounded,
                    label: 'CDN fronting',
                    hint: 'Scanned + tested edges carry the fronted rung',
                    value: settings.cdnFronting,
                    onChanged: (v) => _edit(v, (s, v) => s.cdnFronting = v),
                  ),
                  const Divider(color: Ember.line, height: 1),
                  _SwitchRow(
                    icon: Icons.timer_off_rounded,
                    label: 'Disable timeouts',
                    hint: 'Slower attempts, fewer early give-ups',
                    value: settings.disableTimeouts,
                    onChanged: (v) => _edit(v, (s, v) => s.disableTimeouts = v),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            Text(l.psiphonUpstreamProxy, style: Ember.heading),
            const SizedBox(height: 6),
            Text(l.psiphonUpstreamHint, style: Ember.caption),
            const SizedBox(height: 10),
            TextField(
              controller: _upstream,
              style: Ember.body,
              keyboardType: TextInputType.url,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                hintText: 'http://host:port',
                hintStyle: Ember.caption,
                filled: true,
                fillColor: Ember.field,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: const BorderSide(color: Ember.line),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: const BorderSide(color: Ember.line),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: const BorderSide(color: Ember.orange),
                ),
              ),
              onSubmitted: (_) => _saveUpstream(),
            ),
            const SizedBox(height: 12),
            Text(l.psiphonNextConnectHint, style: Ember.caption),
          ],
        ),
      ),
    );
  }
}

/// A settings row with a real switch (build 2065).
class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.icon,
    required this.label,
    required this.hint,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final String label;
  final String hint;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Row(
      children: [
        Icon(icon, size: 20, color: Ember.orange),
        const SizedBox(width: 11),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: Ember.body),
              Text(hint, style: Ember.caption),
            ],
          ),
        ),
        // Build 2074 (audit item 5): the shared MapToggle
        // pill the sibling engines use, not a stock
        // Material Switch.
        MapToggle(value: value, onChanged: onChanged),
      ],
    ),
  );
}

class _SettingsRow extends StatelessWidget {
  const _SettingsRow({
    required this.icon,
    required this.label,
    this.value,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final String? value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 13),
      child: Row(
        children: [
          Icon(icon, size: 20, color: Ember.orange),
          const SizedBox(width: 11),
          Expanded(child: Text(label, style: Ember.body)),
          if (value != null) ...[
            // Build 2074 (audit item 16): the value is bounded
            // — a long region/method name ellipsizes instead
            // of overflowing the row.
            Flexible(
              child: Text(
                value!,
                style: Ember.dimStyle,
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
                textAlign: TextAlign.end,
              ),
            ),
            const SizedBox(width: 6),
          ],
          // Build 2056 (audit Batch 9): English LTR — right.
          const Icon(Icons.chevron_right_rounded, color: Ember.faint, size: 20),
        ],
      ),
    ),
  );
}

/// The transport multi-select: nothing ticked = the core's automatic
/// choice (its default); ticking any box limits the core to those.
class PsiphonTransportsPage extends StatefulWidget {
  const PsiphonTransportsPage({super.key, required this.psiphon});

  final PsiphonController psiphon;

  @override
  State<PsiphonTransportsPage> createState() => _PsiphonTransportsPageState();
}

class _PsiphonTransportsPageState extends State<PsiphonTransportsPage> {
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final selected = widget.psiphon.settings.protocols;
    return Scaffold(
      backgroundColor: Ember.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Ember.text,
        title: Text(l.psiphonTransports, style: Ember.heading),
      ),
      body: EmberBackground(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 18),
          children: [
            Text(
              selected.isEmpty
                  ? l.psiphonTransportsAuto
                  : '${latDigits(selected.length)} / '
                        '${latDigits(psiphonTransports.length)}',
              style: Ember.caption,
            ),
            const SizedBox(height: 10),
            MapGlass(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Column(
                children: [
                  for (var i = 0; i < psiphonTransports.length; i++) ...[
                    if (i > 0) const Divider(color: Ember.line, height: 1),
                    InkWell(
                      onTap: () async {
                        final t = psiphonTransports[i];
                        final next = PsiphonSettings.fromJson(
                          widget.psiphon.settings.toJson(),
                        );
                        if (!next.protocols.remove(t.value)) {
                          next.protocols.add(t.value);
                        }
                        await widget.psiphon.updateSettings(next);
                        if (mounted) setState(() {});
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 11),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                psiphonTransports[i].label,
                                style: Ember.body,
                              ),
                            ),
                            Icon(
                              selected.contains(psiphonTransports[i].value)
                                  ? Icons.check_box_rounded
                                  : Icons.check_box_outline_blank_rounded,
                              color:
                                  selected.contains(psiphonTransports[i].value)
                                  ? Ember.orange
                                  : Ember.faint,
                              size: 21,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 10),
            Text(l.psiphonNextConnectHint, style: Ember.caption),
          ],
        ),
      ),
    );
  }
}

/// The Psiphon log viewer: psiphon.log (the core's diagnostic
/// notices and, since build 2066, the badvpn bridge's lines too)
/// and tunlink.log (the pre-2066 bridge's file, kept readable so
/// an upgraded phone's old evidence stays visible), newest
/// content last.
class PsiphonLogsPage extends StatefulWidget {
  const PsiphonLogsPage({super.key, required this.psiphon});

  final PsiphonController psiphon;

  @override
  State<PsiphonLogsPage> createState() => _PsiphonLogsPageState();
}

class _PsiphonLogsPageState extends State<PsiphonLogsPage> {
  late Future<String> _logs = widget.psiphon.readLogs();

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: Ember.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Ember.text,
        title: Text(l.psiphonLogs, style: Ember.heading),
        actions: [
          IconButton(
            onPressed: () => setState(() => _logs = widget.psiphon.readLogs()),
            icon: const Icon(Icons.refresh_rounded, color: Ember.dim),
          ),
          IconButton(
            onPressed: () async {
              await widget.psiphon.clearLogs();
              setState(() => _logs = widget.psiphon.readLogs());
            },
            icon: const Icon(Icons.delete_outline_rounded, color: Ember.dim),
          ),
        ],
      ),
      body: EmberBackground(
        child: FutureBuilder<String>(
          future: _logs,
          builder: (context, snap) {
            // Build 2074 (audit item 8): a loading or failed
            // read is not an empty log — spinner while waiting,
            // an error line on failure, "no logs" only when the
            // read truly came back empty.
            if (snap.connectionState == ConnectionState.waiting) {
              return const Center(
                child: CircularProgressIndicator(color: Ember.orange),
              );
            }
            if (snap.hasError) {
              return ListView(
                padding: const EdgeInsets.fromLTRB(18, 8, 18, 18),
                children: [
                  MapGlass(
                    padding: const EdgeInsets.all(13),
                    child: Text(
                      'The logs could not be loaded.',
                      style: Ember.body,
                    ),
                  ),
                ],
              );
            }
            final text = snap.data ?? '';
            return ListView(
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 18),
              children: [
                if (snap.hasData)
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: TextButton.icon(
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: text));
                        if (context.mounted) {
                          ScaffoldMessenger.of(
                            context,
                          ).showSnackBar(SnackBar(content: Text(l.logsCopied)));
                        }
                      },
                      icon: const Icon(
                        Icons.copy_rounded,
                        size: 16,
                        color: Ember.dim,
                      ),
                      label: Text(l.copyAll, style: Ember.caption),
                    ),
                  ),
                MapGlass(
                  padding: const EdgeInsets.all(13),
                  child: SelectableText(
                    text.isEmpty ? l.noLogs : text,
                    style: Ember.caption.copyWith(fontFamily: 'monospace'),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// The connection-method picker (build 2065): Auto runs the
/// ladder (fronted → clean-IP → direct → conduit, winner first);
/// a picked method runs alone. The pairing field for a personal
/// Conduit station lives here too — it is a method prerequisite,
/// so it sits with the method it unlocks.
class PsiphonMethodPage extends StatefulWidget {
  const PsiphonMethodPage({super.key, required this.psiphon});

  final PsiphonController psiphon;

  @override
  State<PsiphonMethodPage> createState() => _PsiphonMethodPageState();
}

class _PsiphonMethodPageState extends State<PsiphonMethodPage> {
  late final TextEditingController _pairing = TextEditingController();
  String? _pairingError;

  PsiphonController get psiphon => widget.psiphon;

  static const _hints = <String, String>{
    '': 'Tries each method in order; the winner on this network goes first next time',
    'A': 'Meek through CDN front domains, with scanned + tested edges',
    'E': 'Fronted meek aimed at the tested clean edge IPs',
    'D': 'Every protocol, direct — no fronting, no in-proxy',
    'C': 'Tunnel through other users\' Conduit stations (WebRTC)',
    'P': 'Only through your paired personal Conduit station',
    'X': 'Chain through the upstream proxy set below',
  };

  Future<void> _pick(String method) async {
    final next = PsiphonSettings.fromJson(psiphon.settings.toJson());
    next.method = method;
    await psiphon.updateSettings(next);
    if (mounted) setState(() {});
  }

  Future<void> _savePairing() async {
    final parsed = parseConduitPairing(_pairing.text);
    if (parsed == null) {
      setState(
        () => _pairingError = 'This is not a Conduit pairing link — it starts with psiphon://pair/',
      );
      return;
    }
    final next = PsiphonSettings.fromJson(psiphon.settings.toJson());
    next.compartmentId = parsed.id;
    next.compartmentName = parsed.name;
    await psiphon.updateSettings(next);
    _pairing.clear();
    if (mounted) setState(() => _pairingError = null);
  }

  Future<void> _clearPairing() async {
    final next = PsiphonSettings.fromJson(psiphon.settings.toJson());
    next.compartmentId = '';
    next.compartmentName = '';
    if (next.method == 'P') next.method = '';
    await psiphon.updateSettings(next);
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _pairing.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = psiphon.settings;
    final winner = settings.winnerFor(settings.networkKey);
    return Scaffold(
      backgroundColor: Ember.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Ember.text,
        title: Text('Connection method', style: Ember.heading),
      ),
      body: EmberBackground(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 18),
          children: [
            if (winner.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(
                  'Last winner on this network: ${psiphonMethodName(winner)}',
                  style: Ember.caption,
                ),
              ),
            MapGlass(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Column(
                children: [
                  for (var i = 0; i < psiphonMethods.length; i++) ...[
                    if (i > 0) const Divider(color: Ember.line, height: 1),
                    InkWell(
                      onTap: () => _pick(psiphonMethods.keys.elementAt(i)),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 11),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    psiphonMethods.values.elementAt(i),
                                    style: Ember.body,
                                  ),
                                  Text(
                                    _hints[psiphonMethods.keys.elementAt(i)] ??
                                        '',
                                    style: Ember.caption,
                                  ),
                                ],
                              ),
                            ),
                            Icon(
                              settings.method ==
                                      psiphonMethods.keys.elementAt(i)
                                  ? Icons.check_circle_rounded
                                  : Icons.circle_outlined,
                              color:
                                  settings.method ==
                                      psiphonMethods.keys.elementAt(i)
                                  ? Ember.orange
                                  : Ember.faint,
                              size: 21,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 18),
            Text('Personal Conduit pairing', style: Ember.heading),
            const SizedBox(height: 6),
            Text(
              settings.compartmentId.isEmpty
                  ? 'Paste a friend\'s psiphon://pair/ link to use their private Conduit station.'
                  : 'Paired: ${settings.compartmentName.isEmpty ? 'a station' : settings.compartmentName}',
              style: Ember.caption,
            ),
            const SizedBox(height: 10),
            if (settings.compartmentId.isEmpty) ...[
              TextField(
                controller: _pairing,
                style: Ember.body,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  hintText: 'psiphon://pair/…',
                  hintStyle: Ember.caption,
                  errorText: _pairingError,
                  filled: true,
                  fillColor: Ember.field,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(color: Ember.line),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(color: Ember.line),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(color: Ember.orange),
                  ),
                ),
                onSubmitted: (_) => _savePairing(),
              ),
              const SizedBox(height: 10),
              EmberButton(
                label: 'Save pairing',
                icon: Icons.link_rounded,
                onTap: _savePairing,
              ),
            ] else
              EmberButton(
                label: 'Remove pairing',
                icon: Icons.link_off_rounded,
                onTap: _clearPairing,
              ),
          ],
        ),
      ),
    );
  }
}

/// The ping-tested CDN edge list (build 2065): built-in Akamai /
/// Fastly candidates plus the owner's own IP+SNI entries. "Test
/// all" runs a real TCP+TLS handshake per entry (apps cannot send
/// ICMP; the number shown is handshake latency). The fastest
/// reachable edges feed the core automatically; pinning one edge
/// and turning auto-use off feeds exactly that one.
class PsiphonEdgesPage extends StatefulWidget {
  const PsiphonEdgesPage({super.key, required this.psiphon});

  final PsiphonController psiphon;

  @override
  State<PsiphonEdgesPage> createState() => _PsiphonEdgesPageState();
}

class _PsiphonEdgesPageState extends State<PsiphonEdgesPage> {
  PsiphonController get psiphon => widget.psiphon;

  Future<void> _edit(void Function(PsiphonSettings) apply) async {
    final next = PsiphonSettings.fromJson(psiphon.settings.toJson());
    apply(next);
    await psiphon.updateSettings(next);
    if (mounted) setState(() {});
  }

  Future<void> _addCustom() async {
    final address = TextEditingController();
    final sni = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Add CDN edge', style: Ember.heading),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: address,
              style: Ember.body,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(hintText: 'IP or hostname'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: sni,
              style: Ember.body,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(hintText: 'SNI hostname'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final a = address.text.trim();
    final s = sni.text.trim();
    if (a.isEmpty) return;
    await _edit((settings) {
      settings.cdnEdges.add(
        CdnEdge(address: a, sni: s.isEmpty ? a : s, provider: 'custom'),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: psiphon,
      builder: (context, _) {
        final settings = psiphon.settings;
        final ranked = rankCdnEdges(settings.cdnEdges);
        return Scaffold(
          backgroundColor: Ember.bg,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            elevation: 0,
            foregroundColor: Ember.text,
            title: Text('CDN edges', style: Ember.heading),
          ),
          body: EmberBackground(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 18),
              children: [
                Text(
                  'Each entry is tested with a real TCP + TLS handshake; the number is that handshake\'s latency.',
                  style: Ember.caption,
                ),
                const SizedBox(height: 10),
                EmberButton(
                  label: psiphon.edgeTesting ? 'Testing…' : 'Test all',
                  icon: Icons.speed_rounded,
                  onTap: psiphon.edgeTesting
                      ? null
                      : () => unawaited(psiphon.testAllEdges()),
                ),
                const SizedBox(height: 12),
                _SwitchRow(
                  icon: Icons.auto_awesome_rounded,
                  label: 'Use fastest automatically',
                  hint: 'Feed the fastest reachable edges to the core',
                  value: settings.edgeAutoUse,
                  onChanged: (v) => _edit((s) => s.edgeAutoUse = v),
                ),
                const SizedBox(height: 6),
                MapGlass(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  child: Column(
                    children: [
                      // Build 2074 (audit item 17): an empty list
                      // says so — no bare empty glass.
                      if (ranked.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Text(
                            'No edges yet — the built-in list loads '
                            'with the engine, or add a custom edge below.',
                            style: Ember.caption,
                          ),
                        ),
                      for (var i = 0; i < ranked.length; i++) ...[
                        if (i > 0) const Divider(color: Ember.line, height: 1),
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 9),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      ranked[i].address,
                                      style: Ember.body,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    Text(
                                      '${ranked[i].provider} · SNI ${ranked[i].sni}',
                                      style: Ember.caption,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ),
                              ),
                              Text(
                                ranked[i].lastTestAtMs == 0
                                    ? 'Not tested'
                                    : ranked[i].lastOk
                                    ? '${latDigits('${ranked[i].lastMs}')} ms'
                                    : 'Failed',
                                style: ranked[i].lastOk
                                    ? Ember.body
                                    : Ember.caption,
                              ),
                              IconButton(
                                tooltip: settings.pinnedEdgeId == ranked[i].id
                                    ? 'Pinned'
                                    : 'Pin this edge',
                                icon: Icon(
                                  settings.pinnedEdgeId == ranked[i].id
                                      ? Icons.push_pin_rounded
                                      : Icons.push_pin_outlined,
                                  size: 18,
                                  color: settings.pinnedEdgeId == ranked[i].id
                                      ? Ember.orange
                                      : Ember.faint,
                                ),
                                onPressed: () => _edit((s) {
                                  s.pinnedEdgeId =
                                      s.pinnedEdgeId == ranked[i].id
                                      ? ''
                                      : ranked[i].id;
                                }),
                              ),
                              if (!ranked[i].builtin)
                                IconButton(
                                  tooltip: 'Remove',
                                  icon: const Icon(
                                    Icons.delete_outline_rounded,
                                    size: 18,
                                    color: Ember.faint,
                                  ),
                                  onPressed: () => _edit((s) {
                                    s.cdnEdges.removeWhere(
                                      (e) => e.id == ranked[i].id,
                                    );
                                    if (s.pinnedEdgeId == ranked[i].id) {
                                      s.pinnedEdgeId = '';
                                    }
                                  }),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                EmberButton(
                  label: 'Add custom edge',
                  icon: Icons.add_rounded,
                  onTap: _addCustom,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
