import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_settings.dart';
import '../core/core_api.dart';
import '../core/core_controller.dart';
import '../core/models.dart';
import '../l10n/app_localizations.dart';
import 'connections_view.dart';
import 'ember/ember_dialogs.dart';
import 'ember/ember_theme.dart';
import 'ember/map_widgets.dart';
import 'format.dart';
import 'widgets.dart';

/// The core's live log: a level and text filter, auto-scroll,
/// clear, and copy; on a computer also the proxy's connections, in a
/// second tab. On a narrow screen (a phone) the tools take two rows: the
/// filter with the level, then auto-scroll with the actions.
class LogsPage extends StatefulWidget {
  const LogsPage({
    super.key,
    required this.core,
    this.settings,
    this.connections,
    this.emberChrome = false,
  });

  final CoreController core;

  /// Build 2116 (AP-02): when the page is pushed as a
  /// route of its own (the Ember shell's Mozilla log
  /// viewer), it carries the shared Ember page chrome —
  /// a Scaffold with a transparent AppBar and an
  /// Ember.heading title — like every sibling log viewer.
  /// Hosted inside another shell's content area (the
  /// desktop layout), it keeps its in-page title instead.
  final bool emberChrome;

  /// Keeps the Connections tab's columns; without it they are not kept.
  final AppSettings? settings;

