/// Smart group rules (build 2105): the editor for the
/// rule-made profile groups (smart_groups.dart). Each rule
/// gathers the profiles it matches into a named group on the
/// V2Ray list; the list shows the groups only while
/// XraySettings.smartGroupsEnabled is on. This page edits the
/// rules themselves — it is reachable from Settings while the
/// feature is on.

import 'package:flutter/material.dart';

import '../../xray/smart_groups.dart';
import '../../xray/xray_controller.dart';
import '../../xray/xray_models.dart';
import 'ember_theme.dart';

class SmartGroupsPage extends StatefulWidget {
  const SmartGroupsPage({super.key, required this.xray});

  final XrayController xray;

  @override
  State<SmartGroupsPage> createState() => _SmartGroupsPageState();
}

class _SmartGroupsPageState extends State<SmartGroupsPage> {
  XrayController get xray => widget.xray;

  Future<void> _persist() async {
    await xray.save();
    xray.notifySettingsChanged();
    if (mounted) setState(() {});
  }

  String _subscriptionNameOf(Profile p) {
    final sub = xray.subscriptionOf(p);
    return sub?.name ?? '';
  }

  int _memberCount(SmartGroupRule rule) {
    return smartGroupMembers(
      rule,
      xray.profiles,
      subscriptionNameOf: (p) => _subscriptionNameOf(p),
    ).length;
  }

  Future<void> _editRule(SmartGroupRule? existing) async {
    final saved = await showDialog<SmartGroupRule>(
      context: context,
      builder: (_) => _RuleDialog(existing: existing, xray: xray),
    );
    if (saved == null) return;
    final rules = xray.settings.smartGroupRules;
    if (existing == null) {
      rules.add(saved);
    } else {
      final at = rules.indexWhere((r) => r.id == existing.id);
      if (at >= 0) rules[at] = saved;
    }
    await _persist();
  }

  Future<void> _deleteRule(SmartGroupRule rule) async {
    xray.settings.smartGroupRules.removeWhere((r) => r.id == rule.id);
    await _persist();
  }

  @override
  Widget build(BuildContext context) {
    final rules = xray.settings.smartGroupRules;
    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Ember.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Ember.text,
        title: Text('Smart groups', style: Ember.heading),
      ),
      body: EmberBackground(child: ListView(
        padding: EdgeInsets.fromLTRB(16, MediaQuery.of(context).padding.top + kToolbarHeight + 8, 16, 24),
        children: [
          Text(
            'A smart group gathers the configs a rule matches '
            'into one section of the config list. A config keeps '
            'its subscription too — the group is a second home, '
            'not a move.',
            style: Ember.body,
          ),
          const SizedBox(height: 14),
          if (rules.isEmpty)
            // Build 2116 (AP-19): the shared empty state,
            // inside the page's card like before.
            const GlassCard(
              child: EmberEmpty(
                icon: Icons.auto_awesome_outlined,
                text: 'No rules yet. Add one — for example, all '
                    'VLESS configs, or every config under 150 ms.',
              ),
            )
          else
            GlassCard(
              child: Column(
                children: [
                  for (var i = 0; i < rules.length; i++) ...[
                    if (i > 0) const Divider(color: Ember.line, height: 18),
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                rules[i].label,
                                style: Ember.heading.copyWith(fontSize: Ember.fontBody),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '${_memberCount(rules[i])} config'
                                '${_memberCount(rules[i]) == 1 ? '' : 's'}',
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
              side: BorderSide(color: Ember.orange.withValues(alpha: 0.7)),
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
      )),
    );
  }
}

class _RuleDialog extends StatefulWidget {
  const _RuleDialog({required this.xray, this.existing});

  final XrayController xray;
  final SmartGroupRule? existing;

  @override
  State<_RuleDialog> createState() => _RuleDialogState();
}

class _RuleDialogState extends State<_RuleDialog> {
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _value = TextEditingController(text: widget.existing?.value ?? '');
  late String _field = widget.existing?.field ?? 'protocol';

  @override
  void initState() {
    super.initState();
    // The Save button keys on the value being non-empty.
    _value.addListener(() => setState(() {}));
  }

  static const _fieldLabels = {
    'protocol': 'Protocol is',
    'name': 'Name contains',
    'address': 'Server contains',
    'subscription': 'Subscription name contains',
    'latency': 'Latency at most (ms)',
  };

  @override
  void dispose() {
    _name.dispose();
    _value.dispose();
    super.dispose();
  }

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
            controller: _name,
            style: Ember.body.copyWith(color: Ember.text),
            // Build 2116 (AP-08): the shared field, like
            // every other form in the app.
            decoration: emberField(context, 'Group name (optional)'),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 7,
            runSpacing: 7,
            children: [
              for (final f in SmartGroupRule.fields)
                EmberChip(
                  label: _fieldLabels[f]!,
                  compact: true,
                  selected: _field == f,
                  onTap: () => setState(() => _field = f),
                ),
            ],
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _value,
            style: Ember.body.copyWith(color: Ember.text),
            keyboardType: _field == 'latency'
                ? TextInputType.number
                : TextInputType.text,
            // Build 2116 (AP-08): the shared field.
            decoration: emberField(
              context,
              _field == 'protocol'
                  ? 'Protocol (vless, vmess, trojan, …)'
                  : _field == 'latency'
                  ? 'Milliseconds'
                  : 'Text to match',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        // Build 2116 (AP-08): the shared dialog action — a
        // TextButton in the token orange, not a stock
        // FilledButton.
        TextButton(
          onPressed: _value.text.trim().isEmpty
              ? null
              : () => Navigator.of(context).pop(
                  SmartGroupRule(
                    id:
                        widget.existing?.id ??
                        'sg${DateTime.now().microsecondsSinceEpoch}',
                    name: _name.text.trim(),
                    field: _field,
                    value: _value.text.trim(),
                  ),
                ),
          child: const Text(
            'Save',
            style: TextStyle(color: Ember.orange),
          ),
        ),
      ],
    );
  }
}
