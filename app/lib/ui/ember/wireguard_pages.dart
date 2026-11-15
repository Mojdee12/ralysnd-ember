/// The standalone WireGuard section's pages, Map Control
/// edition (build 2032, sample s22): WireGuard profiles live
/// in the same store as every V2Ray config (the Xray core's
/// WireGuard outbound is the carrier), but this section is
/// WireGuard only — its own import (.conf files and
/// wireguard:// links), its own list, and the peer-fallback
/// connect ralysnd's WireGuard page has: a config with several
/// peers tries them in order until one actually carries
/// traffic.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../xray/link_parser.dart';
import '../../xray/wg_conf.dart';
import '../../xray/wstunnel_args.dart';
import '../../xray/xray_controller.dart';
import '../../xray/xray_models.dart';
import '../../xray/xray_platform.dart';
import 'ember_format.dart';
import 'ember_theme.dart';
import 'map_widgets.dart';

List<Profile> wgProfilesOf(XrayController xray) =>
    xray.profiles.where((p) => p.protocol == Protocol.wireguard).toList();

/// Imports WireGuard config text (build 2050): the gate, the
/// name prompt, the parser, the store. Shared by the paste
/// path, the file picker, and the home page — one behaviour
/// everywhere. A parse failure names the parser's own reason;
/// nothing fails silently.
Future<void> importWgConfText(
  BuildContext context,
  XrayController xray,
  String text, {
  String suggestedName = 'WireGuard',
}) async {
  // The gate speaks the parser's language (build 2033):
  // section names are case-insensitive there, so a file
  // whose header reads [interface] must pass here too —
  // the pre-2033 case-sensitive check refused files the
  // parser itself would have accepted.
  if (text.isEmpty || !text.toLowerCase().contains('[interface]')) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'That text is not a WireGuard config — no [Interface] section',
        ),
      ),
    );
    return;
  }
  final name = await _askWgName(context, suggestedName);
  if (name == null || !context.mounted) return;
  final result = parseWgConf(text, baseName: name, idFor: newProfileId);
  if (!result.ok) {
    // Build 2074 (audit item 6): a plain sentence — the
    // parser's raw reason stays out of the SnackBar (the
    // build-2070 pattern at _connect below).
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('That file is not a valid WireGuard config'),
      ),
    );
    return;
  }
  for (final p in result.profiles) {
    await xray.addProfile(p);
  }
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Imported ${latDigits(result.profiles.length)} config'
          '${result.profiles.length == 1 ? '' : 's'}'
          '${result.amnezia ? ' — AmneziaWG parameters found: runs with AmneziaWG obfuscation (falls back to plain WireGuard if the obfuscated tunnel cannot reach the server)' : ''}',
        ),
      ),
    );
  }
}

/// The .conf FILE import (build 2050, audit F-H14): the
/// WireGuard page was clipboard-only until now — a config that
/// lives as a file in Downloads or Telegram had no way in.
/// Rides the generalized native picker; a read failure (too
/// large, unreadable) is surfaced by name, never a silent
/// no-op. The file's own name seeds the config name.
Future<void> importWgConfFile(BuildContext context, XrayController xray) async {
  final Map<String, String>? picked;
  try {
    picked = await XrayPlatform.pickTextFile();
  } on PlatformException catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            e.message == 'file-too-large'
                ? 'That file is too large to import (256 KB max)'
                : 'Could not read that file (${e.message ?? e.code})',
          ),
        ),
      );
    }
    return;
  }
  if (picked == null || !context.mounted) return;
  var base = picked['name'] ?? 'WireGuard';
  if (base.toLowerCase().endsWith('.conf')) {
    base = base.substring(0, base.length - 5);
  }
  if (base.trim().isEmpty) base = 'WireGuard';
  await importWgConfText(
    context,
    xray,
    (picked['content'] ?? '').trim(),
    suggestedName: base,
  );
}

