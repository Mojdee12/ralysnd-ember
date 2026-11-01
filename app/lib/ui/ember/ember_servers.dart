/// Servers: Mozilla mode lists the core's countries like mockup 3
/// (smart-pick card, flag rows, colored pings); V2Ray mode lists the
/// configs grouped by subscription like the approved V2Ray mockup —
/// same glass cards, same chips, nothing of v2rayNG's look.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/core_controller.dart';
import '../../core/models.dart';
import '../../features.dart';
import '../../l10n/app_localizations.dart';
import '../../xray/xray_controller.dart';
import '../../xray/xray_models.dart';
import 'ember_format.dart';
import 'ember_theme.dart';
import 'profile_editor.dart';
import 'qr_pages.dart';
import 'world_map.dart';

class EmberServers extends StatelessWidget {
  const EmberServers({
    super.key,
    required this.core,
    required this.xray,
    required this.v2ray,
    required this.onOpenAccounts,
  });

  final CoreController core;
  final XrayController xray;
  final bool v2ray;
  final VoidCallback onOpenAccounts;

  @override
  Widget build(BuildContext context) => v2ray
      ? _V2rayServers(xray: xray, onOpenAccounts: onOpenAccounts)
      : _MozillaServers(core: core);
}

// ---------------------------------------------------------------- Mozilla

class _MozillaServers extends StatefulWidget {
  const _MozillaServers({required this.core});
  final CoreController core;

  @override
  State<_MozillaServers> createState() => _MozillaServersState();
}

class _MozillaServersState extends State<_MozillaServers> {
  List<Location> _locations = [];
  bool _loading = true;
  bool _pinging = false;
  String _query = '';

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final list = await widget.core.call((api) => api.locations());
      if (mounted) {
        setState(() {
          _locations = list.locations;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _pingAll() async {
    setState(() => _pinging = true);
    try {
      final list = await widget.core.call(
        (api) => api.pingLocations([for (final l in _locations) l.code]),
      );
      if (mounted) setState(() => _locations = list.locations);
    } catch (_) {
      // The old numbers stay.
    } finally {
      if (mounted) setState(() => _pinging = false);
    }
  }

  Future<void> _pick(String code) async {
    try {
      await widget.core.call((api) => api.setLocation(code));
      await widget.core.refresh();
    } catch (_) {
      // The core answers the next poll with its own truth.
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final selection = widget.core.status?.selection ?? '';
    final shown = _locations.where((loc) {
      if (_query.isEmpty) return true;
      final q = _query.toLowerCase();
      return loc.name.toLowerCase().contains(q) ||
          loc.city.toLowerCase().contains(q) ||
          localizedCountryName(context, loc.code, loc.name)
              .toLowerCase()
              .contains(q);
    }).toList();

    return ListenableBuilder(
      listenable: widget.core,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 18),
        children: [
          Row(
            children: [
              const Icon(
                Icons.local_fire_department_rounded,
                color: Ember.orange,
                size: 24,
              ),
              const SizedBox(width: 8),
              Text(l.navServers, style: Ember.title),
              const Spacer(),
              IconButton(
                onPressed: _pinging ? null : _pingAll,
                icon: _pinging
                    ? const SizedBox(
                        width: 19,
                        height: 19,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Ember.orange,
                        ),
                      )
                    : const Icon(Icons.speed_rounded, color: Ember.dim),
                tooltip: l.pingAll,
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            onChanged: (v) => setState(() => _query = v),
            style: Ember.body,
            decoration: emberField(
              context,
              l.searchCountry,
              prefix: const Icon(Icons.search_rounded, color: Ember.faint, size: 20),
            ),
          ),
          const SizedBox(height: 16),
          Text(l.chooseServer, style: Ember.heading),
          Text(l.chooseServerSub, style: Ember.caption),
          const SizedBox(height: 12),
          // The smart pick (mockup 3).
          GlassCard(
            glow: selection == 'fastest',
            onTap: () => _pick('fastest'),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: const BoxDecoration(
                    gradient: Ember.gradient,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.bolt_rounded,
                    color: Color(0xFF1A1206),
                    size: 24,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(l.smartPick, style: Ember.heading),
                      Text(l.smartPickSub, style: Ember.caption),
                    ],
                  ),
                ),
                EmberChip(label: l.optimalChip, selected: selection == 'fastest'),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Text(l.allServers, style: Ember.heading),
          const SizedBox(height: 10),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 40),
              child: Center(child: CircularProgressIndicator(color: Ember.orange)),
            )
          else if (shown.isEmpty)
            EmberEmpty(icon: Icons.public_off_rounded, text: l.noServersFound)
          else
            for (final loc in shown) ...[
              _LocationRow(
                location: loc,
                selected: selection == loc.code ||
                    (selection.isEmpty && loc.recommended),
                onTap: () => _pick(loc.code),
              ),
              const SizedBox(height: 9),
            ],
        ],
      ),
    );
  }
}

