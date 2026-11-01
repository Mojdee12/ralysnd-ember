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
import '../../xray/exit_info.dart';
import 'ember_format.dart';
import 'ember_theme.dart';
import 'profile_country.dart';

String regionName(String code) => englishCountryNames[code] ?? code;

/// The exit-region picker: Automatic plus every region the core
/// offers, as a radio list. Used as the Servers tab in Psiphon mode
/// and pushed from the settings page.
class PsiphonRegionsView extends StatelessWidget {
  const PsiphonRegionsView({super.key, required this.psiphon});

  final PsiphonController psiphon;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: psiphon,
      builder: (context, _) {
        final selected = psiphon.settings.region;
        final runningRegion = psiphon.state.region;
        return ListView(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
          children: [
            Center(child: Text(l.region, style: Ember.title)),
            Center(child: Text('Psiphon', style: Ember.caption)),
            const SizedBox(height: 16),
            GlassCard(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Column(
                children: [
                  _RegionRow(
                    code: '',
                    label: l.psiphonRegionAuto,
                    selected: selected.isEmpty,
                    onTap: () => _pick(''),
                  ),
                  for (final code in psiphon.regionChoices) ...[
                    const Divider(color: Ember.line, height: 1),
                    _RegionRow(
                      code: code,
                      label: regionName(code),
                      selected: selected == code,
                      active: psiphon.state.connected && runningRegion == code,
                      onTap: () => _pick(code),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 10),
            Text(l.psiphonNextConnectHint, style: Ember.caption),
          ],
        );
      },
    );
  }

  void _pick(String code) {
    final next = PsiphonSettings.fromJson(psiphon.settings.toJson());
    next.region = code;
    unawaited(psiphon.updateSettings(next));
  }
}

class _RegionRow extends StatelessWidget {
  const _RegionRow({
    required this.code,
    required this.label,
    required this.selected,
    required this.onTap,
    this.active = false,
  });

  final String code;
  final String label;
  final bool selected;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 11),
          child: Row(
            children: [
              if (code.isEmpty)
                const Icon(Icons.bolt_rounded, color: Ember.dim, size: 22)
              else
                Text(countryFlagEmoji(code),
                    style: const TextStyle(fontSize: 19)),
              const SizedBox(width: 11),
              Expanded(child: Text(label, style: Ember.body)),
              if (active) ...[
                Container(
                  width: 8,
                  height: 8,
                  decoration: const BoxDecoration(
                    color: Ember.green,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
              ],
              Icon(
                selected
                    ? Icons.radio_button_checked_rounded
                    : Icons.radio_button_unchecked_rounded,
                color: selected ? Ember.orange : Ember.faint,
                size: 21,
              ),
            ],
          ),
        ),
      );
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
            GlassCard(
              child: Row(
                children: [
                  const Icon(Icons.person_off_rounded, color: Ember.dim),
                  const SizedBox(width: 10),
                  Expanded(child: Text(l.psiphonNoAccount, style: Ember.body)),
                ],
              ),
            ),
            const SizedBox(height: 12),
            GlassCard(
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
                      child: Text(
                        '↓ ${fmtBytes(state.downBytes)} · ↑ ${fmtBytes(state.upBytes)}',
                        style: Ember.body,
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
  late final TextEditingController _upstream =
      TextEditingController(text: widget.psiphon.settings.upstream);

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

  Future<void> _edit<T>(T value, void Function(PsiphonSettings, T) apply) async {
    final next = PsiphonSettings.fromJson(psiphon.settings.toJson());
    apply(next, value);
    await psiphon.updateSettings(next);
    if (mounted) setState(() {});
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
            GlassCard(
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
                        : '${settings.protocols.length}',
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
                Text(value!, style: Ember.dimStyle),
                const SizedBox(width: 6),
              ],
              const Icon(Icons.chevron_left_rounded,
                  color: Ember.faint, size: 20),
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
                  : '${selected.length} / ${psiphonTransports.length}',
              style: Ember.caption,
            ),
            const SizedBox(height: 10),
            GlassCard(
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
                              color: selected
                                      .contains(psiphonTransports[i].value)
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
/// notices) and tunlink.log (the TUN bridge), newest content last.
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
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(l.logsCopied)),
                          );
                        }
                      },
                      icon: const Icon(Icons.copy_rounded,
                          size: 16, color: Ember.dim),
                      label: Text(l.logsCopied, style: Ember.caption),
                    ),
                  ),
                SelectableText(
                  text.isEmpty ? l.noLogs : text,
                  style: Ember.caption.copyWith(fontFamily: 'monospace'),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
