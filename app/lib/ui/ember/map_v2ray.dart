/// The V2Ray page of the Map Control shell (2.1.0): a floating
/// configs panel at the left — "V2Ray CONFIGURATIONS", the
/// Import / Add / Test All ghost buttons, the dark inset search
/// field, and the configs as INDIVIDUAL dark glass sub-cards
/// (orange protocol tag, name, address line, the ping at the
/// right in the frozen colors; the selected card wears the
/// orange glow border). Connecting lives in the shell's bottom
/// bar; the panel's footer carries the backend's own
/// note/error words. All list behavior is the
/// accepted one: tap selects, the popup menu keeps every row
/// action, test-all auto-sorts (persisted) fastest-first.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../../xray/xray_controller.dart';
import '../../xray/xray_models.dart';
import 'ember_format.dart';
import 'ember_theme.dart';
import 'map_widgets.dart';
import 'profile_editor.dart';
import 'qr_pages.dart';

class MapV2rayPage extends StatefulWidget {
  const MapV2rayPage({super.key, required this.xray});

  final XrayController xray;

  @override
  State<MapV2rayPage> createState() => _MapV2rayPageState();
}

class _MapV2rayPageState extends State<MapV2rayPage> {
  String _query = '';
  bool _testingAll = false;

  XrayController get xray => widget.xray;

  /// The page's structural signature: everything the layout
  /// depends on EXCEPT the live rates and totals (those live in
  /// the shell's bottom bar now). The controller polls while
  /// connected; the panel (and its backdrop blur) rebuilds only
  /// when the signature changes.
  String _sig = '';

  @override
  void initState() {
    super.initState();
    xray.addListener(_onTick);
  }

  @override
  void dispose() {
    xray.removeListener(_onTick);
    super.dispose();
  }

  String _signature() => [
    xray.profiles.length,
    xray.selectedProfileId,
    xray.state.running,
    xray.state.name,
    xray.connecting,
    xray.lastError,
    for (final p in xray.profiles)
      '${p.id}:${p.name}:${p.delayMs}:${p.delayFailed}:${xray.isTesting(p.id)}',
  ].join('|');

  void _onTick() {
    if (!mounted) return;
    final next = _signature();
    if (next != _sig) {
      _sig = next;
      setState(() {});
    }
  }

  Future<void> _testAll() async {
    setState(() => _testingAll = true);
    try {
      await xray.testAllDelays();
    } finally {
      if (mounted) setState(() => _testingAll = false);
    }
  }

