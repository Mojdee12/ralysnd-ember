/// The Lantern engine's pages, Map Control edition (build
/// 2024): the home's floating status card, the Servers tab,
/// the Accounts tab (no account — status and session numbers
/// instead), the settings page, and the log viewer.
/// Build 2129 (the gomobile swap): the Servers tab gains the
/// real server picker the official client's API offers —
/// Automatic, or one pinned server from the core's own list —
/// plus the smart-routing toggle backed by the real API, and
/// the owner's private server (the VIP entry) now registers
/// through the core's private-server API and pins for real.

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:flutter/services.dart';

import '../../lantern/lantern_controller.dart';
import '../../lantern/lantern_platform.dart';
import '../../xray/lantern_import.dart';
import '../../l10n/app_localizations.dart';
import '../widgets.dart' show CountryFlag;
import 'ember_dialogs.dart';
import 'ember_format.dart';
import 'ember_theme.dart';
import 'map_widgets.dart';

/// Build 2145 (pro6 composition rebuild): the flat hairline
/// panel that replaces the glass panel on the recomposed
/// Lantern surfaces — a solid card fill and a 1 px hairline
/// edge, no blur, no luminous ring: the sample's
/// bottom-sheet-style server panel.
class _HairlinePanel extends StatelessWidget {
  const _HairlinePanel({required this.child, required this.padding});

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: MapUi.card,
        border: Border.all(color: MapUi.line),
        borderRadius: MapUi.panelBorder,
      ),
      padding: padding,
      child: child,
    );
  }
}

/// The Lantern home: the hero word and the status line open
/// over the map at the top of the page body (build 2145,
/// pro6 sample), and — loudly, by design — the failure card
/// with the captured log tail when a start went wrong.
class LanternHomePage extends StatelessWidget {
  const LanternHomePage({super.key, required this.lantern});

  final LanternController lantern;

  @override
  Widget build(BuildContext context) {
    final state = lantern.state;
    final on = state.connected;
    final error = lantern.lastError;
    // Build 2116 (AP-05): the top gap reads this page's own
    // height via LayoutBuilder, as the V2Ray/Psiphon homes
    // do — the device height maxed the spacer and pushed
    // the first card ~47dp too low.
    return LayoutBuilder(
      builder: (context, constraints) => ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        children: [
          // Build 2074 (audit item 3): the top spacer is a capped
          // fraction of the viewport height, not a fixed 150dp.
          SizedBox(
            // Build 2092 (item 39): the shared home top gap.
            height: emberHomeTopGap(constraints.maxHeight),
          ),
        // Build 2145 (pro6 composition rebuild): the status
        // card leaves — the sample's open composition puts
        // the hero 'Lantern' word and the real status line
        // directly over the map at the top of the page body,
        // no panel under them. Every string, condition and
        // the status dot are the old card's own, re-laid.
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Lantern', style: Ember.hero),
            const SizedBox(height: 8),
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
              ],
            ),
            const SizedBox(height: 8),
            Text(
              on && state.exitLine.isNotEmpty
                  ? 'Exit: ${state.exitLine}'
                  : state.servers >= 0
                  ? '${latDigits(state.servers)} servers in the current list'
                  : 'Lantern chooses the fastest exit itself.',
              style: Ember.body,
            ),
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
        if (error != null && !state.running) ...[
          const SizedBox(height: 12),
          MapGlass(
        blur: false,
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
                // Build 2092 (item 19): an exception-shaped
                // error becomes one plain sentence; the
                // engine's own words pass through.
                SelectableText(
                  error.contains('Exception')
                      ? 'The engine reported an error — the '
                            'detail is in the engine logs.'
                      : error,
                  style: Ember.body,
                ),
              ],
            ),
          ),
        ],
      ],
    ));
  }
}

