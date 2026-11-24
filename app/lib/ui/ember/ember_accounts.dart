/// Accounts / subscriptions: Mozilla mode is mockup 2 (usage bars,
/// the active badge, auto-rotation, the dashed add button); V2Ray mode
/// is the approved subscription mockup (usage rings, days left, the
/// per-subscription auto-update toggle, the dashed add button).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/core_api.dart';
import '../../core/core_controller.dart';
import '../../core/models.dart';
import '../../l10n/app_localizations.dart';
import '../../xray/sub_fetcher.dart';
import '../../xray/xray_controller.dart';
import '../../xray/xray_models.dart';
import '../signin_dialog.dart';
import 'ember_dialogs.dart';
import 'ember_format.dart';
import 'ember_home.dart' show maskEmail;
import 'ember_theme.dart';
import 'fastest_prune_sheet.dart';
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
    this.signinBrowserFallbackOffer = false,
  });

  final CoreController core;
  final XrayController xray;
  final bool v2ray;
  final VoidCallback? onClose;

  /// Build 2105 (Mozilla feature 1): the sign-in dialog's
  /// failure-screen browser offer follows the owner's setting;
  /// the shell passes AppSettings in. Default off keeps other
  /// constructions' dialogs exactly as before.
  final bool signinBrowserFallbackOffer;

  /// The Mozilla bootstrap helper (build 2034); the shell owns
  /// it. Optional so other constructions of this page keep
  /// working — the card simply does not render without it.
  final MozillaBootstrap? bootstrap;

  @override
  // Build 2075 (item 30): the account pages hold sign-in
  // state and subscription URLs — overlay-guarded.
  Widget build(BuildContext context) => OverlayGuard(
    child: v2ray
        ? _V2raySubs(xray: xray, onClose: onClose)
        : _MozillaAccounts(
            core: core,
            onClose: onClose,
            bootstrap: bootstrap,
            signinBrowserFallbackOffer: signinBrowserFallbackOffer,
          ),
  );
}

// ---------------------------------------------------------------- Mozilla