class _LocationRow extends StatelessWidget {
  const _LocationRow({
    required this.location,
    required this.selected,
    required this.onTap,
  });
  final Location location;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final ms = location.pingMs;
    return GlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      glow: selected,
      onTap: onTap,
      child: Row(
        children: [
          FlagCircle(code: location.code, size: 40),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  localizedCountryName(context, location.code, location.name),
                  style: Ember.heading.copyWith(fontSize: 15),
                ),
                if (location.city.isNotEmpty)
                  Text(location.city, style: Ember.caption),
              ],
            ),
          ),
          if (ms > 0) ...[
            Icon(Icons.signal_cellular_alt_rounded, size: 16, color: pingColor(ms)),
            const SizedBox(width: 5),
            Text(
              '${latDigits(ms)} ${l.msUnit}',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: pingColor(ms),
              ),
            ),
            const SizedBox(width: 8),
          ],
          if (selected)
            Container(
              width: 26,
              height: 26,
              decoration: const BoxDecoration(
                gradient: Ember.gradient,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.check_rounded, color: Color(0xFF1A1206), size: 17),
            ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------ V2Ray

class _V2rayServers extends StatefulWidget {
  const _V2rayServers({required this.xray, required this.onOpenAccounts});
  final XrayController xray;
  final VoidCallback onOpenAccounts;

  @override
  State<_V2rayServers> createState() => _V2rayServersState();
}

class _V2rayServersState extends State<_V2rayServers> {
  String _query = '';
  Protocol? _filter;
  bool _testingAll = false;

  XrayController get xray => widget.xray;

  Future<void> _testAll() async {
    setState(() => _testingAll = true);
    try {
      await xray.testAllDelays();
    } finally {
      if (mounted) setState(() => _testingAll = false);
    }
  }

  List<Profile> _shown(Iterable<Profile> all) => all.where((p) {
        if (_filter != null && p.protocol != _filter) return false;
        if (_query.isEmpty) return true;
        final q = _query.toLowerCase();
        return p.name.toLowerCase().contains(q) ||
            p.address.toLowerCase().contains(q);
      }).toList();

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: xray,
      builder: (context, _) {
        final loose = _shown(xray.looseProfiles);
        return ListView(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 18),
          children: [
            Row(
              children: [
                const Icon(
                  Icons.local_fire_department_rounded,
                  color: Ember.orange,
                  size: 24,
                ),
                const SizedBox(width: 8),
                Text(l.navServers, style: Ember.title),
                const Spacer(),
                _RoundAction(
                  icon: Icons.content_paste_rounded,
                  tooltip: l.addByPaste,
                  onTap: () => showPasteSheet(context, xray),
                ),
                const SizedBox(width: 8),
                // Camera QR scanning has no Windows plugin in this
                // tree; desktop imports by paste or manual entry.
                if (!Features.desktopShell) ...[
                  _RoundAction(
                    icon: Icons.qr_code_scanner_rounded,
                    tooltip: l.addByQr,
                    onTap: () => unawaited(scanAndImport(context, xray)),
                  ),
                  const SizedBox(width: 8),
                ],
                _RoundAction(
                  icon: Icons.add_rounded,
                  tooltip: l.addManual,
                  onTap: () => unawaited(openProfileEditor(context, xray)),
                ),
              ],
            ),
            if (xray.profiles.isNotEmpty) ...[
              const SizedBox(height: 12),
              // The ping test for everything: a primary action at the
              // TOP of the page, not buried under the list.
              Row(
                children: [
                  Expanded(
                    child: EmberButton(
                      label: l.testAllDelays,
                      icon: Icons.speed_rounded,
                      // While a run is going the rows themselves show
                      // spinners; the button keeps its gradient face
                      // (EmberButton's disabled face is unreadable)
                      // and simply ignores taps.
                      onTap: _testingAll ? () {} : () => unawaited(_testAll()),
                    ),
                  ),
                  const SizedBox(width: 10),
                  PopupMenuButton<String>(
                    icon: const Icon(Icons.sort_rounded, color: Ember.dim),
                    color: Ember.card,
                    onSelected: (v) {
                      if (v == 'delay') xray.sortProfilesByDelay();
                      if (v == 'name') xray.sortProfilesByName();
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem(value: 'delay', child: Text(l.sortByDelay)),
                      PopupMenuItem(value: 'name', child: Text(l.sortByName)),
                    ],
                  ),
                ],
              ),
            ],
            const SizedBox(height: 12),
            const MapMotifStrip(),
            const SizedBox(height: 12),
            TextField(
              onChanged: (v) => setState(() => _query = v),
              style: Ember.body,
              decoration: emberField(
                context,
                l.searchConfig,
                prefix: const Icon(Icons.search_rounded, color: Ember.faint, size: 20),
              ),
            ),
            const SizedBox(height: 12),
            // The protocol chips (v2ray mockup 2).
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  EmberChip(
                    label: l.filterAll,
                    selected: _filter == null,
                    onTap: () => setState(() => _filter = null),
                  ),
                  const SizedBox(width: 7),
                  for (final proto in Protocol.values) ...[
                    EmberChip(
                      label: proto.label,
                      selected: _filter == proto,
                      onTap: () => setState(() => _filter = proto),
                    ),
                    const SizedBox(width: 7),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 14),
            if (xray.profiles.isEmpty)
              EmberEmpty(
                icon: Icons.dns_outlined,
                text: l.noProfilesYet,
                action: EmberButton(
                  label: l.addByPaste,
                  icon: Icons.content_paste_rounded,
                  onTap: () => showPasteSheet(context, xray),
                ),
              )
            else ...[
              if (loose.isNotEmpty)
                _Group(
                  xray: xray,
                  title: l.looseGroup,
                  profiles: loose,
                ),
              for (final sub in xray.subscriptions) ...[
                if (_shown(xray.profilesOf(sub)).isNotEmpty)
                  _Group(
                    xray: xray,
                    title: sub.name,
                    profiles: _shown(xray.profilesOf(sub)),
                    onRefresh: () => unawaited(_refreshSub(sub.id)),
                  ),
              ],
            ],
          ],
        );
      },
    );
  }

  Future<void> _refreshSub(String id) async {
    final sub = xray.subscriptions.where((s) => s.id == id).firstOrNull;
    if (sub == null) return;
    try {
      await xray.updateSubscription(sub);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).subUpdateFailed)),
        );
      }
    }
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

