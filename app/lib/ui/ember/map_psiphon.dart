/// The Psiphon page of the Map Control shell (2.1.0): the map
/// itself, the arc to the exit region, and the region chips
/// floating lower-left above the bottom bar — dark glass chips,
/// the chosen one orange-tinted with a border and a check.
/// State, exit and rates live in the shell's bottom bar. A
/// region picked mid-session applies on the next connect (the
/// hint line says so, in the core's own terms); a backend error
/// shows as a red line above the chips instead of failing
/// silently.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../psiphon/psiphon_controller.dart';
import 'ember_theme.dart';
import 'map_widgets.dart';
import 'psiphon_pages.dart' show regionName;

class MapPsiphonPage extends StatefulWidget {
  const MapPsiphonPage({super.key, required this.psiphon});

  final PsiphonController psiphon;

  @override
  State<MapPsiphonPage> createState() => _MapPsiphonPageState();
}

class _MapPsiphonPageState extends State<MapPsiphonPage> {
  /// The page's structural signature: the chips and the error
  /// line depend on the region choice and the core's region
  /// list, not on the session counters (the bar shows those).
  String _sig = '';

  @override
  void initState() {
    super.initState();
    widget.psiphon.addListener(_onTick);
  }

  @override
  void dispose() {
    widget.psiphon.removeListener(_onTick);
    super.dispose();
  }

  String _signature() {
    final psiphon = widget.psiphon;
    return [
      psiphon.settings.region,
      psiphon.state.regions.length,
      psiphon.state.connected,
      psiphon.lastError,
    ].join('|');
  }

  void _onTick() {
    if (!mounted) return;
    final next = _signature();
    if (next != _sig) {
      _sig = next;
      setState(() {});
    }
  }

  void _pick(String code) {
    final next = PsiphonSettings.fromJson(widget.psiphon.settings.toJson());
    next.region = code;
    unawaited(widget.psiphon.updateSettings(next));
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final psiphon = widget.psiphon;
    return Positioned(
      left: 24,
      bottom: 124,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if ((psiphon.lastError ?? '').isNotEmpty) ...[
              MapGlass(
                radius: 12,
                padding: const EdgeInsets.symmetric(
                  horizontal: 13,
                  vertical: 9,
                ),
                child: Text(
                  psiphon.lastError ?? '',
                  style: const TextStyle(fontSize: 12.5, color: MapUi.red),
                ),
              ),
              const SizedBox(height: 10),
            ],
            Wrap(
              spacing: 9,
              runSpacing: 9,
              children: [
                _RegionChip(
                  label: l.psiphonRegionAuto,
                  selected: psiphon.settings.region.isEmpty,
                  onTap: () => _pick(''),
                ),
                for (final code in psiphon.regionChoices)
                  _RegionChip(
                    label: regionName(code),
                    selected: psiphon.settings.region == code,
                    onTap: () => _pick(code),
                  ),
              ],
            ),
            const SizedBox(height: 9),
            Text(
              l.psiphonNextConnectHint,
              style: const TextStyle(fontSize: 11.5, color: MapUi.faint),
            ),
          ],
        ),
      ),
    );
  }
}

/// One region chip of the Psiphon page: 40 px dark glass; the
/// selected one is orange-tinted with the orange border and a
/// leading check (the EmberChip desktop treatment, at the
/// sample's chip height).
class _RegionChip extends StatelessWidget {
  const _RegionChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.transparent,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          gradient: selected ? MapUi.selectedGradient : null,
          color: selected ? null : MapUi.panelFillSoft,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? Ember.orange.withValues(alpha: 0.8) : MapUi.line,
            width: selected ? 1.2 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (selected) ...[
              const Icon(Icons.check_rounded, size: 15, color: Ember.orange),
              const SizedBox(width: 5),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
                color: selected ? MapUi.text : MapUi.dim,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
