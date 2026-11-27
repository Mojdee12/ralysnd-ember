/// Shared Ember dialog helpers (build 2092, UI audit 2026-11-16
/// batch 1): one confirm dialog and one scrollable form-dialog
/// scaffold, so every surface asks and scrolls the same way —
/// the pattern the Xray log viewer's confirm-then-clear set in
/// build 2074 (audit item 8/18 family).

import 'package:flutter/material.dart';

import 'ember_theme.dart';

/// The app's one confirmation dialog: [title], a plain [message]
/// (callers name the thing being acted on), a dim Cancel and an
/// orange [confirmLabel]. Returns true only on confirm.
///
/// Used for destructive or hard-to-undo actions (profile/account
/// deletes, identity resets, cache forgets, log clears) — the
/// surfaces that used to fire on a single tap (UI audit items
/// 6, 7, 25, 26, 27, 50, 51).
Future<bool> showEmberConfirm(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  String cancelLabel = 'Cancel',
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      // Build 2150 (audit E49-15): the panel radius and
      // hairline, matching the dialog theme's new shape.
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Ember.radiusPanel),
        side: const BorderSide(color: Ember.line),
      ),
      title: Text(title, style: Ember.heading),
      content: Text(message, style: Ember.dimStyle),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(cancelLabel, style: const TextStyle(color: Ember.dim)),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(
            confirmLabel,
            style: const TextStyle(color: Ember.orange),
          ),
        ),
      ],
    ),
  );
  return confirmed == true;
}

/// The app's one scrollable form-dialog scaffold (UI audit
/// items 9, 31, 45): an [AlertDialog] whose content scrolls, so
/// on short or landscape screens — or with the keyboard up —
/// the actions stay reachable instead of being pushed
/// off-screen by a fixed Column. [content] is the caller's
/// form body; [actions] are the dialog's buttons.
Future<T?> showEmberFormDialog<T>(
  BuildContext context, {
  required String title,
  required Widget content,
  required List<Widget> actions,
}) => showDialog<T>(
  context: context,
  builder: (dialogContext) => AlertDialog(
    // Build 2150 (audit E49-15): as showEmberConfirm above.
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(Ember.radiusPanel),
      side: const BorderSide(color: Ember.line),
    ),
    title: Text(title, style: Ember.heading),
    scrollable: true,
    content: content,
    actions: actions,
  ),
);
