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
import 'ember_format.dart';
import 'ember_theme.dart';
import 'map_widgets.dart';

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
      backgroundColor: MapUi.panelFill,
      title: Text(widget.profileName, style: Ember.heading),
      content: Column(
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
            CheckboxListTile(
              value: _save,
              onChanged: (v) => setState(() => _save = v ?? false),
              title: Text(
                'Save on this device (keystore)',
                style: Ember.caption,
              ),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
              dense: true,
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop((
            user: _user.text.trim(),
            pass: _pass.text,
            save: widget.forSaveOnly || _save,
          )),
          child: Text(widget.forSaveOnly ? 'Save' : 'Connect'),
        ),
      ],
    );
  }
}

/// Connects [controller]'s selected profile, asking for
/// credentials when the controller says they're required —
/// or when a saved entry exists but cannot be read on this
/// device (build 2027: 'credentials-unreadable'; entering
/// them again replaces the entry). Shared by the servers
/// view's rows and the shell's toggle.
Future<void> connectOpenVpnWithPrompt(
  BuildContext context,
  OpenVpnController controller,
) async {
  try {
    await controller.connect();
  } on StateError catch (e) {
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
      Object? saveError;
      try {
        saved = await OpenVpnPlatform.saveCredentials(
          p.credKey,
          answer.user,
          answer.pass,
        );
      } catch (err) {
        saveError = err;
      }
      if (!saved && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              saveError == null
                  ? 'Could not save the credentials on this device'
                  : 'Could not save the credentials ($saveError)',
            ),
          ),
        );
      }
    }
    await controller.connect(user: answer.user, pass: answer.pass);
  }
}

