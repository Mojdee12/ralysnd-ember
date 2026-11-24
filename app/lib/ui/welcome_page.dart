import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';

import '../app_settings.dart';
import '../core/core_controller.dart';
import '../l10n/app_localizations.dart';
import 'ember/ember_theme.dart';
import 'ember/map_widgets.dart';
import 'widgets.dart';

/// The first run: the user picks a language and a country, and the
/// country's sites go directly (the core's routing region).
class WelcomePage extends StatefulWidget {
  const WelcomePage({super.key, required this.core, required this.settings});

  final CoreController core;
  final AppSettings settings;

  @override
  State<WelcomePage> createState() => _WelcomePageState();
}

class _WelcomePageState extends State<WelcomePage> {
  late String _language;
  late String _region;

  /// The region follows the language until the user picks one.
  bool _regionPicked = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final system = PlatformDispatcher.instance.locale;
    _language = widget.settings.language.isNotEmpty
        ? widget.settings.language
        : AppSettings.languageFor(system);
    _region = AppSettings.suggestedRegion(_language, system.countryCode);
  }

  void _pickLanguage(String language) {
    setState(() {
      _language = language;
      if (!_regionPicked) {
        _region = AppSettings.regionForLanguage(language) ?? _region;
      }
    });
    // Show the page in the chosen language at once.
    widget.settings.update(language: language);
  }

  Future<void> _start() async {
    if (_saving) return;
    setState(() => _saving = true);
    final region = _region;
    // Ember 2: smart routing starts OFF (everything goes through the
    // tunnel) unless the user actively picked a region here — the
    // language-suggested region alone must not turn it on, which was
    // the v1 "sites do not open" trap.
    final picked = _regionPicked;
    // Build 2092 (item 47): the busy flag resets in a
    // finally, and firstRun is cleared only when the save
    // actually succeeded — a failed first save used to mark
    // the app set up AND wedge the button disabled.
    try {
      final ok = await runShowingErrors(
        context,
        () => widget.core.editSettings((config) {
          final routing = config['routing'];
          if (routing is! Map<String, Object?>) return;
          routing['enabled'] = picked && region.isNotEmpty;
          if (region.isNotEmpty) routing['region'] = region;
        }),
      );
      if (ok) {
        widget.settings.update(language: _language, firstRun: false);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    // Build 2056: the first screen a new user sees is Map
    // Control now — the Ember background and glass card, Ember
    // dropdowns and the gradient Start button. The
    // language/region choice and the first-run routing rule are
    // untouched.
    return Scaffold(
      backgroundColor: Ember.bg,
      body: EmberBackground(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: GlassCard(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Build 2137 (visual review V-28): the
                    // brand's own shield mark, not the stock
                    // Material shield icon.
                    const EmberShieldMark(size: 56),
                    const SizedBox(height: 16),
                    Text(
                      l.welcomeTitle,
                      textAlign: TextAlign.center,
                      style: Ember.title,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      l.welcomeBody,
                      textAlign: TextAlign.center,
                      style: Ember.dimStyle,
                    ),
                    const SizedBox(height: 28),
                    _dropdown(
                      label: l.language,
                      value: _language,
                      items: [
                        for (final code in AppSettings.supportedLanguages)
                          DropdownMenuItem(
                            value: code,
                            child: Text(
                              languageNames[code]!,
                              style: languageStyle(code),
                            ),
                          ),
                      ],
                      onChanged: (v) => _pickLanguage(v!),
                    ),
                    const SizedBox(height: 16),
                    _dropdown(
                      label: l.region,
                      value: _region,
                      items: [
                        for (final r in AppSettings.regions)
                          DropdownMenuItem(
                            value: r,
                            child: Text(regionName(l, r)),
                          ),
                      ],
                      onChanged: (v) => setState(() {
                        _region = v!;
                        _regionPicked = true;
                      }),
                      helper: l.routingDirectHint,
                    ),
                    const SizedBox(height: 28),
                    EmberButton(
                      label: l.start,
                      onTap: _saving ? null : () => unawaited(_start()),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// A picker in the Ember field style (build 2056): the label
  /// above, the value in a dark inset container, the options on
  /// the Ember card.
  Widget _dropdown({
    required String label,
    required String value,
    required List<DropdownMenuItem<String>> items,
    required ValueChanged<String?> onChanged,
    String? helper,
  }) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Ember.dimStyle),
          const SizedBox(height: 7),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            decoration: BoxDecoration(
              color: Ember.field,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Ember.line),
            ),
            child: DropdownButton<String>(
              value: value,
              isExpanded: true,
              dropdownColor: Ember.card,
              underline: const SizedBox.shrink(),
              style: Ember.body,
              icon: const Icon(
                Icons.keyboard_arrow_down_rounded,
                color: Ember.dim,
              ),
              items: items,
              onChanged: onChanged,
            ),
          ),
          if (helper != null) ...[
            const SizedBox(height: 7),
            Text(helper, style: Ember.caption),
          ],
        ],
      );
}
