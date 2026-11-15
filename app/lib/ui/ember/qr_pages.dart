/// Paste import, QR scanning and QR display for V2Ray configs — all
/// in the Ember sheet/dialog styling.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../l10n/app_localizations.dart';
import '../../xray/lantern_import.dart';
import '../../xray/profile_codec.dart';
import '../../xray/shared_link.dart';
import '../../xray/sub_fetcher.dart';
import '../../xray/xray_controller.dart';
import '../../xray/xray_models.dart';
import 'ember_theme.dart';
import 'map_widgets.dart';

String profileLinkOf(Profile p) => profileToLink(p);

/// Shows the outcome of an import: the imported count, or the
/// first Lantern error when a Lantern link was the only thing
/// pasted and it failed.
void _showImportResult(
  BuildContext context,
  AppLocalizations l,
  ({int added, List<String> errors}) result,
) {
  final failed = result.added == 0 && result.errors.isNotEmpty;
  // Build 2074 (audit item 6): the parser's raw error never
  // reaches the SnackBar — a plain sentence for the user, the
  // detail to diagnostics only (the build 2070 pattern).
  if (failed) debugPrint('Ember import failed: ${result.errors.first}');
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        result.added > 0
            ? l.importedCount(result.added)
            : failed
            ? 'That link could not be imported. Check it and try again.'
            : l.nothingImported,
      ),
      duration: failed
          ? const Duration(seconds: 6)
          : const Duration(seconds: 4),
    ),
  );
}

/// When [text] carries a protected share link (build 2030),
/// asks for its password and returns the text with the link
/// decrypted in place. Null = abort (cancelled or a wrong
/// password). An expired link still unlocks — expiry is
/// advisory — and says so.
Future<String?> _unlockIfNeeded(BuildContext context, String text) async {
  if (!containsProtectedShare(text)) return text;
  final controller = TextEditingController();
  final password = await showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('Protected link', style: Ember.heading),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'This share link is protected with a password.',
            style: Ember.dimStyle,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: controller,
            obscureText: true,
            autofocus: true,
            style: Ember.body,
            decoration: emberField(context, 'Password'),
            onSubmitted: (v) => Navigator.of(dialogContext).pop(v),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(controller.text),
          child: const Text('Unlock'),
        ),
      ],
    ),
  );
  if (password == null || password.isEmpty) return null;
  var expired = false;
  final unlocked = unlockProtectedShares(
    text,
    password,
    onExpired: () => expired = true,
  );
  if (unlocked == null) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('That password did not open the protected link.'),
          duration: Duration(seconds: 5),
        ),
      );
    }
    return null;
  }
  if (expired && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Note: this link was past its expiry — imported '
          'anyway (expiry is advisory).',
        ),
        duration: Duration(seconds: 5),
      ),
    );
  }
  return unlocked;
}

/// Imports [text] (share links and/or Lantern private-server links)
/// and reports the outcome via [_showImportResult].
Future<void> _importWithFeedback(
  BuildContext context,
  XrayController xray,
  String text,
) async {
  final l = AppLocalizations.of(context);
  final unlocked = await _unlockIfNeeded(context, text);
  if (unlocked == null || !context.mounted) return;
  final result = await xray.importLinksAsync(unlocked);
  if (!context.mounted) return;
  _showImportResult(context, l, result);
}

/// The paste-import sheet: a big field for links (or a subscription
/// body), pre-filled with the clipboard when it looks like one.
Future<void> showPasteSheet(BuildContext context, XrayController xray) async {
  final l = AppLocalizations.of(context);
  final controller = TextEditingController();
  try {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text ?? '';
    if (text.contains('://') || containsLanternPrivateServerLink(text)) {
      controller.text = text;
    }
  } catch (_) {
    // No clipboard access: an empty field.
  }
  if (!context.mounted) return;
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
        // Build 2056 (audit A-H8): the sheet scrolled nowhere
        // — on a short screen with the keyboard open the Import
        // button was unreachable.
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(l.addByPaste, style: Ember.heading),
              const SizedBox(height: 6),
              Text(l.pasteHint, style: Ember.caption),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                minLines: 4,
                maxLines: 8,
                style: Ember.body,
                decoration: emberField(context, 'vless://…'),
              ),
              const SizedBox(height: 14),
              EmberButton(
                label: l.importAction,
                icon: Icons.download_rounded,
                onTap: busy
                    ? null
                    : () async {
                        setSheetState(() => busy = true);
                        final unlocked = await _unlockIfNeeded(
                          sheetContext,
                          controller.text,
                        );
                        if (unlocked == null) {
                          if (sheetContext.mounted) {
                            setSheetState(() => busy = false);
                          }
                          return;
                        }
                        final result = await xray.importLinksAsync(unlocked);
                        if (!sheetContext.mounted) return;
                        Navigator.of(sheetContext).pop();
                        if (context.mounted) {
                          _showImportResult(context, l, result);
                        }
                      },
              ),
              if (busy) ...[
                const SizedBox(height: 12),
                const Center(
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: Ember.orange,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}

/// Opens the camera scanner; the first code found is imported as links
/// (or followed as a subscription URL when it is an http link).
Future<void> scanAndImport(BuildContext context, XrayController xray) async {
  final l = AppLocalizations.of(context);
  final code = await Navigator.of(context)
      .push<String>(MaterialPageRoute(builder: (_) => const _ScannerPage()));
  if (code == null || !context.mounted) return;
  // A Lantern private-server link is an https URL too, but it is an
  // invite to resolve, not a subscription: route it to the importer
  // before the subscription branch can claim it.
  if (containsLanternPrivateServerLink(code)) {
    await _importWithFeedback(context, xray, code);
    return;
  }
  if (code.startsWith('http://') || code.startsWith('https://')) {
    try {
      await xray.addSubscription(code);
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(l.subAdded)));
      }
    } catch (e) {
      if (context.mounted) {
        // Build 2050 (audit C-2): the fetcher's specific words.
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(subFetchErrorText(e, fallback: l.subUpdateFailed)),
            duration: const Duration(seconds: 6),
          ),
        );
      }
    }
    return;
  }
  await _importWithFeedback(context, xray, code);
}

