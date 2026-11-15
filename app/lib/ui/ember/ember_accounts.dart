/// Accounts / subscriptions: Mozilla mode is mockup 2 (usage bars,
/// the active badge, auto-rotation, the dashed add button); V2Ray mode
/// is the approved subscription mockup (usage rings, days left, the
/// per-subscription auto-update toggle, the dashed add button).

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/core_controller.dart';
import '../../core/models.dart';
import '../../l10n/app_localizations.dart';
import '../../xray/sub_fetcher.dart';
import '../../xray/xray_controller.dart';
import '../../xray/xray_models.dart';
import '../signin_dialog.dart';
import 'ember_format.dart';
import 'ember_home.dart' show maskEmail;
import 'ember_theme.dart';
import 'map_widgets.dart';
import 'mozilla_bootstrap.dart';
import 'qr_pages.dart' show showSubscriptionQr;

class EmberAccounts extends StatelessWidget {
  const EmberAccounts({
    super.key,
    required this.core,
    required this.xray,
    required this.v2ray,
    this.onClose,
    this.bootstrap,
  });

  final CoreController core;
  final XrayController xray;
  final bool v2ray;
  final VoidCallback? onClose;

  /// The Mozilla bootstrap helper (build 2034); the shell owns
  /// it. Optional so other constructions of this page keep
  /// working — the card simply does not render without it.
  final MozillaBootstrap? bootstrap;

  @override
  Widget build(BuildContext context) => v2ray
      ? _V2raySubs(xray: xray, onClose: onClose)
      : _MozillaAccounts(core: core, onClose: onClose, bootstrap: bootstrap);
}

// ---------------------------------------------------------------- Mozilla

