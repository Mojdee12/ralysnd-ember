/// The Mozilla side of the Map Control shell (2.1.0): the map
/// itself is the page — a floating "Locations" glass button
/// under the brand panel opens the locations panel, an Accounts
/// button sits under it, and the TUN warning (when the chosen
/// mode cannot run) floats above the bottom bar. Connecting,
/// the exit, the quota — all of that lives in the shell's
/// bottom bar, exactly as the approved sample draws it.
///
/// The Servers panel is the sample's floating dark glass panel:
/// "Mozilla Locations", the Ping all chip, the dark inset
/// search, and 60 px rows — round flag, city over country, the
/// ping at the right in the frozen colors, the connected row
/// orange-tinted with the orange check circle. After Ping all
/// the rows sort fastest-first, failed last (display only).

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/core_controller.dart';
import '../../core/models.dart';
import '../../l10n/app_localizations.dart';
import '../connection_mode.dart';
import 'ember_format.dart';
import 'ember_theme.dart';
import 'map_widgets.dart';

/// The Mozilla home overlay of the Map shell.
class MapMozillaPage extends StatelessWidget {
  const MapMozillaPage({
    super.key,
    required this.core,
    required this.onOpenServers,
    required this.onOpenAccounts,
  });

  final CoreController core;
  final VoidCallback onOpenServers;
  final VoidCallback onOpenAccounts;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Stack(
      children: [
        // The floating actions under the brand panel.
        Positioned(
          left: 24,
          top: 84,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _MapActionButton(
                icon: Icons.public_rounded,
                label: 'Locations',
                onTap: onOpenServers,
              ),
              const SizedBox(height: 10),
              _MapActionButton(
                icon: Icons.people_rounded,
                label: l.navAccounts,
                onTap: onOpenAccounts,
              ),
            ],
          ),
        ),
        // The TUN note, when the chosen capture mode cannot run:
        // the same words (and Install action) the old desktop
        // home carried, as a warning chip above the bar.
        Positioned(
          left: 24,
          bottom: 216,
          child: ListenableBuilder(
            listenable: core,
            builder: (context, _) {
              final status = core.status;
              if (status == null) return const SizedBox.shrink();
              final note = tunNote(l, status);
              if (note == null) return const SizedBox.shrink();
              final busy = core.installingTun || core.removingTun;
              return MapGlass(
                radius: 14,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      note.problem
                          ? Icons.warning_amber_rounded
                          : Icons.info_outline_rounded,
                      size: 17,
                      color: Ember.warn,
                    ),
                    const SizedBox(width: 9),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 430),
                      child: Text(
                        note.text,
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: Ember.warn,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (note.install) ...[
                      const SizedBox(width: 8),
                      TextButton(
                        onPressed: busy
                            ? null
                            : () => installTunService(context, core),
                        child: Text(
                          note.again ? l.tunInstallAgain : l.tunInstall,
                        ),
                      ),
                    ],
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// A floating glass action button of the Mozilla page
/// (Locations / Accounts): icon, label, chevron.
class _MapActionButton extends StatelessWidget {
  const _MapActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => MapGlass(
    radius: 14,
    onTap: onTap,
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 19, color: Ember.orange),
        const SizedBox(width: 10),
        Text(
          label,
          style: const TextStyle(
            fontSize: 14.5,
            fontWeight: FontWeight.w600,
            color: MapUi.text,
          ),
        ),
        const SizedBox(width: 8),
        const Icon(Icons.chevron_right_rounded, size: 18, color: MapUi.faint),
      ],
    ),
  );
}

/// The floating Mozilla Locations panel (the Servers sample).
class MapServersPanel extends StatefulWidget {
  const MapServersPanel({super.key, required this.core, required this.onClose});

  final CoreController core;
  final VoidCallback onClose;

  @override
  State<MapServersPanel> createState() => _MapServersPanelState();
}

class _MapServersPanelState extends State<MapServersPanel> {
  List<Location> _locations = [];
  bool _loading = true;
  bool _pinging = false;
  String _query = '';

