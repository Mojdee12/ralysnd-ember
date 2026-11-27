/// Build 2095 (feature 11 — one-click connection presets):
/// Fastest / Random / Auto on the V2Ray home. Fastest is
/// the best MEASURED config in the active group (stored
/// delay, never a guess); Random picks among the measured-
/// alive; Auto is the standing smart behavior (connect the
/// selected config). The pickers are pure and unit-tested;
/// the card only wires them to the connect path.

import 'dart:math';

import 'package:flutter/material.dart';

import '../../xray/xray_controller.dart';
import '../../xray/xray_models.dart';
import 'ember_theme.dart';
import 'sandbox_test_sheet.dart';

/// The best measured config, or null when nothing in
/// [pool] has a successful delay measurement.
Profile? fastestIn(List<Profile> pool) {
  Profile? best;
  for (final p in pool) {
    if (p.delayMs < 0) continue;
    if (best == null || p.delayMs < best.delayMs) best = p;
  }
  return best;
}

/// A random measured-alive config; falls back to a random
/// not-known-dead one; null only for an empty pool.
Profile? randomAliveIn(List<Profile> pool, Random rng) {
  final alive = pool.where((p) => p.delayMs >= 0).toList();
  if (alive.isNotEmpty) return alive[rng.nextInt(alive.length)];
  final unknown = pool.where((p) => !p.delayFailed).toList();
  if (unknown.isNotEmpty) return unknown[rng.nextInt(unknown.length)];
  return null;
}

/// Build 2096 (post-2095 audit L10): the ordered candidate
/// lists the presets walk — Fastest tries the measured
/// pool best-first, Random a shuffled alive pool, so one
/// dead pick falls through to the next candidate instead
/// of ending the tap.
List<Profile> fastestCandidates(List<Profile> pool) {
  final measured = pool.where((p) => p.delayMs >= 0).toList()
    ..sort((a, b) => a.delayMs.compareTo(b.delayMs));
  return measured;
}

List<Profile> randomCandidates(List<Profile> pool, Random rng) {
  final alive = pool.where((p) => p.delayMs >= 0).toList()..shuffle(rng);
  if (alive.isNotEmpty) return alive;
  return pool.where((p) => !p.delayFailed).toList()..shuffle(rng);
}

/// The plain sentence for a preset failure — the raw
/// StateError text never reaches the snackbar.
String presetFailureText(Object error) {
  if (error is StateError) {
    switch (error.message) {
      case 'wg-all-peers-failed':
        return 'No peer of that config carried traffic.';
      case 'no-profile':
        return 'No config is selected.';
      case 'unsupported':
        return 'That config cannot run on this build.';
    }
  }
  return 'That config could not start — trying another is safe.';
}

class QuickPresetsCard extends StatelessWidget {
  const QuickPresetsCard({
    super.key,
    required this.xray,
    required this.stopOtherEngine,
  });

  final XrayController xray;
  final Future<void> Function() stopOtherEngine;

  List<Profile> get _pool {
    final sel = xray.selected;
    if (sel != null) {
      final group = xray.fallbackGroupMembers(sel);
      if (group.length > 1) return group;
    }
    return xray.profiles;
  }

  /// Build 2096 (post-2095 audit L10): walk the
  /// candidates — a failed pick falls through to the
  /// next one; only when every candidate fails does the
  /// tap report, in plain language, never raw error text.
  Future<void> _connect(
    BuildContext context,
    List<Profile> candidates,
    String what,
  ) async {
    if (candidates.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No $what config yet — run Test all first')),
      );
      return;
    }
    // Build 2097 (post-2096 audit L-h): the arbitration
    // stop sits INSIDE the guarded region — build 2096
    // awaited it before the try, so a throwing stop
    // escaped as an unhandled async error and the tap
    // silently did nothing.
    try {
      await stopOtherEngine();
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(presetFailureText(e))),
        );
      }
      return;
    }
    Object? lastError;
    for (final p in candidates) {
      try {
        await connectProfileFromTest(xray, p);
        return;
      } catch (e) {
        lastError = e;
      }
    }
    if (context.mounted && lastError != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(presetFailureText(lastError))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (xray.profiles.isEmpty) return const SizedBox.shrink();
    // Build 2145 (composition rebuild): the card container
    // is the hairline panel language now — a flat charcoal
    // fill with a single hairline rim, no glass. Contents
    // and callbacks are unchanged.
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: MapUi.card,
        borderRadius: BorderRadius.circular(Ember.radiusPanel),
        border: Border.all(color: MapUi.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Quick connect', style: Ember.heading.copyWith(fontSize: Ember.fontTitle)),
          const SizedBox(height: 4),
          Text(
            'One tap, no list digging.',
            style: Ember.caption,
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              EmberChip(
                label: 'Fastest',
                onTap: () => _connect(
                  context,
                  fastestCandidates(_pool),
                  'measured-fastest',
                ),
              ),
              EmberChip(
                label: 'Random',
                onTap: () => _connect(
                  context,
                  randomCandidates(_pool, Random()),
                  'alive',
                ),
              ),
              EmberChip(
                label: 'Auto',
                onTap: () => _connect(
                  context,
                  [if (xray.selected != null) xray.selected!],
                  'selected',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
