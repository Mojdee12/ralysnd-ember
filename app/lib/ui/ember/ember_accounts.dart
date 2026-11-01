/// Accounts / subscriptions: Mozilla mode is mockup 2 (usage bars,
/// the active badge, auto-rotation, the dashed add button); V2Ray mode
/// is the approved subscription mockup (usage rings, days left, the
/// per-subscription auto-update toggle, the dashed add button).

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/core_controller.dart';
import '../../core/models.dart';
import '../../l10n/app_localizations.dart';
import '../../xray/xray_controller.dart';
import '../../xray/xray_models.dart';
import '../signin_dialog.dart';
import 'ember_format.dart';
import 'ember_home.dart' show maskEmail;
import 'ember_theme.dart';
import 'world_map.dart';

class EmberAccounts extends StatelessWidget {
  const EmberAccounts({
    super.key,
    required this.core,
    required this.xray,
    required this.v2ray,
  });

  final CoreController core;
  final XrayController xray;
  final bool v2ray;

  @override
  Widget build(BuildContext context) =>
      v2ray ? _V2raySubs(xray: xray) : _MozillaAccounts(core: core);
}

// ---------------------------------------------------------------- Mozilla

class _MozillaAccounts extends StatelessWidget {
  const _MozillaAccounts({required this.core});
  final CoreController core;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: core,
      builder: (context, _) {
        final accounts = (core.accounts?.accounts ?? const <Account>[])
            .where((a) => a.enabled)
            .toList();
        return ListView(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 18),
          children: [
            Row(
              children: [
                Text(l.accountsTitle, style: Ember.title),
                const Spacer(),
                Text(l.autoRotation, style: Ember.dimStyle),
                const SizedBox(width: 9),
                _RotationToggle(core: core),
              ],
            ),
            const SizedBox(height: 14),
            if (accounts.isEmpty)
              EmberEmpty(
                icon: Icons.people_outline_rounded,
                text: l.noAccountsYet,
              )
            else
              for (final account in accounts) ...[
                _AccountCard(core: core, account: account),
                const SizedBox(height: 11),
              ],
            const SizedBox(height: 4),
            DashedAddButton(
              label: l.addFirefoxAccount,
              onTap: () => showSignInDialog(context, core),
            ),
          ],
        );
      },
    );
  }
}

/// The rotation toggle reads and writes the core's settings.
class _RotationToggle extends StatefulWidget {
  const _RotationToggle({required this.core});
  final CoreController core;

  @override
  State<_RotationToggle> createState() => _RotationToggleState();
}

class _RotationToggleState extends State<_RotationToggle> {
  bool? _enabled;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final settings = await widget.core.settings();
      final rotation = settings['rotation'];
      if (mounted) {
        setState(() {
          _enabled = rotation is Map ? rotation['enabled'] == true : false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _enabled = false);
    }
  }

  Future<void> _set(bool value) async {
    setState(() => _enabled = value);
    try {
      await widget.core.editSettings((config) {
        final rotation = config['rotation'];
        if (rotation is Map<String, Object?>) rotation['enabled'] = value;
      });
    } catch (_) {
      if (mounted) setState(() => _enabled = !value);
    }
  }

  @override
  Widget build(BuildContext context) => EmberToggle(
        value: _enabled ?? true,
        onChanged: _enabled == null ? null : _set,
      );
}

class _AccountCard extends StatelessWidget {
  const _AccountCard({required this.core, required this.account});
  final CoreController core;
  final Account account;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final usage = account.usage;
    final label = account.email.isEmpty ? account.name : account.email;
    final initial = label.isEmpty ? '?' : label[0].toUpperCase();
    return GlassCard(
      glow: account.active,
      onTap: account.active ? null : () => core.activate(account),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: const BoxDecoration(
                  gradient: Ember.gradient,
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Text(
                  initial,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF1A1206),
                  ),
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Text(
                  maskEmail(label),
                  style: Ember.heading.copyWith(fontSize: 15),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (account.active)
                EmberChip(label: l.activeBadge, selected: true)
              else if (account.needsSignIn)
                EmberChip(label: l.signInNeeded, dot: Ember.red),
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert_rounded, color: Ember.faint, size: 20),
                color: Ember.card,
                onSelected: (v) {
                  if (v == 'refresh') unawaited(core.refreshQuota(account));
                  if (v == 'remove') unawaited(core.remove(account));
                },
                itemBuilder: (_) => [
                  PopupMenuItem(value: 'refresh', child: Text(l.refreshQuota)),
                  PopupMenuItem(
                    value: 'remove',
                    child: Text(l.removeAccount, style: const TextStyle(color: Ember.red)),
                  ),
                ],
              ),
            ],
          ),
          if (usage != null) ...[
            const SizedBox(height: 13),
            UsageBar(
              height: 6,
              fraction: usage.limitBytes > 0
                  ? (usage.usedBytes / usage.limitBytes).clamp(0.0, 1.0)
                  : 0,
            ),
            const SizedBox(height: 7),
            Text(
              l.remainingGb(fmtGigabytes(usage.remainingBytes)),
              style: Ember.caption,
            ),
          ],
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------ V2Ray

