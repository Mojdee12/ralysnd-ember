/// The Info page: the About card that used to sit at the bottom of
/// Settings — flame mark, app name, version, the maker credit and
/// the license note — now behind Settings' «اینفو» entry, with the
/// main Settings list kept free of it.

import 'package:flutter/material.dart';

import '../../app_info.dart';
import '../../l10n/app_localizations.dart';
import 'ember_format.dart';
import 'ember_theme.dart';
import 'licenses_page.dart';

class EmberInfoPage extends StatelessWidget {
  const EmberInfoPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Scaffold(
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
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
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
                    '${l.versionRow} ${latDigits(appVersion)}',
                    style: Ember.caption,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Built by Rayan Vakili · Ralysnd',
                    style: TextStyle(fontSize: 13.5, color: Ember.dim),
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
                  EmberChip(
                    label: 'View',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const LicensesPage()),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