  /// The Connections tab is offered; by default on a computer.
  final bool? connections;

  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> {
  /// Levels from least to most severe; the filter shows a level and above.
  static const _levels = ['DEBUG', 'INFO', 'WARN', 'ERROR'];
  static const _max = 2000;

  final _entries = <LogEntry>[];
  final _scroll = ScrollController();
  Timer? _timer;
  int _after = 0;
  bool _reading = false;

  /// Build 2092 (item 17): the first read has completed —
  /// before it, an empty list is a loading state, not
  /// "no logs".
  bool _firstReadDone = false;

  /// Build 2092 (item 17): the last read failed (the core
  /// was unreachable) — an empty list then shows the error
  /// line, not "no logs".
  bool _readFailed = false;
  String _minLevel = 'DEBUG';
  String _text = '';
  bool _follow = true;

  /// The Connections tab is shown (computers only).
  bool _connections = false;

  /// logging.verbose in the core's settings; null until read.
  bool? _verbose;

  @override
  void initState() {
    super.initState();
    _after = widget.core.logsClearedAfter;
    _readVerbose();
    _read();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _read());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _read() async {
    if (_reading) return;
    _reading = true;
    try {
      final more = await widget.core.call((api) => api.logs(_after));
      if (!mounted || more.isEmpty) return;
      // Lines logged before Clear but not yet read (the page reads once a
      // second, and a read may be under way) stay cleared.
      final cleared = widget.core.logsClearedAt;
      setState(() {
        _readFailed = false;
        _entries.addAll([
          for (final e in more)
            if (cleared == null || e.time == null || e.time!.isAfter(cleared))
              e,
        ]);
        _after = more.last.id;
        if (_entries.length > _max) {
          _entries.removeRange(0, _entries.length - _max);
        }
      });
      if (_follow) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scroll.hasClients) {
            _scroll.jumpTo(_scroll.position.maxScrollExtent);
          }
        });
      }
    } on CoreApiException {
      // The next tick tries again.
      if (mounted) setState(() => _readFailed = true);
    } on CoreUnavailable {
      // The shell shows it.
      if (mounted) setState(() => _readFailed = true);
    } finally {
      _reading = false;
      if (mounted && !_firstReadDone) {
        setState(() => _firstReadDone = true);
      }
    }
  }

  Future<void> _readVerbose() async {
    try {
      final config = await widget.core.settings();
      final logging = config['logging'];
      if (mounted) {
        setState(
          () => _verbose = logging is Map<String, Object?>
              ? logging['verbose'] == true
              : false,
        );
      }
    } on Exception {
      // The chip stays hidden.
    }
  }

  Future<void> _setVerbose(bool on) async {
    final ok = await runShowingErrors(
      context,
      () => widget.core.editSettings((config) {
        final logging = config['logging'];
        if (logging is Map<String, Object?>) {
          logging['verbose'] = on;
        } else {
          config['logging'] = <String, Object?>{'verbose': on};
        }
      }),
    );
    if (ok && mounted) setState(() => _verbose = on);
  }

  List<LogEntry> _visible() {
    final min = _levels.indexOf(_minLevel);
    final text = _text.trim().toLowerCase();
    return [
      for (final e in _entries)
        if (_levels.indexOf(e.level) >= min &&
            (text.isEmpty || e.message.toLowerCase().contains(text)))
          e,
    ];
  }

  /// A computer's tools: the levels and the filter, then the switches,
  /// with the actions as icons on the far side (their names in tooltips):
  /// the same layout as the Connections tab.
  Widget _wideTools(AppLocalizations l, List<LogEntry> visible) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      // Build 2074 (audit item 12): the level picker is the
      // Ember segmented control now, not stock SegmentedButton.
      Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: EmberSegmented<String>(
              value: _minLevel,
              options: [
                for (final level in _levels)
                  (level, _levelName(l, level), null),
              ],
              onChanged: (v) => setState(() => _minLevel = v),
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(width: 280, child: _filterField(l)),
        ],
      ),
      const SizedBox(height: 8),
      Row(
        children: [
          Expanded(
            child: Wrap(
              spacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _followSwitch(l),
                // Every destination in the log, for finding problems.
                if (_verbose case final verbose?)
                  _emberSwitch(
                    label: l.verboseLogs,
                    value: verbose,
                    onChanged: _setVerbose,
                  ),
              ],
            ),
          ),
          _copyButton(l, visible),
          _clearButton(l),
        ],
      ),
    ],
  );

  /// A phone's tools, in two rows: the filter with the level beside it,
  /// then auto-scroll with the actions; the full log is in the menu.
  Widget _narrowTools(AppLocalizations l, List<LogEntry> visible) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          Expanded(child: _filterField(l)),
          const SizedBox(width: 8),
          _levelMenu(l),
        ],
      ),
      const SizedBox(height: 4),
      Row(
        children: [
          Expanded(
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: _followSwitch(l),
            ),
          ),
          _copyButton(l, visible),
          _clearButton(l),
          if (_verbose case final verbose?)
            PopupMenuButton<void>(
              itemBuilder: (context) => [
                checkMenuItem(
                  label: l.verboseLogs,
                  checked: verbose,
                  onTap: () => _setVerbose(!verbose),
                ),
              ],
            ),
        ],
      ),
    ],
  );

  static String _levelName(AppLocalizations l, String level) =>
      level == 'DEBUG' ? l.levelAll : level;

  // Build 2074 (audit item 12): the Ember field style, not
  // the stock outlined field.
  Widget _filterField(AppLocalizations l) => TextField(
    style: Ember.body,
    decoration: emberField(
      context,
      l.filter,
      prefix: const Icon(
        Icons.filter_list_rounded,
        size: 20,
        color: Ember.faint,
      ),
    ),
    onChanged: (v) => setState(() => _text = v),
  );

  /// The level as a small menu, as tall as the filter beside it.
  Widget _levelMenu(AppLocalizations l) {
    return PopupMenuButton<String>(
      initialValue: _minLevel,
      onSelected: (v) => setState(() => _minLevel = v),
      itemBuilder: (context) => [
        for (final level in _levels)
          PopupMenuItem(value: level, child: Text(_levelName(l, level))),
      ],
      child: Container(
        height: 48,
        padding: const EdgeInsetsDirectional.only(start: 12, end: 4),
        decoration: BoxDecoration(
          color: MapUi.insetFill,
          border: Border.all(color: Ember.line),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_levelName(l, _minLevel), style: Ember.body),
            const Icon(Icons.arrow_drop_down_rounded, color: Ember.dim),
          ],
        ),
      ),
    );
  }

  /// Build 2074 (audit item 12): a labelled Ember toggle —
  /// the MapToggle pill, not the stock Material Switch the
  /// shared LabeledSwitch carries.
  Widget _emberSwitch({
    required String label,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) => InkWell(
    borderRadius: BorderRadius.circular(10),
    onTap: () => onChanged(!value),
    child: Padding(
      padding: const EdgeInsetsDirectional.only(start: 8, end: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              label,
              style: Ember.body,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 4),
          MapToggle(value: value, onChanged: onChanged),
        ],
      ),
    ),
  );

  Widget _followSwitch(AppLocalizations l) => _emberSwitch(
    label: l.follow,
    value: _follow,
    onChanged: (v) => setState(() => _follow = v),
  );

  // Build 2092 (item 51): the copy icon takes the Ember
  // dim colour, and a successful copy is confirmed with a
  // plain SnackBar — it used to go through the error
  // channel (showError).
  Widget _copyButton(AppLocalizations l, List<LogEntry> visible) => IconButton(
    tooltip: l.copyAll,
    icon: const Icon(Icons.copy_rounded, color: Ember.dim),
    onPressed: visible.isEmpty
        ? null
        : () {
            Clipboard.setData(
              ClipboardData(text: visible.map(_line).join('\n')),
            );
            ScaffoldMessenger.of(context)
                .showSnackBar(SnackBar(content: Text(l.logsCopied)));
          },
  );

  // Build 2092 (items 17/51): Clear confirms first, like
  // the other log pages.
  Widget _clearButton(AppLocalizations l) => IconButton(
    tooltip: l.clear,
    icon: const Icon(Icons.delete_sweep_outlined, color: Ember.dim),
    onPressed: () async {
      final confirmed = await showEmberConfirm(
        context,
        title: l.clear,
        message: 'Clear the log lines shown here?',
        confirmLabel: l.clear,
      );
      if (!confirmed || !mounted) return;
      setState(() {
        widget.core.logsClearedAfter = _after;
        widget.core.logsClearedAt = DateTime.now();
        _entries.clear();
      });
    },
  );

  static String _line(LogEntry e) {
    final t = e.time;
    final time = t == null
        ? ''
        : '${formatTime(t)}:${t.second.toString().padLeft(2, '0')}';
    return '$time ${e.level.padRight(5)} ${e.message}';
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final visible = _visible();
    // Build 2074 (audit item 12): the page sits on the Ember
    // background like every other Ember log viewer; the
    // filtering/loading behaviour above is unchanged.
    final body = EmberBackground(
      child: Padding(
        // Build 2138 (visual review V-26): only in the page's
        // own Scaffold (emberChrome) does the body extend
        // behind the transparent bar — there, add the bar
        // inset to the page margin's top. In the shell tab
        // and the settings wrapper route the same body sits
        // below a bar (or none) and keeps the plain margin.
        padding: widget.emberChrome
            ? pagePadding(context).copyWith(
                top:
                    MediaQuery.of(context).padding.top +
                    kToolbarHeight +
                    pagePadding(context).top,
              )
            : pagePadding(context),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Build 2116 (AP-02): with the route chrome the
            // AppBar carries the title; the in-page title
            // would double it.
            if (!widget.emberChrome) ...[
              PageTitle(l.navLogs),
              const SizedBox(height: 16),
            ],
            if (widget.connections ?? !Platform.isAndroid) ...[
              EmberSegmented<bool>(
                value: _connections,
                options: [
                  (false, l.tabLog, Icons.receipt_long_outlined),
                  (true, l.tabConnections, Icons.swap_vert_rounded),
                ],
                onChanged: (v) => setState(() => _connections = v),
              ),
              const SizedBox(height: 16),
            ],
            if (_connections)
              Expanded(
                child: ConnectionsView(
                  core: widget.core,
                  settings: widget.settings,
                ),
              )
            else ...[
              LayoutBuilder(
                builder: (context, box) => box.maxWidth < 600
                    ? _narrowTools(l, visible)
                    : _wideTools(l, visible),
              ),
              const SizedBox(height: 16),
              Expanded(
                // Build 2074 (audit item 12): glass, not a plain
                // Material Card.
                child: GlassCard(
                  padding: EdgeInsets.zero,
                  child: visible.isEmpty
                      // Build 2092 (item 17): four distinct
                      // empty states — loading, read error,
                      // filter matched nothing, and a truly
                      // empty log.
                      ? Center(
                          child: !_firstReadDone
                              ? const CircularProgressIndicator(
                                  color: Ember.orange,
                                )
                              : Text(
                                  _readFailed && _entries.isEmpty
                                      ? 'The logs could not be loaded.'
                                      : _entries.isNotEmpty
                                      ? 'No lines match the filter.'
                                      : l.noLogs,
                                  style: Ember.dimStyle,
                                ),
                        )
                      : SelectionArea(
                          child: ListView.builder(
                            controller: _scroll,
                            padding: const EdgeInsets.all(12),
                            itemCount: visible.length,
                            itemBuilder: (context, i) =>
                                _LogLine(entry: visible[i]),
                          ),
                        ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
    if (!widget.emberChrome) return body;
    // Build 2116 (AP-02): the shared Ember log-viewer
    // chrome — the Mozilla viewer was pushed bare (no
    // Scaffold, no back button, its title under the
    // status bar) while all four sibling viewers are
    // full pages like this.
    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Ember.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Ember.text,
        title: Text(l.navLogs, style: Ember.heading),
      ),
      body: body,
    );
  }
}

class _LogLine extends StatelessWidget {
  const _LogLine({required this.entry});

  final LogEntry entry;

  @override
  Widget build(BuildContext context) {
    final e = entry;
    // Build 2074 (audit item 12): Ember palette, not
    // StatusColors / theme colours.
    final color = switch (e.level) {
      'ERROR' => Ember.red,
      'WARN' => Ember.warn,
      'DEBUG' => Ember.faint,
      _ => Ember.orange,
    };
    // Consolas on Windows; elsewhere the system's monospace font.
    const mono = TextStyle(
      fontFamily: 'Consolas',
      fontFamilyFallback: ['Menlo', 'DejaVu Sans Mono', 'monospace'],
      fontSize: Ember.fontSmall,
      height: 1.45,
    );
    final t = e.time;
    // Log lines are English and stay left to right in every language.
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Text.rich(
        TextSpan(
          style: mono.copyWith(color: Ember.text),
          children: [
            if (t != null)
              TextSpan(
                text:
                    '${formatTime(t)}:${t.second.toString().padLeft(2, '0')}  ',
                style: const TextStyle(color: Ember.faint),
              ),
            TextSpan(
              text: '${e.level.padRight(5)}  ',
              style: TextStyle(color: color, fontWeight: FontWeight.w700),
            ),
            TextSpan(text: e.message),
          ],
        ),
      ),
    );
  }
}
