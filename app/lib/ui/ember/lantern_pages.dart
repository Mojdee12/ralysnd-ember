/// The Lantern engine's pages: the server view (the Servers tab's
/// content in this mode — the free plan auto-selects, so there is
/// nothing to pick), the no-account page shown on the Accounts tab,
/// the settings page, and the log viewer.
///
/// Lantern's free tier needs no account and offers no server
/// choice; nothing here promises Pro features.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../../lantern/lantern_controller.dart';
import 'ember_format.dart';
import 'ember_theme.dart';

/// The Servers tab in Lantern mode: one fixed entry, "Automatic
/// (Free)", and — once the core has connected — the server it
/// actually landed on.
class LanternServersView extends StatelessWidget {
  const LanternServersView({super.key, required this.lantern});

  final LanternController lantern;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: lantern,
      builder: (context, _) {
        final state = lantern.state;
        final exit = lantern.exitInfo;
        return ListView(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
          children: [
            Center(child: Text(l.navServers, style: Ember.title)),
            Center(child: Text('Lantern', style: Ember.caption)),
            const SizedBox(height: 16),
            GlassCard(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 11),
                child: Row(
                  children: [
                    const Icon(Icons.bolt_rounded, color: Ember.dim, size: 22),
                    const SizedBox(width: 11),
                    Expanded(
                      child: Text(l.lanternAutoFree, style: Ember.body),
                    ),
                    const Icon(
                      Icons.radio_button_checked_rounded,
                      color: Ember.orange,
                      size: 21,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            Text(l.lanternFreeHint, style: Ember.caption),
            if (state.connected && state.serverLine.isNotEmpty) ...[
              const SizedBox(height: 14),
              GlassCard(
                child: Row(
                  children: [
                    const Icon(Icons.dns_rounded, color: Ember.dim, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(l.lanternServer, style: Ember.caption),
                          Text(state.serverLine, style: Ember.body),
                        ],
                      ),
                    ),
                    Container(
                      width: 8,
                      height: 8,
                      decoration: const BoxDecoration(
                        color: Ember.green,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (exit != null) ...[
              const SizedBox(height: 12),
              GlassCard(
                child: Row(
                  children: [
                    const Icon(Icons.public_rounded,
                        size: 16, color: Ember.dim),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        exit.line,
                        style: Ember.body,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

/// The Accounts tab in Lantern mode: there is no account — a status
/// card and the session's numbers instead.
class LanternAboutView extends StatelessWidget {
  const LanternAboutView({super.key, required this.lantern});

  final LanternController lantern;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: lantern,
      builder: (context, _) {
        final state = lantern.state;
        final exit = lantern.exitInfo;
        return ListView(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
          children: [
            Center(child: Text(l.navAccounts, style: Ember.title)),
            Center(child: Text('Lantern', style: Ember.caption)),
            const SizedBox(height: 16),
            GlassCard(
              child: Row(
                children: [
                  const Icon(Icons.person_off_rounded, color: Ember.dim),
                  const SizedBox(width: 10),
                  Expanded(child: Text(l.lanternNoAccount, style: Ember.body)),
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
                  if (state.serverLine.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      '${l.lanternServer}: ${state.serverLine}',
                      style: Ember.body,
                    ),
                  ],
                  if (exit != null) ...[
                    const SizedBox(height: 6),
                    Text(exit.line, style: Ember.body),
                  ],
                  if (state.capAllotted != null && state.capUsed != null) ...[
                    const SizedBox(height: 6),
                    Directionality(
                      textDirection: TextDirection.ltr,
                      child: Text(
                        '${l.lanternDataCap}: ${fmtBytes(state.capUsed!)} / '
                        '${fmtBytes(state.capAllotted!)}',
                        style: Ember.body,
                      ),
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

/// The Lantern engine's settings page: the free plan has no knobs —
/// status and the log viewer are all that honestly belong here.
class LanternSettingsPage extends StatelessWidget {
  const LanternSettingsPage({super.key, required this.lantern});

  final LanternController lantern;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: Ember.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Ember.text,
        title: Text('Lantern', style: Ember.heading),
      ),
      body: EmberBackground(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 18),
          children: [
            GlassCard(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 13),
                child: Row(
                  children: [
                    const Icon(Icons.tune_rounded,
                        size: 20, color: Ember.orange),
                    const SizedBox(width: 11),
                    Expanded(
                      child: Text(l.lanternAutoFree, style: Ember.body),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            Text(l.lanternFreeHint, style: Ember.caption),
            const SizedBox(height: 18),
            GlassCard(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: InkWell(
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => LanternLogsPage(lantern: lantern),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  child: Row(
                    children: [
                      const Icon(Icons.receipt_long_rounded,
                          size: 20, color: Ember.orange),
                      const SizedBox(width: 11),
                      Expanded(
                        child: Text(l.lanternLogs, style: Ember.body),
                      ),
                      const Icon(Icons.chevron_left_rounded,
                          color: Ember.faint, size: 20),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The Lantern log viewer: lantern.log (the core's own log, wired
/// to this file by the service) and tunlink.log (the TUN bridge),
/// newest content last.
class LanternLogsPage extends StatefulWidget {
  const LanternLogsPage({super.key, required this.lantern});

  final LanternController lantern;

  @override
  State<LanternLogsPage> createState() => _LanternLogsPageState();
}

class _LanternLogsPageState extends State<LanternLogsPage> {
  late Future<String> _logs = widget.lantern.readLogs();

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: Ember.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Ember.text,
        title: Text(l.lanternLogs, style: Ember.heading),
        actions: [
          IconButton(
            onPressed: () => setState(() => _logs = widget.lantern.readLogs()),
            icon: const Icon(Icons.refresh_rounded, color: Ember.dim),
          ),
          IconButton(
            onPressed: () async {
              await widget.lantern.clearLogs();
              setState(() => _logs = widget.lantern.readLogs());
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