Future<String?> _askWgName(BuildContext context, String initial) async {
  final controller = TextEditingController(text: initial);
  try {
    return await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Config name', style: Ember.heading),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: Ember.body,
          decoration: const InputDecoration(
            hintText: 'Name for the imported config',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Import'),
          ),
        ],
      ),
    );
  } finally {
    controller.dispose();
  }
}

/// The WireGuard home (mode 5): the status card (s22's
/// two-path card: the selected config, or the empty state with
/// the import actions), over the map.
class WireGuardHomePage extends StatelessWidget {
  const WireGuardHomePage({
    super.key,
    required this.xray,
    required this.onOpenServers,
  });

  final XrayController xray;
  final VoidCallback onOpenServers;

  @override
  Widget build(BuildContext context) {
    final on = xray.state.running;
    final selected = xray.selected;
    final wgSelected =
        selected != null && selected.protocol == Protocol.wireguard
        ? selected
        : null;
    final count = wgProfilesOf(xray).length;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      children: [
        // Build 2074 (audit item 3): the top spacer is a capped
        // fraction of the viewport height, not a fixed 150dp.
        SizedBox(
          height: (MediaQuery.sizeOf(context).height * 0.18).clamp(0.0, 150.0),
        ),
        MapGlass(
          rim: on && wgSelected != null,
          luminous: !(on && wgSelected != null),
          padding: const EdgeInsets.all(16),
          onTap: onOpenServers,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 9,
                    height: 9,
                    decoration: BoxDecoration(
                      color: on && wgSelected != null
                          ? Ember.green
                          : Ember.faint,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      on && wgSelected != null ? 'Connected' : 'WireGuard',
                      style: Ember.heading,
                    ),
                  ),
                  const Icon(Icons.chevron_right_rounded, color: MapUi.faint),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                wgSelected != null
                    ? '${wgSelected.displayName} • ${wgSelected.address}:${wgSelected.port}'
                    : count > 0
                    ? '${latDigits(count)} WireGuard config${count == 1 ? '' : 's'} — '
                          'pick one in the configurations panel.'
                    : 'No WireGuard configs yet — import a .conf file '
                          'or a wireguard:// link in the configurations '
                          'panel.',
                style: Ember.body,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              if (on && wgSelected != null && xray.exitInfo != null) ...[
                const SizedBox(height: 6),
                Text('Exit: ${xray.exitInfo!.line}', style: Ember.caption),
              ],
              // Build 2050 (audit C-1): an AmneziaWG profile
              // running as plain WireGuard says so here — the
              // session is not obfuscated, and the card must
              // not imply it is.
              if (on && xray.awgFallbackNotice.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  xray.awgFallbackNotice,
                  style: Ember.caption.copyWith(color: Ember.warn),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        // Build 2050 (audit F-H14): a labelled import on the
        // home page itself — before this, the only door was an
        // unlabelled whole-card tap into the configurations
        // panel, and the panel itself was clipboard-only.
        MapGlass(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: Text('Bring your own config', style: Ember.heading),
              ),
              MapActionPill(
                icon: Icons.folder_open_rounded,
                label: 'Import .conf file',
                onTap: () => importWgConfFile(context, xray),
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
              Text('How it runs', style: Ember.heading),
              const SizedBox(height: 6),
              Text(
                'WireGuard rides the V2Ray engine\u2019s core as an '
                'outbound — the same tunnel, stats and routing as '
                'every other config. A config with several peers '
                'tries them in order until one carries traffic '
                '(peer fallback). A config with AmneziaWG '
                'parameters runs on Ember\u2019s AmneziaWG engine '
                'instead, with the obfuscation applied for real; '
                'a peer the obfuscated tunnel cannot reach falls '
                'back to plain WireGuard.',
                style: Ember.caption,
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _WgWstunnelCard(xray: xray),
      ],
    );
  }
}

/// WireGuard over WebSocket (build 2072): the engine-level
/// wstunnel option. While on, a WireGuard session carried by
/// the V2Ray engine sends its peer traffic through a
/// wstunnel client to the URL below — the session's config
/// points the peer at the local forwarder
/// (127.0.0.1:$wstunnelListenPort) and the wstunnel server
/// dials the real endpoint. The stored configs are never
/// rewritten. AmneziaWG-engine sessions are not wrapped.
class _WgWstunnelCard extends StatefulWidget {
  const _WgWstunnelCard({required this.xray});

  final XrayController xray;

  @override
  State<_WgWstunnelCard> createState() => _WgWstunnelCardState();
}

class _WgWstunnelCardState extends State<_WgWstunnelCard> {
  late final TextEditingController _url = TextEditingController(
    text: widget.xray.settings.wgWstunnelUrl,
  );

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final xray = widget.xray;
    final on = xray.settings.wgWstunnel;
    final urlOk = isWstunnelUrl(_url.text);
    return MapGlass(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.language_rounded, size: 16, color: MapUi.dim),
              const SizedBox(width: 7),
              Expanded(
                child: Text('WireGuard over WebSocket', style: Ember.heading),
              ),
              EmberToggle(value: on, onChanged: (v) => xray.setWgWstunnel(v)),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Carries the peer\u2019s UDP inside a WebSocket '
            'tunnel (wstunnel) — for networks where the '
            'WireGuard endpoint is blocked but a ws/wss '
            'endpoint passes. A wstunnel server must run at '
            'the other end; it dials the real peer. Applies '
            'to WireGuard configs on the V2Ray engine; '
            'AmneziaWG-engine sessions are not wrapped.',
            style: Ember.caption,
          ),
          if (on) ...[
            const SizedBox(height: 11),
            TextField(
              controller: _url,
              style: Ember.body,
              textDirection: TextDirection.ltr,
              keyboardType: TextInputType.url,
              onChanged: (_) => setState(() {}),
              onSubmitted: (v) => xray.setWgWstunnelUrl(v),
              decoration: emberField(context, 'wss://your-server.example:443')
                  .copyWith(
                    labelText: 'wstunnel server URL',
                    labelStyle: const TextStyle(
                      color: Ember.faint,
                      fontSize: 13,
                    ),
                    floatingLabelStyle: const TextStyle(color: Ember.orange),
                  ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _url.text.trim().isEmpty
                        ? 'Enter the wstunnel server URL.'
                        : urlOk
                        ? 'Sessions forward through this server.'
                        : 'The URL must start with ws:// or wss://.',
                    style: Ember.caption.copyWith(
                      color: _url.text.trim().isNotEmpty && !urlOk
                          ? Ember.orange
                          : null,
                    ),
                  ),
                ),
                MapActionPill(
                  icon: Icons.check_rounded,
                  label: 'Save URL',
                  onTap: () => xray.setWgWstunnelUrl(_url.text),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// The configurations panel in WireGuard mode: import actions
/// on top, then the WireGuard profiles with delay + exit data
/// and the fallback connect.
class WireGuardServersView extends StatelessWidget {
  const WireGuardServersView({super.key, required this.xray, this.onClose});

  final XrayController xray;
  final VoidCallback? onClose;

  Future<void> _importConf(BuildContext context) async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (!context.mounted) return;
    if (text.isEmpty || !text.toLowerCase().contains('[interface]')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Copy a .conf file\u2019s text first, then tap import'),
        ),
      );
      return;
    }
    await importWgConfText(context, xray, text);
  }

  Future<void> _importLink(BuildContext context) async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (!context.mounted) return;
    if (!text.contains('wireguard://') && !text.contains('wg://')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Copy a wireguard:// link first, then tap import'),
        ),
      );
      return;
    }
    final r = await xray.importLinksAsync(text);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            // Build 2074 (audit items 6+27): the count routes
            // through latDigits(), and a failed import is a
            // plain sentence — the parser's raw first error
            // stays out of the SnackBar.
            r.added > 0
                ? 'Imported ${latDigits(r.added)} config${r.added == 1 ? '' : 's'}'
                : 'Nothing importable in the clipboard',
          ),
        ),
      );
    }
  }

  Future<void> _connect(BuildContext context, Profile p) async {
    try {
      if (xray.state.running && xray.selected?.id == p.id) {
        await xray.disconnect();
        return;
      }
      await xray.connectWireGuardWithFallback(p);
    } on StateError catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              // Build 2074 (audit item 6): only the known code
              // gets its sentence; any other StateError message
              // is raw internals and stays out of the SnackBar.
              e.message == 'wg-all-peers-failed'
                  ? 'No peer of this config carried traffic — '
                        'the endpoints may be filtered or down'
                  : 'The tunnel did not start — check the core logs',
            ),
          ),
        );
      }
    } catch (e) {
      // Build 2070 (review §3.4): a plain line, not the raw
      // exception — the detail stays in the controller's
      // diagnostics journal and the log page.
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('The tunnel did not start — check the core logs'),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: xray,
      builder: (context, _) {
        final profiles = wgProfilesOf(xray);
        // Group peers of one imported config together.
        final groups = <String, List<Profile>>{};
        for (final p in profiles) {
          groups.putIfAbsent(wgGroupKey(p), () => []).add(p);
        }
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          children: [
            MapGlass(
              luminous: true,
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'WireGuard configurations',
                          style: Ember.heading,
                        ),
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
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      MapActionPill(
                        icon: Icons.folder_open_rounded,
                        label: 'Import file',
                        onTap: () => importWgConfFile(context, xray),
                      ),
                      MapActionPill(
                        icon: Icons.content_paste_rounded,
                        label: 'Paste .conf',
                        onTap: () => _importConf(context),
                      ),
                      MapActionPill(
                        icon: Icons.link_rounded,
                        label: 'Paste link',
                        onTap: () => _importLink(context),
                      ),
                    ],
                  ),
                  if (profiles.isEmpty) ...[
                    const SizedBox(height: 10),
                    Text(
                      'Nothing here yet. Import a .conf file from '
                      'storage, or paste its text; several peers '
                      'in one file become a fallback group.',
                      style: Ember.caption,
                    ),
                  ],
                ],
              ),
            ),
            for (final entry in groups.entries) ...[
              if (entry.value.length > 1) ...[
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        entry.value.first.name.split(' · ').first.toUpperCase(),
                        style: const TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.6,
                          color: MapUi.dim,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      '${latDigits(entry.value.length)} peers · fallback on',
                      style: Ember.caption,
                    ),
                  ],
                ),
              ],
              for (final p in entry.value) ...[
                const SizedBox(height: 10),
                _WgProfileRow(
                  xray: xray,
                  profile: p,
                  onConnect: () => _connect(context, p),
                ),
              ],
            ],
          ],
        );
      },
    );
  }
}