class _MozillaAccounts extends StatelessWidget {
  const _MozillaAccounts({
    required this.core,
    this.onClose,
    this.bootstrap,
    this.signinBrowserFallbackOffer = false,
  });
  final CoreController core;
  final VoidCallback? onClose;
  final MozillaBootstrap? bootstrap;
  final bool signinBrowserFallbackOffer;

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
        // Build 2095 (whole-app journey audit #53): disabled
        // accounts are SHOWN (with their state and an Enable
        // action) — the enabled-only filter hid them entirely,
        // so an account turned off in the legacy UI could
        // never be turned back on here.
        final accounts = allAccounts;
        // Build 2096 (post-2095 audit L22): the accounts
        // lists sit in the frost region like the config
        // lists — build 2095's appearance batch missed
        // these two panels.
        return MapListFrost(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            children: [
              // Build 2145 (composition rebuild, pro6-mozilla):
              // the glass header panel is retired — the page
              // opens with the sample's composition: the close
              // control where MapPanelHeader carried it, a
              // centred thin orange ring emblem (the mark this
              // surface already uses — an account letter in an
              // orange ring, build 2144's account mark; no new
              // asset is invented), the hero word, then the
              // accounts title and the auto-rotation row open
              // over the page ground. Title, toggle and
              // callbacks unchanged.
              if (onClose != null)
                Align(
                  alignment: Alignment.centerRight,
                  child: IconButton(
                    tooltip: 'Close',
                    onPressed: onClose,
                    icon: const Icon(Icons.close_rounded, size: 19),
                    color: MapUi.dim,
                    constraints: const BoxConstraints(
                      minWidth: 48,
                      minHeight: 48,
                    ),
                  ),
                ),
              Center(
                child: Container(
                  // Fidelity rollout batch 3 (pro6-mozilla):
                  // the ring grows to the sample's emblem
                  // scale with its 1.5 dp stroke — same mark,
                  // same letter, no new asset.
                  width: 120,
                  height: 120,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: Ember.orange, width: 1.5),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    l.modeMozilla.isEmpty ? '?' : l.modeMozilla[0],
                    style: Ember.hero.copyWith(color: Ember.orange),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Center(child: Text(l.modeMozilla, style: Ember.hero)),
              const SizedBox(height: 6),
              Center(
                child: Text(
                  l.accountsTitle,
                  style: Ember.microLabel,
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Text(l.autoRotation, style: Ember.body),
                  const Spacer(),
                  _RotationToggle(core: core),
                ],
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
                  _AccountCard(
                    core: core,
                    account: account,
                    signinBrowserFallbackOffer: signinBrowserFallbackOffer,
                  ),
                  const SizedBox(height: 11),
                ],
              const SizedBox(height: 4),
              // Fidelity rollout batch 3 (pro6-mozilla): the
              // dashed add box retires for the batch's bare
              // add row — plus glyph and the orange label on
              // the ground, no border (the Subscriptions
              // 'Add from URL' row's language). Same label,
              // same sign-in dialog behind it. (DashedAddButton
              // keeps its other call sites untouched.)
              InkWell(
                onTap: () => showSignInDialog(
                  context,
                  core,
                  browserFallbackOffer: signinBrowserFallbackOffer,
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.add_rounded,
                        size: 18,
                        color: Ember.orange,
                      ),
                      const SizedBox(width: 10),
                      Text(
                        l.addFirefoxAccount,
                        style: const TextStyle(
                          fontSize: Ember.fontTitle,
                          fontWeight: FontWeight.w600,
                          color: Ember.orange,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
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
      // Build 2097 (post-2096 audit C-L13): a failed read
      // leaves the toggle UNKNOWN — neutral and disabled,
      // the 2074 loading pattern — not OFF. Build 2096
      // invented an OFF the core never reported; a tap
      // from that false base would have written the wrong
      // value over a working rotation setting.
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

/// Build 2095 (whole-app journey audit #24): account actions
/// report their failures — refresh and remove used to run
/// unawaited and silent, so a failed refresh looked done.
void _accountActionFailed(BuildContext context, Object e) {
  final text = e.toString();
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        text.length > 160 ? '${text.substring(0, 160)}\u2026' : text,
      ),
      duration: const Duration(seconds: 5),
    ),
  );
}

Future<void> _runAccountAction(
  BuildContext context,
  Future<void> Function() action,
) async {
  try {
    await action();
  } catch (e) {
    if (context.mounted) _accountActionFailed(context, e);
  }
}

/// Build 2095 (whole-app journey audit #7): the re-sign-in
/// flow the legacy accounts page always had — the Ember card
/// showed a "Sign-in needed" chip with no way through it, a
/// dead end. A 409 from the core means no stored password:
/// fall back to the pre-filled sign-in dialog.
Future<void> _signInAgainMozilla(
  BuildContext context,
  CoreController core,
  Account account, {
  bool browserFallbackOffer = false,
}) async {
  final api = core.api;
  // Build 2098 (post-2097 audit L24): a not-yet-ready core
  // used to swallow the tap entirely — the button looked
  // dead. It says so now, in plain words.
  if (api == null) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'The Mozilla core is not ready yet — try again '
            'in a moment.',
          ),
        ),
      );
    }
    return;
  }
  try {
    final started = await api.startSignInAgain(account.id);
    if (context.mounted) {
      await showSignInDialog(
        context,
        core,
        started: started,
        browserFallbackOffer: browserFallbackOffer,
      );
    }
  } on CoreApiException catch (e) {
    if (!context.mounted) return;
    if (e.statusCode == 409) {
      await showSignInDialog(
        context,
        core,
        email: account.email,
        browserFallbackOffer: browserFallbackOffer,
      );
    } else {
      _accountActionFailed(context, e);
    }
  } catch (e) {
    if (context.mounted) _accountActionFailed(context, e);
  }
}

