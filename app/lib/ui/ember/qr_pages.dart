/// Paste import, QR scanning and QR display for V2Ray configs — all
/// in the Ember sheet/dialog styling.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../l10n/app_localizations.dart';
import '../../xray/profile_codec.dart';
import '../../xray/xray_controller.dart';
import '../../xray/xray_models.dart';
import 'ember_theme.dart';

String profileLinkOf(Profile p) => profileToLink(p);

/// The paste-import sheet: a big field for links (or a subscription
/// body), pre-filled with the clipboard when it looks like one.
Future<void> showPasteSheet(BuildContext context, XrayController xray) async {
  final l = AppLocalizations.of(context);
  final controller = TextEditingController();
  try {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text ?? '';
    if (text.contains('://')) controller.text = text;
  } catch (_) {
    // No clipboard access: an empty field.
  }
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Ember.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
    ),
    builder: (sheetContext) => Padding(
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
            onTap: () {
              final added = xray.importLinks(controller.text);
              Navigator.of(sheetContext).pop();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text(
                    added > 0 ? l.importedCount(added) : l.nothingImported,
                  ),
                ));
              }
            },
          ),
        ],
      ),
    ),
  );
}

/// Opens the camera scanner; the first code found is imported as links
/// (or followed as a subscription URL when it is an http link).
Future<void> scanAndImport(BuildContext context, XrayController xray) async {
  final l = AppLocalizations.of(context);
  final code = await Navigator.of(context).push<String>(
    MaterialPageRoute(builder: (_) => const _ScannerPage()),
  );
  if (code == null || !context.mounted) return;
  if (code.startsWith('http://') || code.startsWith('https://')) {
    try {
      await xray.addSubscription(code);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l.subAdded)),
        );
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l.subUpdateFailed)),
        );
      }
    }
    return;
  }
  final added = xray.importLinks(code);
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(added > 0 ? l.importedCount(added) : l.nothingImported),
    ));
  }
}

class _ScannerPage extends StatefulWidget {
  const _ScannerPage();

  @override
  State<_ScannerPage> createState() => _ScannerPageState();
}

class _ScannerPageState extends State<_ScannerPage> {
  final MobileScannerController _controller = MobileScannerController();
  bool _done = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
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
              width: 250,
              height: 250,
              decoration: BoxDecoration(
                border: Border.all(color: Ember.orange, width: 2.5),
                borderRadius: BorderRadius.circular(24),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Shows a config's link as a QR code for another device to scan.
Future<void> showProfileQr(BuildContext context, Profile profile) async {
  final l = AppLocalizations.of(context);
  final link = profileToLink(profile);
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: Ember.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      title: Text(profile.name, style: Ember.heading),
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
              size: 220,
              backgroundColor: Colors.white,
            ),
          ),
          const SizedBox(height: 12),
          Text(l.shareQrHint, style: Ember.caption, textAlign: TextAlign.center),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: link));
            if (dialogContext.mounted) Navigator.of(dialogContext).pop();
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(l.linkCopied)),
              );
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

/// Shows a whole subscription as ONE QR (build 2034, parity
/// port): the QR carries the bare subscription URL — scan targets
/// route a bare URL to "add subscription", so the other device
/// lands on the same subscription with one scan. The name is NOT
/// carried (the receiver names it from the provider's
/// profile-title or the host, like any pasted subscription URL).
Future<void> showSubscriptionQr(
  BuildContext context,
  Subscription sub,
) async {
  final l = AppLocalizations.of(context);
  final link = sub.url;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: Ember.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      title: Text(
        sub.name.isEmpty ? 'Subscription' : sub.name,
        style: Ember.heading,
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
              size: 220,
              backgroundColor: Colors.white,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Scan with Ember on another device to add this '
            'subscription there.',
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
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(l.linkCopied)),
              );
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
