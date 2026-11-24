/// The Xray core's log viewer: the tails of xray.log and tunlink.log
/// from the engine's working directory.
///
/// Build 2095 (V2Ray journey audit #21, #28): the page tails
/// the logs LIVE (a 2.5 s poll while it is visible — it used
/// to read once at open, so a connect failing in front of
/// the user never appeared), and the core log level is
/// chosen here (warning / info / debug), writing the stored
/// setting the config builder reads — the builder hardcoded
/// 'warning', so the page could never show more.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../xray/xray_controller.dart';
import 'ember_theme.dart';
import 'map_widgets.dart';

class XrayLogsPage extends StatefulWidget {
  const XrayLogsPage({super.key, required this.xray});
  final XrayController xray;

  @override
  State<XrayLogsPage> createState() => _XrayLogsPageState();
}

class _XrayLogsPageState extends State<XrayLogsPage> {
  String _text = '';
  bool _loading = true;
  bool _failed = false;
  Timer? _tail;
  final ScrollController _scroll = ScrollController();
  bool _firstLoad = true;

  /// Build 2092 (item 51): long log lines wrap by default;
  /// the toggle switches the body to horizontal scrolling
  /// so a long line stays on one line.
  bool _wrap = true;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
    // Build 2095 (audit #21): the live tail.
    _tail = Timer.periodic(
      const Duration(milliseconds: 2500),
      (_) => unawaited(_refresh()),
    );
  }

  @override
  void dispose() {
    _tail?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final text = await widget.xray.readLogs();
      if (!mounted) return;
      final changed = text != _text;
      // Build 2125 (audit A25-20 / P-31): an unchanged poll
      // no longer rebuilds the page. Up to 2124 every 2.5 s
      // tick setState'd the whole log view even when the
      // text was identical, re-laying-out up to ~700 KB of
      // log text for nothing.
      if (!changed && !_loading && !_failed) return;
      setState(() {
        _text = text;
        _loading = false;
        _failed = false;
      });
      if (changed && _firstLoad) {
        _firstLoad = false;
        // Start at the newest lines; later polls keep the
        // user's scroll position (content only appends).
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scroll.hasClients) {
            _scroll.jumpTo(_scroll.position.maxScrollExtent);
          }
        });
      }
    } catch (_) {
      if (!mounted) return;
      // A failed poll keeps the last good text; only a
      // failed FIRST read is the error state.
      setState(() {
        _loading = false;
        if (_text.isEmpty) _failed = true;
      });
    }
  }

  /// Build 2074 (audit item 8): Clear used to wipe every log
  /// instantly on tap — it now asks first, naming what goes.
  Future<void> _confirmClear(BuildContext context) async {
    final l = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: Text(l.clear, style: Ember.heading),
        content: Text(
          'Clear all core logs? This cannot be undone.',
          style: Ember.dimStyle,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(
              l.closeAction,
              style: const TextStyle(color: Ember.dim),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l.clear, style: const TextStyle(color: Ember.orange)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await widget.xray.clearLogs();
    if (mounted) {
      setState(() {
        _text = '';
        _firstLoad = true;
      });
      unawaited(_refresh());
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final text = _text;
    // Build 2074 (audit item 8): a failed read and a
    // still-loading read are NOT an empty log.
    final waiting = _loading && text.isEmpty;
    final empty = !_loading && !_failed && text.trim().isEmpty;
    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Ember.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Ember.text,
        title: Text(l.navLogs, style: Ember.heading),
        actions: [
          IconButton(
            // Build 2074 (audit item 8): tooltips on both
            // AppBar actions.
            tooltip: 'Refresh',
            onPressed: () => unawaited(_refresh()),
            icon: const Icon(Icons.refresh_rounded, color: Ember.dim),
          ),
          // Build 2092 (item 51): the wrap toggle.
          IconButton(
            tooltip: _wrap ? 'Scroll long lines sideways' : 'Wrap lines',
            onPressed: () => setState(() => _wrap = !_wrap),
            icon: Icon(
              _wrap ? Icons.wrap_text_rounded : Icons.view_headline_rounded,
              color: Ember.dim,
            ),
          ),
          IconButton(
            tooltip: l.clear,
            onPressed: () => _confirmClear(context),
            icon: const Icon(Icons.delete_outline_rounded, color: Ember.dim),
          ),
        ],
      ),
      body: EmberBackground(
        child: Padding(
          padding: EdgeInsets.fromLTRB(16, MediaQuery.of(context).padding.top + kToolbarHeight + 4, 16, 16),
          child: Column(
            children: [
              // Build 2095 (audit #28): the core log level,
              // stored and read by the config builder.
              Row(
                children: [
                  Text('Core log level', style: Ember.caption),
                  const SizedBox(width: 10),
                  for (final (value, label) in const [
                    ('warning', 'Warning'),
                    ('info', 'Info'),
                    ('debug', 'Debug'),
                  ]) ...[
                    EmberChip(
                      label: label,
                      selected: widget.xray.settings.logLevel == value,
                      onTap: () async {
                        widget.xray.settings.logLevel = value;
                        await widget.xray.save();
                        if (mounted) setState(() {});
                      },
                    ),
                    const SizedBox(width: 7),
                  ],
                ],
              ),
              const SizedBox(height: 4),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: Text(
                  'Applies on the next connect.',
                  style: Ember.caption,
                ),
              ),
              const SizedBox(height: 8),
              // Build 2070 (review §3.4): Copy All — the one
              // viewer missing it, and the owner's most-pasted
              // page; same button shape as the Psiphon and
              // Lantern viewers.
              // Build 2074 (audit item 8): a ≥48 dp hit area.
              if (!empty && text.isNotEmpty)
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: TextButton.icon(
                    style: TextButton.styleFrom(
                      minimumSize: const Size(0, 48),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                    ),
                    onPressed: () async {
                      // Build 2119 (audit F-20): the
                      // diagnostics bundle rides the
                      // self-clearing clipboard like every
                      // other secret copy in the app — up
                      // to 2118 this one Copy All left the
                      // whole export sitting on the
                      // world-readable clipboard forever.
                      await copySensitive(text);
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(l.logsCopied)),
                        );
                      }
                    },
                    icon: const Icon(
                      Icons.copy_rounded,
                      size: 16,
                      color: Ember.dim,
                    ),
                    label: Text(l.copyAll, style: Ember.caption),
                  ),
                ),
              Expanded(
                child: GlassCard(
                  padding: const EdgeInsets.all(13),
                  child: SizedBox.expand(
                    child: waiting
                        ? const Center(
                            child: CircularProgressIndicator(
                              color: Ember.orange,
                            ),
                          )
                        : _failed
                        ? Center(
                            child: Text(
                              'The logs could not be read. Try Refresh.',
                              style: Ember.dimStyle,
                              textAlign: TextAlign.center,
                            ),
                          )
                        : empty
                        ? Center(
                            child: Text(
                              'No logs yet',
                              style: Ember.dimStyle,
                            ),
                          )
                        // Build 2092 (item 51): wrapped
                        // (default) or sideways-scrolling
                        // body — in the sideways mode the
                        // text gets unbounded width, so
                        // each line stays whole.
                        : _wrap
                        ? SingleChildScrollView(
                            controller: _scroll,
                            child: SelectableText(
                              text,
                              textDirection: TextDirection.ltr,
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: Ember.fontMicro,
                                height: 1.45,
                                color: Ember.dim,
                              ),
                            ),
                          )
                        : SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: SingleChildScrollView(
                              controller: _scroll,
                              child: SelectableText(
                                text,
                                textDirection: TextDirection.ltr,
                                style: const TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: Ember.fontMicro,
                                  height: 1.45,
                                  color: Ember.dim,
                                ),
                              ),
                            ),
                          ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