/// The Servers tab in Lantern mode (build 2129): the core's
/// own server list with a real picker — Automatic (the core
/// chooses) or one pinned server — the Smart/Private mode
/// buttons, the VIP private entry, and the smart-routing
/// toggle backed by the core's real API.
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
        final servers = lantern.pickerServers;
        // Duplicate labels get a (2), (3) suffix, LML's rule,
        // so two servers in one city stay tellable apart.
        final labelCounts = <String, int>{};
        String labelFor(LanternServer server) {
          final base = server.label;
          final n = (labelCounts[base] ?? 0) + 1;
          labelCounts[base] = n;
          return n > 1 ? '$base ($n)' : base;
        }

        // Build 2144 (pro6 reskin): labels are resolved in
        // the core list's own order first (the duplicate
        // suffixes above are unchanged), then the rows are
        // composed as the sample lays them out — the
        // private-server row first, Automatic next, then
        // the free (public fleet) rows.
        final labelsByTag = <String, String>{
          for (final server in servers) server.tag: labelFor(server),
        };
        final privateServers = [
          for (final server in servers)
            if (!server.isLantern) server,
        ];
        final publicServers = [
          for (final server in servers)
            if (server.isLantern) server,
        ];

        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          children: [
            // Fidelity rollout batch 3 (pro6-lantern): the
            // view opens with the sample's hero zone over the
            // ground — the hero word, the connection state as
            // a quiet tracked line, the list's size and the
            // current mode under it. The page's Close rides
            // the hero row (the same control the panel's
            // title row carried, build 2074's ≥48 dp target).
            // The panel below keeps only the picker; its
            // explainer survives as the panel's caption
            // footnote, verbatim.
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(child: Text('Lantern', style: Ember.hero)),
                      if (onClose != null)
                        IconButton(
                          tooltip: 'Close',
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
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          color: state.connected ? Ember.green : MapUi.dim,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 7),
                      Text(
                        state.connected ? 'CONNECTED' : 'NOT CONNECTED',
                        style: Ember.microLabel,
                      ),
                    ],
                  ),
                  const SizedBox(height: 5),
                  Text(
                    '${latDigits(servers.length)} SERVERS · '
                    '${lantern.privateMode ? 'PRIVATE' : lantern.selectedTag.isEmpty ? 'AUTOMATIC' : 'PINNED'}',
                    style: Ember.microLabel.copyWith(color: MapUi.dim),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            // Build 2145 (pro6 composition rebuild): the
            // picker panel goes flat — the sample's
            // bottom-sheet-style hairline panel (solid fill,
            // hairline edge, hairline rows) replaces the
            // luminous glass panel; the contents, order and
            // callbacks inside are unchanged.
            _HairlinePanel(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Build 2129: the server picker. The first
                  // entry is Automatic (tag ""); every other
                  // entry is one server from the core's list.
                  // Build 2144 (pro6 reskin): the private
                  // row(s) lead the picker, as in the sample.
                  for (final server in privateServers)
                    _ServerPickerRow(
                      label: labelsByTag[server.tag] ?? server.label,
                      caption: 'PRIVATE SERVER',
                      isPrivate: true,
                      selected: state.running
                          ? state.selectedTag == server.tag
                          : lantern.privateMode,
                      onTap: () async {
                        // The private row: Private mode is
                        // its selection. While running,
                        // register first, then switch — a
                        // failed registration never
                        // switches.
                        await lantern.setPrivateMode(true);
                        if (state.running &&
                            await lantern.registerPrivateForSwitch()) {
                          await lantern.liveSwitch(server.tag);
                        }
                        return;
                      },
                    ),
                  _ServerPickerRow(
                    label: 'Automatic',
                    caption: 'The core chooses the fastest exit',
                    // Build 2131: while a session runs, the
                    // check follows the LIVE session's server
                    // (the published selected tag); otherwise
                    // it follows the persisted pick.
                    selected: state.running
                        ? state.selectedTag.isEmpty
                        : !lantern.privateMode &&
                              lantern.selectedTag.isEmpty,
                    onTap: () async {
                      await lantern.setPrivateMode(false);
                      await lantern.setSelectedTag('');
                      // Build 2131: rows stay live while
                      // connected — the tap switches the
                      // running session right away.
                      if (state.running) await lantern.liveSwitch('');
                    },
                  ),
                  for (final server in publicServers)
                    _ServerPickerRow(
                      label: labelsByTag[server.tag] ?? server.label,
                      // Build 2147 (#24 sweep): public rows
                      // carry no caption (the sample's clean
                      // rows); a private entry in the public
                      // loop keeps its mark.
                      caption: server.isLantern
                          ? ''
                          : 'PRIVATE SERVER',
                      selected: state.running
                          ? state.selectedTag == server.tag
                          : server.isLantern
                          ? !lantern.privateMode &&
                                lantern.selectedTag == server.tag
                          : lantern.privateMode,
                      onTap: () async {
                        if (!server.isLantern) {
                          // The private row: Private mode is
                          // its selection. While running,
                          // register first, then switch — a
                          // failed registration never
                          // switches.
                          await lantern.setPrivateMode(true);
                          if (state.running &&
                              await lantern.registerPrivateForSwitch()) {
                            await lantern.liveSwitch(server.tag);
                          }
                          return;
                        }
                        await lantern.setPrivateMode(false);
                        await lantern.setSelectedTag(server.tag);
                        if (state.running) {
                          await lantern.liveSwitch(server.tag);
                        }
                      },
                    ),
                  const SizedBox(height: 8),
                  _RefreshListPill(lantern: lantern),
                  const SizedBox(height: 12),
                  // Fidelity rollout batch 3: the panel's old
                  // head explainer closes the panel as its
                  // caption footnote — the same words, the
                  // quiet tier.
                  Text(
                    state.servers >= 0
                        ? '${latDigits(servers.length > state.serverList.length ? servers.length : state.servers)} servers in the current list. '
                              'Automatic lets the core pick the fastest '
                              'exit; picking a server pins the '
                              'connection to it — while connected '
                              'the switch happens right away, while '
                              'disconnected the pick applies at the '
                              'next connect.'
                        : 'No server list yet — the core fetches '
                              'one when it connects, or fetch it now.',
                    style: Ember.caption,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            // Fidelity rollout batch 3: smart routing, the
            // server mode and the VIP block leave the panel
            // for an OPEN section under it, hairline-separated
            // — the sample's composition. Every control,
            // value and callback is the panel's own, moved
            // not changed.
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Build 2129: smart routing as the real API
                  // setting it always was — Lantern's own
                  // rule list sent direct, bypassing the
                  // tunnel. DEFAULT OFF (forced off at every
                  // core init); the toggle applies it through
                  // Mobile.setSmartRoutingEnabled. Distinct
                  // from the Smart/Private server mode below.
                  // Batch 3: the row's label takes the quiet
                  // tracked tier (the string itself verbatim).
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Smart routing', style: Ember.microLabel),
                            Text(
                              'Lantern sends the services on its own '
                              'list direct, outside the tunnel.',
                              style: Ember.caption,
                            ),
                          ],
                        ),
                      ),
                      // Build 2144 (pro6 reskin): the shared
                      // MapToggle pill, like the sibling
                      // engines' toggles — same value and
                      // callback (default OFF unchanged).
                      MapToggle(
                        value: lantern.smartRouting,
                        onChanged: (on) => lantern.setSmartRouting(on),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Container(height: 1, color: MapUi.line),
                  const SizedBox(height: 16),
                  // The server mode — Smart (the public fleet)
                  // or Private, the owner's own server.
                  // Batch 3: the row's label takes the quiet
                  // tracked tier, like smart routing's above.
                  Row(
                    children: [
                      Expanded(
                        child: Text('Server mode', style: Ember.microLabel),
                      ),
                      EmberChip(
                        label: 'Smart',
                        compact: true,
                        selected: !lantern.privateMode,
                        onTap: () async {
                          await lantern.setPrivateMode(false);
                          // Build 2131: while running, the
                          // mode buttons switch the live
                          // session too — Smart returns it to
                          // the persisted public pick
                          // ('' = Automatic).
                          if (state.running) {
                            await lantern.liveSwitch(lantern.selectedTag);
                          }
                        },
                      ),
                      const SizedBox(width: 7),
                      EmberChip(
                        label: 'Private',
                        compact: true,
                        selected: lantern.privateMode,
                        onTap: () async {
                          await lantern.setPrivateMode(true);
                          // Build 2131: while running,
                          // register the private server,
                          // then switch the live session to
                          // it; a failed registration never
                          // switches.
                          if (state.running &&
                              await lantern.registerPrivateForSwitch()) {
                            await lantern.liveSwitch(lantern.privateTag);
                          }
                        },
                      ),
                    ],
                  ),
                  if (lantern.privateMode) ...[
                    const SizedBox(height: 16),
                    Container(height: 1, color: MapUi.line),
                    const SizedBox(height: 14),
                    // The VIP entry (the owner's naming):
                    // his own exit, headlined VIP with its
                    // country beside it once known.
                    Row(
                      children: [
                        if (lantern.privateCode.isNotEmpty) ...[
                          CountryFlag(code: lantern.privateCode, width: 26),
                          const SizedBox(width: 8),
                        ],
                        Expanded(
                          child: Text(
                            lantern.vipLabel,
                            style: Ember.heading.copyWith(fontSize: Ember.fontTitle),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      lantern.privateName.isNotEmpty
                          ? 'Your own server (${lantern.privateName}) — '
                                'registered with the Lantern core itself '
                                'in Private mode, and the connection is '
                                'pinned to it: this server, or no '
                                'connection.'
                          : 'Your own server — in Private mode it is '
                                'registered with the Lantern core itself '
                                'before connecting, and the connection '
                                'is pinned to it. Its country shows here '
                                'after the first registration.',
                      style: Ember.caption,
                    ),
                    const SizedBox(height: 10),
                    _PrivateKeyRow(lantern: lantern, running: state.running),
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

/// One picker row: a flag (when the server's country is
/// known), the label, and a check when selected.
class _ServerPickerRow extends StatelessWidget {
  const _ServerPickerRow({
    required this.label,
    this.caption = '',
    required this.selected,
    required this.onTap,
    this.isPrivate = false,
  });

  final String label;

  /// Build 2147 (#24 sweep): the sample's rows are clean —
  /// a name, and (on the private row) a micro-label
  /// caption. The flag chips and raw core tags the rows
  /// used to carry are gone; a public row shows its name
  /// only.
  final String caption;
  final bool selected;
  final VoidCallback? onTap;

  /// Build 2144 (pro6 reskin): the private-server row of the
  /// sample — an orange home icon, the heading-weight name,
  /// a micro-label caption, and the 2 px orange left edge.
  final bool isPrivate;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        // The sample's private row carries the orange left
        // edge; other rows keep a transparent edge of the
        // same width so the columns stay aligned, over a
        // hairline under every row.
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(
              color: isPrivate ? Ember.orange : Colors.transparent,
              width: 2,
            ),
            bottom: const BorderSide(color: MapUi.line, width: 1),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
          child: Row(
            children: [
              if (isPrivate) ...[
                const Icon(
                  Icons.home_rounded,
                  size: 22,
                  color: Ember.orange,
                ),
                const SizedBox(width: 9),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: isPrivate ? Ember.heading : Ember.body,
                    ),
                    if (caption.isNotEmpty)
                      Text(
                        caption,
                        style: isPrivate
                            ? Ember.microLabel
                            : Ember.caption,
                      ),
                  ],
                ),
              ),
              if (selected)
                Icon(Icons.check_rounded, size: 18, color: Ember.orange),
            ],
          ),
        ),
      ),
    );
  }
}

