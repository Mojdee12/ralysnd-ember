/// The Info page: the About card that used to sit at the bottom of
/// Settings — flame mark, app name, version, the maker credit and
/// the license note — now behind Settings' «اینفو» entry, with the
/// main Settings list kept free of it.

import 'package:flutter/material.dart';

import '../../app_info.dart';
import '../../core/android_core.dart';
import '../../l10n/app_localizations.dart';
import 'ember_updater.dart';
import 'ember_format.dart';
import 'ember_theme.dart';
import 'licenses_page.dart';

class EmberInfoPage extends StatelessWidget {
  const EmberInfoPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Ember.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Ember.text,
        title: Text(l.infoRow, style: Ember.heading),
      ),
      // Build 2056 (audit §5): the Info page was fully off-theme
      // (default AppBar, no background).
      body: EmberBackground(
        child: ListView(
          padding: EdgeInsets.fromLTRB(18, MediaQuery.of(context).padding.top + kToolbarHeight + 14, 18, 18),
          children: [
            GlassCard(
              child: Column(
                children: [
                  Container(
                    width: 52,
                    height: 52,
                    decoration: const BoxDecoration(
                      gradient: Ember.gradient,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.local_fire_department_rounded,
                      color: Color(0xFF1A1206),
                      size: 28,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text('Ralysnd Ember', style: Ember.heading),
                  Text(
                    // Build 2095 (whole-app journey audit
                    // #59 + §9 minor): the build number shows
                    // here too — support answers start with it.
                    '${l.versionRow} ${latDigits(appVersion)} '
                    '• Build ${latDigits(appBuildNumber)}',
                    style: Ember.caption,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Built by Rayan Vakili · Ralysnd',
                    style: TextStyle(fontSize: Ember.fontBody, color: Ember.dim),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    l.licenseNote,
                    style: Ember.caption,
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            // Build 2095 (whole-app journey audit #59): the
            // repo link and the update check fold into Info —
            // they used to live only behind other doors.
            GlassCard(
              onTap: () => AndroidCore.openUrl(
                'https://github.com/$githubRepo',
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.code_rounded,
                    size: 19,
                    color: Ember.dim,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Source on GitHub — $githubRepo',
                      style: Ember.body,
                    ),
                  ),
                  const Icon(
                    Icons.open_in_new_rounded,
                    size: 16,
                    color: Ember.dim,
                  ),
                ],
              ),
            ),
            if (EmberUpdater.instance != null) ...[
              const SizedBox(height: 14),
              ListenableBuilder(
                listenable: EmberUpdater.instance!,
                builder: (context, _) {
                  final u = EmberUpdater.instance!;
                  return GlassCard(
                    child: Row(
                      children: [
                        const Icon(
                          Icons.system_update_rounded,
                          size: 19,
                          color: Ember.dim,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            u.state == EmberUpdateState.available
                                ? 'Build '
                                      '${latDigits('${u.release!.build}')} '
                                      'is available'
                                : u.state == EmberUpdateState.upToDate
                                ? 'You are on the latest build'
                                : 'Check for updates',
                            style: Ember.body,
                          ),
                        ),
                        EmberButton(
                          label: 'Check',
                          onTap: u.busy
                              ? null
                              : () => u.check(manual: true),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ],
            const SizedBox(height: 14),
            // Build 2074 (audit item 26): the whole card is the
            // navigation row it looks like — not only the small
            // "View" chip. Both taps land on the same page.
            GlassCard(
              onTap: () => Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const LicensesPage())),
              child: Row(
                children: [
                  const Icon(
                    Icons.description_outlined,
                    size: 19,
                    color: Ember.dim,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text('Open Source Licenses', style: Ember.body),
                  ),
                  // Build 2092 (item 55): one navigation
                  // target — the card itself. The chip is a
                  // visual affordance now, not a second
                  // nested tap target to the same page.
                  const EmberChip(label: 'View'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
