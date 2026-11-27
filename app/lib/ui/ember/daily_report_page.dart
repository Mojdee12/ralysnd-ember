/// Daily problem report page (build 2149, owner
/// expansion 4): today's problem counts by type and the
/// day's failure list from the structured problem journal
/// (lib/xray/problem_report.dart), with a Share action
/// (system share sheet, plain text) and a Clear action.
/// Build 2157 (feature pick 3) adds the one-tap Send
/// (oneTapReportText: header + 7-day counts + crashes +
/// today's digest, shared in one tap) and the
/// detailed-logging window section — both on this same
/// journal and gate.
/// The page exists only behind the Settings → 'Daily
/// problem report' toggle (DEFAULT OFF); the journal it
/// reads records nothing while the toggle is off. The
/// 2147 encrypted diagnostics export is a separate path
/// and stays untouched. Nothing here touches the network.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../app_info.dart';
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
                // Build 2157 (feature pick 3): the one-tap
                // send — the whole report (7-day counts,
                // crashes, today's digest) composed and
                // handed to the share sheet in one tap, no
                // reading-first. Same journal, same privacy
                // shape as the digest below.
                MapActionPill(
                  icon: Icons.send_outlined,
                  label: 'Send problem report',
                  primary: true,
                  onTap: () => XrayPlatform.shareText(
                    oneTapReportText(
                      journal,
                      now: now,
                      appLine: 'App $appVersion (build $appBuildNumber)',
                    ),
                    title: 'Ember problem report',
                  ),
                ),
                const SizedBox(height: 14),
                _DetailedLogSection(xray: xray),
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

/// The detailed-logging window's section (build 2157,
/// feature pick 3): arm a 10-minute window, watch its
/// countdown, stop it early, or send the report while it
/// runs. The window itself is the controller's state
/// machine (XrayController.startDetailedLogging) — this
/// section only renders it; the 1 s ticker exists solely
/// for the countdown and is cancelled with the widget.
class _DetailedLogSection extends StatefulWidget {
  const _DetailedLogSection({required this.xray});

  final XrayController xray;

  @override
  State<_DetailedLogSection> createState() => _DetailedLogSectionState();
}

class _DetailedLogSectionState extends State<_DetailedLogSection> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final xray = widget.xray;
    if (!xray.detailedLogActive) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Chasing a problem right now? Collect detailed '
            'logs for 10 minutes: the core log level goes '
            'to debug (from the next connect) while the '
            'journal records, then send the report above.',
            style: Ember.caption,
          ),
          const SizedBox(height: 10),
          MapActionPill(
            icon: Icons.timer_outlined,
            label: 'Collect detailed logs for 10 minutes',
            onTap: () => unawaited(xray.startDetailedLogging()),
          ),
        ],
      );
    }
    final remaining = Duration(milliseconds: xray.detailedLogRemainingMs);
    final mmss =
        '${remaining.inMinutes}'
        ':${(remaining.inSeconds % 60).toString().padLeft(2, '0')}';
    return MapGlass(
      blur: false,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Detailed logging on — $mmss left. Reproduce '
            'the problem now; its events land in the report.',
            style: Ember.body,
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: MapActionPill(
                  icon: Icons.send_outlined,
                  label: 'Send report now',
                  primary: true,
                  onTap: () => XrayPlatform.shareText(
                    oneTapReportText(
                      xray.problemJournal,
                      now: DateTime.now(),
                      appLine: 'App $appVersion (build $appBuildNumber)',
                    ),
                    title: 'Ember problem report',
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: MapActionPill(
                  icon: Icons.stop_circle_outlined,
                  label: 'Stop',
                  onTap: () => unawaited(xray.endDetailedLogging()),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
