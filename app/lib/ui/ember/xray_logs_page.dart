/// The Xray core's log viewer: the tails of xray.log and tunlink.log
/// from the engine's working directory.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../../xray/xray_controller.dart';
import 'ember_theme.dart';

class XrayLogsPage extends StatefulWidget {
  const XrayLogsPage({super.key, required this.xray});
  final XrayController xray;

  @override
  State<XrayLogsPage> createState() => _XrayLogsPageState();
}

class _XrayLogsPageState extends State<XrayLogsPage> {
  late Future<String> _logs = widget.xray.readLogs();

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
    if (mounted) setState(() => _logs = widget.xray.readLogs());
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Scaffold(
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
            onPressed: () => setState(() => _logs = widget.xray.readLogs()),
            icon: const Icon(Icons.refresh_rounded, color: Ember.dim),
          ),
          IconButton(
            tooltip: l.clear,
            onPressed: () => _confirmClear(context),
            icon: const Icon(Icons.delete_outline_rounded, color: Ember.dim),
          ),
        ],
      ),
      body: EmberBackground(
        child: FutureBuilder<String>(
          future: _logs,
          builder: (context, snap) {
            final text = snap.data ?? '';
            // Build 2074 (audit item 8): a failed read and a
            // still-loading read are NOT an empty log — branch
            // on waiting / hasError / empty explicitly instead
            // of rendering every one as a blank card.
            final waiting =
                snap.connectionState == ConnectionState.waiting &&
                !snap.hasData;
            final empty = snap.hasData && text.trim().isEmpty;
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              child: Column(
                children: [
                  // Build 2070 (review §3.4): Copy All — the one
                  // viewer missing it, and the owner's most-pasted
                  // page; same button shape as the Psiphon and
                  // Lantern viewers.
                  // Build 2074 (audit item 8): a ≥48 dp hit area.
                  if (snap.hasData && !empty)
                    Align(
                      alignment: AlignmentDirectional.centerEnd,
                      child: TextButton.icon(
                        style: TextButton.styleFrom(
                          minimumSize: const Size(0, 48),
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                        ),
                        onPressed: () async {
                          await Clipboard.setData(ClipboardData(text: text));
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
                            : snap.hasError
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
                            : SingleChildScrollView(
                                child: SelectableText(
                                  text,
                                  textDirection: TextDirection.ltr,
                                  style: const TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 11,
                                    height: 1.45,
                                    color: Ember.dim,
                                  ),
                                ),
                              ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