class _AccountCard extends StatelessWidget {
  const _AccountCard({
    required this.core,
    required this.account,
    this.signinBrowserFallbackOffer = false,
  });
  final CoreController core;
  final Account account;
  final bool signinBrowserFallbackOffer;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final usage = account.usage;
    final label = account.email.isEmpty ? account.name : account.email;
    // Build 2145 (composition rebuild, pro6-mozilla): the
    // glass card is retired — the account is a hairline
    // panel of labelled rows (ACCOUNT / STATUS), the
    // sample's composition. The state the chips carried
    // moves into the STATUS row (same facts, same words);
    // the ring emblem moved to the page head. EXIT row:
    // GAP — this surface has no exit/relay selection (the
    // relay choice lives on the bootstrap card), so no
    // row is drawn for it.
    final statusText = account.active
        ? l.activeBadge
        : account.needsSignIn
        ? l.signInNeeded
        : !account.enabled
        // Build 2095 (audit #53): the turned-off state is
        // named on the card.
        ? 'Turned off'
        : '—';
    final statusDot = account.active
        ? Ember.green
        : account.needsSignIn
        ? Ember.red
        : MapUi.dim;
    // Fidelity rollout batch 3 (pro6-mozilla): the usage
    // figure's parts and the fraction of the quota LEFT —
    // the sample's line shows what remains (batch 2's
    // group-head composition), where the retired UsageBar
    // filled what was used.
    final remainingParts = usage == null
        ? const <String>[]
        : fmtBytes(usage.remainingBytes).split(' ');
    final leftFraction = usage != null && usage.limitBytes > 0
        ? (usage.remainingBytes / usage.limitBytes).clamp(0.0, 1.0)
        : 0.0;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: MapUi.line),
        borderRadius: Ember.radius,
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: Ember.radius,
        child: InkWell(
          borderRadius: Ember.radius,
          // Build 2095 (audit #7): a card that needs sign-in
          // routes its tap to the sign-in flow, not to
          // activate (which the core refuses for it);
          // activation failures surface instead of
          // vanishing. (Was GlassCard's onTap — same rule.)
          onTap: account.needsSignIn
              ? () => _signInAgainMozilla(
                  context,
                  core,
                  account,
                  browserFallbackOffer: signinBrowserFallbackOffer,
                )
              : account.active || !account.enabled
              ? null
              : () => _runAccountAction(context, () => core.activate(account)),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text('ACCOUNT', style: Ember.microLabel),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Text(
                        maskEmail(label),
                        style: Ember.heading.copyWith(
                          fontSize: Ember.fontTitle,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    // Build 2058 (audit §5 Subscriptions/Accounts):
                    // the card is tappable when inactive (activates
                    // the account) but nothing said so — a chevron
                    // marks the affordance.
                    // Build 2098 (post-2097 audit L24): only when
                    // the card IS tappable — a turned-off account's
                    // card takes no tap (onTap is null above), and
                    // it used to wear the chevron anyway.
                    if (!account.active &&
                        (account.needsSignIn || account.enabled))
                      const Padding(
                        padding: EdgeInsets.only(right: 2),
                        child: Icon(
                          Icons.chevron_right_rounded,
                          size: 19,
                          color: MapUi.dim,
                        ),
                      ),
                    // Build 2092 (items 24/25): the menu button
                    // gets the full 48 dp target, and Remove
                    // confirms first, naming the account — it used
                    // to sign the account out on one tap.
                    // Build 2145: the manage menu wears the
                    // sample's orange MANAGE text instead of the
                    // ⋮ glyph — same menu, same items, same
                    // callbacks, same 48 dp target.
                    ConstrainedBox(
                      constraints: const BoxConstraints(
                        minWidth: 48,
                        minHeight: 48,
                      ),
                      child: PopupMenuButton<String>(
                        padding: EdgeInsets.zero,
                        color: Ember.card,
                        onSelected: (v) async {
                          if (v == 'refresh') {
                            await _runAccountAction(
                              context,
                              () => core.refreshQuota(account),
                            );
                          }
                          // Build 2095 (audit #53): enable/disable
                          // lives on the card it affects.
                          if (v == 'enable') {
                            await _runAccountAction(
                              context,
                              () => core.setEnabled(account, true),
                            );
                          }
                          if (v == 'disable') {
                            await _runAccountAction(
                              context,
                              () => core.setEnabled(account, false),
                            );
                          }
                          if (v == 'remove') {
                            final confirmed = await showEmberConfirm(
                              context,
                              title: l.removeAccount,
                              message:
                                  'Remove ${account.email}? The account '
                                  'signs out on this device.',
                              confirmLabel: l.removeAccount,
                            );
                            if (confirmed && context.mounted) {
                              await _runAccountAction(context, () async {
                                await core.remove(account);
                                // Build 2095 (audit #24): the FxA
                                // browser session goes with the
                                // account — its cookies used to
                                // survive removal, so the next
                                // sign-in opened already
                                // authenticated as the removed
                                // account. The app's only WebView
                                // is the FxA one.
                                try {
                                  await WebViewCookieManager().clearCookies();
                                } catch (_) {
                                  // No WebView plugin on this host.
                                }
                              });
                            }
                          }
                        },
                        itemBuilder: (_) => [
                          PopupMenuItem(
                            value: 'refresh',
                            child: Text(l.refreshQuota),
                          ),
                          PopupMenuItem(
                            value: account.enabled ? 'disable' : 'enable',
                            child: Text(
                              account.enabled ? 'Turn off' : 'Turn on',
                            ),
                          ),
                          PopupMenuItem(
                            value: 'remove',
                            child: Text(
                              l.removeAccount,
                              style: const TextStyle(color: Ember.red),
                            ),
                          ),
                        ],
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 14,
                          ),
                          child: Text('MANAGE', style: Ember.microLabelOrange),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Container(height: 1, color: MapUi.line),
                const SizedBox(height: 12),
                // The STATUS row: the state the chips used
                // to carry, with its dot (green active, red
                // sign-in needed, dim otherwise).
                Row(
                  children: [
                    Text('STATUS', style: Ember.microLabel),
                    const SizedBox(width: 14),
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: statusDot,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: Text(statusText, style: Ember.body)),
                  ],
                ),
                if (account.needsSignIn) ...[
                  const SizedBox(height: 12),
                  // Build 2145 wore the sample's flat-orange
                  // pill here; fidelity rollout batch 3
                  // (pro6-mozilla) re-reads the sample: its
                  // connect action is the SLIM hairline pill
                  // with the tracked label — the Home slim
                  // bar's language (R2). Same localized label
                  // verbatim, same callback.
                  Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(999),
                      onTap: () => _signInAgainMozilla(
                        context,
                        core,
                        account,
                        browserFallbackOffer: signinBrowserFallbackOffer,
                      ),
                      child: Container(
                        height: 46,
                        decoration: BoxDecoration(
                          border: Border.all(color: MapUi.line),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(
                              Icons.login_rounded,
                              size: 16,
                              color: Ember.orange,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              l.signInAgain,
                              style: const TextStyle(
                                fontSize: Ember.fontBody,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 2.4,
                                color: Ember.text,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
                // Build 2095 (audit #54): an unread quota SAYS it
                // has not been read — the card used to show nothing
                // at all, indistinguishable from "no quota concept".
                if (usage == null) ...[
                  const SizedBox(height: 10),
                  Text(
                    'Quota not read yet — refresh it from the \u22ef menu.',
                    style: Ember.caption,
                  ),
                ],
                if (usage != null) ...[
                  const SizedBox(height: 14),
                  // Fidelity rollout batch 3 (pro6-mozilla):
                  // the 6 dp gradient UsageBar retires — the
                  // usage is the Servers group head's quiet
                  // figure + line (batch 2, accepted): the
                  // remaining quota as the numeral figure,
                  // the 2 px line of what is LEFT, then the
                  // same words the card always carried (the
                  // remaining sentence, the used-of-total
                  // line with its reset date — build 2095
                  // audit #54 facts, verbatim).
                  if (usage.unlimited)
                    Text('Unlimited plan', style: Ember.heading)
                  else ...[
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Text(remainingParts.first, style: Ember.numeral),
                        if (remainingParts.length > 1) ...[
                          const SizedBox(width: 6),
                          Text(
                            remainingParts.sublist(1).join(' '),
                            style: Ember.heading.copyWith(
                              fontWeight: FontWeight.w300,
                            ),
                          ),
                        ],
                        const Spacer(),
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Text('REMAINING', style: Ember.microLabel),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: Container(
                        height: 2,
                        color: MapUi.line,
                        child: Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: FractionallySizedBox(
                            widthFactor: leftFraction,
                            child: Container(color: Ember.orange),
                          ),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  Text(
                    l.remainingGb(fmtGigabytes(usage.remainingBytes)),
                    style: Ember.microLabel,
                  ),
                  const SizedBox(height: 3),
                  if (!usage.unlimited)
                    Text(
                      '${fmtGigabytes(usage.usedBytes)} of '
                      '${fmtGigabytes(usage.limitBytes)} used'
                      '${usage.resetAt == null ? '' : ' · resets '
                                '${usage.resetAt!.year}-'
                                '${usage.resetAt!.month.toString().padLeft(2, '0')}-'
                                '${usage.resetAt!.day.toString().padLeft(2, '0')}'}',
                      style: Ember.caption,
                    ),
                ],
              ],
            ),
          ),
        ),
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
      builder: (context, _) => MapListFrost(
        // Build 2096 (post-2095 audit L22): frost region,
        // as the config lists got in build 2095.
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          children: [
            // Build 2144 (reskin): the MapPanelHeader gives
            // way to the same open typography the V2Ray tab
            // header got — the title as the huge light hero
            // word, the existing actions bare at the right,
            // the same close control MapPanelHeader carried.
            // Title text, actions and callbacks unchanged.
            // Build 2145 (UI-review fix A9): the hero word gets
            // its OWN full-width line — at phone widths the
            // actions row squeezed it into a FittedBox shrink
            // (which also fought the user's text scale). The
            // actions keep their order and targets on the row
            // beneath, right-aligned as before.
            Text(
              l.subscriptionsTitle,
              style: Ember.hero,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (xray.subscriptions.isNotEmpty)
                  // Build 2092 (item 28): Update all shows its
                  // busy state and cannot stack runs.
                  _UpdateAllButton(
                    label: l.updateAll,
                    onRun: () async {
                      // Build 2095 (V2Ray journey audit #7):
                      // the counts reach the user — a partial
                      // failure used to look identical to a
                      // clean run.
                      final r = await xray.updateAllSubscriptions();
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              r.failed == 0
                                  ? 'All ${latDigits(r.updated)} subscriptions updated'
                                  : '${latDigits(r.updated)} updated, '
                                        '${latDigits(r.failed)} failed',
                            ),
                          ),
                        );
                      }
                    },
                  ),
                if (xray.subscriptions.isNotEmpty) const SizedBox(width: 10),
                // Sample D (build 2050) carried a round ember
                // add button here. Batch 2 (fidelity rollout,
                // owner order 2026-11-23): the header speaks
                // the samples' language like the Servers
                // header — the add action is a bare tracked
                // orange text action, same sheet behind it.
                TextButton(
                  onPressed: () => showAddSubscriptionSheet(context, xray),
                  child: const Text(
                    'Add',
                    style: TextStyle(
                      fontSize: Ember.fontSmall,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.2,
                      color: Ember.orange,
                    ),
                  ),
                ),
                if (onClose != null)
                  IconButton(
                    tooltip: 'Close',
                    onPressed: onClose,
                    icon: const Icon(Icons.close_rounded, size: 19),
                    color: MapUi.dim,
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.only(left: 4),
                    constraints: const BoxConstraints(
                      minWidth: 48,
                      minHeight: 48,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            // Sample D's add panel: an Add-from-URL button and an Add pill —
            // both open the add sheet, which carries the real
            // form (name, HWID, fallback URL, certificate trust).
            // Build 2145 (UI-review fix A2): the add panel joins
            // the page's open editorial language — no glass box;
            // the block closes with the same bottom hairline the
            // subscription blocks wear.
            DecoratedBox(
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: MapUi.line)),
              ),
              child: Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l.addSubscription,
                    style: Ember.heading.copyWith(fontSize: Ember.fontTitle),
                  ),
                  const SizedBox(height: 10),
                  // Build 2074 (audit item 7) made the old fake
                  // input an unmistakable button (tinted box);
                  // a gradient Add pill stood beside it, both
                  // opening the sheet. Batch 2 (fidelity
                  // rollout): the tint box and the gradient
                  // pill retire — the panel is ONE bare action
                  // row in the samples' language (an orange
                  // link glyph + the label over the block's
                  // hairline), still opening the same sheet,
                  // which carries the real form.
                  InkWell(
                    onTap: () => showAddSubscriptionSheet(context, xray),
                    child: const Padding(
                      padding: EdgeInsets.symmetric(vertical: 13),
                      child: Row(
                        children: [
                          Icon(
                            Icons.add_link_rounded,
                            size: 17,
                            color: Ember.orange,
                          ),
                          SizedBox(width: 8),
                          // Build 2145 (UI-review fix A4): the
                          // label flexes — at large text scales
                          // it ellipsizes inside the row instead
                          // of overflowing it.
                          Flexible(
                            child: Text(
                              'Add from URL',
                              style: TextStyle(
                                color: Ember.orange,
                                fontSize: Ember.fontBody,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.6,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
                ),
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

  /// "Keep only the fastest" (build 2033, sheet replaced in
  /// build 2076 — feature queue #6): the bare Material dialogs
  /// are gone; the shared Map Control sheet states the exact
  /// counts, the N picker and the warning, and Cancel deletes
  /// nothing. The 2076 plan ranks by stored delay with
  /// untested last, so untested configs now go when a real
  /// ranking exists — the old "never-tested stays" rule is
  /// superseded, named in BUILD-LOG-2.md's 2076 entry.
  Future<void> _keepFastestFlow(BuildContext context) async {
    final removed = await showFastestPruneSheet(
      context,
      xray: xray,
      scope: xray.profilesOf(sub),
      scopeName: sub.name,
      restoreNote:
          'A refresh of this subscription can bring removed configs back.',
      onRunTestAll: () async {
        final cancelled = await xray.testAllDelays(only: xray.profilesOf(sub));
        if (!cancelled) xray.sortProfilesByDelay();
      },
    );
    if (removed != null && removed > 0 && context.mounted) {
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
    // Batch 2: the percent figure retired with the old
    // traffic row (see the numeral block in build below).
    final count = xray.profilesOf(sub).length;
    final ago = _subUpdatedAgo(sub.lastUpdatedMs);
    // Sample D anatomy (build 2050): the name with direct icon
    // actions (refresh / share QR / more / delete), a
    // nodes-and-freshness line, then the traffic row with its
    // bar and percent — the usage ring gives way to the bar.
    // Nothing from the old card is lost: keep-fastest rides
    // the ⋮ menu, the auto-update toggle stays at the foot.
    // Build 2145 (UI-review fix A2): the bordered glass card
    // is retired — the subscription now renders as the SAME
    // open editorial block the Servers page uses for the same
    // object (hairline group head over flat rows): no fill, no
    // rim, the content over a bottom hairline. One design
    // language for one object, on both pages.
    return DecoratedBox(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: MapUi.line)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(2, 2, 2, 16),
        child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  sub.name,
                  style: Ember.heading.copyWith(fontSize: Ember.fontTitle),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              _BusyRefreshButton(
                tooltip: l.updateNow,
                onRun: () => _updateSub(context),
              ),
              // Build 2092 (item 24): the header carried
              // four 48 dp actions beside the name — at
              // phone widths the name was squeezed to a
              // sliver. Share-QR and Delete move into the
              // menu (Delete keeps its confirmation); the
              // refresh stays direct; the menu button gets
              // the full 48 dp target.
              SizedBox(
                width: 48,
                height: 48,
                child: PopupMenuButton<String>(
                  padding: EdgeInsets.zero,
                  icon: const Icon(
                    Icons.more_vert_rounded,
                    color: Ember.faint,
                    size: 20,
                  ),
                  color: Ember.card,
                  onSelected: (v) {
                    if (v == 'fastest') {
                      unawaited(_keepFastestFlow(context));
                    }
                    if (v == 'qr') {
                      unawaited(showSubscriptionQr(context, sub));
                    }
                    // Build 2095 (V2Ray journey audit #4):
                    // edit in place — before this, changing
                    // anything meant delete + re-add.
                    if (v == 'edit') {
                      unawaited(
                        showAddSubscriptionSheet(context, xray, existing: sub),
                      );
                    }
                    // Build 2095 (V2Ray journey audit #24):
                    // the stored URL was reachable nowhere.
                    if (v == 'copyurl') {
                      // Build 2095 (audit 5-4): self-clearing copy.
                      unawaited(copySensitive(sub.url));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Subscription URL copied'),
                        ),
                      );
                    }
                    if (v == 'delete') {
                      unawaited(_confirmDelete(context));
                    }
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                      value: 'fastest',
                      child: Text('Keep only the fastest\u2026'),
                    ),
                    const PopupMenuItem(
                      value: 'qr',
                      child: Text('Share as QR code'),
                    ),
                    const PopupMenuItem(
                      value: 'edit',
                      child: Text('Edit subscription\u2026'),
                    ),
                    const PopupMenuItem(
                      value: 'copyurl',
                      child: Text('Copy subscription URL'),
                    ),
                    PopupMenuItem(
                      value: 'delete',
                      child: Text(
                        l.deleteSubscription,
                        style: const TextStyle(color: Ember.red),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 3),
          Text(
            '${latDigits(count)} nodes${ago.isEmpty ? '' : ' \u00b7 $ago'}',
            style: Ember.caption,
          ),
          // Build 2095 (feature 10 — subscription health):
          // alive/total from the latest test data, and a
          // plain dead flag when every tested node failed.
          Builder(
            builder: (context) {
              final profiles = xray.profilesOf(sub);
              final health = sub.healthOf(profiles);
              final alive = health.alive;
              final tested = health.tested;
              if (tested == 0) return const SizedBox.shrink();
              final dead = health.dead;
              return Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text(
                  dead
                      ? 'No working nodes — every tested config failed'
                      // Build 2096 (post-2095 audit L9):
                      // the denominator is the TESTED
                      // count — "3 of 40 working" for 3
                      // tested-and-alive read as breakage.
                      : '${latDigits(alive)} of ${latDigits(tested)} tested nodes working',
                  style: Ember.caption.copyWith(
                    // Build 2118 (appearance fix round): the
                    // working-nodes line wore the neon Ember.green
                    // (#41D97E) — a second, saturated green outside
                    // the palette. The owner's frozen ping green
                    // is the app's one green; status text uses it.
                    color: dead ? Ember.red : MapUi.pingGreen,
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 10),
          if (sub.totalBytes > 0) ...[
            // Batch 2 (fidelity rollout): the traffic block
            // takes the Servers group head's composition for
            // the same object — one design language on both
            // pages. The REMAINING figure stands at the
            // numeral scale over the 2 px progress line of
            // what is left; the used-of pair and the expiry
            // facts follow as tracked micro lines. The old
            // 'Traffic X / Y' body row, the 5 px used-fraction
            // bar and the percent text retire — every fact
            // they carried survives in the new lines (the
            // low-quota red and its warning stand).
            Builder(
              builder: (context) {
                final parts = fmtBytes(
                  (sub.totalBytes - sub.usedBytes).clamp(0, sub.totalBytes),
                ).split(' ');
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Flexible(
                      child: Text(
                        parts.first,
                        style: Ember.numeral,
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (parts.length > 1) ...[
                      const SizedBox(width: 8),
                      Text(
                        parts.sublist(1).join(' '),
                        style: const TextStyle(
                          fontSize: Ember.fontDisplay,
                          fontWeight: FontWeight.w300,
                          color: MapUi.text,
                        ),
                      ),
                    ],
                  ],
                );
              },
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: (1 - sub.usedFraction).clamp(0.0, 1.0),
              minHeight: 2,
              backgroundColor: MapUi.line,
              // Build 2095 (feature 3): the bar turns red in
              // the low-quota state.
              color: sub.quotaLow ? Ember.red : Ember.orange,
            ),
            const SizedBox(height: 8),
            Text(
              '${fmtBytes(sub.usedBytes)} of ${fmtBytes(sub.totalBytes)}',
              style: Ember.microLabel,
            ),
            if (sub.expireEpochSec > 0) ...[
              const SizedBox(height: 4),
              Text(
                'Expires '
                '${DateTime.fromMillisecondsSinceEpoch(sub.expireEpochSec * 1000).toIso8601String().substring(0, 10)}'
                '${sub.remainingDays >= 0 ? ' \u00b7 ${l.daysLeft(latDigits(sub.remainingDays))}' : ''}',
                style: Ember.microLabel,
              ),
            ],
            if (sub.quotaLow)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text(
                  'Running low — renew or switch before it runs out.',
                  style: Ember.caption.copyWith(color: Ember.red),
                ),
              ),
          ] else if (sub.expireEpochSec > 0) ...[
            // Build 2096 (post-2095 audit M17): an
            // expiry-only panel (expire but no total) —
            // the days left, the date and the low warning
            // used to be swallowed by the no-usage branch
            // even though quotaLow computed them.
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Expires ${DateTime.fromMillisecondsSinceEpoch(sub.expireEpochSec * 1000).toIso8601String().substring(0, 10)}',
                    style: Ember.body,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (sub.remainingDays >= 0)
                  Text(
                    l.daysLeft(latDigits(sub.remainingDays)),
                    style: Ember.caption.copyWith(
                      // Build 2145 (UI-review fix A6): neutral
                      // unless quotaLow, as in the traffic branch
                      // above — green is reserved for status.
                      color: sub.quotaLow ? Ember.red : null,
                    ),
                  ),
              ],
            ),
            if (sub.quotaLow)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text(
                  'Running low — renew or switch before it runs out.',
                  style: Ember.caption.copyWith(color: Ember.red),
                ),
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
      ),
    );
  }
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
/// Build 2095 (third-pass audit 5-6): the cleartext
/// confirm, shared by the sheet's submit paths and named
/// for what the user is accepting.
Future<bool> confirmCleartextSubscription(BuildContext context) async {
  final ok = await showEmberConfirm(
    context,
    title: 'Unencrypted subscription',
    message:
        'This subscription address uses plain http, not https. '
        'The address itself is a private key, and anyone on the '
        'network path — including the carrier — could read it '
        'and the configs it returns, or replace them. Add it '
        'only if you trust the network you are on.',
    confirmLabel: 'Add anyway',
  );
  return ok == true;
}

Future<void> showAddSubscriptionSheet(
  BuildContext context,
  XrayController xray, {
  Subscription? existing,
}) async {
  final l = AppLocalizations.of(context);
  final editing = existing != null;
  // Build 2095 (V2Ray journey audit #4): edit mode pre-fills
  // every stored field — the sheet is the subscription's
  // only editor now.
  final url = TextEditingController(text: existing?.url ?? '');
  final name = TextEditingController(text: existing?.name ?? '');
  final hwid = TextEditingController(text: existing?.hwid ?? '');
  final fallbackUrl = TextEditingController(text: existing?.fallbackUrl ?? '');
  final headers = TextEditingController(
    text:
        existing?.customHeaders.entries
            .map((e) => '${e.key}: ${e.value}')
            .join('\n') ??
        '',
  );
  // Build 2095 (V2Ray journey audit #26): the certificate
  // pin is settable up-front, not only after a failed fetch
  // offers it.
  final certPin = TextEditingController(text: existing?.certPin ?? '');
  // Build 2105 (provider DNS): the subscription's own DNS for
  // its server hostnames, used at connect while the Provider
  // DNS switch is on.
  final dns = TextEditingController(text: existing?.dns ?? '');
  var busy = false;
  var showAdvanced = editing;
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
                Text(
                  editing ? 'Edit subscription' : l.addSubscription,
                  style: Ember.heading,
                ),
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
                  TextField(
                    controller: certPin,
                    style: Ember.body,
                    textDirection: TextDirection.ltr,
                    decoration: emberField(
                      context,
                      'Certificate pin (SHA-256) \u2014 optional',
                    ),
                  ),
                  const SizedBox(height: 10),
                  // Build 2105 (provider DNS): a DoH URL or a
                  // resolver address; used only while the
                  // Provider DNS switch (Settings) is on.
                  TextField(
                    controller: dns,
                    style: Ember.body,
                    textDirection: TextDirection.ltr,
                    keyboardType: TextInputType.url,
                    decoration: emberField(
                      context,
                      'Provider DNS — for this subscription\'s '
                      'server names (optional)',
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
                              if (editing) {
                                await xray.editSubscription(
                                  existing,
                                  name: name.text.trim(),
                                  url: url.text.trim(),
                                  certPin: offeredPin!,
                                  hwid: hwid.text.trim(),
                                  fallbackUrl: fallbackUrl.text.trim(),
                                  dns: dns.text.trim(),
                                  customHeaders: parsedHeaders,
                                  // The cleartext confirm was
                                  // given at this sheet's
                                  // submit (audit 5-6).
                                  allowCleartext: url.text.trim().startsWith(
                                    'http://',
                                  ),
                                );
                              } else {
                                await xray.addSubscription(
                                  url.text.trim(),
                                  name: name.text.trim(),
                                  certPin: offeredPin!,
                                  hwid: hwid.text.trim(),
                                  fallbackUrl: fallbackUrl.text.trim(),
                                  dns: dns.text.trim(),
                                  customHeaders: parsedHeaders,
                                  allowCleartext: url.text.trim().startsWith(
                                    'http://',
                                  ),
                                );
                              }
                              if (sheetContext.mounted) {
                                Navigator.of(sheetContext).pop();
                              }
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      editing
                                          ? 'Subscription updated'
                                          : l.subAdded,
                                    ),
                                  ),
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
                if (!editing) ...[
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
                ],
                const SizedBox(height: 14),
                EmberButton(
                  label: busy
                      ? l.working
                      : editing
                      ? 'Save changes'
                      : l.addSubscription,
                  icon: Icons.add_rounded,
                  onTap: busy
                      ? null
                      : () async {
                          // Build 2098 (post-2097 audit L21):
                          // an empty URL used to submit as a
                          // silent no-op — the tap looked dead.
                          if (url.text.trim().isEmpty) {
                            setSheetState(
                              () => errorText =
                                  'Enter the subscription URL first.',
                            );
                            return;
                          }
                          final parsedHeaders = readHeaders();
                          if (parsedHeaders == null) return;
                          // Build 2095 (audit 5-6): cleartext
                          // needs the explicit opt-in first.
                          var allowCleartext = false;
                          if (url.text.trim().startsWith('http://')) {
                            if (!await confirmCleartextSubscription(context)) {
                              return;
                            }
                            allowCleartext = true;
                          }
                          setSheetState(() {
                            busy = true;
                            errorText = null;
                            offeredPin = null;
                          });
                          try {
                            if (editing) {
                              await xray.editSubscription(
                                existing,
                                name: name.text.trim(),
                                url: url.text.trim(),
                                certPin: certPin.text.trim(),
                                hwid: hwid.text.trim(),
                                fallbackUrl: fallbackUrl.text.trim(),
                                dns: dns.text.trim(),
                                customHeaders: parsedHeaders,
                                allowCleartext: allowCleartext,
                              );
                            } else {
                              await xray.addSubscription(
                                url.text.trim(),
                                name: name.text.trim(),
                                certPin: certPin.text.trim(),
                                hwid: hwid.text.trim(),
                                fallbackUrl: fallbackUrl.text.trim(),
                                dns: dns.text.trim(),
                                customHeaders: parsedHeaders,
                                allowCleartext: allowCleartext,
                              );
                            }
                            if (sheetContext.mounted) {
                              Navigator.of(sheetContext).pop();
                            }
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    editing
                                        ? 'Subscription updated'
                                        : l.subAdded,
                                  ),
                                ),
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
  // Build 2092 (item 61): the sheet is closed — dispose its
  // controllers instead of leaking them per open (six since
  // build 2095 added the certificate pin).
  url.dispose();
  name.dispose();
  hwid.dispose();
  fallbackUrl.dispose();
  headers.dispose();
  certPin.dispose();
  dns.dispose();
}

/// Build 2092 (item 28): a refresh icon button that owns
/// its busy state — spinner + disabled while its run is in
/// flight, so a subscription refresh can never stack.
class _BusyRefreshButton extends StatefulWidget {
  const _BusyRefreshButton({required this.tooltip, required this.onRun});
  final String tooltip;
  final Future<void> Function() onRun;

  @override
  State<_BusyRefreshButton> createState() => _BusyRefreshButtonState();
}

class _BusyRefreshButtonState extends State<_BusyRefreshButton> {
  bool _busy = false;

  Future<void> _tap() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.onRun();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 48,
    height: 48,
    child: IconButton(
      padding: EdgeInsets.zero,
      tooltip: widget.tooltip,
      onPressed: _busy ? null : () => unawaited(_tap()),
      icon: _busy
          ? const SizedBox(
              width: 19,
              height: 19,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Ember.orange,
              ),
            )
          : const Icon(Icons.refresh_rounded, size: 19, color: Ember.dim),
    ),
  );
}

/// Build 2092 (item 28): the Update-all ghost button with
/// its busy state wired (MapGhostButton's busy parameter
/// was never passed here).
class _UpdateAllButton extends StatefulWidget {
  const _UpdateAllButton({required this.label, required this.onRun});
  final String label;
  final Future<void> Function() onRun;

  @override
  State<_UpdateAllButton> createState() => _UpdateAllButtonState();
}

class _UpdateAllButtonState extends State<_UpdateAllButton> {
  bool _busy = false;

  Future<void> _tap() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.onRun();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => MapGhostButton(
    icon: Icons.refresh_rounded,
    label: widget.label,
    busy: _busy,
    onTap: _busy ? null : () => unawaited(_tap()),
  );
}
