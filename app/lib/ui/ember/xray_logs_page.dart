/// The Xray core's log viewer: the tails of xray.log and tunlink.log
/// from the engine's working directory.

import 'package:flutter/material.dart';

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
            onPressed: () => setState(() => _logs = widget.xray.readLogs()),
            icon: const Icon(Icons.refresh_rounded, color: Ember.dim),
          ),
          IconButton(
            onPressed: () async {
              await widget.xray.clearLogs();
              setState(() => _logs = widget.xray.readLogs());
            },
            icon: const Icon(Icons.delete_outline_rounded, color: Ember.dim),
          ),
        ],
      ),
      body: EmberBackground(
        child: FutureBuilder<String>(
          future: _logs,
          builder: (context, snap) => Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            child: GlassCard(
              padding: const EdgeInsets.all(13),
              child: SizedBox.expand(
                child: SingleChildScrollView(
                  child: SelectableText(
                    snap.data ?? '…',
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
        ),
      ),
    );
  }
}
