import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../core/android_core.dart';
import '../l10n/app_localizations.dart';
import 'ember/ember_theme.dart';
import 'ember/map_widgets.dart';
import 'widgets.dart';

/// Android, per-app proxy (v2rayN's words): bypass the selected apps, or
/// proxy only the selected apps. The routing region's list (Iran's banks,
/// messengers, and the like) is a suggestion: checked at first, and again
/// with "Suggested apps", never forced. The apps without a launcher icon
/// (mostly the system's) show on request, or when chosen. The choice is
/// kept by the app (CoreService.kt) and applied when the page closes.
class BypassAppsPage extends StatefulWidget {
  const BypassAppsPage({super.key, this.region});

  /// The routing region's name while routing is on; its apps are marked.
  final String? region;

  @override
  State<BypassAppsPage> createState() => _BypassAppsPageState();
}

class _BypassAppsPageState extends State<BypassAppsPage> {
  /// The system's apps are listed too; kept while the app runs.
  static bool _showSystem = false;

  List<InstalledApp>? _apps;
  AppRouting? _routing;

  /// Build 2092 (item 18): a failed load is a state of its
  /// own, with a retry — not an eternal spinner.
  bool _loadFailed = false;

  /// The choice when the page opened, to know whether to apply it.
  String _initial = '';
  String _query = '';
  final Map<String, Future<Uint8List?>> _icons = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // Build 2092 (item 18): the platform call can throw —
    // catch it into the error state instead of leaving the
    // spinner up forever.
    try {
      final apps = await AndroidCore.installedApps();
      final routing = await AndroidCore.appRouting();
      if (!mounted) return;
      setState(() {
        _loadFailed = false;
        _routing = routing;
        _initial = routing.key;
        _apps = apps;
        _sort();
      });
    } catch (_) {
      if (mounted) setState(() => _loadFailed = true);
    }
  }

  /// The app's icon future, cached per package (build 2092,
  /// item 60: hoisted out of the row builder).
  Future<Uint8List?> _iconFor(String package) =>
      _icons.putIfAbsent(package, () => AndroidCore.appIcon(package));

  /// The checked apps first, then by name.
  void _sort() {
    final r = _routing!;
    _apps!.sort((a, b) {
      final ca = r.checked(a.package), cb = r.checked(b.package);
      if (ca != cb) return ca ? -1 : 1;
      return a.label.toLowerCase().compareTo(b.label.toLowerCase());
    });
  }

  void _save() => AndroidCore.setAppRouting(_routing!, apply: false);

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final routing = _routing;
    final q = _query.trim().toLowerCase();
    final apps = [
      for (final a in _apps ?? const <InstalledApp>[])
        if ((a.launcher || _showSystem || routing!.checked(a.package)) &&
            (q.isEmpty ||
                a.label.toLowerCase().contains(q) ||
                a.package.toLowerCase().contains(q)))
          a,
    ];
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        // Applied once: the VPN is set up again with the new choice.
        if (didPop && routing != null && routing.key != _initial) {
          AndroidCore.setAppRouting(routing, apply: true);
        }
      },
      child: Scaffold(
        extendBodyBehindAppBar: true,
        backgroundColor: Ember.bg,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          foregroundColor: Ember.text,
          title: Text(l.bypassApps, style: Ember.heading),
          actions: [
            PopupMenuButton<void>(
              itemBuilder: (context) => [
                checkMenuItem(
                  label: l.showSystemApps,
                  checked: _showSystem,
                  onTap: () => setState(() => _showSystem = !_showSystem),
                ),
              ],
            ),
          ],
        ),
        body: EmberBackground(
          child: _loadFailed
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: GlassCard(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'The installed apps could not be loaded.',
                            style: Ember.body,
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 12),
                          EmberButton(
                            label: 'Retry',
                            icon: Icons.refresh_rounded,
                            onTap: () {
                              setState(() => _loadFailed = false);
                              _load();
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                )
              : routing == null || _apps == null
              // Build 2092 (item 18): the spinner is the
              // app's orange, not the theme's.
              ? const Center(
                  child: CircularProgressIndicator(color: Ember.orange),
                )
              : ListView.builder(
                  // Build 2138 (visual review V-26): the body
                  // extends behind the transparent bar — the
                  // list starts below it.
                  padding: EdgeInsets.only(
                    top: MediaQuery.of(context).padding.top + kToolbarHeight,
                  ),
                  itemCount: apps.length + 1,
                  itemBuilder: (context, i) {
                    if (i == 0) {
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            // Build 2092 (item 41): the app's
                            // segmented control, not the stock
                            // Material one.
                            EmberSegmented<bool>(
                              options: [
                                (false, l.appModeExclude, null),
                                (true, l.appModeInclude, null),
                              ],
                              value: routing.onlyChosen,
                              onChanged: (v) {
                                setState(() {
                                  routing.onlyChosen = v;
                                  _sort();
                                });
                                _save();
                              },
                            ),
                            const SizedBox(height: 10),
                            Text(
                              routing.onlyChosen
                                  ? l.appModeIncludeHint
                                  : l.appModeExcludeHint,
                              style: Ember.caption,
                            ),
                            if (!routing.onlyChosen &&
                                routing.suggested.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Align(
                                alignment: AlignmentDirectional.centerStart,
                                child: MapActionPill(
                                  icon: Icons.auto_awesome_rounded,
                                  label: l.suggestedApps,
                                  onTap: () {
                                    final added = routing.checkSuggested(
                                      _apps!.map((a) => a.package),
                                    );
                                    setState(_sort);
                                    _save();
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text(l.suggestedAdded(added)),
                                        behavior: SnackBarBehavior.floating,
                                      ),
                                    );
                                  },
                                ),
                              ),
                            ],
                            const SizedBox(height: 12),
                            TextField(
                              decoration: emberField(
                                context,
                                l.search,
                                prefix: const Icon(
                                  Icons.search_rounded,
                                  color: MapUi.faint,
                                  size: 18,
                                ),
                              ),
                              onChanged: (v) => setState(() => _query = v),
                            ),
                            // Build 2056 (audit §5): a search that
                            // matches nothing showed a bare header.
                            if (q.isNotEmpty && apps.isEmpty) ...[
                              const SizedBox(height: 16),
                              Text(
                                'No apps match “$q”.',
                                style: Ember.caption,
                                textAlign: TextAlign.center,
                              ),
                            ],
                          ],
                        ),
                      );
                    }
                    final app = apps[i - 1];
                    final onList =
                        widget.region != null &&
                        routing.suggested.contains(app.package);
                    final checked = routing.checked(app.package);
                    // Build 2092 (item 41): an Ember row —
                    // icon, name, package and the app's
                    // toggle — not a stock CheckboxListTile
                    // with theme colours.
                    return InkWell(
                      onTap: () {
                        setState(() => routing.toggle(app.package, !checked));
                        _save();
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        child: Row(
                          children: [
                            SizedBox.square(
                              dimension: 40,
                              child: FutureBuilder<Uint8List?>(
                                future: _iconFor(app.package),
                                builder: (context, snap) =>
                                    snap.hasError || snap.data == null
                                    ? const Icon(
                                        Icons.android_rounded,
                                        color: MapUi.dim,
                                      )
                                    : Image.memory(
                                        snap.data!,
                                        gaplessPlayback: true,
                                      ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    app.label,
                                    style: Ember.body,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  Text(
                                    onList
                                        ? l.fromRegionList(widget.region!)
                                        : app.package,
                                    style: Ember.caption.copyWith(
                                      color: onList ? Ember.orange : null,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            MapToggle(
                              value: checked,
                              onChanged: (v) {
                                setState(() => routing.toggle(app.package, v));
                                _save();
                              },
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ),
    );
  }
}