/// The OpenVPN home: a status card floating over the map,
/// the selected-profile card under it, the exit card when
/// connected, and — loudly — the failure card with the log
/// tail when a connect went wrong.
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
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      children: [
        const SizedBox(height: 170),
        MapGlass(
          // Build 2026 (Gemini v6 audit): no more 0.8-width
          // wrapper — the status card and the profile card
          // below share the full width and radius; the
          // disconnected card carries the diagonal glass
          // rim (luminous), the connected one the orange rim.
          rim: on,
          luminous: !on,
          borderColor: on ? Ember.orange.withValues(alpha: 0.55) : null,
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
                      color: on
                          ? Ember.green
                          : state.running
                          ? Ember.amber
                          : Ember.faint,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      on ? 'Connected' : state.phaseLabel,
                      style: Ember.heading,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                on && state.exitLine.isNotEmpty
                    ? 'Exit: ${state.exitLine}'
                    : selected != null
                    ? 'Profile: ${selected.name}'
                    : 'No profile selected.',
                style: Ember.body,
              ),
              if (!state.available) ...[
                const SizedBox(height: 8),
                Text(
                  'The OpenVPN core is not included in this build '
                  '(it ships for arm64 phones).',
                  style: Ember.caption,
                ),
              ],
              // The country picker: the current selection,
              // one tap from changing it (2026 selection
              // contract — see the field's doc).
              if (selected != null && !state.running) ...[
                const SizedBox(height: 12),
                InkWell(
                  onTap: onOpenServers,
                  borderRadius: BorderRadius.circular(10),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
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
                          // brightened to the audit's #9BB0C7.
                          style: Ember.caption.copyWith(
                            color: const Color(0xFF9BB0C7),
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
        // Crash visibility (2026): a previous session that
        // ended without a clean stop names its last stage —
        // a silent death is no longer possible.
        if (!state.running &&
            (state.lastUnclean || state.lastExitReason.isNotEmpty)) ...[
          const SizedBox(height: 12),
          MapGlass(
            // 2027 (v7 audit): the diagnostics card wears the
            // ember-tinted border so it reads as a warning
            // surface, not another content card.
            borderColor: const Color(0x55FF8533),
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
                    Text(
                      'Last session ended unexpectedly',
                      style: Ember.heading,
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
          MapGlass(
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
                    Text('The OpenVPN engine failed', style: Ember.heading),
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
        if (state.running && selected != null) ...[
          const SizedBox(height: 12),
          MapGlass(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(selected.name, style: Ember.heading),
                const SizedBox(height: 8),
                if (selected.firstRemote != null)
                  Text(
                    '${selected.firstRemote!.host}:${selected.firstRemote!.port}'
                    ' · ${selected.proto.toUpperCase()}',
                    style: Ember.body,
                  ),
                if (state.upBytes > 0 || state.downBytes > 0) ...[
                  const SizedBox(height: 6),
                  ovpnTrafficLine(state.downBytes, state.upBytes),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }
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
    backgroundColor: MapUi.panelFill,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(profile.name, style: Ember.heading),
            const SizedBox(height: 6),
            Text(
              switch (status) {
                'ok' => 'Credentials saved on this device (keystore).',
                'unreadable' =>
                  'Saved credentials could not be read on this device. '
                      'Set them again to replace the entry.',
                _ => 'No saved credentials for this profile.',
              },
              style: Ember.body,
            ),
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
                    Object? failure;
                    try {
                      saved = await OpenVpnPlatform.saveCredentials(
                        profile.credKey,
                        answer.user,
                        answer.pass,
                      );
                    } catch (e) {
                      failure = e;
                    }
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          saved
                              ? 'Credentials saved for ${profile.name}'
                              : 'Could not save the credentials'
                                    '${failure == null ? '' : ' ($failure)'}',
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
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Color(0x5952759C)),
                    ),
                    onPressed: () async {
                      await OpenVpnPlatform.deleteCredentials(
                        profile.credKey,
                      );
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
                    },
                    child: const Text('Remove saved'),
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
class OpenVpnServersView extends StatefulWidget {
  const OpenVpnServersView({super.key, required this.openvpn, this.onClose});

  final OpenVpnController openvpn;
  final VoidCallback? onClose;

  @override
  State<OpenVpnServersView> createState() => _OpenVpnServersViewState();
}

class _OpenVpnServersViewState extends State<OpenVpnServersView> {
  String _query = '';

  OpenVpnController get openvpn => widget.openvpn;

  Future<void> _importFile() async {
    final picked = await OpenVpnPlatform.pickFile();
    if (picked == null || !mounted) return;
    await _import(picked['name'] ?? 'profile.ovpn', picked['content'] ?? '');
  }

  Future<void> _importPaste() async {
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: MapUi.panelFill,
        title: Text('Paste a .ovpn profile', style: Ember.heading),
        content: TextField(
          controller: controller,
          style: Ember.caption.copyWith(fontFamily: 'monospace'),
          maxLines: 12,
          decoration: emberField(context, 'client\ndev tun\nremote …'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Import'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (text == null || !mounted) return;
    await _import('Imported profile', text);
  }

  Future<void> _import(String name, String text) async {
    try {
      final p = await openvpn.importProfile(name, text);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Imported ${p.name}')));
    } on StateError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Import failed: ${_importErrorText(e)}')),
      );
    }
  }

  String _importErrorText(StateError e) {
    if (e.message == 'not-an-ovpn-profile') {
      return 'that text is not an OpenVPN client profile';
    }
    if (e.message.startsWith('core-rejected:')) {
      return 'the core rejected it (${e.message.substring(14)})';
    }
    return e.message;
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: openvpn,
      builder: (context, _) {
        final shown = openvpn.userProfiles.where((p) {
          if (_query.isEmpty) return true;
          return p.name.toLowerCase().contains(_query.toLowerCase());
        }).toList();
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          children: [
            MapGlass(
              luminous: true,
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  MapPanelHeader(
                    title: 'OpenVPN profiles',
                    onClose: widget.onClose,
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
                    'Your own .ovpn profiles — import one from a '
                    'file or paste it, tap to select, then '
                    'connect from Home. If a profile asks for a '
                    'username and password, Connect asks at '
                    'connect time; long-press a profile to manage '
                    'its saved credentials.',
                    style: Ember.caption.copyWith(fontSize: 10.5),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      OutlinedButton.icon(
                        onPressed: _importFile,
                        icon: const Icon(Icons.folder_open_rounded, size: 17),
                        label: const Text('Import file'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _importPaste,
                        icon: const Icon(Icons.content_paste_rounded, size: 17),
                        label: const Text('Import paste'),
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
                  for (var i = 0; i < shown.length; i++)
                    _ProfileRow(
                      profile: shown[i],
                      selected: openvpn.selectedId == shown[i].id,
                      ping: openvpn.pings[shown[i].id],
                      divider:
                          i + 1 < shown.length &&
                          openvpn.selectedId != shown[i].id &&
                          openvpn.selectedId != shown[i + 1].id,
                      onTap: () => openvpn.select(shown[i].id),
                      onDelete: () => openvpn.deleteProfile(shown[i].id),
                      onPing: () => unawaited(openvpn.pingProfile(shown[i])),
                      onLongPress:
                          shown[i].needsAuth &&
                              !shown[i].hasInlineCredentials
                          ? () => unawaited(
                              showProfileCredentialsSheet(
                                context,
                                openvpn,
                                shown[i],
                              ),
                            )
                          : null,
                    ),
                  if (openvpn.userProfiles.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text(
                        'No profiles yet — import a .ovpn file to '
                        'get started.',
                        style: Ember.body,
                      ),
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
          ],
        );
      },
    );
  }
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
    this.divider = false,
  });

  final OvpnProfile profile;
  final bool selected;
  final VoidCallback onTap;
  final OvpnPing? ping;
  final VoidCallback? onDelete;
  final VoidCallback? onPing;
  final VoidCallback? onLongPress;

  /// A 1px hairline under this row (between unselected rows).
  final bool divider;

  @override
  Widget build(BuildContext context) {
    final p = profile;
    final primary = p.name;
    final remote = p.firstRemote;
    return InkWell(
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
                border: Border.all(color: Ember.orange.withValues(alpha: 0.45)),
                borderRadius: BorderRadius.circular(12),
              )
            : divider
            ? const BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: Color(0x2252759C), width: 1),
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
                  const Icon(
                    Icons.vpn_key_rounded,
                    size: 24,
                    color: MapUi.dim,
                  ),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          primary,
                          style: Ember.heading.copyWith(fontSize: 14.5),
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          remote != null
                              ? '${remote.host}:${remote.port}'
                                    ' · ${p.proto.toUpperCase()}'
                              : p.proto.toUpperCase(),
                          style: Ember.caption,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  if (ping != null && ping!.measured)
                    Text(
                      '${latDigits(ping!.ms)} ms',
                      style: TextStyle(
                        fontSize: 13,
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
            Center(child: Text('Status', style: Ember.title)),
            Center(
              child: Text(
                'OpenVPN',
                style: Ember.caption.copyWith(
                  color: const Color(0xFF9BB0C7),
                  shadows: const [Shadow(color: Colors.black, blurRadius: 6)],
                ),
              ),
            ),
            const SizedBox(height: 16),
            MapGlass(
              // When this card carries the crash diagnostics,
              // it trades the luminous ring for the ember-
              // tinted border, like the home's diagnostics
              // card (2027 v7 audit).
              luminous:
                  state.running ||
                  (state.lastStage.isEmpty && state.lastExitReason.isEmpty),
              borderColor:
                  (!state.running &&
                      (state.lastStage.isNotEmpty ||
                          state.lastExitReason.isNotEmpty))
                  ? const Color(0x55FF8533)
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
                        style: Ember.caption.copyWith(
                          fontFamily: 'monospace',
                        ),
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
      backgroundColor: Ember.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Ember.text,
        title: Text('OpenVPN', style: Ember.heading),
      ),
      body: EmberBackground(
        child: ListenableBuilder(
          listenable: openvpn,
          builder: (context, _) {
            return ListView(
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 18),
              children: [
                MapGlass(
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
          IconButton(
            onPressed: () async {
              await widget.openvpn.clearLogs();
              _reload();
            },
            icon: const Icon(Icons.delete_outline_rounded, color: Ember.dim),
          ),
        ],
      ),
      body: EmberBackground(
        child: FutureBuilder<({String trail, String logs})>(
          future: _bundle,
          builder: (context, snap) {
            final trail = snap.data?.trail ?? '';
            final logs = snap.data?.logs ?? '';
            final all = '— Session trail —\n$trail\n\n— Engine log —\n$logs';
            Widget section(String title, String text) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Ember.heading),
                const SizedBox(height: 6),
                SelectableText(
                  text.isEmpty ? l.noLogs : text,
                  style: Ember.caption.copyWith(fontFamily: 'monospace'),
                ),
              ],
            );
            return ListView(
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 18),
              children: [
                if (snap.hasData)
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: TextButton.icon(
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
                      label: Text(l.logsCopied, style: Ember.caption),
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