class _ScannerPage extends StatefulWidget {
  const _ScannerPage();

  @override
  State<_ScannerPage> createState() => _ScannerPageState();
}

class _ScannerPageState extends State<_ScannerPage> {
  final MobileScannerController _controller = MobileScannerController();
  bool _done = false;
  bool _torch = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    // Build 2074 (audit item 24): the frame is sized from the
    // viewport, not fixed at 250 — on short/landscape screens
    // the fixed frame collided with the hint column below.
    final viewSize = MediaQuery.sizeOf(context);
    final frameSide = (viewSize.shortestSide * 0.68).clamp(180.0, 280.0);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Ember.text,
        title: Text(l.addByQr, style: Ember.heading),
      ),
      body: Stack(
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: (capture) {
              if (_done) return;
              for (final barcode in capture.barcodes) {
                final value = barcode.rawValue;
                if (value != null && value.isNotEmpty) {
                  _done = true;
                  Navigator.of(context).pop(value);
                  return;
                }
              }
            },
          ),
          Center(
            child: Container(
              width: frameSide,
              height: frameSide,
              decoration: BoxDecoration(
                border: Border.all(color: Ember.orange, width: 2.5),
                borderRadius: BorderRadius.circular(24),
              ),
            ),
          ),
          // Build 2056 (audit Batch 11): the scanner gave no
          // guidance — no hint text, no torch toggle.
          // Build 2074 (audit item 24): the column sits in a
          // SafeArea so the pill never slides under the
          // gesture bar on short screens.
          Positioned(
            left: 24,
            right: 24,
            bottom: 12,
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Point the camera at a QR code — a config link or a subscription URL.',
                    style: Ember.caption,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  MapActionPill(
                    icon: _torch
                        ? Icons.flashlight_off_rounded
                        : Icons.flashlight_on_rounded,
                    label: _torch ? 'Torch off' : 'Torch on',
                    onTap: () async {
                      await _controller.toggleTorch();
                      if (mounted) setState(() => _torch = !_torch);
                    },
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Shows a config's link as a QR code for another device to scan.
Future<void> showProfileQr(BuildContext context, Profile profile) =>
    // Build 2045: the dialog titles the config the user sees;
    // the link itself still carries the server name.
    _showQrDialog(
      context,
      title: profile.displayName,
      data: profileToLink(profile),
    );

/// Shares a whole subscription as ONE QR code (build 2033):
/// the payload is the subscription URL itself — the app's
/// own scanner already routes a scanned http(s) code that is
/// not a single config to "add subscription", so the other
/// device lands on the same subscription with one scan. The
/// name is NOT carried (the receiver names it from the
/// provider's profile-title or the host, like any pasted
/// subscription URL).
Future<void> showSubscriptionQr(BuildContext context, Subscription sub) =>
    _showQrDialog(
      context,
      title: sub.name.isEmpty ? 'Subscription' : sub.name,
      data: sub.url,
      hint:
          'Scan with Ember on another device to add this '
          'subscription there.',
    );

Future<void> _showQrDialog(
  BuildContext context, {
  required String title,
  required String data,
  String? hint,
}) async {
  final l = AppLocalizations.of(context);
  final link = data;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      // Build 2059 (audit §6 appearance low): the title is a
      // profile/subscription name — ellipsis, never overflow; the
      // dialog shape/background come from the app theme now.
      title: Text(
        title,
        style: Ember.heading,
        overflow: TextOverflow.ellipsis,
        maxLines: 1,
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(18),
            ),
            child: QrImageView(
              data: link,
              version: QrVersions.auto,
              // Build 2074 (audit item 24): the fixed 220 px
              // code was tight at 320 dp wide — cap it to the
              // dialog's width (screen minus insets and the
              // white frame's padding).
              size: (MediaQuery.sizeOf(dialogContext).width * 0.62).clamp(
                160.0,
                220.0,
              ),
              backgroundColor: Colors.white,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            hint ?? l.shareQrHint,
            style: Ember.caption,
            textAlign: TextAlign.center,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: link));
            if (dialogContext.mounted) Navigator.of(dialogContext).pop();
            if (context.mounted) {
              ScaffoldMessenger.of(context)
                  .showSnackBar(SnackBar(content: Text(l.linkCopied)));
            }
          },
          child: Text(l.copyLink, style: const TextStyle(color: Ember.orange)),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: Text(l.closeAction, style: const TextStyle(color: Ember.dim)),
        ),
      ],
    ),
  );
}