  /// "Keep only working" (build 2034 parity): removes every
  /// config whose last delay test failed; never-tested configs
  /// stay. Confirmed first — it deletes.
  Future<void> _keepOnlyWorking(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Ember.card,
        title: Text('Keep only working?', style: Ember.heading),
        content: Text(
          'Every config whose last delay test failed will be '
          'removed. Configs that were never tested stay.',
          style: Ember.body,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove failed'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final removed = await xray.keepOnlyWorking();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            removed > 0
                ? 'Removed $removed failed config${removed == 1 ? '' : 's'}'
                : 'Nothing to remove',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final q = _query.toLowerCase();
    final shown = xray.profiles.where((p) {
      if (q.isEmpty) return true;
      return p.name.toLowerCase().contains(q) ||
          p.address.toLowerCase().contains(q);
    }).toList();
    return Positioned(
      left: 24,
      top: 112,
      bottom: 124,
      width: 484,
      child: MapGlass(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'V2Ray CONFIGURATIONS',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.3,
                      color: MapUi.dim,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                MapGhostButton(
                  icon: Icons.download_rounded,
                  label: 'Import',
                  primary: false,
                  onTap: () => unawaited(showPasteSheet(context, xray)),
                ),
                MapGhostButton(
                  icon: Icons.add_rounded,
                  label: 'Add',
                  onTap: () => unawaited(openProfileEditor(context, xray)),
                ),
                if (xray.profiles.any((p) => p.delayFailed))
                  MapGhostButton(
                    icon: Icons.cleaning_services_rounded,
                    label: 'Keep working',
                    primary: false,
                    onTap: () => unawaited(_keepOnlyWorking(context)),
                  ),
                MapGhostButton(
                  icon: Icons.speed_rounded,
                  label: 'Test All',
                  busy: _testingAll,
                  onTap: xray.profiles.isEmpty
                      ? null
                      : () => unawaited(_testAll()),
                ),
              ],
            ),
            const SizedBox(height: 14),
            TextField(
              onChanged: (v) => setState(() => _query = v),
              style: Ember.body,
              decoration: emberField(
                context,
                l.searchConfig,
                prefix: const Icon(
                  Icons.search_rounded,
                  color: MapUi.faint,
                  size: 20,
                ),
              ),
            ),
            const SizedBox(height: 14),
            Expanded(
              child: xray.profiles.isEmpty
                  ? Center(child: Text(l.noProfilesYet, style: Ember.dimStyle))
                  : shown.isEmpty
                  ? Center(child: Text(l.noServersFound, style: Ember.dimStyle))
                  : ListView(
                      padding: EdgeInsets.zero,
                      children: [
                        for (var i = 0; i < shown.length; i++) ...[
                          if (i > 0) const SizedBox(height: 12),
                          _MapConfigRow(xray: xray, profile: shown[i]),
                        ],
                      ],
                    ),
            ),
            const SizedBox(height: 10),
            _FallbackGroupCard(xray: xray),
            _PanelFooter(xray: xray),
          ],
        ),
      ),
    );
  }
}

/// The selected config's fallback group (build 2035), in the
/// page's own section anatomy — caps micro-header, then rows.
/// Shows the group in failover order with each member's state
/// (active / tested delay / untested / cooling down) and the
/// on/off toggle; tapping a member selects it. Hidden when the
/// group has a single member: there is nothing to fall back to.
class _FallbackGroupCard extends StatelessWidget {
  const _FallbackGroupCard({required this.xray});
  final XrayController xray;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final sel = xray.selected;
    if (sel == null) return const SizedBox.shrink();
    final members = xray.fallbackGroupMembers(sel);
    if (members.length < 2) return const SizedBox.shrink();
    final groupName = xray.subscriptionOf(sel)?.name ?? l.looseGroup;
    final on = xray.settings.adaptiveFailover;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(
              Icons.alt_route_rounded,
              size: 14,
              color: Ember.orange,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                'FALLBACK GROUP — ${groupName.toUpperCase()}',
                style: const TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.6,
                  color: MapUi.dim,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Text(latDigits(members.length), style: Ember.caption),
            const SizedBox(width: 8),
            MapToggle(
              value: on,
              onChanged: (v) async {
                xray.settings.adaptiveFailover = v;
                await xray.save();
              },
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          on
              ? 'If a config dies, the next member takes over automatically'
              : 'Off — turn on to switch to the next member automatically',
          style: const TextStyle(fontSize: 11, color: MapUi.dim),
        ),
        const SizedBox(height: 8),
        for (final p in members) ...[
          _FallbackMemberRow(
            xray: xray,
            profile: p,
            active: p.id == xray.selectedProfileId,
          ),
          const SizedBox(height: 6),
        ],
        const SizedBox(height: 8),
      ],
    );
  }
}

