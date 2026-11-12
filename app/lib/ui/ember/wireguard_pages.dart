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
import '../../xray/xray_controller.dart';
import '../../xray/xray_models.dart';
import 'ember_format.dart';
import 'ember_theme.dart';
import 'map_widgets.dart';

List<Profile> wgProfilesOf(XrayController xray) =>
    xray.profiles.where((p) => p.protocol == Protocol.wireguard).toList();

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
        const SizedBox(height: 150),
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
                      on && wgSelected != null
                          ? 'Connected'
                          : 'WireGuard',
                      style: Ember.heading,
                    ),
                  ),
                  const Icon(Icons.chevron_right_rounded, color: MapUi.faint),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                wgSelected != null
                    ? '${wgSelected.name} • ${wgSelected.address}:${wgSelected.port}'
                    : count > 0
                    ? '$count WireGuard config${count == 1 ? '' : 's'} — '
                          'pick one in the configurations panel.'
                    : 'No WireGuard configs yet — import a .conf file '
                          'or a wireguard:// link in the configurations '
                          'panel.',
                style: Ember.body,
              ),
              if (on && wgSelected != null && xray.exitInfo != null) ...[
                const SizedBox(height: 6),
                Text(
                  'Exit: ${xray.exitInfo!.line}',
                  style: Ember.caption,
                ),
              ],
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
                '(peer fallback). AmneziaWG configs import as '
                'plain WireGuard: the Xray core has no AmneziaWG '
                'obfuscation, and the import says so when it sees '
                'one.',
                style: Ember.caption,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The configurations panel in WireGuard mode: import actions
/// on top, then the WireGuard profiles with delay + exit data
/// and the fallback connect.
class WireGuardServersView extends StatelessWidget {
  const WireGuardServersView({
    super.key,
    required this.xray,
    this.onClose,
  });

  final XrayController xray;
  final VoidCallback? onClose;

  Future<void> _importConf(BuildContext context) async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (!context.mounted) return;
    // The gate speaks the parser's language (build 2033):
    // section names are case-insensitive there, so a file
    // whose header reads [interface] must pass here too —
    // the pre-2033 case-sensitive check refused files the
    // parser itself would have accepted.
    if (text.isEmpty || !text.toLowerCase().contains('[interface]')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Copy a .conf file\u2019s text first, then tap import',
          ),
        ),
      );
      return;
    }
    final name = await _askName(context);
    if (name == null || !context.mounted) return;
    final result = parseWgConf(
      text,
      baseName: name,
      idFor: newProfileId,
    );
    if (!result.ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Not a WireGuard config: ${result.error}')),
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
            'Imported ${result.profiles.length} config'
            '${result.profiles.length == 1 ? '' : 's'}'
            '${result.amnezia ? ' — AmneziaWG parameters found: imported as plain WireGuard (the core cannot do AmneziaWG obfuscation)' : ''}',
          ),
        ),
      );
    }
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
            r.added > 0
                ? 'Imported ${r.added} config${r.added == 1 ? '' : 's'}'
                : (r.errors.isNotEmpty
                      ? r.errors.first
                      : 'Nothing importable in the clipboard'),
          ),
        ),
      );
    }
  }

  Future<String?> _askName(BuildContext context) async {
    final controller = TextEditingController(text: 'WireGuard');
    try {
      return await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: Ember.card,
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
              onPressed: () =>
                  Navigator.of(context).pop(controller.text.trim()),
              child: const Text('Import'),
            ),
          ],
        ),
      );
    } finally {
      controller.dispose();
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
              e.message == 'wg-all-peers-failed'
                  ? 'No peer of this config carried traffic — '
                        'the endpoints may be filtered or down'
                  : e.message,
            ),
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
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
                        IconButton(
                          onPressed: onClose,
                          icon: const Icon(
                            Icons.close_rounded,
                            color: MapUi.dim,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      OutlinedButton.icon(
                        onPressed: () => _importConf(context),
                        icon: const Icon(
                          Icons.content_paste_rounded,
                          size: 17,
                        ),
                        label: const Text('Paste .conf'),
                      ),
                      OutlinedButton.icon(
                        onPressed: () => _importLink(context),
                        icon: const Icon(Icons.link_rounded, size: 17),
                        label: const Text('Paste link'),
                      ),
                    ],
                  ),
                  if (profiles.isEmpty) ...[
                    const SizedBox(height: 10),
                    Text(
                      'Nothing here yet. A .conf from any WireGuard '
                      'provider works; several peers in one file '
                      'become a fallback group.',
                      style: Ember.caption,
                    ),
                  ],
                ],
              ),
            ),
            for (final entry in groups.entries) ...[
              if (entry.value.length > 1) ...[
                const SizedBox(height: 14),
                Text(
                  '${entry.value.first.name.split(' · ').first} — '
                  '${entry.value.length} peers, fallback on',
                  style: Ember.caption,
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
                      p.name,
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
                const EmberChip(
                  label: 'AmneziaWG stored — runs as plain WireGuard',
                ),
              if (profileHasTotals(p))
                EmberChip(label: fmtProfileTotals(p)),
              EmberChip(
                label: 'Delete',
                onTap: () async {
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
              child: Text(
                'Your own configs, no account',
                style: Ember.caption,
              ),
            ),
            const SizedBox(height: 16),
            MapGlass(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    on && selected != null
                        ? 'Connected: ${selected.name}'
                        : 'Not connected',
                    style: Ember.heading,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '$count WireGuard config${count == 1 ? '' : 's'} '
                    'in the store',
                    style: Ember.body,
                  ),
                  if (on &&
                      selected != null &&
                      selected.protocol == Protocol.wireguard) ...[
                    const SizedBox(height: 6),
                    Directionality(
                      textDirection: TextDirection.ltr,
                      child: Text(
                        '↓ ${fmtBytes(xray.state.downBytes)} · '
                        '↑ ${fmtBytes(xray.state.upBytes)}',
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
