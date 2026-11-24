/// Paste import, QR scanning and QR display for V2Ray configs — all
/// in the Ember sheet/dialog styling.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../l10n/app_localizations.dart';
import '../../xray/lantern_import.dart';
import '../../xray/link_parser.dart';
import '../../xray/profile_codec.dart';
import '../../xray/shared_link.dart';
import '../../xray/sub_fetcher.dart';
import '../../xray/wg_conf.dart';
import '../../xray/xray_controller.dart';
import '../../xray/xray_models.dart';
import '../../xray/xray_platform.dart';
import 'ember_dialogs.dart';
import 'wireguard_pages.dart';
import 'ember_theme.dart';
import 'map_widgets.dart';

String profileLinkOf(Profile p) => profileToLink(p);

/// Shows the outcome of an import: the imported count, or the
/// first Lantern error when a Lantern link was the only thing
/// pasted and it failed.
///
/// Build 2094: subscriptions the import added are named with
/// their config counts — a pasted subscription link used to
/// vanish into the bare total (when it imported at all).
void _showImportResult(
  BuildContext context,
  AppLocalizations l,
  ({
    int added,
    List<String> errors,
    List<({String name, int configs})> subscriptions,
  })
  result,
) {
  final failed = result.added == 0 && result.errors.isNotEmpty;
  // Build 2074 (audit item 6): the parser's raw error never
  // reaches the SnackBar — a plain sentence for the user, the
  // detail to diagnostics only (the build 2070 pattern).
  if (failed) debugPrint('Ember import failed: ${result.errors.first}');
  final subNote = result.subscriptions
      .map(
        (s) =>
            'Subscription "${s.name}" added '
            '(${s.configs} config${s.configs == 1 ? '' : 's'})',
      )
      .join(' ');
  // Build 2095 (V2Ray journey audit #8): the controller's
  // curated per-line notes (duplicates skipped, lines that
  // could not be read) reach the user — they used to be
  // dropped whenever anything at all imported, so a paste
  // with dead lines looked like a clean import.
  final errorNote = result.errors.join(' ');
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        result.added > 0
            ? '${l.importedCount(result.added)}'
                  '${subNote.isEmpty ? '' : ' $subNote'}'
                  '${errorNote.isEmpty ? '' : ' $errorNote'}'
            : failed
            ? errorNote
            : l.nothingImported,
      ),
      duration: failed || errorNote.isNotEmpty
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
  // Build 2092 (items 45/61): the shared scrollable form
  // scaffold (the keyboard no longer crushes the dialog),
  // and the controller is disposed once the dialog closes.
  final password = await showEmberFormDialog<String>(
    context,
    title: 'Protected link',
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
          onSubmitted: (v) => Navigator.of(context).pop(v),
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      TextButton(
        onPressed: () => Navigator.of(context).pop(controller.text),
        child: const Text('Unlock'),
      ),
    ],
  );
  controller.dispose();
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

/// Build 2101 (settings-dns-2099-diagnosis.md, S4/I2): an
/// import that never throws. A failure anywhere inside the
/// import machinery used to escape the callers' awaits as an
/// uncaught async error — the paste sheet stayed busy forever
/// with part of the batch imported and no message, and the
/// scan paths failed just as silently. Null means the import
/// itself failed; the caller shows the plain message.
Future<
  ({
    int added,
    List<String> errors,
    List<({String name, int configs})> subscriptions,
  })?