class _FallbackMemberRow extends StatelessWidget {
  const _FallbackMemberRow({
    required this.xray,
    required this.profile,
    required this.active,
  });
  final XrayController xray;
  final Profile profile;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final coolingDown = xray.isCoolingDown(profile.id);
    final status = coolingDown
        ? 'Cooling down'
        : profile.delayMs >= 0
        ? '${latDigits(profile.delayMs)}ms'
        : profile.delayFailed
        ? 'Failed'
        : 'Untested';
    final statusColor = coolingDown || profile.delayFailed
        ? Ember.red
        : profile.delayMs >= 0
        ? mapPingColor(profile.delayMs)
        : MapUi.dim;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => xray.select(profile),
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
          child: Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: active
                      ? Ember.orange
                      : coolingDown
                      ? Ember.red
                      : MapUi.faint,
                ),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  profile.name,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                    color: active ? Ember.orange : MapUi.text,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (active)
                const Padding(
                  padding: EdgeInsets.only(right: 8),
                  child: Text(
                    'ACTIVE',
                    style: TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.8,
                      color: Ember.orange,
                    ),
                  ),
                ),
              Text(
                status,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: statusColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The panel's footer line: the last error in red, the
/// backend's note, or the config count while idle — the words
/// the old status bar carried. (No session clock: the approved
/// samples' panel face carries none.)
class _PanelFooter extends StatelessWidget {
  const _PanelFooter({required this.xray});

  final XrayController xray;

  @override
  Widget build(BuildContext context) {
    final state = xray.state;
    final error = xray.lastError;
    if (error != null && error.isNotEmpty) {
      return Text(
        error,
        style: const TextStyle(fontSize: 12, color: MapUi.red),
        overflow: TextOverflow.ellipsis,
      );
    }
    if (state.note.isNotEmpty) {
      return Text(
        state.note,
        style: const TextStyle(fontSize: 12, color: MapUi.faint),
        overflow: TextOverflow.ellipsis,
      );
    }
    if (!state.running) {
      return Text(
        '${latDigits(xray.profiles.length)} configs',
        style: const TextStyle(fontSize: 12, color: MapUi.faint),
      );
    }
    return const SizedBox.shrink();
  }
}

/// One config sub-card: orange protocol tag, name + address,
/// the ping at the right; the selected card is orange-tinted
/// with the glow border, and the running one adds the check.
/// Tap selects; the popup menu keeps the phone row's actions.
class _MapConfigRow extends StatelessWidget {
  const _MapConfigRow({required this.xray, required this.profile});

  final XrayController xray;
  final Profile profile;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final selected = xray.selectedProfileId == profile.id;
    final running = xray.state.running && selected;
    final transport = switch (profile.network) {
      'ws' => 'WS',
      'grpc' => 'gRPC',
      'httpupgrade' => 'HTTPUpgrade',
      'xhttp' => 'XHTTP',
      'h2' || 'http' => 'HTTP',
      'kcp' => 'KCP',
      'quic' => 'QUIC',
      _ => 'TCP',
    };
    final security = switch (profile.security) {
      'tls' => 'TLS',
      'reality' => 'Reality',
      _ => 'None',
    };
    final subtitle =
        '${profile.address}:${latDigits(profile.port)} • $transport • $security';
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => xray.select(profile),
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          decoration: BoxDecoration(
            // The selected row, softened toward the samples
            // (fidelity round 3): a gentle warm wash falling
            // down the card, the #FF9445 hairline, and a low
            // ember bloom instead of the hard wireframe glow.
            gradient: selected
                ? const LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0x33FF8533), Color(0x14FF8533)],
                  )
                : null,
            color: selected ? null : Colors.white.withValues(alpha: 0.055),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected ? const Color(0xFFFF9445) : MapUi.lineStrong,
              width: selected ? 1.2 : 1,
            ),
            boxShadow: selected
                ? [
                    const BoxShadow(
                      color: Color(0x33E65A1E),
                      blurRadius: 12,
                      spreadRadius: -1,
                    ),
                  ]
                : const [],
          ),
          child: Row(
            children: [
              // The protocol tag: the sample's small rust chip —
              // ~38×20, radius 4, deep fill, rust border, peach
              // bold text.
              Container(
                constraints: const BoxConstraints(minWidth: 38),
                height: 20,
                padding: const EdgeInsets.symmetric(horizontal: 7),
                decoration: BoxDecoration(
                  color: const Color(0xFF2A1610),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: const Color(0xFF7A321A)),
                ),
                alignment: Alignment.center,
                child: Text(
                  profile.protocol.label,
                  style: const TextStyle(
                    fontSize: 9.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.4,
                    color: Color(0xFFFFAE85),
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      profile.name,
                      style: const TextStyle(
                        fontSize: 15.5,
                        fontWeight: FontWeight.w600,
                        color: MapUi.text,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      style: const TextStyle(fontSize: 12.5, color: MapUi.dim),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              _RowPing(
                xray: xray,
                profile: profile,
                unit: l.msUnit,
                inActiveRow: selected,
              ),
              PopupMenuButton<String>(
                icon: const Icon(
                  Icons.more_vert_rounded,
                  color: MapUi.faint,
                  size: 20,
                ),
                color: const Color(0xFF16233A),
                onSelected: (v) => unawaited(_act(context, v)),
                itemBuilder: (_) => [
                  PopupMenuItem(value: 'delay', child: Text(l.delayTest)),
                  PopupMenuItem(value: 'speed', child: Text(l.speedTest)),
                  PopupMenuItem(value: 'edit', child: Text(l.editProfile)),
                  PopupMenuItem(value: 'duplicate', child: Text(l.duplicate)),
                  PopupMenuItem(value: 'resetStats', child: Text(l.resetStats)),
                  PopupMenuItem(value: 'qr', child: Text(l.shareQr)),
                  PopupMenuItem(value: 'copy', child: Text(l.copyLink)),
                  PopupMenuItem(
                    value: 'delete',
                    child: Text(
                      l.deleteProfile,
                      style: const TextStyle(color: MapUi.red),
                    ),
                  ),
                ],
              ),
              if (running)
                const Icon(
                  Icons.check_circle_rounded,
                  size: 20,
                  color: MapUi.pingGreen,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _act(BuildContext context, String action) async {
    final l = AppLocalizations.of(context);
    switch (action) {
      case 'delay':
        final ms = await xray.testDelay(profile);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                ms >= 0
                    ? '${l.delayTest}: ${latDigits(ms)} ${l.msUnit}'
                    : l.testFailed,
              ),
            ),
          );
        }
      case 'speed':
        final bps = await xray.testSpeed(profile);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                bps >= 0 ? '${l.speedTest}: ${fmtRate(bps)}' : l.testFailed,
              ),
            ),
          );
        }
      case 'edit':
        await openProfileEditor(context, xray, existing: profile);
      case 'duplicate':
        await xray.duplicateProfile(profile);
      case 'resetStats':
        await xray.resetProfileStats(profile);
      case 'qr':
        await showProfileQr(context, profile);
      case 'copy':
        await Clipboard.setData(ClipboardData(text: profileLinkOf(profile)));
        if (context.mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(l.linkCopied)));
        }
      case 'delete':
        await xray.deleteProfile(profile);
    }
  }
}

