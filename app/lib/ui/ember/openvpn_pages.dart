/// The OpenVPN engine's pages, Map Control edition (build
/// 2025): the home's floating status card, the Servers tab
/// (the user's own imported profiles), the settings page,
/// and the log viewer.
///
/// Build 2028 (owner's ruling): OpenVPN is a plain client —
/// the bundled TunnelBear pack, its country list and the
/// TunnelBear-keyed Accounts tab are gone. The user imports
/// his own .ovpn profiles; when a profile asks for a
/// username/password, Connect asks at connect time, and a
/// saved pair lives in the system keystore under that
/// profile's own id, managed from the profile itself.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../../openvpn/openvpn_controller.dart';
import '../../openvpn/openvpn_models.dart';
import '../../openvpn/openvpn_platform.dart';
import 'ember_dialogs.dart';
import 'ember_format.dart';
import 'ember_theme.dart';
import 'map_widgets.dart';

/// Build 2145 (pro6 composition rebuild): the flat hairline
/// panel that replaces MapGlass on the recomposed OpenVPN
/// surfaces — a solid card fill and a 1 px hairline edge, no
/// blur, no luminous ring (the sample's document panel).
class _HairlinePanel extends StatelessWidget {
  const _HairlinePanel({
    required this.child,
    required this.padding,
    this.borderColor,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: MapUi.card,
        border: Border.all(color: borderColor ?? MapUi.line),
        borderRadius: MapUi.panelBorder,
      ),
      padding: padding,
      child: child,
    );
  }
}

/// The session's traffic counters with real arrow icons
/// (build 2026: the 2025 pages used ↓/↑ characters, which the
/// device font rendered as missing-glyph boxes).
Widget ovpnTrafficLine(int downBytes, int upBytes) {
  return Directionality(
    textDirection: TextDirection.ltr,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.arrow_downward_rounded, size: 14, color: Ember.dim),
        const SizedBox(width: 4),
        Text(fmtBytes(downBytes), style: Ember.body),
        const SizedBox(width: 10),
        const Icon(Icons.arrow_upward_rounded, size: 14, color: Ember.dim),
        const SizedBox(width: 4),
        Text(fmtBytes(upBytes), style: Ember.body),
      ],
    ),
  );
}

/// What the credentials prompt returns: the pair, and whether
/// to save them to the vault under the profile's key.
typedef OvpnCredentialAnswer = ({String user, String pass, bool save});

/// Asks for a profile's username/password. [profileName] is
/// shown in the title. With [forSaveOnly] (build 2028: the
/// profile's credentials manager) the confirm button reads
/// Save and the save toggle is hidden — the pair is only
/// being stored, not connected with.
///
/// The dialog is a StatefulWidget that owns its text
/// controllers and disposes them with its State (build 2028):
/// the 2025 helper disposed them the moment showDialog
/// returned, while the dialog's exit transition still had
/// the fields mounted — a used-after-dispose the new client
/// tests caught.
Future<OvpnCredentialAnswer?> promptOpenVpnCredentials(
  BuildContext context, {
  required String profileName,
  bool forSaveOnly = false,
}) => showDialog<OvpnCredentialAnswer>(
  context: context,
  builder: (context) =>
      _CredentialsDialog(profileName: profileName, forSaveOnly: forSaveOnly),
);

class _CredentialsDialog extends StatefulWidget {
  const _CredentialsDialog({
    required this.profileName,
    required this.forSaveOnly,
  });

  final String profileName;
  final bool forSaveOnly;

  @override
  State<_CredentialsDialog> createState() => _CredentialsDialogState();
}

class _CredentialsDialogState extends State<_CredentialsDialog> {
  final _user = TextEditingController();
  final _pass = TextEditingController();
  bool _save = true;

  @override
  void dispose() {
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.profileName, style: Ember.heading),
      // Build 2092 (item 31): the content scrolls (the
      // keyboard no longer crushes it) and the save choice
      // is the app's MapToggle, not a stock checkbox tile.
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _user,
              style: Ember.body,
              autofillHints: const [AutofillHints.username],
              decoration: emberField(context, 'Username / email'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _pass,
              style: Ember.body,
              obscureText: true,
              autofillHints: const [AutofillHints.password],
              decoration: emberField(context, 'Password'),
            ),
            if (!widget.forSaveOnly) ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Save on this device (keystore)',
                      style: Ember.caption,
                    ),
                  ),
                  MapToggle(
                    value: _save,
                    onChanged: (v) => setState(() => _save = v),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        EmberButton(
          label: widget.forSaveOnly ? 'Save' : 'Connect',
          onTap: () => Navigator.of(context).pop((
            user: _user.text.trim(),
            pass: _pass.text,
            save: widget.forSaveOnly || _save,
          )),
        ),
      ],
    );
  }
}

/// Whether a connect failure is the server rejecting the
/// credentials themselves (build 2095, whole-app journey
/// audit #9): the core's terminal AUTH_FAILED, or a sentence
/// saying the same.
bool isOvpnAuthFailure(String message) =>
    message.contains('AUTH_FAILED') ||
    message.toLowerCase().contains('authentication failed') ||
    message.toLowerCase().contains('auth failed');

