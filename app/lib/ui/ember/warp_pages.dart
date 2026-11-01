/// The WARP+ engine's pages: the setup summary (the Servers tab's
/// content in this mode — WARP has no server list to pick from),
/// the settings page (connection mode, endpoint scan, cfon country,
/// endpoint override, logs), and the no-account page shown on the
/// Accounts tab — warp-plus registers an anonymous identity itself.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../../warp/warp_controller.dart';
import '../../warp/warp_platform.dart';
import 'ember_format.dart';
import 'ember_theme.dart';
import 'profile_country.dart';
import 'psiphon_pages.dart' show regionName;

String warpModeLabel(AppLocalizations l, WarpMode mode) => switch (mode) {
      WarpMode.standard => l.warpModeStandard,
      WarpMode.gool => l.warpModeGool,
      WarpMode.cfon => l.warpModeCfon,
    };

String warpModeHint(AppLocalizations l, WarpMode mode) => switch (mode) {
      WarpMode.standard => l.warpModeStandardHint,
      WarpMode.gool => l.warpModeGoolHint,
      WarpMode.cfon => l.warpModeCfonHint,
    };

/// The Servers tab in WARP mode: there is no server list — the
/// current setup at a glance, with the knobs themselves one tap
/// away on the settings page.
class WarpServersView extends StatelessWidget {
  const WarpServersView({super.key, required this.warp});

  final WarpController warp;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: warp,
      builder: (context, _) {
        final settings = warp.settings;
        final state = warp.state;
        return ListView(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
          children: [
            Center(child: Text(l.navServers, style: Ember.title)),
            Center(child: Text('WARP+', style: Ember.caption)),
            const SizedBox(height: 16),
            GlassCard(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Column(
                children: [
                  _SummaryRow(
                    icon: Icons.tune_rounded,
                    label: l.warpMode,
                    value: warpModeLabel(l, settings.mode),
                  ),
                  const Divider(color: Ember.line, height: 1),
                  _SummaryRow(
                    icon: Icons.radar_rounded,
                    label: l.warpScan,
                    value: settings.scan ? '✓' : '—',
                  ),
                  const Divider(color: Ember.line, height: 1),
                  _SummaryRow(
                    icon: Icons.dns_outlined,
                    label: l.warpEndpoint,
                    value: settings.endpoint.trim().isEmpty
                        ? l.warpEndpointAuto
                        : settings.endpoint.trim(),
                  ),
                  if (settings.mode == WarpMode.cfon) ...[
                    const Divider(color: Ember.line, height: 1),
                    _SummaryRow(
                      icon: Icons.public_rounded,
                      label: l.warpCountry,
                      value: regionName(settings.country),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 12),
            GlassCard(
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => WarpSettingsPage(warp: warp),
                ),
              ),
              child: Row(
                children: [
                  const Icon(Icons.tune_rounded, color: Ember.orange),
                  const SizedBox(width: 10),
                  Expanded(child: Text(l.allSettings, style: Ember.body)),
                  const Icon(Icons.chevron_left_rounded, color: Ember.faint),
                ],
              ),
            ),
            if (state.running) ...[
              const SizedBox(height: 12),
              GlassCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l.warpLocalProxy, style: Ember.heading),
                    const SizedBox(height: 8),
                    Text(
                      'SOCKS  127.0.0.1:${WarpPlatform.socksPort}',
                      style: Ember.body,
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 10),
            Text(l.warpMasqueNote, style: Ember.caption),
          ],
        );
      },
    );
  }
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            Icon(icon, size: 20, color: Ember.orange),
            const SizedBox(width: 11),
            Expanded(child: Text(label, style: Ember.body)),
            Flexible(
              child: Text(
                value,
                style: Ember.dimStyle,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      );
}

/// The Accounts tab in WARP mode: there is no account — a status
/// card and the session's numbers instead.
class WarpAboutView extends StatelessWidget {
  const WarpAboutView({super.key, required this.warp});