class _MozillaAccounts extends StatelessWidget {
  const _MozillaAccounts({required this.core, this.onClose, this.bootstrap});
  final CoreController core;
  final VoidCallback? onClose;
  final MozillaBootstrap? bootstrap;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: core,
      builder: (context, _) {
        // Build 2074 (audit item 17): keep the unfiltered list
        // for the empty check — filtering to enabled first made
        // an all-disabled list falsely read "no accounts yet".
        final allAccounts = core.accounts?.accounts ?? const <Account>[];
        final accounts = allAccounts.where((a) => a.enabled).toList();
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          children: [
            // Build 2074 (audit item 23): the header and the
            // auto-rotation row sit on a MapGlass panel, not
            // bare on the dotted map.
            MapGlass(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  MapPanelHeader(title: l.accountsTitle, onClose: onClose),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Text(l.autoRotation, style: Ember.body),
                      const Spacer(),
                      _RotationToggle(core: core),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            if (bootstrap != null) ...[
              MozillaBootstrapCard(bootstrap: bootstrap!),
              const SizedBox(height: 14),
            ],
            if (accounts.isEmpty)
              EmberEmpty(
                icon: Icons.people_outline_rounded,
                text: allAccounts.isEmpty
                    ? l.noAccountsYet
                    : 'Accounts are saved, but all are turned off',
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
  // Build 2074 (audit item 7): while the real setting loads,
  // the toggle renders neutral and disabled (dimmed, OFF
  // position, no tap) instead of claiming ON with
  // `_enabled ?? true`; the real value takes over once known.
  Widget build(BuildContext context) => Opacity(
    opacity: _enabled == null ? 0.5 : 1,
    child: EmberToggle(
      value: _enabled ?? false,
      onChanged: _enabled == null ? null : _set,
    ),
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
              // Build 2058 (audit §5 Subscriptions/Accounts):
              // the card is tappable when inactive (activates
              // the account) but nothing said so — a chevron
              // marks the affordance.
              if (!account.active)
                const Padding(
                  padding: EdgeInsets.only(right: 2),
                  child: Icon(
                    Icons.chevron_right_rounded,
                    size: 19,
                    color: MapUi.dim,
                  ),
                ),
              PopupMenuButton<String>(
                icon: const Icon(
                  Icons.more_vert_rounded,
                  color: Ember.faint,
                  size: 20,
                ),
                color: Ember.card,
                onSelected: (v) {
                  if (v == 'refresh') unawaited(core.refreshQuota(account));
                  if (v == 'remove') unawaited(core.remove(account));
                },
                itemBuilder: (_) => [
                  PopupMenuItem(value: 'refresh', child: Text(l.refreshQuota)),
                  PopupMenuItem(
                    value: 'remove',
                    child: Text(
                      l.removeAccount,
                      style: const TextStyle(color: Ember.red),
                    ),
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
  const _V2raySubs({required this.xray, this.onClose});
  final XrayController xray;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: xray,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        children: [
          MapPanelHeader(
            title: l.subscriptionsTitle,
            onClose: onClose,
            actions: [
              if (xray.subscriptions.isNotEmpty)
                MapGhostButton(
                  icon: Icons.refresh_rounded,
                  label: l.updateAll,
                  onTap: () => unawaited(xray.updateAllSubscriptions()),
                ),
              // Sample D (build 2050): the round ember add
              // button in the header.
              // Build 2074 (audit item 4): 48 dp hit area —
              // the icon stays 22.
              Material(
                color: Ember.orange,
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => showAddSubscriptionSheet(context, xray),
                  child: const SizedBox(
                    width: 48,
                    height: 48,
                    child: Icon(
                      Icons.add_rounded,
                      color: Color(0xFF1A1206),
                      size: 22,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          // Sample D's add panel: an Add-from-URL button and an Add pill —
          // both open the add sheet, which carries the real
          // form (name, HWID, fallback URL, certificate trust).
          MapGlass(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l.addSubscription,
                  style: Ember.heading.copyWith(fontSize: 14.5),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      // Build 2074 (audit item 7): this was a
                      // fake input — placeholder-styled text in
                      // an inset field box that only opened the
                      // sheet. It is now an unmistakable button:
                      // ember-tinted fill and border, a link icon
                      // and an action label. Same tap behaviour.
                      child: InkWell(
                        onTap: () => showAddSubscriptionSheet(context, xray),
                        borderRadius: BorderRadius.circular(16),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 13,
                          ),
                          decoration: BoxDecoration(
                            color: Ember.orange.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: Ember.orange.withValues(alpha: 0.55),
                            ),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.add_link_rounded,
                                size: 17,
                                color: Ember.orange,
                              ),
                              SizedBox(width: 8),
                              Text(
                                'Add from URL',
                                style: TextStyle(
                                  color: Ember.orange,
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: () => showAddSubscriptionSheet(context, xray),
                        borderRadius: BorderRadius.circular(16),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 13,
                          ),
                          decoration: BoxDecoration(
                            gradient: Ember.gradient,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: const Text(
                            'Add',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFF1A1206),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
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
        ],
      ),
    );
  }
}

/// "Updated 12 min ago" for a subscription card (build 2050,
/// sample D); '' when it never refreshed.
String _subUpdatedAgo(int lastUpdatedMs) {
  if (lastUpdatedMs <= 0) return '';
  final d = DateTime.now().millisecondsSinceEpoch - lastUpdatedMs;
  if (d < 60 * 1000) return 'Updated just now';
  if (d < 3600 * 1000) return 'Updated ${latDigits(d ~/ 60000)} min ago';
  if (d < 86400 * 1000) return 'Updated ${latDigits(d ~/ 3600000)} h ago';
  return 'Updated ${latDigits(d ~/ 86400000)} d ago';
}

class _SubCard extends StatelessWidget {
  const _SubCard({required this.xray, required this.sub});
  final XrayController xray;
  final Subscription sub;

  /// "Keep only the fastest" (build 2033): pick how many of
  /// this subscription's tested configs survive, confirm the
  /// exact removal count the controller computes, then apply.
  /// Never-tested configs are kept — the dialog says so.
  Future<void> _keepFastestFlow(BuildContext context) async {
    final n = await showDialog<int>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Keep only the fastest', style: Ember.heading),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final count in [5, 10, 20])
              ListTile(
                // Build 2074 (audit item 27): latDigits.
                title: Text('Fastest ${latDigits(count)}', style: Ember.body),
                onTap: () => Navigator.of(dialogContext).pop(count),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
    if (n == null || !context.mounted) return;
    final victims = xray.fastestPruneVictims(sub, n);
    if (victims.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Nothing to remove')));
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        // Build 2074 (audit item 27): both counts route
        // through latDigits.
        title: Text('Keep the fastest ${latDigits(n)}?', style: Ember.heading),
        content: Text(
          'Removes ${latDigits(victims.length)} config${victims.length == 1 ? '' : 's'} '
          'from ${sub.name}: the slowest tested ones and those '
          'whose last test failed. Configs that were never '
          'tested stay.',
          style: Ember.body,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(
              'Remove ${latDigits(victims.length)}',
              style: const TextStyle(color: Ember.red),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final removed = await xray.keepFastestInSubscription(sub, n);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Removed ${latDigits(removed)} config${removed == 1 ? '' : 's'}',
          ),
        ),
      );
    }
  }

  /// Deletes this subscription — after a confirmation that
  /// names it (build 2074, audit item 18), matching the
  /// keep-fastest confirmation above. The delete used to fire
  /// on the first tap of the trash icon.
  Future<void> _confirmDelete(BuildContext context) async {
    final l = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l.deleteSubscription, style: Ember.heading),
        content: Text(
          'Delete "${sub.name}" and remove its configs? '
          'This cannot be undone.',
          style: Ember.body,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(
              l.deleteSubscription,
              style: const TextStyle(color: Ember.red),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    await xray.deleteSubscription(sub);
  }

  /// Refreshes this subscription, surfacing the fetcher's
  /// specific words on failure (build 2050, audit C-2).
  Future<void> _updateSub(BuildContext context) async {
    final l = AppLocalizations.of(context);
    try {
      await xray.updateSubscription(sub);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(subFetchErrorText(e, fallback: l.subUpdateFailed)),
            duration: const Duration(seconds: 6),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final percent = sub.totalBytes > 0
        ? (sub.usedFraction * 100).round()
        : null;
    final count = xray.profilesOf(sub).length;
    final ago = _subUpdatedAgo(sub.lastUpdatedMs);
    // Sample D anatomy (build 2050): the name with direct icon
    // actions (refresh / share QR / more / delete), a
    // nodes-and-freshness line, then the traffic row with its
    // bar and percent — the usage ring gives way to the bar.
    // Nothing from the old card is lost: keep-fastest rides
    // the ⋮ menu, the auto-update toggle stays at the foot.
    return GlassCard(
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
              _SubIconButton(
                icon: Icons.refresh_rounded,
                tooltip: l.updateNow,
                onTap: () => unawaited(_updateSub(context)),
              ),
              _SubIconButton(
                icon: Icons.qr_code_rounded,
                tooltip: 'Share as QR code',
                onTap: () => unawaited(showSubscriptionQr(context, sub)),
              ),
              PopupMenuButton<String>(
                padding: EdgeInsets.zero,
                icon: const Icon(
                  Icons.more_vert_rounded,
                  color: Ember.faint,
                  size: 20,
                ),
                color: Ember.card,
                onSelected: (v) async {
                  if (v == 'fastest') await _keepFastestFlow(context);
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: 'fastest',
                    child: Text('Keep only the fastest\u2026'),
                  ),
                ],
              ),
              _SubIconButton(
                icon: Icons.delete_outline_rounded,
                tooltip: l.deleteSubscription,
                onTap: () => unawaited(_confirmDelete(context)),
              ),
            ],
          ),
          const SizedBox(height: 3),
          Text(
            '${latDigits(count)} nodes${ago.isEmpty ? '' : ' \u00b7 $ago'}',
            style: Ember.caption,
          ),
          const SizedBox(height: 10),
          if (sub.totalBytes > 0) ...[
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Traffic  ${fmtGigabytes(sub.usedBytes)} / '
                    '${fmtGigabytes(sub.totalBytes)}',
                    style: Ember.body,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (sub.remainingDays >= 0)
                  Text(
                    l.daysLeft(latDigits(sub.remainingDays)),
                    style: Ember.caption.copyWith(color: Ember.green),
                  ),
              ],
            ),
            const SizedBox(height: 7),
            Row(
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(999),
                    child: LinearProgressIndicator(
                      value: sub.usedFraction,
                      minHeight: 5,
                      backgroundColor: MapUi.line,
                      color: Ember.orange,
                    ),
                  ),
                ),
                const SizedBox(width: 9),
                Text('${latDigits(percent ?? 0)}%', style: Ember.caption),
              ],
            ),
          ] else
            Text(l.noUsageInfo, style: Ember.dimStyle),
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

/// One of a subscription card's direct icon actions
/// (build 2050, sample D).
class _SubIconButton extends StatelessWidget {
  const _SubIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  // Build 2074 (audit item 4): 48 dp hit area for the
  // refresh / QR / delete actions — the icon stays 19.
  Widget build(BuildContext context) => SizedBox(
    width: 48,
    height: 48,
    child: IconButton(
      padding: EdgeInsets.zero,
      tooltip: tooltip,
      icon: Icon(icon, size: 19, color: Ember.dim),
      onPressed: onTap,
    ),
  );
}

/// The add-subscription sheet: a URL, an optional name.
///
/// Build 2050 (audit C-2/C-3, A-H8): failures surface IN the
/// sheet with the fetcher's specific words — and a certificate
/// failure offers the presented certificate to trust for this
/// subscription only, then retries with it pinned. The sheet
/// scrolls: form + presets + button overflowed short screens
/// before. The Advanced section carries the optional HWID,
/// fallback URL and extra request headers (audit F-H13; the
/// headers map landed in build 2051).
Future<void> showAddSubscriptionSheet(
  BuildContext context,
  XrayController xray,
) async {
  final l = AppLocalizations.of(context);
  final url = TextEditingController();
  final name = TextEditingController();
  final hwid = TextEditingController();
  final fallbackUrl = TextEditingController();
  final headers = TextEditingController();
  var busy = false;
  var showAdvanced = false;
  String? errorText;
  String? offeredPin;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Ember.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
    ),
    builder: (sheetContext) => StatefulBuilder(
      builder: (sheetContext, setSheetState) {
        // Parses the Advanced headers field (build 2051): a bad
        // line shows its error IN the sheet and aborts the add
        // — the fetch never runs with half-parsed headers.
        Map<String, String>? readHeaders() {
          final parsed = parseCustomHeaders(headers.text);
          if (parsed.error != null) {
            setSheetState(() => errorText = parsed.error);
            return null;
          }
          return parsed.headers;
        }

        return Padding(
          padding: EdgeInsets.fromLTRB(
            18,
            18,
            18,
            18 + MediaQuery.viewInsetsOf(sheetContext).bottom,
          ),
          child: SingleChildScrollView(
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
                  decoration: emberField(context, 'https://\u2026'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: name,
                  style: Ember.body,
                  decoration: emberField(context, l.subNameHint),
                ),
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: busy
                        ? null
                        : () =>
                              setSheetState(() => showAdvanced = !showAdvanced),
                    child: Text(
                      showAdvanced ? 'Advanced \u25b4' : 'Advanced \u25be',
                      style: Ember.caption.copyWith(color: Ember.orange),
                    ),
                  ),
                ),
                if (showAdvanced) ...[
                  TextField(
                    controller: hwid,
                    style: Ember.body,
                    textDirection: TextDirection.ltr,
                    decoration: emberField(
                      context,
                      'Device ID (HWID) — only if the panel asks for one',
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: fallbackUrl,
                    style: Ember.body,
                    textDirection: TextDirection.ltr,
                    keyboardType: TextInputType.url,
                    decoration: emberField(
                      context,
                      'Fallback URL — tried when the main one fails',
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: headers,
                    style: Ember.body,
                    textDirection: TextDirection.ltr,
                    keyboardType: TextInputType.multiline,
                    minLines: 2,
                    maxLines: 4,
                    decoration: emberField(
                      context,
                      'Extra headers — one per line, Name: value',
                    ),
                  ),
                  const SizedBox(height: 6),
                ],
                if (errorText != null) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(11),
                    decoration: BoxDecoration(
                      color: Ember.red.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: Ember.red.withValues(alpha: 0.45),
                      ),
                    ),
                    child: Text(
                      errorText!,
                      style: Ember.caption.copyWith(color: Ember.text),
                    ),
                  ),
                ],
                if (offeredPin != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    'Certificate SHA-256: $offeredPin',
                    style: Ember.caption,
                    textDirection: TextDirection.ltr,
                  ),
                  const SizedBox(height: 8),
                  EmberButton(
                    label: busy
                        ? l.working
                        : 'Trust this certificate and retry',
                    icon: Icons.verified_user_rounded,
                    onTap: busy
                        ? null
                        : () async {
                            final parsedHeaders = readHeaders();
                            if (parsedHeaders == null) return;
                            setSheetState(() => busy = true);
                            try {
                              await xray.addSubscription(
                                url.text.trim(),
                                name: name.text.trim(),
                                certPin: offeredPin!,
                                hwid: hwid.text.trim(),
                                fallbackUrl: fallbackUrl.text.trim(),
                                customHeaders: parsedHeaders,
                              );
                              if (sheetContext.mounted) {
                                Navigator.of(sheetContext).pop();
                              }
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text(l.subAdded)),
                                );
                              }
                            } catch (e) {
                              if (sheetContext.mounted) {
                                setSheetState(() {
                                  busy = false;
                                  errorText = subFetchErrorText(
                                    e,
                                    fallback: l.subUpdateFailed,
                                  );
                                  offeredPin =
                                      e is SubFetchException &&
                                          e.kind ==
                                              SubFetchErrorKind.certificate
                                      ? e.certSha256
                                      : null;
                                });
                              }
                            }
                          },
                  ),
                ],
                const SizedBox(height: 14),
                Text('Free verified pools (v2go)', style: Ember.heading),
                const SizedBox(height: 5),
                Text(
                  'Public configs the v2go project live-tests every '
                  'hour and republishes only while they carry traffic. '
                  'The servers belong to unknown third parties \u2014 fine '
                  'for getting online, never for anything private. '
                  'Tap one to fill the form; nothing is added until '
                  'you confirm.',
                  style: Ember.caption,
                ),
                const SizedBox(height: 9),
                Wrap(
                  spacing: 7,
                  runSpacing: 7,
                  children: [
                    for (final preset in v2goPresets)
                      EmberChip(
                        label: preset.name.replaceFirst('v2go \u2014 ', ''),
                        onTap: busy
                            ? null
                            : () => setSheetState(() {
                                url.text = preset.url;
                                name.text = preset.name;
                              }),
                      ),
                  ],
                ),
                const SizedBox(height: 14),
                EmberButton(
                  label: busy ? l.working : l.addSubscription,
                  icon: Icons.add_rounded,
                  onTap: busy
                      ? null
                      : () async {
                          if (url.text.trim().isEmpty) return;
                          final parsedHeaders = readHeaders();
                          if (parsedHeaders == null) return;
                          setSheetState(() {
                            busy = true;
                            errorText = null;
                            offeredPin = null;
                          });
                          try {
                            await xray.addSubscription(
                              url.text.trim(),
                              name: name.text.trim(),
                              hwid: hwid.text.trim(),
                              fallbackUrl: fallbackUrl.text.trim(),
                              customHeaders: parsedHeaders,
                            );
                            if (sheetContext.mounted) {
                              Navigator.of(sheetContext).pop();
                            }
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text(l.subAdded)),
                              );
                            }
                          } catch (e) {
                            if (sheetContext.mounted) {
                              setSheetState(() {
                                busy = false;
                                // Build 2050 (audit C-2): the
                                // fetcher's specific words, in the
                                // sheet — never a generic failure.
                                errorText = subFetchErrorText(
                                  e,
                                  fallback: l.subUpdateFailed,
                                );
                                offeredPin =
                                    e is SubFetchException &&
                                        e.kind == SubFetchErrorKind.certificate
                                    ? e.certSha256
                                    : null;
                              });
                            }
                          }
                        },
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}