  /// Why the last delay test failed, when it did — a core refusal
  /// must not look exactly like "ping does nothing".
  String _pingError = '';

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
    setState(() {
      _pinging = true;
      _pingError = '';
    });
    try {
      final list = await widget.core.call(
        (api) => api.pingLocations([for (final l in _locations) l.code]),
      );
      // After a ping run the rows stand fastest-first, failed
      // last (display only; the core's order is untouched, and
      // the connected row keeps its highlight wherever it lands).
      if (mounted) {
        setState(() => _locations = sortedLocationsByPing(list.locations));
      }
    } catch (e) {
      if (mounted) setState(() => _pingError = e.toString());
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
    return Positioned(
      left: 24,
      top: 84,
      bottom: 216,
      width: 430,
      child: MapGlass(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
        child: ListenableBuilder(
          listenable: widget.core,
          builder: (context, _) {
            final selection = widget.core.status?.selection ?? '';
            final shown = _locations.where((loc) {
              if (_query.isEmpty) return true;
              final q = _query.toLowerCase();
              return loc.name.toLowerCase().contains(q) ||
                  loc.city.toLowerCase().contains(q) ||
                  localizedCountryName(
                    context,
                    loc.code,
                    loc.name,
                  ).toLowerCase().contains(q);
            }).toList();
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Mozilla Locations',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w600,
                          color: MapUi.text,
                        ),
                      ),
                    ),
                    MapGhostButton(
                      icon: Icons.speed_rounded,
                      label: l.pingAll,
                      busy: _pinging,
                      onTap: _pinging ? null : () => unawaited(_pingAll()),
                    ),
                    IconButton(
                      onPressed: widget.onClose,
                      icon: const Icon(
                        Icons.close_rounded,
                        size: 20,
                        color: MapUi.dim,
                      ),
                      visualDensity: VisualDensity.compact,
                      tooltip: MaterialLocalizations.of(context)
                          .closeButtonTooltip,
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
                    prefix: const Icon(
                      Icons.search_rounded,
                      color: MapUi.faint,
                      size: 20,
                    ),
                  ),
                ),
                // The smart pick, kept as the panel's first row:
                // one tap lets the core choose the fastest exit.
                const SizedBox(height: 12),
                _SmartPickRow(
                  selected: selection == 'fastest',
                  title: l.smartPick,
                  subtitle: l.smartPickSub,
                  chipLabel: l.optimalChip,
                  onTap: () => _pick('fastest'),
                ),
                if (_pingError.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      _pingError,
                      style: Ember.caption.copyWith(color: Ember.red),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                const SizedBox(height: 6),
                Expanded(
                  child: _loading
                      ? const Center(
                          child: CircularProgressIndicator(color: Ember.orange),
                        )
                      : shown.isEmpty
                      ? EmberEmpty(
                          icon: Icons.public_off_rounded,
                          text: l.noServersFound,
                        )
                      : ListView(
                          padding: EdgeInsets.zero,
                          children: [
                            for (var i = 0; i < shown.length; i++) ...[
                              if (i > 0)
                                const Divider(color: MapUi.line, height: 1),
                              _MapLocationRow(
                                location: shown[i],
                                selected:
                                    selection == shown[i].code ||
                                    (selection.isEmpty && shown[i].recommended),
                                onTap: () => _pick(shown[i].code),
                              ),
                            ],
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

/// The smart-pick row at the panel's head.
class _SmartPickRow extends StatelessWidget {
  const _SmartPickRow({
    required this.selected,
    required this.title,
    required this.subtitle,
    required this.chipLabel,
    required this.onTap,
  });

  final bool selected;
  final String title;
  final String subtitle;
  final String chipLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.transparent,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          gradient: selected ? MapUi.selectedGradient : null,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? Ember.orange.withValues(alpha: 0.55) : MapUi.line,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: const BoxDecoration(
                gradient: Ember.gradient,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.bolt_rounded,
                color: Color(0xFF1A1206),
                size: 21,
              ),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: MapUi.text,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: const TextStyle(fontSize: 12, color: MapUi.faint),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            EmberChip(label: chipLabel, selected: selected),
          ],
        ),
      ),
    ),
  );
}

/// One location row of the panel: 60 px — round flag 30, city
/// bold over country grey, the ping at the right in the frozen
/// colors (failed reads "Failed" in red); the connected row is
/// orange-tinted with the orange check circle.
class _MapLocationRow extends StatelessWidget {
  const _MapLocationRow({
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
    final country = localizedCountryName(context, location.code, location.name);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          height: 60,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            gradient: selected ? MapUi.selectedGradient : null,
            borderRadius: BorderRadius.circular(12),
            border: selected
                ? Border.all(color: Ember.orange.withValues(alpha: 0.45))
                : null,
          ),
          child: Row(
            children: [
              FlagCircle(code: location.code, size: 30),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      location.city.isEmpty ? country : location.city,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: MapUi.text,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (location.city.isNotEmpty)
                      Text(
                        country,
                        style: const TextStyle(
                          fontSize: 12.5,
                          color: MapUi.dim,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
              if (ms > 0)
                Text(
                  '${latDigits(ms)} ${l.msUnit}',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: mapPingColor(ms),
                  ),
                )
              else if (location.pingError.isNotEmpty)
                const Text(
                  'Failed',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: MapUi.red,
                  ),
                )
              else
                const Text(
                  '—',
                  style: TextStyle(fontSize: 14, color: MapUi.faint),
                ),
              if (selected) ...[
                const SizedBox(width: 10),
                Container(
                  width: 24,
                  height: 24,
                  decoration: const BoxDecoration(
                    gradient: Ember.gradient,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.check_rounded,
                    color: Colors.white,
                    size: 15,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