>
_runGuardedImport(XrayController xray, String text) async {
  try {
    return await xray.importLinksAsync(text);
  } catch (_) {
    return null;
  }
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
  final result = await _runGuardedImport(xray, unlocked);
  if (!context.mounted) return;
  if (result == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Could not import that text.')),
    );
    return;
  }
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
                        final result = await _runGuardedImport(
                          xray,
                          unlocked,
                        );
                        if (!sheetContext.mounted) return;
                        if (result == null) {
                          // Build 2101 (S4/I2): the sheet
                          // un-busies and says so, instead of
                          // spinning forever.
                          setSheetState(() => busy = false);
                          ScaffoldMessenger.of(
                            sheetContext,
                          ).showSnackBar(
                            const SnackBar(
                              content: Text('Could not import that text.'),
                            ),
                          );
                          return;
                        }
                        Navigator.of(sheetContext).pop();
                        if (context.mounted) {
                          _showImportResult(context, l, result);
                        }
                      },
              ),
              // Build 2095 (V2Ray journey audit #14): import
              // from a FILE — the sheet used to accept typed or
              // pasted text only, while the platform file
              // picker already existed for other flows.
              TextButton.icon(
                onPressed: busy
                    ? null
                    : () async {
                        // Build 2098 (post-2097 audit L6): the
                        // pick used to run bare — a picker
                        // failure (IMP-3's named
                        // PlatformException included) escaped
                        // as an uncaught async error and the
                        // tap looked dead. It surfaces now.
                        Map<String, String>? picked;
                        try {
                          picked = await XrayPlatform.pickTextFile();
                        } catch (_) {
                          if (sheetContext.mounted) {
                            ScaffoldMessenger.of(
                              sheetContext,
                            ).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'Could not read that file.',
                                ),
                              ),
                            );
                          }
                          return;
                        }
                        final content = picked?['content'];
                        if (content == null || content.trim().isEmpty) {
                          return;
                        }
                        if (!sheetContext.mounted) return;
                        setSheetState(() => busy = true);
                        final unlocked = await _unlockIfNeeded(
                          sheetContext,
                          content,
                        );
                        if (unlocked == null) {
                          if (sheetContext.mounted) {
                            setSheetState(() => busy = false);
                          }
                          return;
                        }
                        final result = await _runGuardedImport(
                          xray,
                          unlocked,
                        );
                        if (!sheetContext.mounted) return;
                        if (result == null) {
                          // Build 2101 (S4/I2): as on the paste
                          // button above — un-busy and say so.
                          setSheetState(() => busy = false);
                          ScaffoldMessenger.of(
                            sheetContext,
                          ).showSnackBar(
                            const SnackBar(
                              content: Text('Could not import that text.'),
                            ),
                          );
                          return;
                        }
                        Navigator.of(sheetContext).pop();
                        if (context.mounted) {
                          _showImportResult(context, l, result);
                        }
                      },
                icon: const Icon(Icons.folder_open_rounded, size: 17),
                label: const Text('Import from a file'),
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
  final code = await Navigator.of(context)
      .push<String>(MaterialPageRoute(builder: (_) => const _ScannerPage()));
  if (code == null || !context.mounted) return;
  await importScannedCode(context, xray, code);
}

