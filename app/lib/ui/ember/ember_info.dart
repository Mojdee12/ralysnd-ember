/// The Info page: the About card that used to sit at the bottom of
/// Settings — flame mark, app name, version, the maker credit and
/// the license note — now behind Settings' «اینفو» entry, with the
/// main Settings list kept free of it.

import 'package:flutter/material.dart';

import '../../app_info.dart';
import '../../l10n/app_localizations.dart';
import 'ember_theme.dart';

class EmberInfoPage extends StatelessWidget {
  const EmberInfoPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l.infoRow)),
      body: ListView(
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
                  '${l.versionRow} $appVersion',
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
        ],
      ),
    );
  }
}
