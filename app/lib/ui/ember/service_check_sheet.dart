/// The service reachability result sheet (build 2091): one
/// isolated-core verdict per service for a config, in the Map
/// Control sheet language — the same shape as the sandbox test
/// sheet (surface + 26 px top radius, GlassCard rows, Connect
/// when the check ran). The check itself never touches the live
/// tunnel: it runs in a throwaway core on a free port.
///
/// The sheet says "Reachable" / "No answer", never "loads":
/// a HEAD answer proves reachability through the node, not a
/// full page load.

import 'package:flutter/material.dart';

import '../../net/service_check.dart';
import '../../xray/xray_models.dart';
import 'ember_format.dart';
import 'ember_theme.dart';

/// Shows the service check result for [profile]: a bottom
/// sheet in the same shape as the sandbox test sheet.
/// [onConnect] runs when the user taps Connect; the caller
/// owns its errors (StateError → SnackBar, as the editor
/// does). No Connect button when the check failed or no
/// callback is given.
Future<void> showServiceCheckSheet(
  BuildContext context, {
  required Profile profile,
  required ServiceCheckResult result,
  Future<void> Function()? onConnect,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Ember.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
    ),
    builder: (sheetContext) => SafeArea(
      child: ServiceCheckSheet(
        profile: profile,
        result: result,
        onConnect: onConnect == null
            ? null
            : () async {
                Navigator.of(sheetContext).pop();
                await onConnect();
              },
      ),
    ),
  );
}

/// The sheet body, kept separate from [showServiceCheckSheet]
/// so widget tests can pump it directly.
class ServiceCheckSheet extends StatelessWidget {
  const ServiceCheckSheet({
    super.key,
    required this.profile,
    required this.result,
    this.onConnect,
  });

  final Profile profile;
  final ServiceCheckResult result;
  final Future<void> Function()? onConnect;

  @override
  Widget build(BuildContext context) {
    final all = result.allReachable;
    final none = result.noneReachable;
    final color = !result.ok
        ? Ember.red
        : all
        ? Ember.green
        : none
        ? Ember.red
        : Ember.warn;
    final icon = !result.ok || none
        ? Icons.error_rounded
        : all
        ? Icons.check_circle_rounded
        : Icons.warning_rounded;
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 22, color: color),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Services through this node',
                    style: Ember.heading.copyWith(fontSize: Ember.fontHeadline),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(left: 32),
              child: Text(
                profile.displayName,
                style: Ember.body.copyWith(color: Ember.dim),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(left: 32),
              child: Text(
                'Isolated test — the live tunnel is untouched.',
                style: Ember.body.copyWith(color: Ember.dim, fontSize: Ember.fontSmall),
              ),
            ),
            const SizedBox(height: 14),
            GlassCard(
              child: Column(
                children: [
                  // Build 2092 (item 57): an explicit empty
                  // state instead of an empty card.
                  if (result.entries.isEmpty)
                    Text('No services were checked.', style: Ember.body),
                  for (var i = 0; i < result.entries.length; i++) ...[
                    if (i > 0) const SizedBox(height: 10),
                    _ServiceRow(entry: result.entries[i]),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 12),
            Text(result.summary, style: Ember.body),
            const SizedBox(height: 16),
            if (onConnect != null && result.ok)
              EmberButton(
                label: 'Connect',
                icon: Icons.power_settings_new_rounded,
                onTap: () => onConnect!(),
              ),
            if (onConnect != null && result.ok) const SizedBox(height: 8),
            Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(
                  'Close',
                  style: Ember.body.copyWith(color: Ember.dim),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ServiceRow extends StatelessWidget {
  const _ServiceRow({required this.entry});

  final ServiceCheckEntry entry;

  @override
  // Build 2092 (item 57): the row carries the 48 dp floor
  // and the label ellipsizes instead of squeezing the
  // verdict column.
  Widget build(BuildContext context) => Container(
    constraints: const BoxConstraints(minHeight: 48),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Icon(
          entry.reachable ? Icons.check_circle_rounded : Icons.cancel_rounded,
          size: 18,
          color: entry.reachable ? Ember.green : Ember.red,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            entry.label,
            style: Ember.body,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              entry.reachable ? 'Reachable' : 'No answer',
              style: Ember.body.copyWith(
                color: entry.reachable ? Ember.green : Ember.red,
              ),
            ),
            if (entry.reachable)
              Text(
                '${latDigits(entry.ms)} ms · ${latDigits(entry.status)}',
                style: Ember.body.copyWith(color: Ember.dim, fontSize: Ember.fontSmall),
              ),
          ],
        ),
      ],
    ),
  );
}