/// Connects [controller]'s selected profile, asking for
/// credentials when the controller says they're required —
/// or when a saved entry exists but cannot be read on this
/// device (build 2027: 'credentials-unreadable'; entering
/// them again replaces the entry). Shared by the servers
/// view's rows and the shell's toggle.
///
/// Build 2095 (audit #9): when the server REJECTS a saved
/// pair (AUTH_FAILED), the flow offers to re-enter the
/// credentials instead of failing identically forever — the
/// saved pair is deleted and the normal prompt path runs,
/// so the new pair replaces it in the vault.
Future<void> connectOpenVpnWithPrompt(
  BuildContext context,
  OpenVpnController controller,
) async {
  try {
    await controller.connect();
  } on StateError catch (e) {
    if (isOvpnAuthFailure(e.message) && context.mounted) {
      final p = controller.selected;
      if (p != null &&
          p.needsAuth &&
          !p.hasInlineCredentials &&
          p.credKey.isNotEmpty) {
        final reenter = await showEmberConfirm(
          context,
          title: 'The server rejected the saved password',
          message:
              'The saved credentials for ${p.name} did not work. '
              'Re-enter them? The saved pair is replaced.',
          confirmLabel: 'Re-enter',
        );
        if (reenter == true && context.mounted) {
          await OpenVpnPlatform.deleteCredentials(p.credKey);
          await connectOpenVpnWithPrompt(context, controller);
        }
        return;
      }
    }
    if ((e.message != 'credentials-required' &&
            e.message != 'credentials-unreadable') ||
        !context.mounted) {
      rethrow;
    }
    final unreadable = e.message == 'credentials-unreadable';
    final p = controller.selected;
    if (p == null) rethrow;
    if (unreadable) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'The saved credentials could not be read on this '
            'device — enter them again to replace them.',
          ),
        ),
      );
    }
    final answer = await promptOpenVpnCredentials(context, profileName: p.name);
    if (answer == null || answer.user.isEmpty) return;
    if (answer.save && p.credKey.isNotEmpty) {
      // Build 2027: the save outcome is VISIBLE. In 2026 this
      // result was ignored entirely — a failed save slipped
      // by in silence while the UI elsewhere claimed a saved
      // account. The typed pair still connects this session
      // either way; he is told when the save did not stick.
      var saved = false;
      try {
        saved = await OpenVpnPlatform.saveCredentials(
          p.credKey,
          answer.user,
          answer.pass,
        );
      } catch (_) {
        // Build 2074 (audit item 6): the failure is reported
        // below as a plain sentence; the raw error is not
        // carried into the UI.
        saved = false;
      }
      if (!saved && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not save the credentials on this device'),
          ),
        );
      }
    }
    await controller.connect(user: answer.user, pass: answer.pass);
  }
}

/// The OpenVPN home: the centred hero composition (build
/// 2145, pro6 sample) — the hero word and profile-count line
/// over the map, the selected profile as a document panel,
/// the status word at hero scale under it, and — loudly —
/// the failure card with the log tail when a connect went
/// wrong.
class OpenVpnHomePage extends StatelessWidget {
  const OpenVpnHomePage({super.key, required this.openvpn, this.onOpenServers});

  final OpenVpnController openvpn;

  /// Opens the Servers tab (the country/profile picker). The
  /// 2025 home had NO route to it — the selected country was
  /// display-only text and the header's Locations pill renders
  /// only in Mozilla mode, so the owner sat on the default
  /// profile (Argentina) with no way to change it. The picker
  /// row below is that route (build 2026).
  final VoidCallback? onOpenServers;