class _WgProfileRow extends StatelessWidget {
  const _WgProfileRow({
    required this.xray,
    required this.profile,
    required this.onConnect,
  });

  final XrayController xray;
  final Profile profile;
  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context) {
    final p = profile;
    final live = xray.state.running && xray.selected?.id == p.id;
    return MapGlass(
      // Build 2074 (audit item 13): repeated list rows render
      // without a live BackdropFilter — the static-fill pattern
      // OpenVPN's list already used.
      blur: false,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      // Build 2045: the name the user sees.
                      p.displayName,
                      style: Ember.heading,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      '${p.address}:${p.port}',
                      style: Ember.caption,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              EmberChip(
                label: live
                    ? 'Disconnect'
                    : xray.connecting
                    ? 'Working…'
                    : 'Connect',
                selected: live,
                onTap: xray.connecting ? null : onConnect,
              ),
            ],
          ),
          const SizedBox(height: 9),
          Wrap(
            spacing: 7,
            runSpacing: 7,
            children: [
              EmberChip(
                label: p.delayMs >= 0
                    ? 'Ping ${latDigits(p.delayMs)}ms'
                    : p.delayFailed
                    ? 'Ping failed'
                    : 'Ping —',
                dot: p.delayMs >= 0
                    ? mapPingColor(p.delayMs)
                    : p.delayFailed
                    ? Ember.red
                    : null,
                onTap: () => xray.testDelay(p),
              ),
              if (p.exitIp.isNotEmpty)
                EmberChip(
                  label:
                      'Exit ${p.exitIp}'
                      '${p.exitCountryCode.isNotEmpty ? ' • ${p.exitCountryCode}' : ''}',
                ),
              if (p.hasAmneziaParams)
                EmberChip(
                  // Build 2050 (audit C-1): the chip tells the
                  // truth for the LIVE row — a session the AWG
                  // engine could not start runs plain, and the
                  // row says so instead of claiming obfuscation.
                  label: live && xray.awgFallbackNotice.isNotEmpty
                      ? 'AmneziaWG failed — running plain WireGuard'
                      : 'AmneziaWG — runs obfuscated',
                ),
              if (profileHasTotals(p)) EmberChip(label: fmtProfileTotals(p)),
              MapActionPill(
                icon: Icons.delete_outline_rounded,
                label: 'Delete',
                onTap: () async {
                  final confirm = await showDialog<bool>(
                    context: context,
                    builder: (dialogContext) => AlertDialog(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(24),
                      ),
                      title: Text(
                        'Delete ${p.displayName}?',
                        style: Ember.heading,
                      ),
                      content: Text(
                        'This removes the config and its stored traffic totals.',
                        style: Ember.body,
                      ),
                      actions: [
                        TextButton(
                          onPressed: () =>
                              Navigator.of(dialogContext).pop(false),
                          child: const Text(
                            'Cancel',
                            style: TextStyle(color: Ember.dim),
                          ),
                        ),
                        EmberButton(
                          label: 'Delete',
                          onTap: () => Navigator.of(dialogContext).pop(true),
                        ),
                      ],
                    ),
                  );
                  if (confirm != true || !context.mounted) return;
                  if (live) await xray.disconnect();
                  await xray.deleteProfile(p);
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The Accounts tab in WireGuard mode: no account — the
/// configs are the user's own files; session numbers instead.
class WireGuardAboutView extends StatelessWidget {
  const WireGuardAboutView({super.key, required this.xray});

  final XrayController xray;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: xray,
      builder: (context, _) {
        final count = wgProfilesOf(xray).length;
        final on = xray.state.running;
        final selected = xray.selected;
        return ListView(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
          children: [
            Center(child: Text('WireGuard', style: Ember.title)),
            Center(
              child: Text('Your own configs, no account', style: Ember.caption),
            ),
            const SizedBox(height: 16),
            MapGlass(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    on && selected != null
                        // Build 2045: the name the user sees.
                        ? 'Connected: ${selected.displayName}'
                        : 'Not connected',
                    style: Ember.heading,
                    // Build 2059 (audit §6 appearance low): the name
                    // can be long — ellipsis, never overflow.
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${latDigits(count)} WireGuard config${count == 1 ? '' : 's'} '
                    'in the store',
                    style: Ember.body,
                  ),
                  if (on &&
                      selected != null &&
                      selected.protocol == Protocol.wireguard) ...[
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
                          Text(
                            fmtBytes(xray.state.downBytes),
                            style: Ember.body,
                          ),
                          const SizedBox(width: 10),
                          const Icon(
                            Icons.arrow_upward_rounded,
                            size: 14,
                            color: Ember.dim,
                          ),
                          const SizedBox(width: 3),
                          Text(fmtBytes(xray.state.upBytes), style: Ember.body),
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
