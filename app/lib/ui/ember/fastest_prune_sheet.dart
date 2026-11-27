// The "keep only the fastest N" confirmation sheet (build 2076,
// feature queue #6): prune a group — or the servers list's
// visible configs — to its fastest N by stored delay, in the
// Map Control sheet language of the 2061 sandbox verdict sheet
// (surface + 26 px top radius, Ember.heading title, GlassCard
// rows, EmberButton primary action, plain-words warning). Never
// a bare Material dialog. The plan is computed pure before
// anything is deleted, so the sheet states exact counts first;
// Confirm deletes only the plan's removed profiles.

import 'package:flutter/material.dart';

import '../../xray/xray_controller.dart';
import '../../xray/xray_models.dart';
import 'ember_format.dart';
import 'ember_theme.dart';

/// Shows the keep-fastest sheet for [scope] (the group or the
/// visible list the Test All just covered) and returns how many
/// profiles were removed, or null when nothing was pruned.
/// [onRunTestAll] starts a Test All over the same scope when the
/// sheet finds no results to rank yet.
Future<int?> showFastestPruneSheet(
  BuildContext context, {
  required XrayController xray,
  required List<Profile> scope,
  required String scopeName,
  String? restoreNote,
  Future<void> Function()? onRunTestAll,
}) {
  return showModalBottomSheet<int>(
    context: context,
    // Build 2074 (audit item 16): scroll-controlled, with a
    // scrollable body — the counts + kept names + warning must
    // not clip on small screens.
    isScrollControlled: true,
    backgroundColor: Ember.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
    ),
    builder: (sheetContext) => SafeArea(
      child: FastestPruneSheet(
        scopeName: scopeName,
        restoreNote: restoreNote,
        planFor: (n) => xray.planFastestPruneFor(scope, n),
        onConfirm: (plan) => xray.applyFastestPrune(plan),
        onRunTestAll: onRunTestAll,
      ),
    ),
  );
}

/// The sheet body, kept separate from [showFastestPruneSheet]
/// so widget tests can pump it directly with fake plans.
class FastestPruneSheet extends StatefulWidget {
  const FastestPruneSheet({
    super.key,
    required this.scopeName,
    this.restoreNote,
    required this.planFor,
    required this.onConfirm,
    this.onRunTestAll,
  });

  final String scopeName;
  final String? restoreNote;
  final FastestPrunePlan Function(int n) planFor;
  final Future<int> Function(FastestPrunePlan plan) onConfirm;
  final Future<void> Function()? onRunTestAll;

  @override
  State<FastestPruneSheet> createState() => _FastestPruneSheetState();
}

class _FastestPruneSheetState extends State<FastestPruneSheet> {
  int _n = 5;

  /// Build 2092 (item 8): the deletion shows busy and the
  /// sheet cannot be dismissed out from under it.
  bool _busy = false;

  Future<void> _confirm(FastestPrunePlan plan) async {
    if (_busy) return;
    setState(() => _busy = true);
    final removed = await widget.onConfirm(plan);
    if (mounted) Navigator.of(context).pop(removed);
  }