  @override
  Widget build(BuildContext context) {
    final state = openvpn.state;
    final on = state.connected;
    final error = openvpn.lastError;
    final selected = openvpn.selected;
    // Build 2145 (pro6 composition rebuild): the document
    // panel's mono meta line — protocol · port · cipher,
    // every part from the selected profile's own data (the
    // cipher via ovpnCipherLabel, as the Servers rows read
    // it); a part the profile does not carry is absent.
    final selectedRemote = selected?.firstRemote;
    final selectedCipher = selected == null
        ? null
        : ovpnCipherLabel(selected);
    final selectedMeta = selected == null
        ? ''
        : [
            selected.proto.toUpperCase(),
            if (selectedRemote != null) latDigits(selectedRemote.port),
            if (selectedCipher != null) selectedCipher.toUpperCase(),
          ].join(' · ');
    // Build 2116 (AP-05): LayoutBuilder page height, as on
    // the V2Ray/Psiphon homes — not the device height.
    return LayoutBuilder(
      builder: (context, constraints) => ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        children: [
          // Build 2074 (audit item 3): the top spacer is a capped
          // fraction of the viewport height, not a fixed 150dp.
          SizedBox(
            // Build 2092 (items 39/59): the shared home top
            // gap (was this page's own 0.18/150 variant).
            height: emberHomeTopGap(constraints.maxHeight),
          ),
        // Build 2145 (pro6 composition rebuild): the glass
        // status card leaves — the sample's centred hero
        // composition: the 'OpenVPN' hero word and the real
        // profile-count line centred over the map, the
        // selected profile as a document panel under them,
        // and the status area below carrying the real status
        // word at hero scale where the sample puts its
        // session numeral (no session count exists in the
        // app — that numeral is a recorded gap, not
        // invented). The AUTH/CERT rows of the sample's
        // panel are likewise a gap: the profile object
        // carries no cert verdict, and its saved-credential
        // state lives in the async vault, not on the
        // profile — both rows are omitted, not faked.
        Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text('OpenVPN', style: Ember.hero, textAlign: TextAlign.center),
            const SizedBox(height: 6),
            Text(
              // The settings page's own count wording.
              '${latDigits(openvpn.userProfiles.length)} '
              'imported profile(s)',
              style: Ember.caption,
              textAlign: TextAlign.center,
            ),
          ],
        ),
        if (selected != null) ...[
          const SizedBox(height: 16),
          _HairlinePanel(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    // The sample's document row: the orange
                    // file icon, as the Servers rows wear it.
                    const Icon(
                      Icons.description_outlined,
                      size: 24,
                      color: Ember.orange,
                    ),
                    const SizedBox(width: 11),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            selected.name,
                            style: Ember.heading.copyWith(
                              fontSize: Ember.fontTitle,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            selectedMeta,
                            style: Ember.caption.copyWith(
                              fontFamily: 'monospace',
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                // The running session's traffic, formerly the
                // separate running-profile card's line — same
                // condition, folded into the document panel.
                if (state.running &&
                    (state.upBytes > 0 || state.downBytes > 0)) ...[
                  const SizedBox(height: 8),
                  ovpnTrafficLine(state.downBytes, state.upBytes),
                ],
                // The country picker: the current selection,
                // one tap from changing it (2026 selection
                // contract — see the field's doc).
                if (!state.running) ...[
                  const SizedBox(height: 12),
                  InkWell(
                    onTap: onOpenServers,
                    borderRadius: BorderRadius.circular(10),
                    child: Padding(
                      // Build 2092 (item 32): the row's tap
                      // target reaches the 48 dp floor (was
                      // ~28 dp: 4 dp padding around a 20 dp
                      // icon).
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.vpn_key_rounded,
                            size: 20,
                            color: MapUi.dim,
                          ),
                          const SizedBox(width: 9),
                          Expanded(
                            child: Text(
                              selected.name,
                              style: Ember.body,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Text(
                            'Change',
                            // 2027 (v7 audit): the caption grey
                            // was too faint over the map —
                            // brightened to the audit's steel
                            // label tone (MapUi.steelLabel).
                            style: Ember.caption.copyWith(
                              color: MapUi.steelLabel,
                            ),
                          ),
                          const Icon(
                            Icons.chevron_right_rounded,
                            size: 18,
                            color: MapUi.faint,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
        const SizedBox(height: 20),
        // The status area: the status dot and the real
        // status word at hero scale, centred — the old status
        // card's first row, re-laid at the sample's numeral
        // position.
        Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                  color: on
                      ? Ember.green
                      : state.running
                      ? Ember.amber
                      : Ember.faint,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  on ? 'Connected' : state.phaseLabel,
                  style: Ember.hero,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Text(
          on && state.exitLine.isNotEmpty
              ? 'Exit: ${state.exitLine}'
              : selected != null
              ? 'Profile: ${selected.name}'
              : 'No profile selected.',
          style: Ember.body,
          textAlign: TextAlign.center,
        ),
        // Build 2125 (audit A25-25 / P-04 remainder):
        // a v4-only session's IPv6 rides direct — said
        // on the page, not left silent.
        if (on && !state.ipv6Captured) ...[
          const SizedBox(height: 6),
          Text(
            'IPv6 is not captured by this session — IPv6 '
            'traffic stays outside the tunnel and keeps '
            'your current IP address.',
            style: Ember.caption,
          ),
        ],
        // Build 2125 (audit A25-04): the kill-switch
        // hold names itself — the session is down,
        // but its TUN is held so traffic is blocked,
        // never direct.
        if (state.killSwitchHeld) ...[
          const SizedBox(height: 6),
          Text(
            'Kill switch holding: the session dropped, '
            'and its tunnel is being held so traffic '
            'stays blocked instead of going direct. '
            'Reconnect or disconnect to clear it.',
            style: Ember.caption,
          ),
        ],
        if (!state.available) ...[
          const SizedBox(height: 8),
          Text(
            'The OpenVPN core is not included in this build '
            '(it ships for arm64 phones).',
            style: Ember.caption,
          ),
        ],
        // Crash visibility (2026): a previous session that
        // ended without a clean stop names its last stage —
        // a silent death is no longer possible.
        if (!state.running &&
            (state.lastUnclean || state.lastExitReason.isNotEmpty)) ...[
          const SizedBox(height: 12),
          // Build 2145: flat hairline panel (was MapGlass);
          // the ember-tinted border that marks it as a
          // warning surface (2027 v7 audit) is kept.
          _HairlinePanel(
            borderColor: Ember.orange.withValues(alpha: 0.33),
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.warning_amber_rounded,
                      size: 16,
                      color: Ember.amber,
                    ),
                    const SizedBox(width: 7),
                    // Build 2074 (audit item 16): the header text
                    // is bounded — it ellipsizes instead of
                    // overflowing the card at large font scales.
                    Expanded(
                      child: Text(
                        'Last session ended unexpectedly',
                        style: Ember.heading,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (state.lastUnclean && state.lastStage.isNotEmpty)
                  Text(
                    'It stopped at stage "${state.lastStage}" with no '
                    'clean shutdown — the full trail is in the '
                    'engine log.',
                    style: Ember.body,
                  ),
                // Build 2028: when the trail captured the
                // exception itself, the card shows it — the
                // death names itself here, not only in a file.
                if (state.lastException.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  SelectableText(
                    state.lastException,
                    style: Ember.body.copyWith(fontFamily: 'monospace'),
                  ),
                ],
                if (state.lastExitReason.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(state.lastExitReason, style: Ember.body),
                ],
              ],
            ),
          ),
        ],
        if (error != null && !state.running) ...[
          const SizedBox(height: 12),
          // Build 2145: flat hairline panel (was MapGlass),
          // contents unchanged.
          _HairlinePanel(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.error_outline_rounded,
                      size: 16,
                      color: Ember.red,
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        'The OpenVPN engine failed',
                        style: Ember.heading,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                SelectableText(error, style: Ember.body),
                if (state.logTail.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text('Engine log (last lines)', style: Ember.caption),
                  const SizedBox(height: 4),
                  SelectableText(
                    state.logTail
                        .skip(
                          state.logTail.length > 8
                              ? state.logTail.length - 8
                              : 0,
                        )
                        .join('\n'),
                    style: Ember.caption.copyWith(fontFamily: 'monospace'),
                  ),
                ],
              ],
            ),
          ),
        ],
        // Build 2050 (audit F-H15): the import door on the
        // home page itself, whenever no session is running —
        // before this, the FIRST import (zero profiles, the
        // exact moment it matters) had no import anywhere on
        // this page, only a "Locations" pill into the servers
        // view.
        if (!state.running) ...[
          const SizedBox(height: 12),
          // Build 2145: flat hairline panel (was MapGlass);
          // the import actions take the sample's pairing —
          // the file import as the flat pill, the paste
          // import as an orange TEXT action, same labels,
          // same callbacks, in place.
          _HairlinePanel(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Your own profiles', style: Ember.heading),
                const SizedBox(height: 6),
                Text(
                  'Import a .ovpn file from storage, or paste '
                  'one. The profile lands in this engine\u2019s '
                  'list, selected and ready to connect.',
                  style: Ember.caption,
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    MapActionPill(
                      icon: Icons.folder_open_rounded,
                      label: 'Import file',
                      // Build 2144 (pro6 reskin): the import
                      // action wears the sample's orange.
                      primary: true,
                      onTap: () =>
                          unawaited(importOpenVpnFile(context, openvpn)),
                    ),
                    TextButton(
                      style: TextButton.styleFrom(
                        minimumSize: const Size(0, 48),
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                      ),
                      onPressed: () =>
                          unawaited(importOpenVpnPaste(context, openvpn)),
                      child: Text(
                        'Import paste',
                        style: Ember.heading.copyWith(color: Ember.orange),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
        // Build 2145: the separate running-profile card is
        // gone — the document panel above carries the
        // selected profile in every state, traffic line
        // included (same conditions as the old card's).
      ],
      ),
    );
  }
}

/// Renames one profile (build 2095, whole-app journey
/// audit #34): a form dialog over the controller's
/// renameProfile — id and credKey never change.
Future<void> _renameProfileDialog(
  BuildContext context,
  OpenVpnController controller,
  OvpnProfile profile,
) async {
  final controllerField = TextEditingController(text: profile.name);
  final name = await showEmberFormDialog<String>(
    context,
    title: 'Rename profile',
    content: TextField(
      controller: controllerField,
      autofocus: true,
      style: Ember.body,
      decoration: emberField(context, 'Profile name'),
      onSubmitted: (v) => Navigator.of(context).pop(v),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      TextButton(
        onPressed: () => Navigator.of(context).pop(controllerField.text),
        child: const Text('Rename'),
      ),
    ],
  );
  controllerField.dispose();
  if (name == null || name.trim().isEmpty || name.trim() == profile.name) {
    return;
  }
  await controller.renameProfile(profile.id, name);
}

/// Manages one profile's saved credentials (build 2028):
/// the only credential surface left — there is no global
/// account anymore. Opened from the profile row's long-press
/// menu. Shows what the vault can prove about the entry
/// ('ok' = decrypts on this device, 'unreadable' = present
/// but undecryptable, 'none'), and offers set/replace (with
/// the 2027 rule: every save ends in a visible outcome) and
/// remove. Values are never read back into the UI.
Future<void> showProfileCredentialsSheet(
  BuildContext context,
  OpenVpnController controller,
  OvpnProfile profile,
) async {
  if (profile.credKey.isEmpty) return;
  var status = await OpenVpnPlatform.credentialStatus(profile.credKey);
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: Ember.surface,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(profile.name, style: Ember.heading),
            const SizedBox(height: 6),
            Text(switch (status) {
              'ok' => 'Credentials saved on this device (keystore).',
              'unreadable' =>
                'Saved credentials could not be read on this device. '
                    'Set them again to replace the entry.',
              _ => 'No saved credentials for this profile.',
            }, style: Ember.body),
            const SizedBox(height: 14),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                EmberButton(
                  label: status == 'ok' ? 'Replace' : 'Set credentials',
                  onTap: () async {
                    final answer = await promptOpenVpnCredentials(
                      context,
                      profileName: profile.name,
                      forSaveOnly: true,
                    );
                    if (answer == null || answer.user.isEmpty) return;
                    var saved = false;
                    try {
                      saved = await OpenVpnPlatform.saveCredentials(
                        profile.credKey,
                        answer.user,
                        answer.pass,
                      );
                    } catch (_) {
                      // Build 2074 (audit item 6): reported below
                      // as a plain sentence; the raw error is not
                      // carried into the UI.
                      saved = false;
                    }
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          saved
                              ? 'Credentials saved for ${profile.name}'
                              : 'Could not save the credentials',
                        ),
                      ),
                    );
                    if (saved) {
                      status = await OpenVpnPlatform.credentialStatus(
                        profile.credKey,
                      );
                      setState(() {});
                    }
                  },
                ),
                if (status != 'none')
                  // Build 2082 (verification V-2): the last stock
                  // Material button on an engine page — a
                  // MapActionPill like the Import pills above, so
                  // the A-H3 one-button-language gate holds for
                  // this sheet too.
                  MapActionPill(
                    icon: Icons.delete_outline_rounded,
                    label: 'Remove saved',
                    onTap: () => unawaited(() async {
                      await OpenVpnPlatform.deleteCredentials(profile.credKey);
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            'Saved credentials removed for ${profile.name}',
                          ),
                        ),
                      );
                      status = 'none';
                      setState(() {});
                    }()),
                  ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

/// The Servers tab in OpenVPN mode (build 2028): the user's
/// imported profiles only — import from a file or by paste,
/// tap to select, long-press for the profile's credentials.
/// An honest empty state says to import a .ovpn.
/// The wording for an import failure (build 2025, kept).
/// Build 2074 (audit item 6): plain sentences only — the
/// core's raw rejection detail and any other raw StateError
/// message stay out of the SnackBar.
String ovpnImportErrorText(StateError e) {
  if (e.message == 'not-an-ovpn-profile') {
    return 'that text is not an OpenVPN client profile';
  }
  if (e.message.startsWith('core-rejected:')) {
    return 'the core rejected it';
  }
  return 'that profile could not be imported';
}

/// Plain sentence for an .ovpn intent-intake failure (build
/// 2085, audit F-H15) — the same sentences the file picker
/// shows for the same failures, so "Open with Ember" and the
/// in-app import never disagree about what went wrong.
String ovpnIntakeErrorText(String error) {
  if (error == 'file-too-large') {
    return 'That file is too large to import (256 KB max)';
  }
  return 'Could not read that file';
}

/// Imports profile [text] under [name] through the controller
/// and reports the outcome — the one import path every
/// OpenVPN surface shares (build 2050).
Future<void> importOpenVpnText(
  BuildContext context,
  OpenVpnController openvpn,
  String name,
  String text,
) async {
  try {
    final p = await openvpn.importProfile(name, text);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('Imported ${p.name}')));
  } on StateError catch (e) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      // Build 2092 (item 11): a plain sentence, not a
      // fragment after a colon.
      SnackBar(
        content: Text(
          'Import failed — ${ovpnImportErrorText(e)[0].toUpperCase()}'
          '${ovpnImportErrorText(e).substring(1)}',
        ),
      ),
    );
  }
}