  final WarpController warp;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: warp,
      builder: (context, _) {
        final state = warp.state;
        final exit = warp.exitInfo;
        return ListView(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
          children: [
            Center(child: Text(l.navAccounts, style: Ember.title)),
            Center(child: Text('WARP+', style: Ember.caption)),
            const SizedBox(height: 16),
            GlassCard(
              child: Row(
                children: [
                  const Icon(Icons.person_off_rounded, color: Ember.dim),
                  const SizedBox(width: 10),
                  Expanded(child: Text(l.warpNoAccount, style: Ember.body)),
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
                              : state.active
                                  ? Ember.amber
                                  : Ember.faint,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        state.connected
                            ? l.statusConnected
                            : state.active
                                ? l.stateConnecting
                                : l.statusDisconnected,
                        style: Ember.heading,
                      ),
                    ],
                  ),
                  if (state.mode.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(state.mode, style: Ember.body),
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
                  if (state.running) ...[
                    const SizedBox(height: 8),
                    Text(
                      'SOCKS 127.0.0.1:${WarpPlatform.socksPort}',
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

/// All of the WARP+ engine's settings on one page.
class WarpSettingsPage extends StatefulWidget {
  const WarpSettingsPage({super.key, required this.warp});

  final WarpController warp;

  @override
  State<WarpSettingsPage> createState() => _WarpSettingsPageState();
}

class _WarpSettingsPageState extends State<WarpSettingsPage> {
  late final TextEditingController _endpoint =
      TextEditingController(text: widget.warp.settings.endpoint);

  WarpController get warp => widget.warp;

  @override
  void dispose() {
    _saveEndpoint();
    _endpoint.dispose();
    super.dispose();
  }

  void _saveEndpoint() {
    final value = _endpoint.text.trim();
    if (value == warp.settings.endpoint) return;
    final next = WarpSettings.fromJson(warp.settings.toJson());
    next.endpoint = value;
    unawaited(warp.updateSettings(next));
  }

  Future<void> _edit<T>(T value, void Function(WarpSettings, T) apply) async {
    final next = WarpSettings.fromJson(warp.settings.toJson());
    apply(next, value);
    await warp.updateSettings(next);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final settings = warp.settings;
    return Scaffold(
      backgroundColor: Ember.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Ember.text,
        title: Text('WARP+', style: Ember.heading),
      ),
      body: EmberBackground(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 18),
          children: [
            Text(l.warpMode, style: Ember.heading),
            const SizedBox(height: 10),
            EmberSegmented<WarpMode>(
              value: settings.mode,
              onChanged: (v) => _edit(v, (s, v) => s.mode = v),
              options: [
                (WarpMode.standard, l.warpModeStandard, Icons.bolt_rounded),
                (WarpMode.gool, l.warpModeGool, Icons.layers_rounded),
                (WarpMode.cfon, l.warpModeCfon, Icons.hub_rounded),
              ],
            ),
            const SizedBox(height: 8),
            Text(warpModeHint(l, settings.mode), style: Ember.caption),
            if (settings.mode == WarpMode.cfon) ...[
              const SizedBox(height: 16),
              GlassCard(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: _SettingsRow(
                  icon: Icons.public_rounded,
                  label: l.warpCountry,
                  value: regionName(settings.country),
                  onTap: () async {
                    await Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => WarpCountriesPage(warp: warp),
                      ),
                    );
                    if (mounted) setState(() {});
                  },
                ),
              ),
            ],
            const SizedBox(height: 18),
            GlassCard(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Row(
                      children: [
                        const Icon(Icons.radar_rounded,
                            size: 20, color: Ember.orange),
                        const SizedBox(width: 11),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(l.warpScan, style: Ember.body),
                              const SizedBox(height: 2),
                              Text(l.warpScanHint, style: Ember.caption),
                            ],
                          ),
                        ),
                        Switch(
                          value: settings.scan,
                          onChanged: (v) => _edit(v, (s, v) => s.scan = v),
                          activeTrackColor: Ember.orange,
                        ),
                      ],
                    ),
                  ),
                  const Divider(color: Ember.line, height: 1),
                  _SettingsRow(
                    icon: Icons.receipt_long_rounded,
                    label: l.warpLogs,
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => WarpLogsPage(warp: warp),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            Text(l.warpEndpoint, style: Ember.heading),
            const SizedBox(height: 6),
            Text(l.warpEndpointHint, style: Ember.caption),
            const SizedBox(height: 10),
            TextField(
              controller: _endpoint,
              style: Ember.body,
              keyboardType: TextInputType.url,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                hintText: '188.114.97.1:2408',
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
              onSubmitted: (_) => _saveEndpoint(),
            ),
            const SizedBox(height: 12),
            Text(l.warpMasqueNote, style: Ember.caption),
            const SizedBox(height: 6),
            Text(l.warpNextConnectHint, style: Ember.caption),
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

/// The cfon exit-country picker: the countries warp-plus's built-in
/// Psiphon accepts, as a radio list.
class WarpCountriesPage extends StatelessWidget {
  const WarpCountriesPage({super.key, required this.warp});

  final WarpController warp;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: Ember.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Ember.text,
        title: Text(l.warpCountry, style: Ember.heading),
      ),
      body: EmberBackground(
        child: ListenableBuilder(
          listenable: warp,
          builder: (context, _) {
            final selected = warp.settings.country;
            return ListView(
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 18),
              children: [
                GlassCard(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Column(
                    children: [
                      for (var i = 0; i < warpCfonCountries.length; i++) ...[
                        if (i > 0) const Divider(color: Ember.line, height: 1),
                        InkWell(
                          onTap: () async {
                            final next =
                                WarpSettings.fromJson(warp.settings.toJson());
                            next.country = warpCfonCountries[i];
                            await warp.updateSettings(next);
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 11),
                            child: Row(
                              children: [
                                Text(
                                  countryFlagEmoji(warpCfonCountries[i]),
                                  style: const TextStyle(fontSize: 19),
                                ),
                                const SizedBox(width: 11),
                                Expanded(
                                  child: Text(
                                    regionName(warpCfonCountries[i]),
                                    style: Ember.body,
                                  ),
                                ),
                                Icon(
                                  selected == warpCfonCountries[i]
                                      ? Icons.radio_button_checked_rounded
                                      : Icons.radio_button_unchecked_rounded,
                                  color: selected == warpCfonCountries[i]
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
                Text(l.warpNextConnectHint, style: Ember.caption),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// The WARP log viewer: warp.log (the core's own log) and
/// tunlink.log (the TUN bridge), newest content last.
class WarpLogsPage extends StatefulWidget {
  const WarpLogsPage({super.key, required this.warp});

  final WarpController warp;

  @override
  State<WarpLogsPage> createState() => _WarpLogsPageState();
}

class _WarpLogsPageState extends State<WarpLogsPage> {
  late Future<String> _logs = widget.warp.readLogs();

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: Ember.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Ember.text,
        title: Text(l.warpLogs, style: Ember.heading),
        actions: [
          IconButton(
            onPressed: () => setState(() => _logs = widget.warp.readLogs()),
            icon: const Icon(Icons.refresh_rounded, color: Ember.dim),
          ),
          IconButton(
            onPressed: () async {
              await widget.warp.clearLogs();
              setState(() => _logs = widget.warp.readLogs());
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