/// Routes one scanned/opened code through the import paths
/// (build 2095, whole-app journey audit #38: shared with the
/// deep-link intake, so a link opened from another app lands
/// exactly where a scan lands).
Future<void> importScannedCode(
  BuildContext context,
  XrayController xray,
  String code,
) async {
  final l = AppLocalizations.of(context);
  // A Lantern private-server link is an https URL too, but it is an
  // invite to resolve, not a subscription: route it to the importer
  // before the subscription branch can claim it.
  if (containsLanternPrivateServerLink(code)) {
    await _importWithFeedback(context, xray, code);
    return;
  }
  // Build 2095 (whole-app journey audit #17): a QR can
  // carry a whole WireGuard .conf — route it to the WG
  // importer instead of letting the link parser choke on it.
  // Build 2102: the shared isWgConfText gate — the pre-2102
  // check here was case-sensitive ('[Interface]') while the
  // parser accepts any case, so a lowercase-header conf
  // fell through to the link parser.
  if (isWgConfText(code)) {
    await importWgConfText(context, xray, code);
    return;
  }
  if (code.startsWith('http://') || code.startsWith('https://')) {
    // Build 2095 (V2Ray journey audit #6): an http(s) code
    // is not automatically a subscription — single-config
    // links exist in http(s) form too. The link parser gets
    // first claim; only a code it cannot read AND that is
    // subscription-shaped goes to the fetcher.
    if (parseLink(code) != null) {
      await _importWithFeedback(context, xray, code);
      return;
    }
    if (!isSubscriptionUrl(code)) {
      await _importWithFeedback(context, xray, code);
      return;
    }
    try {
      await xray.addSubscription(code);
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(l.subAdded)));
      }
    } catch (e) {
      // Build 2095 (third-pass audit 5-6): a scanned
      // cleartext subscription gets the same explicit
      // opt-in as the typed paths.
      if (e is StateError &&
          e.message == 'cleartext-subscription' &&
          context.mounted) {
        final ok = await showEmberConfirm(
          context,
          title: 'Unencrypted subscription',
          message:
              'This subscription address uses plain http, not '
              'https. The address itself is a private key, and '
              'anyone on the network path could read it and '
              'the configs it returns, or replace them. Add '
              'it only if you trust this network.',
          confirmLabel: 'Add anyway',
        );
        if (ok == true && context.mounted) {
          try {
            await xray.addSubscription(code, allowCleartext: true);
            if (context.mounted) {
              ScaffoldMessenger.of(context)
                  .showSnackBar(SnackBar(content: Text(l.subAdded)));
            }
          } catch (e2) {
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    subFetchErrorText(e2, fallback: l.subUpdateFailed),
                  ),
                  duration: const Duration(seconds: 6),
                ),
              );
            }
          }
        }
        return;
      }
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
    // Build 2092 (item 45): the frame is also capped by the
    // viewport height — in landscape the shortestSide rule
    // alone left it colliding with the hint/torch column.
    final frameSide = (viewSize.shortestSide * 0.68)
        .clamp(180.0, 280.0)
        .clamp(120.0, viewSize.height * 0.52);
    // Build 2075 (item 30): the scanner is a sensitive
    // surface — overlay-guarded while it is up.
    return OverlayGuard(
      child: Scaffold(
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
                // Build 2116 (AP-10): the caption and pills
                // sit on a dark scrim strip — dim caption
                // text over a bright camera image was
                // unreadable in daylight scenes.
                child: Container(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(18),
                  ),
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
                    const SizedBox(height: 8),
                    // Build 2095 (feature 6): decode a QR
                    // from a gallery image — the decoded
                    // value returns through the exact same
                    // pop path as a camera detection, so
                    // every import route applies unchanged.
                    MapActionPill(
                      icon: Icons.photo_library_rounded,
                      label: 'From gallery',
                      onTap: () async {
                        final path = await XrayPlatform.pickImageFile();
                        if (path == null || !mounted) return;
                        final value = (await decodeQrValuesFromImageFile(
                          path,
                        )).firstOrNull;
                        if (value != null && value.isNotEmpty && mounted) {
                          _done = true;
                          Navigator.of(context).pop(value);
                        } else if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                'No QR code found in that image',
                              ),
                            ),
                          );
                        }
                      },
                    ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Build 2096 (post-2095 audit L16): decode every QR
/// value in a gallery image. The throwaway scanner
/// controller is disposed, and a decode failure reads as
/// "no codes" instead of escaping as an unhandled async
/// throw (build 2095 created the controller inline, never
/// disposed it, and let analyzeImage's throws fly).
Future<List<String>> decodeQrValuesFromImageFile(String path) async {
  final controller = MobileScannerController();
  try {
    final capture = await controller.analyzeImage(path);
    return [
      for (final b in capture?.barcodes ?? const [])
        if (b.rawValue != null && b.rawValue!.isNotEmpty) b.rawValue!,
    ];
  } catch (_) {
    return const [];
  } finally {
    await controller.dispose();
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
    builder: (dialogContext) => OverlayGuard(
      child: AlertDialog(
        // Build 2059 (audit §6 appearance low): the title is a
        // profile/subscription name — ellipsis, never overflow; the
        // dialog shape/background come from the app theme now.
        title: Text(
          title,
          style: Ember.heading,
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
        ),
        // Build 2092 (item 45): the dialog scrolls and the
        // code is capped by the available HEIGHT as well as
        // the width — in landscape the fixed-height content
        // used to overflow.
        scrollable: true,
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
                // Build 2092 (item 45): …and by the height, so
                // a landscape screen keeps the actions on it.
                size: (MediaQuery.sizeOf(dialogContext).width * 0.62)
                    .clamp(160.0, 220.0)
                    .clamp(
                      120.0,
                      MediaQuery.sizeOf(dialogContext).height * 0.42,
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
            child: Text(
              l.copyLink,
              style: const TextStyle(color: Ember.orange),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(
              l.closeAction,
              style: const TextStyle(color: Ember.dim),
            ),
          ),
        ],
      ),
    ),
  );
}