class _Group extends StatelessWidget {
  const _Group({
    required this.xray,
    required this.title,
    required this.profiles,
    this.onRefresh,
  });
  final XrayController xray;
  final String title;
  final List<Profile> profiles;
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: Ember.heading.copyWith(fontSize: 14.5),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                latDigits(profiles.length),
                style: Ember.caption,
              ),
              if (onRefresh != null)
                IconButton(
                  onPressed: onRefresh,
                  icon: const Icon(Icons.refresh_rounded, color: Ember.dim, size: 19),
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
          const SizedBox(height: 8),
          for (final p in profiles) ...[
            _ProfileRow(xray: xray, profile: p),
            const SizedBox(height: 9),
          ],
          const SizedBox(height: 6),
        ],
      );
}

class _ProfileRow extends StatelessWidget {
  const _ProfileRow({required this.xray, required this.profile});
  final XrayController xray;
  final Profile profile;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final selected = xray.selectedProfileId == profile.id;
    final testing = xray.isTesting(profile.id);
    return GlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      glow: selected,
      onTap: () => xray.select(profile),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        profile.name,
                        style: Ember.heading.copyWith(fontSize: 14.5),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    EmberChip(label: profile.protocol.label),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  maskHost(profile.address),
                  style: Ember.caption,
                  overflow: TextOverflow.ellipsis,
                ),
                if (profileHasTotals(profile)) ...[
                  const SizedBox(height: 3),
                  // The totals line is one fully-English LTR string;
                  // pin its direction so bidi never reorders it.
                  Directionality(
                    textDirection: TextDirection.ltr,
                    child: Text(
                      fmtProfileTotals(profile),
                      style: Ember.caption.copyWith(color: Ember.dim),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (testing && Features.desktopShell)
            const SizedBox(
              width: 88,
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Ember.orange),
                ),
              ),
            )
          else if (testing)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2, color: Ember.orange),
            )
          else if (profile.delayMs >= 0 && Features.desktopShell)
            _PingPill(ms: profile.delayMs, unit: l.msUnit)
          else if (profile.delayMs >= 0)
            Text(
              '${latDigits(profile.delayMs)} ${l.msUnit}',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: pingColor(profile.delayMs),
              ),
            )
          else if (profile.delayFailed && Features.desktopShell)
            const SizedBox(
              width: 88,
              child: Text(
                'Failed',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: Ember.red,
                ),
              ),
            )
          else if (profile.delayFailed)
            const Text(
              'Failed',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: Ember.red,
              ),
            )
          else if (!profile.protocol.supportedByCore)
            const Icon(Icons.block_rounded, size: 17, color: Ember.red),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert_rounded, color: Ember.faint, size: 20),
            color: Ember.card,
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
                child: Text(l.deleteProfile, style: const TextStyle(color: Ember.red)),
              ),
            ],
          ),
          if (selected)
            Container(
              width: 26,
              height: 26,
              decoration: const BoxDecoration(
                gradient: Ember.gradient,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.check_rounded, color: Color(0xFF1A1206), size: 17),
            ),
        ],
      ),
    );
  }

  Future<void> _act(BuildContext context, String action) async {
    final l = AppLocalizations.of(context);
    switch (action) {
      case 'delay':
        final ms = await xray.testDelay(profile);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(ms >= 0 ? '${l.delayTest}: ${latDigits(ms)} ${l.msUnit}' : l.testFailed),
          ));
        }
      case 'speed':
        final bps = await xray.testSpeed(profile);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(bps >= 0 ? '${l.speedTest}: ${fmtRate(bps)}' : l.testFailed),
          ));
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
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l.linkCopied)),
          );
        }
      case 'delete':
        await xray.deleteProfile(profile);
    }
  }
}

