/// The Lantern engine's pages, Map Control edition (build
/// 2024): the home's floating status card, the Servers tab
/// (the core's list state + its two actions), the Accounts tab
/// (no account — status and session numbers instead), the
/// settings page, and the log viewer. Lantern picks its exit
/// itself; there is no server picker, only the list actions
/// the core's driver contract offers (refetch / fresh list).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../lantern/lantern_controller.dart';
import '../../lantern/lantern_platform.dart';
import '../../l10n/app_localizations.dart';
import 'ember_format.dart';
import 'ember_theme.dart';
import 'map_widgets.dart';

/// The Lantern home: a status card floating over the map in
/// the Psiphon panel's position, the exit card under it when
/// connected, and — loudly, by design — the failure card with
/// the captured log tail when a start went wrong.
class LanternHomePage extends StatelessWidget {
  const LanternHomePage({super.key, required this.lantern});

  final LanternController lantern;

  @override
  Widget build(BuildContext context) {
    final state = lantern.state;
    final on = state.connected;
    final error = lantern.lastError;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      children: [
        // Build 2074 (audit item 3): the top spacer is a capped
        // fraction of the viewport height, not a fixed 150dp.
        SizedBox(
          height: (MediaQuery.sizeOf(context).height * 0.18).clamp(0.0, 150.0),
        ),
        // 2027 (v7 audit, split-width): no fractional wrapper —
        // the status card and the Local proxies card below are
        // single full-width MapGlass panels, the same width
        // and radius as every other engine's cards. The 0.8
        // wrappers (2025, v5 item 5) are what read as an inner
        // box floating inside a wider container.
        MapGlass(
          rim: on,
          // 2025 (Gemini audit v5, item 5): the disconnected
          // status card wears the diagonal luminous rim.
          luminous: !on,
          borderColor: on ? Ember.orange.withValues(alpha: 0.55) : null,
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
                      color: on
                          ? Ember.green
                          : state.running || state.coreRunning
                          ? Ember.amber
                          : Ember.faint,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      on ? 'Connected' : state.stageLabel,
                      style: Ember.heading,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (state.exhausted)
                    const EmberChip(label: 'Limit reached', dot: Ember.red),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                on && state.exitLine.isNotEmpty
                    ? 'Exit: ${state.exitLine}'
                    : state.servers >= 0
                    ? '${latDigits(state.servers)} servers in the current list'
                    : state.hasKeptConfig
                    ? 'A kept list is on the device '
                          '(${latDigits((state.keptServers > 0 ? state.keptServers : 0) + (state.keptMasque > 0 ? state.keptMasque : 0))} servers) '
                          '— the next connect starts instantly, no fetch.'
                    : 'Lantern chooses the fastest exit itself.',
                style: Ember.body,
              ),
              if (lantern.viaWarpLeg) ...[
                const SizedBox(height: 4),
                Text(
                  'The direct list fetch failed — the control plane '
                  'is riding the WARP leg for this start.',
                  style: Ember.caption,
                ),
              ],
              if (!state.available) ...[
                const SizedBox(height: 8),
                Text(
                  'The Lantern core is not included in this build '
                  '(it ships for arm64 phones).',
                  style: Ember.caption,
                ),
              ],
            ],
          ),
        ),
        if (error != null && !state.running) ...[
          const SizedBox(height: 12),
          MapGlass(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.error_outline_rounded,
                      size: 16,
                      color: Ember.red,
                    ),
                    SizedBox(width: 7),
                    // Build 2074 (audit item 16): the header text
                    // is bounded — it ellipsizes instead of
                    // overflowing the card at large font scales.
                    Expanded(
                      child: Text(
                        'The Lantern engine failed to start',
                        style: Ember.heading,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                SelectableText(error, style: Ember.body),
                if (state.stdoutTail.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text('Core output (last lines)', style: Ember.caption),
                  const SizedBox(height: 4),
                  SelectableText(
                    state.stdoutTail
                        .skip(
                          state.stdoutTail.length > 8
                              ? state.stdoutTail.length - 8
                              : 0,
                        )
                        .join('\n'),
                    style: Ember.caption.copyWith(fontFamily: 'monospace'),
                  ),
                ],
              ],
            ),
          ),
        ],
        if (state.running) ...[
          const SizedBox(height: 12),
          // 2027 (v7 audit, split-width): full width, like the
          // status card above it — the 0.8 wrapper is gone.
          MapGlass(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Local proxies', style: Ember.heading),
                const SizedBox(height: 8),
                Text(
                  'SOCKS  127.0.0.1:${LanternPlatform.socksPort}',
                  style: Ember.body,
                ),
                const SizedBox(height: 4),
                Text(
                  'HTTP  127.0.0.1:${LanternPlatform.httpPort}',
                  style: Ember.body,
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// The Servers tab in Lantern mode: there is no picker — the
/// core fetches a signed server list and auto-selects. What
/// the user controls is the list itself: refetch it while the
/// engine runs, or forget it for a fresh one while stopped.
class LanternServersView extends StatelessWidget {
  const LanternServersView({super.key, required this.lantern, this.onClose});

  final LanternController lantern;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: lantern,
      builder: (context, _) {
        final state = lantern.state;
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          children: [
            MapGlass(
              // 2025 (Gemini audit v5, item 5): the diagonal rim
              // on the outer panel, like the other engines' panels.
              luminous: true,
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text('Lantern servers', style: Ember.heading),
                      ),
                      if (onClose != null)
                        // Build 2074 (audit item 4): a ≥48dp hit
                        // area for the panel close button.
                        IconButton(
                          onPressed: onClose,
                          icon: const Icon(Icons.close_rounded, size: 19),
                          color: MapUi.dim,
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.only(left: 4),
                          constraints: const BoxConstraints(
                            minWidth: 48,
                            minHeight: 48,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    state.servers >= 0
                        ? '${latDigits(state.servers)} servers in the current list. '
                              'The core tests them and connects through the '
                              'fastest one that answers.'
                        : state.hasKeptConfig
                        ? 'A kept list is on the device: '
                              '${latDigits(state.keptServers > 0 ? state.keptServers : 0)} fronted'
                              '${state.keptMasque > 0 ? ' + ${latDigits(state.keptMasque)} MASQUE' : ''} '
                              'servers. Starts use it instantly; it '
                              'refreshes behind the connection.'
                        : 'No server list yet — the core fetches one when '
                              'it connects.',
                    style: Ember.body,
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Smart server choice (the core\u2019s -smart mode)',
                          style: Ember.body,
                        ),
                      ),
                      MapToggle(
                        value: lantern.smartRouting,
                        onChanged: state.coreRunning
                            ? null
                            : lantern.setSmartRouting,
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      MapActionPill(
                        icon: Icons.refresh_rounded,
                        label: 'Refetch list',
                        onTap: state.coreRunning
                            ? () async {
                                final ok = await lantern.fetchList();
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        ok
                                            ? 'Refetching the server list…'
                                            : 'The core is not running',
                                      ),
                                    ),
                                  );
                                }
                              }
                            : null,
                      ),
                      MapActionPill(
                        icon: Icons.restart_alt_rounded,
                        label: 'Fresh list',
                        primary: true,
                        onTap: !state.coreRunning
                            ? () async {
                                final n = await lantern.rotateList();
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        n >= 0
                                            ? 'Cached list forgotten — the next '
                                                  'connect fetches a fresh one'
                                            : 'Stop the engine first',
                                      ),
                                    ),
                                  );
                                }
                              }
                            : null,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// The Accounts tab in Lantern mode: there is no account — a