/// The list refresh: asks the core for its list now (the
/// service initializes it if needed) and says so.
class _RefreshListPill extends StatefulWidget {
  const _RefreshListPill({required this.lantern});

  final LanternController lantern;

  @override
  State<_RefreshListPill> createState() => _RefreshListPillState();
}

class _RefreshListPillState extends State<_RefreshListPill> {
  bool _busy = false;

  Future<void> _refresh() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.lantern.refreshServers();
      if (mounted) {
        // Build 2132: the count matches the picker — the
        // app-guaranteed private row counts too.
        final merged = widget.lantern.pickerServers.length;
        final n = merged > widget.lantern.state.serverList.length
            ? merged
            : widget.lantern.state.servers;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              n >= 0
                  ? 'Server list updated — ${latDigits(n)} servers'
                  : 'The list has not arrived yet — try again in a moment',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  // Build 2147 (#24 sweep): the sample's action row — a
  // centred orange text action over a hairline, not a
  // pill. Same refresh, same busy discipline.
  Widget build(BuildContext context) => InkWell(
    onTap: _busy ? null : () => unawaited(_refresh()),
    child: Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: MapUi.line, width: 1)),
      ),
      child: Text(
        _busy ? 'Refreshing…' : 'Refresh list',
        textAlign: TextAlign.center,
        style: Ember.microLabelOrange,
      ),
    ),
  );
}