  @override
  Widget build(BuildContext context) {
    final plan = widget.planFor(_n);
    return PopScope(
      canPop: !_busy,
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.content_cut_rounded,
                    size: 22,
                    color: Ember.orange,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Keep only the fastest',
                      style: Ember.heading.copyWith(
                        fontSize: Ember.fontHeadline,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.only(left: 32),
                child: Text(
                  '${widget.scopeName} · ${latDigits(plan.scopeTotal)} configs',
                  style: Ember.body.copyWith(color: Ember.dim),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 6,
                children: [
                  for (final n in const [3, 5, 10])
                    EmberChip(
                      label: latDigits(n),
                      compact: true,
                      selected: _n == n,
                      onTap: () => setState(() => _n = n),
                    ),
                ],
              ),
              const SizedBox(height: 14),
              switch (plan.state) {
                FastestPruneState.ready => _ReadyBody(
                  plan: plan,
                  restoreNote: widget.restoreNote,
                  busy: _busy,
                  onConfirm: () => _confirm(plan),
                ),
                FastestPruneState.noResults => _NotReadyBody(
                  text:
                      'No test results yet in this scope — run Test All '
                      'to measure every config first. Pruning without '
                      'results would delete configs blind.',
                  onRunTestAll: widget.onRunTestAll == null
                      ? null
                      : () async {
                          Navigator.of(context).pop();
                          await widget.onRunTestAll!();
                        },
                ),
                FastestPruneState.nothingToPrune => _NotReadyBody(
                  text: _nothingToPruneReason(plan),
                  onRunTestAll: widget.onRunTestAll == null
                      ? null
                      : () async {
                          Navigator.of(context).pop();
                          await widget.onRunTestAll!();
                        },
                ),
              },
              const SizedBox(height: 8),
              Center(
                child: TextButton(
                  // Build 2092 (item 8): Cancel is disabled
                  // while the deletion runs.
                  onPressed: _busy ? null : () => Navigator.of(context).pop(),
                  child: Text(
                    'Cancel',
                    style: Ember.body.copyWith(color: Ember.dim),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _nothingToPruneReason(FastestPrunePlan plan) {
    if (plan.eligibleCount < plan.testedCount) {
      return 'Only ${latDigits(plan.eligibleCount)} tested configs '
          'can be kept — the rest exit in excluded countries, so '
          'there is nothing to prune.';
    }
    if (plan.testedCount < plan.scopeTotal) {
      return 'Only ${latDigits(plan.testedCount)} of '
          '${latDigits(plan.scopeTotal)} configs have test results '
          '— the fastest ${latDigits(plan.n)} cannot be picked '
          'from that alone. Run Test All to measure the rest first.';
    }
    return 'Only ${latDigits(plan.scopeTotal)} configs in this '
        'scope — already within the fastest ${latDigits(plan.n)}.';
  }
}

/// The ready state's body: the counts, the kept names, the
/// active-profile note, the warning, and the Remove action.
class _ReadyBody extends StatelessWidget {
  const _ReadyBody({
    required this.plan,
    required this.restoreNote,
    required this.onConfirm,
    this.busy = false,
  });

  /// Build 2092 (item 8): the deletion is in flight.
  final bool busy;

  final FastestPrunePlan plan;
  final String? restoreNote;
  final Future<void> Function() onConfirm;

  @override
  Widget build(BuildContext context) {
    final keptNames = plan.keep.take(5).map((p) => p.displayName).join(' · ');
    final keptCaption = plan.keep.length > 5
        ? '$keptNames · and ${latDigits(plan.keep.length - 5)} more'
        : keptNames;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GlassCard(
          child: Column(
            children: [
              _Row(
                label: 'Keep',
                value: '${latDigits(plan.keep.length)} configs',
                caption: keptCaption.isEmpty ? null : keptCaption,
              ),
              const SizedBox(height: 10),
              _Row(
                label: 'Remove',
                value: '${latDigits(plan.remove.length)} configs',
                caption: plan.untestedRemoved > 0
                    ? '${latDigits(plan.untestedRemoved)} of them '
                          'never tested'
                    : null,
              ),
              const SizedBox(height: 10),
              _Row(
                label: 'Tested',
                value:
                    '${latDigits(plan.testedCount)} / '
                    '${latDigits(plan.scopeTotal)}',
              ),
            ],
          ),
        ),
        if (plan.activeKeptOutsideN != null) ...[
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                Icons.info_outline_rounded,
                size: 16,
                color: Ember.orange,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '"${plan.activeKeptOutsideN!.displayName}" is the '
                  'active config — it stays even though it is '
                  'outside the fastest ${latDigits(plan.n)}.',
                  style: Ember.body,
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 12),
        Text(
          'This deletes the removed profiles from this device '
          'and cannot be undone.'
          '${restoreNote == null ? '' : ' $restoreNote'}',
          style: Ember.body,
        ),
        const SizedBox(height: 16),
        EmberButton(
          label: busy ? 'Removing…' : 'Remove ${latDigits(plan.remove.length)}',
          icon: Icons.delete_rounded,
          onTap: busy ? null : () => onConfirm(),
        ),
      ],
    );
  }
}

/// A non-ready state's body: the reason, and Run Test All when
/// the caller offers it.
class _NotReadyBody extends StatelessWidget {
  const _NotReadyBody({required this.text, required this.onRunTestAll});

  final String text;
  final Future<void> Function()? onRunTestAll;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      GlassCard(child: Text(text, style: Ember.body)),
      if (onRunTestAll != null) ...[
        const SizedBox(height: 16),
        EmberButton(
          label: 'Run Test All',
          icon: Icons.speed_rounded,
          onTap: () => onRunTestAll!(),
        ),
      ],
    ],
  );
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.value, this.caption});

  final String label;
  final String value;
  final String? caption;

  @override
  // Build 2092 (item 57): the summary rows carry the
  // 48 dp floor, and the kept-names caption is capped at
  // two lines instead of growing the card without bound.
  Widget build(BuildContext context) => Container(
    constraints: const BoxConstraints(minHeight: 48),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Text(label, style: Ember.body.copyWith(color: Ember.dim)),
        ),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(value, style: Ember.body),
              if (caption != null)
                Text(
                  caption!,
                  style: Ember.body.copyWith(
                    color: Ember.dim,
                    fontSize: Ember.fontSmall,
                  ),
                  textAlign: TextAlign.right,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
            ],
          ),
        ),
      ],
    ),
  );
}