/// status card and the session's numbers instead (the Psiphon
/// about page's shape).
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
        return ListView(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
          children: [
            Center(child: Text(l.navAccounts, style: Ember.title)),
            Center(child: Text('Lantern', style: Ember.caption)),
            const SizedBox(height: 16),
            MapGlass(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(Icons.person_off_rounded, color: Ember.dim),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'No account — Lantern connects anonymously.',
                      style: Ember.body,
                    ),
                  ),
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
                  if (state.exitLine.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text('Exit: ${state.exitLine}', style: Ember.body),
                  ],
                  if (state.servers >= 0) ...[
                    const SizedBox(height: 6),
                    Text(
                      'Servers: ${latDigits(state.servers)}',
                      style: Ember.body,
                    ),
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
                  if (state.exhausted) ...[
                    const SizedBox(height: 8),
                    Text(
                      'The free capacity allocation is used up for now.',
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

/// All of the Lantern engine's settings on one page: the list
/// actions and the log viewer. (The engine has no user-tunable
/// connection options in this build.)
class LanternSettingsPage extends StatelessWidget {
  const LanternSettingsPage({super.key, required this.lantern});

  final LanternController lantern;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Ember.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Ember.text,
        title: Text('Lantern', style: Ember.heading),
      ),
      body: EmberBackground(
        child: ListenableBuilder(
          listenable: lantern,
          builder: (context, _) {
            final state = lantern.state;
            return ListView(
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 18),
              children: [
                MapGlass(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Server list', style: Ember.heading),
                      const SizedBox(height: 6),
                      Text(
                        state.servers >= 0
                            ? '${latDigits(state.servers)} servers cached.'
                            : 'No list cached yet.',
                        style: Ember.body,
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          // Build 2074 (audit item 20): the same
                          // outcome feedback the Servers view's
                          // identical pills give — these used to
                          // fire in silence.
                          MapActionPill(
                            icon: Icons.refresh_rounded,
                            label: 'Refetch list',
                            onTap: state.coreRunning
                                ? () async {
                                    final ok = await lantern.fetchList();
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        SnackBar(
                                          content: Text(
                                            ok
                                                ? 'Refetching the server list…'
                                                : 'The core is not running',
                                          ),
                                        ),
                                      );
                                    }
                                  }
                                : null,
                          ),
                          MapActionPill(
                            icon: Icons.restart_alt_rounded,
                            label: 'Fresh list',
                            primary: true,
                            onTap: !state.coreRunning
                                ? () async {
                                    final n = await lantern.rotateList();
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(context)
                                          .showSnackBar(
                                            SnackBar(
                                              content: Text(
                                                n >= 0
                                                    ? 'Cached list forgotten — the next '
                                                          'connect fetches a fresh one'
                                                    : 'Stop the engine first',
                                              ),
                                            ),
                                          );
                                    }
                                  }
                                : null,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                MapGlass(
                  padding: const EdgeInsets.all(16),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => LanternLogsPage(lantern: lantern),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.terminal_rounded, color: Ember.dim),
                      SizedBox(width: 10),
                      Expanded(child: Text('Engine logs', style: Ember.body)),
                      Icon(Icons.chevron_right_rounded, color: MapUi.faint),
                    ],
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

/// The Lantern log viewer: the core's stdout and stderr and
/// the TUN bridge's log, newest content last.
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
        title: Text('Lantern logs', style: Ember.heading),
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
                  GlassCard(
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
                GlassCard(
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
