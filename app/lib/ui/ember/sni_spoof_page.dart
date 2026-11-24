// SNI spoofing rules (build 2127, H3): the editor for
// the per-domain decoy-SNI rules (sni_spoof.dart). Each
// rule names a domain and the decoy name the sing-box
// engine shows a filter in a fake TLS hello ahead of
// the real handshake, for connections to that domain
// and its subdomains. The list applies only while
// XraySettings.sniSpoofEnabled is on; this page edits
// the rules themselves.

import 'package:flutter/material.dart';

import '../../xray/sni_spoof.dart';
import '../../xray/xray_controller.dart';
import 'ember_theme.dart';

class SniSpoofPage extends StatefulWidget {
  const SniSpoofPage({super.key, required this.xray});

  final XrayController xray;

  @override
  State<SniSpoofPage> createState() => _SniSpoofPageState();
}

class _SniSpoofPageState extends State<SniSpoofPage> {
  XrayController get xray => widget.xray;

  Future<void> _persist() async {
    await xray.save();
    xray.notifySettingsChanged();
    if (mounted) setState(() {});
  }

  Future<void> _editRule(SniSpoofRule? existing) async {
    final saved = await showDialog<SniSpoofRule>(
      context: context,
      builder: (_) => _RuleDialog(existing: existing),
    );
    if (saved == null) return;
    final rules = xray.settings.sniSpoofRules;
    if (existing == null) {
      rules.add(saved);
    } else {
      final at = rules.indexWhere((r) => r.id == existing.id);
      if (at >= 0) rules[at] = saved;
    }
    await _persist();
  }

  Future<void> _deleteRule(SniSpoofRule rule) async {
    xray.settings.sniSpoofRules.removeWhere((r) => r.id == rule.id);
    await _persist();
  }

  @override
  Widget build(BuildContext context) {
    final rules = xray.settings.sniSpoofRules;
    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Ember.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Ember.text,
        title: Text('SNI spoofing rules', style: Ember.heading),
      ),
      body: EmberBackground(
        child: ListView(
          padding: EdgeInsets.fromLTRB(16, MediaQuery.of(context).padding.top + kToolbarHeight + 8, 16, 24),
          children: [
            Text(
              'For a domain in this list, the sing-box engine '
              'sends a fake TLS hello with the decoy name '
              'before the real handshake, so a filter that '
              'reads the name sees the decoy. The rule '
              'covers the domain and its subdomains. It '
              'applies to configs the sing-box engine '
              'serves (TUIC, AnyTLS, Snell, Naive and '
              'diverted configs).',
              style: Ember.body,
            ),
            const SizedBox(height: 14),
            if (rules.isEmpty)
              const GlassCard(
                child: EmberEmpty(
                  icon: Icons.visibility_off_outlined,
                  text:
                      'No rules yet. Add one — a domain a '
                      'filter blocks by name, and a harmless '
                      'name to show it instead.',
                ),
              )
            else
              GlassCard(
                child: Column(
                  children: [
                    for (var i = 0; i < rules.length; i++) ...[
                      if (i > 0)
                        const Divider(color: Ember.line, height: 18),
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment:
                                  CrossAxisAlignment.start,
                              children: [
                                Text(
                                  rules[i].label,
                                  style: Ember.heading.copyWith(
                                    fontSize: Ember.fontBody,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  rules[i].method.isEmpty
                                      ? 'Core default method'
                                      : 'Method: ${rules[i].method}',
                                  style: Ember.body,
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            tooltip: 'Edit rule',
                            icon: const Icon(
                              Icons.edit_outlined,
                              size: 19,
                              color: Ember.dim,
                            ),
                            onPressed: () => _editRule(rules[i]),
                          ),
                          IconButton(
                            tooltip: 'Delete rule',
                            icon: const Icon(
                              Icons.delete_outline_rounded,
                              size: 19,
                              color: Ember.dim,
                            ),
                            onPressed: () => _deleteRule(rules[i]),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            const SizedBox(height: 14),
            OutlinedButton.icon(
              onPressed: () => _editRule(null),
              icon: const Icon(Icons.add_rounded, size: 19),
              label: const Text('Add a rule'),
              style: OutlinedButton.styleFrom(
                foregroundColor: Ember.orange,
                side: BorderSide(
                  color: Ember.orange.withValues(alpha: 0.7),
                ),
                padding: const EdgeInsets.symmetric(vertical: 13),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
                textStyle: const TextStyle(
                  fontSize: Ember.fontTitle,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RuleDialog extends StatefulWidget {
  const _RuleDialog({this.existing});

  final SniSpoofRule? existing;

  @override
  State<_RuleDialog> createState() => _RuleDialogState();
}

class _RuleDialogState extends State<_RuleDialog> {
  late final _domain = TextEditingController(
    text: widget.existing?.domain ?? '',
  );
  late final _spoof = TextEditingController(
    text: widget.existing?.spoof ?? '',
  );
  late String _method = widget.existing?.method ?? '';

  @override
  void initState() {
    super.initState();
    // The Save button keys on both fields being non-empty.
    _domain.addListener(() => setState(() {}));
    _spoof.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _domain.dispose();
    _spoof.dispose();
    super.dispose();
  }

  bool get _valid =>
      _domain.text.trim().isNotEmpty && _spoof.text.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        widget.existing == null ? 'Add a rule' : 'Edit rule',
        style: Ember.heading,
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _domain,
            style: Ember.body.copyWith(color: Ember.text),
            decoration: emberField(context, 'Domain (e.g. example.com)'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _spoof,
            style: Ember.body.copyWith(color: Ember.text),
            decoration: emberField(context, 'Decoy name (e.g. cdn.example.net)'),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 7,
            runSpacing: 7,
            children: [
              EmberChip(
                label: 'Core default',
                compact: true,
                selected: _method.isEmpty,
                onTap: () => setState(() => _method = ''),
              ),
              for (final m in sniSpoofMethods)
                EmberChip(
                  label: m,
                  compact: true,
                  selected: _method == m,
                  onTap: () => setState(() => _method = m),
                ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: _valid
              ? () => Navigator.of(context).pop(
                  SniSpoofRule(
                    id:
                        widget.existing?.id ??
                        'ss${DateTime.now().microsecondsSinceEpoch}',
                    domain: _domain.text.trim(),
                    spoof: _spoof.text.trim(),
                    method: _method,
                  ),
                )
              : null,
          child: const Text(
            'Save',
            style: TextStyle(color: Ember.orange),
          ),
        ),
      ],
    );
  }
}
