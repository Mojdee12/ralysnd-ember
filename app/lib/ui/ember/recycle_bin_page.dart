/// Recently deleted (build 2129, leg 6 / Xray recycle
/// bin): the restore surface over the deletion tombstones
/// (builds 2096/2097). Deleting a subscription profile has
/// always recorded a tombstone so refreshes cannot
/// resurrect it — but until now there was no way back.
///
/// What the tombstone retained was ONLY its identity key —
/// no name, no full profile — so this page was honest
/// about what Restore does: it removes the tombstone,
/// and the profile returns at its subscription's next
/// refresh (the row says so). Entries are identified by
/// the endpoint fields the key itself carries
/// (protocol · address:port) and their subscription.
///
/// Build 2149 (audit A43-11): deletions now retain the
/// profile's data beside the key, so Restore brings the
/// config itself back at once and the row shows its
/// name. Pre-2149 entries keep the refresh restore and
/// the key-derived label; the header copy says both.
///
/// Delete permanently moves the key to the purged set:
/// it leaves this list and keeps blocking refreshes —
/// there is no way back from it. Nothing here restores
/// or purges on its own; both are deliberate taps, and
/// hand-added (non-subscription) profiles never had
/// tombstones, so they never appear here.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../xray/xray_controller.dart';
import 'ember_format.dart';
import 'ember_theme.dart';

class RecycleBinPage extends StatelessWidget {
  const RecycleBinPage({super.key, required this.xray});

  final XrayController xray;

  Future<void> _purge(
    BuildContext context,
    DeletedProfileEntry entry,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Delete permanently?', style: Ember.heading),
        content: Text(
          '${entry.label} will leave this list for good. It '
          'will still stay deleted — a refresh of '
          '${entry.subscription.name} will not bring it '
          'back — but it can never be restored from here.',
          style: Ember.body,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete permanently'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await xray.purgeDeletedProfile(entry.subscription, entry.key);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Ember.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Ember.text,
        title: Text('Recently deleted', style: Ember.heading),
      ),
      body: EmberBackground(
        child: AnimatedBuilder(
          animation: xray,
          builder: (context, _) {
            final entries = xray.deletedProfiles;
            if (entries.isEmpty) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Text(
                    'Nothing here. Configs you delete from a '
                    'subscription wait here until you restore '
                    'or permanently delete them.',
                    style: Ember.dimStyle,
                    textAlign: TextAlign.center,
                  ),
                ),
              );
            }
            return ListView(
              padding: EdgeInsets.fromLTRB(18, MediaQuery.of(context).padding.top + kToolbarHeight + 6, 18, 24),
              children: [
                Text(
                  // Build 2149 (audit A43-11): entries
                  // deleted from this build on keep their
                  // config's data and restore at once;
                  // older entries keep the refresh restore.
                  'Restoring a config brings it straight '
                  'back. Entries deleted before this build '
                  'return the next time their subscription '
                  'refreshes.',
                  style: Ember.dimStyle,
                ),
                const SizedBox(height: 14),
                for (final entry in entries) ...[
                  Container(
                    padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
                    decoration: BoxDecoration(
                      color: Ember.card,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: MapUi.line),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.delete_outline_rounded,
                          size: 18,
                          color: Ember.faint,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                entry.label,
                                style: Ember.body,
                                overflow: TextOverflow.ellipsis,
                              ),
                              Text(
                                entry.subscription.name.isEmpty
                                    ? 'Subscription'
                                    : entry.subscription.name,
                                style: Ember.dimStyle.copyWith(fontSize: Ember.fontSmall),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                        TextButton(
                          onPressed: () => unawaited(
                            xray.restoreDeletedProfile(
                              entry.subscription,
                              entry.key,
                            ),
                          ),
                          child: const Text('Restore'),
                        ),
                        IconButton(
                          tooltip: 'Delete permanently',
                          icon: const Icon(
                            Icons.delete_forever_rounded,
                            size: 19,
                            color: Ember.faint,
                          ),
                          onPressed: () =>
                              unawaited(_purge(context, entry)),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 9),
                ],
                Text(
                  '${latDigits(entries.length)} deleted '
                  'config${entries.length == 1 ? '' : 's'}',
                  style: Ember.dimStyle.copyWith(fontSize: Ember.fontSmall),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