class _V2raySubs extends StatelessWidget {
  const _V2raySubs({required this.xray});
  final XrayController xray;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: xray,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 18),
        children: [
          Row(
            children: [
              Text(l.subscriptionsTitle, style: Ember.title),
              const Spacer(),
              if (xray.subscriptions.isNotEmpty)
                IconButton(
                  onPressed: () => unawaited(xray.updateAllSubscriptions()),
                  icon: const Icon(Icons.refresh_rounded, color: Ember.dim),
                  tooltip: l.updateAll,
                ),
            ],
          ),
          const SizedBox(height: 12),
          const MapMotifStrip(),
          const SizedBox(height: 14),
          if (xray.subscriptions.isEmpty)
            EmberEmpty(
              icon: Icons.subscriptions_outlined,
              text: l.noSubscriptionsYet,
            )
          else
            for (final sub in xray.subscriptions) ...[
              _SubCard(xray: xray, sub: sub),
              const SizedBox(height: 11),
            ],
          const SizedBox(height: 4),
          DashedAddButton(
            label: l.addSubscription,
            onTap: () => showAddSubscriptionSheet(context, xray),
          ),
        ],
      ),
    );
  }
}

class _SubCard extends StatelessWidget {
  const _SubCard({required this.xray, required this.sub});
  final XrayController xray;
  final Subscription sub;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final percent =
        sub.totalBytes > 0 ? (sub.usedFraction * 100).round() : null;
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (sub.totalBytes > 0)
                UsageRing(
                  fraction: sub.usedFraction,
                  centerText: '${latDigits(percent ?? 0)}%',
                  size: 76,
                )
              else
                Container(
                  width: 62,
                  height: 62,
                  decoration: const BoxDecoration(
                    color: Ember.cardSoft,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.subscriptions_rounded,
                    color: Ember.orange,
                    size: 27,
                  ),
                ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            sub.name,
                            style: Ember.heading.copyWith(fontSize: 15),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        PopupMenuButton<String>(
                          icon: const Icon(
                            Icons.more_vert_rounded,
                            color: Ember.faint,
                            size: 20,
                          ),
                          color: Ember.card,
                          onSelected: (v) async {
                            if (v == 'update') {
                              try {
                                await xray.updateSubscription(sub);
                              } catch (_) {
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text(l.subUpdateFailed)),
                                  );
                                }
                              }
                            }
                            if (v == 'delete') await xray.deleteSubscription(sub);
                          },
                          itemBuilder: (_) => [
                            PopupMenuItem(value: 'update', child: Text(l.updateNow)),
                            PopupMenuItem(
                              value: 'delete',
                              child: Text(
                                l.deleteSubscription,
                                style: const TextStyle(color: Ember.red),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                    if (sub.totalBytes > 0)
                      Text(
                        l.subUsedOf(
                          fmtGigabytes(sub.usedBytes),
                          fmtGigabytes(sub.totalBytes),
                        ),
                        style: Ember.dimStyle,
                      )
                    else
                      Text(l.noUsageInfo, style: Ember.dimStyle),
                    const SizedBox(height: 7),
                    Wrap(
                      spacing: 7,
                      runSpacing: 7,
                      children: [
                        if (sub.remainingDays >= 0)
                          EmberChip(
                            label: l.daysLeft(latDigits(sub.remainingDays)),
                            dot: Ember.green,
                          ),
                        EmberChip(
                          label: l.profilesCount(
                            latDigits(xray.profilesOf(sub).length),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Divider(color: Ember.line, height: 1),
          const SizedBox(height: 10),
          Row(
            children: [
              const Icon(Icons.autorenew_rounded, size: 17, color: Ember.dim),
              const SizedBox(width: 8),
              Expanded(child: Text(l.subAutoUpdate, style: Ember.body)),
              EmberToggle(
                value: sub.autoUpdate,
                onChanged: (v) async {
                  sub.autoUpdate = v;
                  await xray.save();
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The add-subscription sheet: a URL, an optional name.
Future<void> showAddSubscriptionSheet(
  BuildContext context,
  XrayController xray,
) async {
  final l = AppLocalizations.of(context);
  final url = TextEditingController();
  final name = TextEditingController();
  var busy = false;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Ember.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
    ),
    builder: (sheetContext) => StatefulBuilder(
      builder: (sheetContext, setSheetState) => Padding(
        padding: EdgeInsets.fromLTRB(
          18,
          18,
          18,
          18 + MediaQuery.viewInsetsOf(sheetContext).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l.addSubscription, style: Ember.heading),
            const SizedBox(height: 13),
            TextField(
              controller: url,
              style: Ember.body,
              textDirection: TextDirection.ltr,
              keyboardType: TextInputType.url,
              decoration: emberField(context, 'https://…'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: name,
              style: Ember.body,
              decoration: emberField(context, l.subNameHint),
            ),
            const SizedBox(height: 14),
            EmberButton(
              label: busy ? l.working : l.addSubscription,
              icon: Icons.add_rounded,
              onTap: busy
                  ? null
                  : () async {
                      if (url.text.trim().isEmpty) return;
                      setSheetState(() => busy = true);
                      try {
                        await xray.addSubscription(
                          url.text.trim(),
                          name: name.text.trim(),
                        );
                        if (sheetContext.mounted) {
                          Navigator.of(sheetContext).pop();
                        }
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(l.subAdded)),
                          );
                        }
                      } catch (_) {
                        if (sheetContext.mounted) {
                          setSheetState(() => busy = false);
                          ScaffoldMessenger.of(sheetContext).showSnackBar(
                            SnackBar(content: Text(l.subUpdateFailed)),
                          );
                        }
                      }
                    },
            ),
          ],
        ),
      ),
    ),
  );
}