/// Build 2129 (the paste-intake fix): a lantern:// key given
/// on the Lantern page goes to the Lantern private-server
/// path — it becomes the VIP key and turns Private mode on.
/// It NEVER falls into the V2Ray profile importer (the
/// pre-2129 defect: pasting the key here created a V2Ray
/// profile instead of registering the VIP). The Xray-side
/// importer stays for keys pasted on the V2Ray side.
Future<void> showLanternKeySheet(
  BuildContext context,
  LanternController lantern,
) async {
  final controller = TextEditingController();
  try {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text ?? '';
    if (containsLanternPrivateServerLink(text)) controller.text = text;
  } catch (_) {
    // No clipboard access: an empty field.
  }
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Ember.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
    ),
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.fromLTRB(
        18,
        18,
        18,
        18 + MediaQuery.viewInsetsOf(sheetContext).bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Add your Lantern server', style: Ember.heading),
            const SizedBox(height: 6),
            Text(
              'Paste the lantern:// key your server manager prints. '
              'It is registered with the Lantern core as your '
              'private server — not added to the V2Ray configs.',
              style: Ember.caption,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              minLines: 3,
              maxLines: 6,
              style: Ember.body,
              decoration: emberField(sheetContext, 'lantern://private-server?…'),
            ),
            const SizedBox(height: 14),
            EmberButton(
              label: 'Save key',
              icon: Icons.vpn_key_rounded,
              onTap: () async {
                final link = findLanternPrivateServerLink(controller.text);
                if (link == null) {
                  ScaffoldMessenger.of(sheetContext).showSnackBar(
                    const SnackBar(
                      content: Text(
                        'That text carries no lantern:// private-server key.',
                      ),
                    ),
                  );
                  return;
                }
                await lantern.setPrivateKey(controller.text.trim());
                await lantern.setPrivateMode(true);
                if (sheetContext.mounted) Navigator.of(sheetContext).pop();
              },
            ),
          ],
        ),
      ),
    ),
  );
  controller.dispose();
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
        blur: false,
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
        blur: false,
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
                  // Build 2125 (audit A25-04): the
                  // kill-switch hold names itself — the
                  // session is down, but its TUN is held so
                  // traffic is blocked, never direct.
                  if (state.killSwitchHeld) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Kill switch holding: the session dropped, '
                      'and its tunnel is being held so traffic '
                      'stays blocked instead of going direct. '
                      'Reconnect or disconnect to clear it.',
                      style: Ember.caption,
                    ),
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
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// All of the Lantern engine's settings on one page: the
/// server list and the log viewer. (Build 2129: the picker's
/// choices and the smart-routing toggle live on the Servers
/// tab; this page keeps the list summary and the logs.)
class LanternSettingsPage extends StatelessWidget {
  const LanternSettingsPage({super.key, required this.lantern});