/// The .ovpn FILE import (build 2050, audit F-H15): the
/// picker call is wrapped — a platform failure is a named
/// message now, not an uncaught exception — and an oversize
/// file (the native reader's 256 KB cap) says so instead of
/// reading as a cancelled pick.
Future<void> importOpenVpnFile(
  BuildContext context,
  OpenVpnController openvpn,
) async {
  final Map<String, String>? picked;
  try {
    picked = await OpenVpnPlatform.pickFile();
  } on PlatformException catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            e.message == 'file-too-large'
                ? 'That file is too large to import (256 KB max)'
                // Build 2074 (audit item 6): plain sentence —
                // the raw platform message/code stays out.
                : 'Could not read that file',
          ),
        ),
      );
    }
    return;
  }
  if (picked == null) return;
  // Build 2097 (IMP-2): no mounted check here — the pick
  // completing IS the user's intent, and importOpenVpnText
  // already adds through the controller before it gates
  // its messages on the context. Build 2096 discarded a
  // completed pick wholesale when the page had been
  // disposed mid-pick (the re-lock window), which read as
  // "file import does nothing at all".
  await importOpenVpnText(
    context,
    openvpn,
    picked['name'] ?? 'profile.ovpn',
    picked['content'] ?? '',
  );
}

/// The paste-a-profile dialog + import, shared by the
/// servers view and the home page (build 2050).
/// Build 2074 (audit item 26): the dialog is a StatefulWidget
/// that owns its text controller and disposes it with its
/// State — the 2050 helper disposed the controller the moment
/// showDialog returned, while the exit transition could still
/// have the field mounted (the used-after-dispose the
/// credentials dialog above was rebuilt to avoid in 2028).
Future<void> importOpenVpnPaste(
  BuildContext context,
  OpenVpnController openvpn,
) async {
  final text = await showDialog<String>(
    context: context,
    builder: (context) => const _PasteProfileDialog(),
  );
  if (text == null || !context.mounted) return;
  await importOpenVpnText(context, openvpn, 'Imported profile', text);
}

