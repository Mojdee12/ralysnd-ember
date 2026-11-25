/// Daily problem report page (build 2149, owner
/// expansion 4): today's problem counts by type and the
/// day's failure list from the structured problem journal
/// (lib/xray/problem_report.dart), with a Share action
/// (system share sheet, plain text) and a Clear action.
/// The page exists only behind the Settings → 'Daily
/// problem report' toggle (DEFAULT OFF); the journal it
/// reads records nothing while the toggle is off. The
/// 2147 encrypted diagnostics export is a separate path
/// and stays untouched. Nothing here touches the network.
library;

import 'package:flutter/material.dart';

import '../../xray/problem_report.dart';
import '../../xray/xray_controller.dart';
import '../../xray/xray_platform.dart';
import 'ember_format.dart';
import 'ember_theme.dart';
import 'map_widgets.dart';

class DailyReportPage extends StatelessWidget {
  const DailyReportPage({super.key, required this.xray});

  final XrayController xray;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Ember.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Ember.text,
        // Build 2150 (engine appearance audit E49-10): the
        // centered, enlarged title was the only one of its
        // kind — the app dialect is the left-aligned plain
        // Ember.heading title (the recycle bin's form).
        title: Text('Daily problem report', style: Ember.heading),
      ),
      body: EmberBackground(
        child: ListenableBuilder(
          listenable: xray,
          builder: (context, _) {
            final now = DateTime.now();
            final journal = xray.problemJournal;
            final counts = journal.countsForDay(now);
            final events = journal.forDay(now);
            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 110, 16, 24),
              children: [
                Text(
                  'Problems recorded today '
                  '(${now.year}-${now.month.toString().padLeft(2, '0')}'
                  '-${now.day.toString().padLeft(2, '0')}). The journal '
                  'keeps a rolling 7 days and never records addresses, '
                  'links or credentials — only what kind of problem, '
                  'on which named config, and why.',
                  style: Ember.caption,
                ),
                const SizedBox(height: 14),
                if (events.isEmpty)
                  Text(
                    'No problems recorded today.',
                    style: Ember.body,
                  )
                else ...[
                  MapGlass(
                    blur: false,
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final entry in counts.entries)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    ProblemTypes.label(entry.key),
                                    style: Ember.body,
                                  ),
                                ),
                                Text(
                                  latDigits(entry.value),
                                  style: Ember.title.copyWith(
                                    color: Ember.orange,
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  for (final e in events)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: MapGlass(
                        blur: false,
                        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Text(e.timeLabel, style: Ember.caption),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    e.profileName.isEmpty
                                        ? e.engine
                                        : e.profileName,
                                    style: Ember.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                if (e.shape.isNotEmpty)
                                  Text(e.shape, style: Ember.caption),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '${ProblemTypes.label(e.type)}'
                              '${e.stage.isEmpty ? '' : ' · ${e.stage}'}'
                              ' — ${e.reason}',
                              style: Ember.caption,
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: MapActionPill(
                        icon: Icons.share_outlined,
                        label: 'Share report',
                        onTap: events.isEmpty
                            ? null
                            : () => XrayPlatform.shareText(
                                journal.digestText(now),
                                title: 'Ember daily problem report',
                              ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: MapActionPill(
                        icon: Icons.delete_outline,
                        label: 'Clear',
                        onTap: journal.isEmpty
                            ? null
                            : () => xray.clearProblemJournal(),
                      ),
                    ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