  final LanternController lantern;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Ember.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Ember.text,
        title: Text('Lantern', style: Ember.heading),
      ),
      body: EmberBackground(banded: true, 
        child: ListenableBuilder(
          listenable: lantern,
          builder: (context, _) {
            final state = lantern.state;
            return ListView(
              padding: EdgeInsets.fromLTRB(18, MediaQuery.of(context).padding.top + kToolbarHeight + 8, 18, 18),
              children: [
                MapGlass(
        blur: false,
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
                      _RefreshListPill(lantern: lantern),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                MapGlass(
        blur: false,
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
      extendBodyBehindAppBar: true,
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
          // Build 2092 (item 51): Clear carries a tooltip
          // and confirms first, like the other log pages.
          IconButton(
            tooltip: 'Clear logs',
            onPressed: () async {
              final confirmed = await showEmberConfirm(
                context,
                title: 'Clear logs?',
                message: 'Delete the saved Lantern logs?',
                confirmLabel: 'Clear',
              );
              if (!confirmed) return;
              await widget.lantern.clearLogs();
              setState(() => _logs = widget.lantern.readLogs());
            },
            icon: const Icon(Icons.delete_outline_rounded, color: Ember.dim),
          ),
        ],
      ),
      body: EmberBackground(banded: true, 
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
                padding: EdgeInsets.fromLTRB(18, MediaQuery.of(context).padding.top + kToolbarHeight + 8, 18, 18),
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
              padding: EdgeInsets.fromLTRB(18, MediaQuery.of(context).padding.top + kToolbarHeight + 8, 18, 18),
              children: [
                if (snap.hasData)
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: TextButton.icon(
                      // Build 2092 (item 51): 48 dp floor.
                      style: TextButton.styleFrom(
                        minimumSize: const Size(0, 48),
                      ),
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

/// The private key row of the VIP entry — the key is the
/// lantern:// link the owner's server manager prints; it is
/// pasted, never typed. Build 2129: pasting goes through
/// showLanternKeySheet, which validates the link and routes
/// it to the Lantern private-server path only.
class _PrivateKeyRow extends StatelessWidget {
  const _PrivateKeyRow({required this.lantern, required this.running});

  final LanternController lantern;
  final bool running;

  @override
  Widget build(BuildContext context) {
    final hasKey = lantern.privateKey.trim().isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          hasKey
              ? 'Server key saved.'
              : 'No server key yet — paste the lantern:// link '
                    'your server manager prints.',
          style: Ember.body,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            // Build 2145 (pro6 composition rebuild): the
            // add-private-server action is the sample's orange
            // TEXT action — same label, same callback (the key
            // sheet), same disabled-while-running condition;
            // only the pill chrome leaves.
            TextButton(
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 48),
                padding: const EdgeInsets.symmetric(horizontal: 4),
              ),
              onPressed: running
                  ? null
                  : () => showLanternKeySheet(context, lantern),
              child: Text(
                hasKey ? 'Replace key' : 'Paste key',
                style: Ember.heading.copyWith(color: Ember.orange),
              ),
            ),
            if (hasKey)
              MapActionPill(
                icon: Icons.delete_outline_rounded,
                label: 'Remove key',
                onTap: running ? null : () => lantern.setPrivateKey(''),
              ),
          ],
        ),
      ],
    );
  }
}