class _PasteProfileDialog extends StatefulWidget {
  const _PasteProfileDialog();

  @override
  State<_PasteProfileDialog> createState() => _PasteProfileDialogState();
}

class _PasteProfileDialogState extends State<_PasteProfileDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Paste a .ovpn profile', style: Ember.heading),
      // Build 2092 (item 31): scrollable like the other
      // form dialogs.
      content: SingleChildScrollView(
        child: TextField(
          controller: _controller,
          style: Ember.caption.copyWith(fontFamily: 'monospace'),
          maxLines: 12,
          decoration: emberField(context, 'client\ndev tun\nremote \u2026'),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        EmberButton(
          label: 'Import',
          onTap: () => Navigator.of(context).pop(_controller.text),
        ),
      ],
    );
  }
}

class OpenVpnServersView extends StatefulWidget {
  const OpenVpnServersView({super.key, required this.openvpn});

  final OpenVpnController openvpn;

  @override
  State<OpenVpnServersView> createState() => _OpenVpnServersViewState();
}

class _OpenVpnServersViewState extends State<OpenVpnServersView> {
  String _query = '';

  OpenVpnController get openvpn => widget.openvpn;

  Future<void> _importFile() => importOpenVpnFile(context, openvpn);

  Future<void> _importPaste() => importOpenVpnPaste(context, openvpn);

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    // Build 2095 (owner-reported appearance fix): the same
    // container-level frosted backing as the V2Ray list —
    // these profile rows (MapGlass blur: false) rendered on
    // the bare dotted map.
    return MapListFrost(
      child: ListenableBuilder(
        listenable: openvpn,
        builder: (context, _) {
          final shown = openvpn.userProfiles.where((p) {
            if (_query.isEmpty) return true;
            return p.name.toLowerCase().contains(_query.toLowerCase());
          }).toList();
          // Build 2055 (audit A-H4): slivers — the header panel
          // on its own, the profile rows lazily built below it.
          // The old form put every row in one giant blurred
          // MapGlass, all built eagerly.
          return CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  // Build 2145: the header panel goes flat —
                  // hairline panel, contents unchanged.
                  child: _HairlinePanel(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        MapPanelHeader(
                          title: 'OpenVPN profiles',
                          // Build 2150 (engine appearance audit
                          // E49-03): no onClose — the panel's ✕
                          // duplicated the shell header's BACK
                          // on this shell tab. BACK is the one
                          // way out.
                          actions: [
                            if (openvpn.pinging)
                              const SizedBox(
                                width: 19,
                                height: 19,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Ember.orange,
                                ),
                              )
                            else
                              MapGhostButton(
                                icon: Icons.bolt_rounded,
                                label: l.pingAll,
                                onTap: () => unawaited(openvpn.pingAll()),
                              ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Your own .ovpn profiles — import one, tap to '
                          'select, connect from Home. Long-press a '
                          'profile to manage its saved credentials.',
                          // Build 2138 (V-06): was caption at
                          // 10.5 sp — caption itself is the
                          // micro step now, no override needed.
                          style: Ember.caption,
                        ),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 10,
                          runSpacing: 10,
                          children: [
                            MapActionPill(
                              icon: Icons.folder_open_rounded,
                              label: 'Import file',
                              // Build 2144 (pro6 reskin): the
                              // import action wears the
                              // sample's orange.
                              primary: true,
                              onTap: _importFile,
                            ),
                            // Build 2145: the paste import is
                            // the sample's orange TEXT action —
                            // same label, same callback, in
                            // place beside the flat pill.
                            TextButton(
                              style: TextButton.styleFrom(
                                minimumSize: const Size(0, 48),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                ),
                              ),
                              onPressed: _importPaste,
                              child: Text(
                                'Import paste',
                                style: Ember.heading.copyWith(
                                  color: Ember.orange,
                                ),
                              ),
                            ),
                          ],
                        ),
                        if (openvpn.userProfiles.length > 1) ...[
                          const SizedBox(height: 12),
                          TextField(
                            onChanged: (v) => setState(() => _query = v),
                            style: Ember.body,
                            decoration: emberField(
                              context,
                              'Search profiles',
                              prefix: const Icon(
                                Icons.search_rounded,
                                color: Ember.faint,
                                size: 20,
                              ),
                            ),
                          ),
                        ],
                        const SizedBox(height: 6),
                        if (openvpn.userProfiles.isEmpty)
                          // Build 2116 (AP-19): the shared
                          // empty state, like the other lists.
                          const EmberEmpty(
                            icon: Icons.vpn_key_outlined,
                            text: 'No profiles yet — import a .ovpn '
                                'file to get started.',
                          )
                        else if (shown.isEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 10),
                            child: Text(
                              'No profile matches the search.',
                              style: Ember.body,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              if (shown.isNotEmpty)
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  sliver: SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (context, i) => _ProfileRow(
                        profile: shown[i],
                        selected: openvpn.selectedId == shown[i].id,
                        ping: openvpn.pings[shown[i].id],
                        divider:
                            i + 1 < shown.length &&
                            openvpn.selectedId != shown[i].id &&
                            openvpn.selectedId != shown[i + 1].id,
                        onTap: () => openvpn.select(shown[i].id),
                        // Build 2092 (item 7): the row delete
                        // confirms first, naming the profile —
                        // it fired on one tap before.
                        onDelete: () => unawaited(
                          _confirmDeleteProfile(context, openvpn, shown[i]),
                        ),
                        onPing: () => unawaited(openvpn.pingProfile(shown[i])),
                        onLongPress:
                            shown[i].needsAuth && !shown[i].hasInlineCredentials
                            ? () => unawaited(
                                showProfileCredentialsSheet(
                                  context,
                                  openvpn,
                                  shown[i],
                                ),
                              )
                            : null,
                        onCredentials:
                            shown[i].needsAuth && !shown[i].hasInlineCredentials
                            ? () => unawaited(
                                showProfileCredentialsSheet(
                                  context,
                                  openvpn,
                                  shown[i],
                                ),
                              )
                            : null,
                        onRename: () => unawaited(
                          _renameProfileDialog(context, openvpn, shown[i]),
                        ),
                      ),
                      childCount: shown.length,
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// The cipher a profile declares, read from its own config
/// text (build 2144, pro6 reskin): the `cipher` line's value,
/// else the first entry of `data-ciphers` — the sample's
/// document-row micro-line shows it beside protocol and port.
/// Null when the profile declares neither (the core's default
/// then applies, and the row simply omits it).
String? ovpnCipherLabel(OvpnProfile profile) {
  String? dataCipher;
  for (final raw in profile.config.split('\n')) {
    final parts = raw.trim().split(RegExp(r'\s+'));
    if (parts.length < 2) continue;
    final head = parts.first.toLowerCase();
    if (head == 'cipher') return parts[1];
    if (head == 'data-ciphers' && dataCipher == null) {
      dataCipher = parts[1].split(':').first;
    }
  }
  return dataCipher;
}

/// One selectable profile row (an imported profile), in the
/// Mozilla location row's shape. Long-press opens the
/// profile's saved-credentials manager when it has one.
class _ProfileRow extends StatelessWidget {
  const _ProfileRow({
    required this.profile,
    required this.selected,
    required this.onTap,
    this.ping,
    this.onDelete,
    this.onPing,
    this.onLongPress,
    this.onCredentials,
    this.onRename,
    this.divider = false,
  });

  final OvpnProfile profile;
  final bool selected;
  final VoidCallback onTap;
  final OvpnPing? ping;
  final VoidCallback? onDelete;
  final VoidCallback? onPing;
  final VoidCallback? onLongPress;

  /// Build 2095 (whole-app journey audit #51): the
  /// credentials manager was reachable ONLY by long-press —
  /// a visible button opens the same sheet.
  final VoidCallback? onCredentials;

  /// Build 2095 (whole-app journey audit #34): rename.
  final VoidCallback? onRename;

  /// A 1px hairline under this row (between unselected rows).
  final bool divider;

  @override
  Widget build(BuildContext context) {
    final p = profile;
    final primary = p.name;
    final remote = p.firstRemote;
    // Build 2074 (audit item 22): the row wears the shared
    // glass row container, matching WireGuard's profile rows
    // (MapGlass with blur: false), instead of sitting bare on
    // the map as a tint/hairline InkWell.
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      // Build 2145: the row's glass leaves — a flat hairline
      // container (solid fill, hairline edge) carries the
      // same InkWell, selection treatment and actions.
      child: Container(
        decoration: BoxDecoration(
          color: MapUi.card,
          border: Border.all(color: MapUi.line),
          borderRadius: MapUi.panelBorder,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          child: Container(
            // The selected row must read as selected at a glance
            // (2026): orange tint + border, the treatment the
            // Mozilla locations use — 2025 showed only a small
            // check circle, which the owner experienced as
            // "selection does not work at all".
            decoration: selected
                ? BoxDecoration(
                    color: Ember.orange.withValues(alpha: 0.07),
                    border: Border.all(
                      color: Ember.orange.withValues(alpha: 0.45),
                    ),
                    borderRadius: BorderRadius.circular(12),
                  )
                : divider
                ? const BoxDecoration(
                    border: Border(
                      // Build 2144: the blue-tinted hairline
                      // literal is neutralised to the palette's
                      // hairline token.
                      bottom: BorderSide(color: MapUi.line, width: 1),
                    ),
                  )
                : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      // Build 2144 (pro6 reskin): the profile
                      // reads as a document — the sample's
                      // orange file icon.
                      const Icon(
                        Icons.description_outlined,
                        size: 24,
                        color: Ember.orange,
                      ),
                      const SizedBox(width: 11),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              primary,
                              style: Ember.heading.copyWith(fontSize: Ember.fontTitle),
                              overflow: TextOverflow.ellipsis,
                            ),
                            Text(
                              // Build 2144 (pro6 reskin): the
                              // mono micro-line — protocol, port
                              // and the cipher the profile itself
                              // declares, from its own data.
                              remote != null
                                  ? '${remote.host}:${latDigits(remote.port)}'
                                        ' · ${p.proto.toUpperCase()}'
                                        '${ovpnCipherLabel(p) == null ? '' : ' · ${ovpnCipherLabel(p)!.toUpperCase()}'}'
                                  : '${p.proto.toUpperCase()}'
                                        '${ovpnCipherLabel(p) == null ? '' : ' · ${ovpnCipherLabel(p)!.toUpperCase()}'}',
                              style: Ember.caption.copyWith(
                                fontFamily: 'monospace',
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      if (ping != null && ping!.measured)
                        Text(
                          '${latDigits(ping!.ms)} ms',
                          style: TextStyle(
                            fontSize: Ember.fontBody,
                            fontWeight: FontWeight.w700,
                            color: mapPingColor(ping!.ms),
                          ),
                        )
                      else if (ping != null &&
                          ping!.method == 'UNSUPPORTED_CONTROL_AUTH')
                        Text('—', style: Ember.caption),
                      if (onPing != null) ...[
                        const SizedBox(width: 4),
                        IconButton(
                          onPressed: onPing,
                          icon: const Icon(
                            Icons.bolt_rounded,
                            size: 18,
                            color: MapUi.dim,
                          ),
                          tooltip: 'Measure latency',
                        ),
                      ],
                      if (selected) ...[
                        const SizedBox(width: 8),
                        Container(
                          width: 20,
                          height: 20,
                          decoration: const BoxDecoration(
                            gradient: Ember.gradient,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.check_rounded,
                            color: Color(0xFF1A1206),
                            size: 13,
                          ),
                        ),
                      ],
                      if (onCredentials != null)
                        IconButton(
                          onPressed: onCredentials,
                          icon: const Icon(
                            Icons.key_rounded,
                            size: 19,
                            color: MapUi.dim,
                          ),
                          tooltip: 'Saved credentials',
                        ),
                      if (onRename != null)
                        IconButton(
                          onPressed: onRename,
                          icon: const Icon(
                            Icons.edit_rounded,
                            size: 19,
                            color: MapUi.dim,
                          ),
                          tooltip: 'Rename profile',
                        ),
                      if (onDelete != null)
                        IconButton(
                          onPressed: onDelete,
                          icon: const Icon(
                            Icons.delete_outline_rounded,
                            size: 19,
                            color: MapUi.dim,
                          ),
                          tooltip: 'Delete profile',
                        ),
                    ],
                  ),
                  if (p.unsupported.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      'Not honoured on a phone: ${p.unsupported.join(', ')}',
                      style: Ember.caption.copyWith(color: Ember.amber),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The status page in OpenVPN mode (build 2028): session
/// state and the crash diagnostics, nothing else. It
/// replaces the TunnelBear Accounts tab, which the owner's
/// generic-client ruling removed — credentials are managed
/// per profile (Servers tab, long-press), never on a global
/// account page. This page remains reachable only where the
/// shell's shared tab slot lands in OpenVPN mode.
class OpenVpnStatusView extends StatelessWidget {
  const OpenVpnStatusView({super.key, required this.openvpn});

  final OpenVpnController openvpn;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: openvpn,
      builder: (context, _) {
        final state = openvpn.state;
        return ListView(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
          children: [
            Center(child: Text('Status', style: Ember.microLabel)),
            // Build 2144 (pro6 reskin): the centred editorial
            // composition — the engine title in the samples'
            // hero tier. (No active-session numeral: the app
            // tracks a single session's state, not a count, so
            // the status block below stays as the record.)
            Center(
              child: Text(
                'OpenVPN',
                style: Ember.hero.copyWith(
                  shadows: const [Shadow(color: Colors.black, blurRadius: 6)],
                ),
              ),
            ),
            const SizedBox(height: 16),
            // Build 2145: flat hairline panel (was MapGlass).
            // When this panel carries the crash diagnostics,
            // it wears the ember-tinted border, like the
            // home's diagnostics panel (2027 v7 audit); the
            // luminous ring leaves with the glass.
            _HairlinePanel(
              borderColor:
                  (!state.running &&
                      (state.lastStage.isNotEmpty ||
                          state.lastExitReason.isNotEmpty))
                  ? Ember.orange.withValues(alpha: 0.33)
                  : null,
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 9,
                        height: 9,
                        decoration: BoxDecoration(
                          color: state.connected
                              ? Ember.green
                              : state.running
                              ? Ember.amber
                              : Ember.faint,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        state.connected
                            ? l.statusConnected
                            : state.running
                            ? l.stateConnecting
                            : l.statusDisconnected,
                        style: Ember.heading,
                      ),
                    ],
                  ),
                  if (state.exitLine.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text('Exit: ${state.exitLine}', style: Ember.body),
                  ],
                  if (state.upBytes > 0 || state.downBytes > 0) ...[
                    const SizedBox(height: 6),
                    ovpnTrafficLine(state.downBytes, state.upBytes),
                  ],
                  // Crash diagnostics (2026): the breadcrumb
                  // trail's last stage + the system's exit
                  // reason, where the owner can read them.
                  // Build 2028 adds the exception text itself.
                  if (!state.running &&
                      (state.lastStage.isNotEmpty ||
                          state.lastExitReason.isNotEmpty ||
                          state.lastException.isNotEmpty)) ...[
                    const SizedBox(height: 10),
                    if (state.lastStage.isNotEmpty)
                      Text(
                        'Last session stage: ${state.lastStage}'
                        '${state.lastUnclean ? ' (no clean stop)' : ''}',
                        style: Ember.caption,
                      ),
                    if (state.lastException.isNotEmpty)
                      SelectableText(
                        state.lastException,
                        style: Ember.caption.copyWith(fontFamily: 'monospace'),
                      ),
                    if (state.lastExitReason.isNotEmpty)
                      Text(state.lastExitReason, style: Ember.caption),
                  ],
                  const SizedBox(height: 10),
                  Text(
                    'OpenVPN here is a plain client for your own '
                    '.ovpn profiles — manage them and their '
                    'saved credentials in the Servers tab.',
                    style: Ember.caption,
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// The OpenVPN engine's settings page: profile counts, the
/// credential store's state, and the log viewer.
class OpenVpnSettingsPage extends StatelessWidget {
  const OpenVpnSettingsPage({super.key, required this.openvpn});

  final OpenVpnController openvpn;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Ember.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Ember.text,
        title: Text('OpenVPN', style: Ember.heading),
      ),
      body: EmberBackground(banded: true, 
        child: ListenableBuilder(
          listenable: openvpn,
          builder: (context, _) {
            return ListView(
              padding: EdgeInsets.fromLTRB(18, MediaQuery.of(context).padding.top + kToolbarHeight + 8, 18, 18),
              children: [
                MapGlass(
        blur: false,
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Profiles', style: Ember.heading),
                      const SizedBox(height: 6),
                      Text(
                        '${latDigits(openvpn.userProfiles.length)} '
                        'imported profile(s). OpenVPN is a plain '
                        'client — import your own .ovpn files in '
                        'the Servers tab.',
                        style: Ember.body,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Credentials are kept in the system keystore '
                        'and never leave the device.',
                        style: Ember.caption,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                MapGlass(
        blur: false,
                  padding: const EdgeInsets.all(16),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => OpenVpnLogsPage(openvpn: openvpn),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.terminal_rounded, color: Ember.dim),
                      const SizedBox(width: 10),
                      Expanded(child: Text('Engine logs', style: Ember.body)),
                      Icon(Icons.chevron_right_rounded, color: MapUi.faint),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// The OpenVPN log viewer (build 2028): TWO surfaces — the
/// session trail (breadcrumbs: every connect's stage markers,
/// including any terminate / run_exception line) and the
/// service's engine log. Before this build only the engine
/// log was shown, and a session dying early writes almost
/// nothing to it — the owner's "my log is empty" while the
/// trail that names the death sat unread in another file.
/// Build 2092 (item 7): the Servers-tab row delete asks
/// first, naming the profile — it fired on one tap before.
Future<void> _confirmDeleteProfile(
  BuildContext context,
  OpenVpnController controller,
  OvpnProfile profile,
) async {
  final confirmed = await showEmberConfirm(
    context,
    title: 'Delete profile?',
    // Build 2098 (post-2097 audit L17): the disconnect-first
    // disclosure, matching the multi-delete wording.
    message:
        'Delete "${profile.name}"? This cannot be undone. '
        'If it is connected, it is disconnected first.',
    confirmLabel: 'Delete',
  );
  if (confirmed) await controller.deleteProfile(profile.id);
}

class OpenVpnLogsPage extends StatefulWidget {
  const OpenVpnLogsPage({super.key, required this.openvpn});

  final OpenVpnController openvpn;

  @override
  State<OpenVpnLogsPage> createState() => _OpenVpnLogsPageState();
}

class _OpenVpnLogsPageState extends State<OpenVpnLogsPage> {
  late Future<({String trail, String logs})> _bundle = widget.openvpn
      .readLogBundle();

  void _reload() => setState(() => _bundle = widget.openvpn.readLogBundle());

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Ember.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Ember.text,
        title: Text('OpenVPN logs', style: Ember.heading),
        actions: [
          IconButton(
            onPressed: _reload,
            icon: const Icon(Icons.refresh_rounded, color: Ember.dim),
          ),
          // Build 2092 (item 51): Clear carries a tooltip
          // and confirms first, like the other log pages.
          IconButton(
            tooltip: 'Clear logs',
            onPressed: () async {
              final confirmed = await showEmberConfirm(
                context,
                title: 'Clear logs?',
                message: 'Delete the saved OpenVPN logs?',
                confirmLabel: 'Clear',
              );
              if (!confirmed) return;
              await widget.openvpn.clearLogs();
              _reload();
            },
            icon: const Icon(Icons.delete_outline_rounded, color: Ember.dim),
          ),
        ],
      ),
      body: EmberBackground(banded: true, 
        child: FutureBuilder<({String trail, String logs})>(
          future: _bundle,
          builder: (context, snap) {
            // Build 2074 (audit item 8): a loading or failed
            // read is not an empty log — spinner while waiting,
            // an error line on failure, "no logs" only when a
            // read truly came back empty (the section builder
            // below already renders that case).
            if (snap.connectionState == ConnectionState.waiting) {
              return const Center(
                child: CircularProgressIndicator(color: Ember.orange),
              );
            }
            if (snap.hasError) {
              return ListView(
                padding: EdgeInsets.fromLTRB(18, MediaQuery.of(context).padding.top + kToolbarHeight + 8, 18, 18),
                children: [
                  GlassCard(
                    padding: const EdgeInsets.all(13),
                    child: Text(
                      'The logs could not be loaded.',
                      style: Ember.body,
                    ),
                  ),
                ],
              );
            }
            final trail = snap.data?.trail ?? '';
            final logs = snap.data?.logs ?? '';
            final all = '— Session trail —\n$trail\n\n— Engine log —\n$logs';
            Widget section(String title, String text) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Ember.heading),
                const SizedBox(height: 6),
                GlassCard(
                  padding: const EdgeInsets.all(13),
                  child: SelectableText(
                    text.isEmpty ? l.noLogs : text,
                    style: Ember.caption.copyWith(fontFamily: 'monospace'),
                  ),
                ),
              ],
            );
            return ListView(
              padding: EdgeInsets.fromLTRB(18, MediaQuery.of(context).padding.top + kToolbarHeight + 8, 18, 18),
              children: [
                if (snap.hasData)
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: TextButton.icon(
                      // Build 2092 (item 51): the Copy all
                      // action reaches the 48 dp floor.
                      style: TextButton.styleFrom(
                        minimumSize: const Size(0, 48),
                      ),
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: all));
                        if (context.mounted) {
                          ScaffoldMessenger.of(
                            context,
                          ).showSnackBar(SnackBar(content: Text(l.logsCopied)));
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
                section('Session trail', trail),
                const SizedBox(height: 18),
                section('Engine log', logs),
              ],
            );
          },
        ),
      ),
    );
  }
}