/// The desktop V2Ray list's ping column (the locked clean mockup):
/// a pill of one fixed width in every row, so the values form a
/// straight right-aligned column instead of the phone's bare text.
class _PingPill extends StatelessWidget {
  const _PingPill({required this.ms, required this.unit});

  final int ms;
  final String unit;

  @override
  Widget build(BuildContext context) {
    final color = pingColor(ms);
    return SizedBox(
      width: 88,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 5),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.16),
          border: Border.all(color: color.withValues(alpha: 0.5)),
          borderRadius: BorderRadius.circular(999),
        ),
        alignment: Alignment.center,
        child: Text(
          '${latDigits(ms)} $unit',
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w800,
            color: color,
          ),
        ),
      ),
    );
  }
}

class _RoundAction extends StatelessWidget {
  const _RoundAction({required this.icon, required this.tooltip, required this.onTap});
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: Material(
          color: Ember.card,
          shape: const CircleBorder(side: BorderSide(color: Ember.line)),
          child: InkWell(
            onTap: onTap,
            customBorder: const CircleBorder(),
            child: SizedBox(
              width: 40,
              height: 40,
              child: Icon(icon, color: Ember.orange, size: 20),
            ),
          ),
        ),
      );
}

/// host••• masking for config rows, as the mockup shows: the address is
/// not hidden, only shortened visually when long.
String maskHost(String address) {
  if (address.length <= 24) return address;
  return '${address.substring(0, 12)}…${address.substring(address.length - 6)}';
}