/// The row's ping: a spinner while testing, the measured value
/// in the frozen colors, "Failed" in red, an em dash before the
/// first test. In the ACTIVE row only, the green softens to the
/// samples' mint (#3CD070 family) — same hue, same ≤150 rule
/// (fidelity round 3, per the brief's arbitration).
class _RowPing extends StatelessWidget {
  const _RowPing({
    required this.xray,
    required this.profile,
    required this.unit,
    this.inActiveRow = false,
  });

  final XrayController xray;
  final Profile profile;
  final String unit;
  final bool inActiveRow;

  @override
  Widget build(BuildContext context) {
    if (xray.isTesting(profile.id)) {
      return const SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: 2, color: Ember.orange),
      );
    }
    if (profile.delayMs >= 0) {
      return Text(
        '${latDigits(profile.delayMs)} $unit',
        style: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w700,
          color: inActiveRow && profile.delayMs <= 150
              ? const Color(0xFF3CD070)
              : mapPingColor(profile.delayMs),
        ),
      );
    }
    if (profile.delayFailed) {
      return const Text(
        'Failed',
        style: TextStyle(
          fontSize: 13.5,
          fontWeight: FontWeight.w700,
          color: MapUi.red,
        ),
      );
    }
    return const Text('—', style: TextStyle(fontSize: 14, color: MapUi.faint));
  }
}
