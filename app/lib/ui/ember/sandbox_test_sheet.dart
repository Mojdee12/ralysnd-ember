/// The sandbox test result sheet (build 2061, feature queue #1):
/// one isolated-core verdict for a config, in the Map Control
/// sheet language — verdict header, delay / hold / exit rows,
/// a plain-words line, and Connect when the config carried
/// traffic. The test itself never touches the live tunnel: it
/// runs in a throwaway core on a free port.

import 'package:flutter/material.dart';

import '../../xray/sandbox_test.dart';
import '../../xray/xray_controller.dart';
import '../../xray/xray_models.dart';
import 'ember_format.dart';
import 'ember_theme.dart';

/// Connects [profile] the way the editor's status card does:
/// select, then the profile's own engine path (WireGuard
/// profiles take the peer-fallback path).
Future<void> connectProfileFromTest(
  XrayController xray,
  Profile profile,
) async {
  xray.select(profile);
  if (profile.protocol == Protocol.wireguard) {
    await xray.connectWireGuardWithFallback(profile);
  } else {
    await xray.connect();
  }
}

/// Shows the sandbox result for [profile]: a bottom sheet in
/// the same shape as the Import sheet (surface + 26 px top
/// radius). [onConnect] runs when the user taps Connect; the
/// caller owns its errors (StateError → SnackBar, as the
/// editor does). No Connect button when the test failed or no
/// callback is given.
Future<void> showSandboxTestSheet(
  BuildContext context, {
  required Profile profile,
  required SandboxTestResult result,
  Future<void> Function()? onConnect,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    // Build 2074 (audit item 16): scroll-controlled, with a
    // scrollable body — the verdict + unbounded detail text +
    // Connect used to clip on small screens.
    isScrollControlled: true,
    backgroundColor: Ember.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
    ),
    builder: (sheetContext) => SafeArea(
      child: SandboxTestSheet(
        profile: profile,
        result: result,
        onConnect: onConnect == null
            ? null
            : () async {
                Navigator.of(sheetContext).pop();
                await onConnect();
              },
      ),
    ),
  );
}

/// The sheet body, kept separate from [showSandboxTestSheet]
/// so widget tests can pump it directly.
class SandboxTestSheet extends StatelessWidget {
  const SandboxTestSheet({
    super.key,
    required this.profile,
    required this.result,
    this.onConnect,
  });

  final Profile profile;
  final SandboxTestResult result;
  final Future<void> Function()? onConnect;

  @override
  Widget build(BuildContext context) {
    final verdict = result.verdict;
    final color = switch (verdict) {
      SandboxVerdict.works => Ember.green,
      SandboxVerdict.unstable => Ember.warn,
      SandboxVerdict.failed => Ember.red,
    };
    final icon = switch (verdict) {
      SandboxVerdict.works => Icons.check_circle_rounded,
      SandboxVerdict.unstable => Icons.warning_rounded,
      SandboxVerdict.failed => Icons.error_rounded,
    };
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 22, color: color),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    result.title,
                    style: Ember.heading.copyWith(fontSize: Ember.fontHeadline),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(left: 32),
              child: Text(
                profile.displayName,
                style: Ember.body.copyWith(color: Ember.dim),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(height: 14),
            GlassCard(
              child: Column(
                children: [
                  _Row(
                    label: 'Delay',
                    value: result.delayMs >= 0
                        ? '${latDigits(result.delayMs)} ms'
                        : '—',
                  ),
                  const SizedBox(height: 10),
                  _Row(
                    label: 'Connection hold',
                    value: result.ok
                        ? '${latDigits(result.heldProbes)}/3 probes'
                        : '—',
                    caption: result.ok ? _probeTimes(result) : null,
                  ),
                  const SizedBox(height: 10),
                  _Row(
                    label: 'Exit IP',
                    value: result.exitIp.isNotEmpty ? result.exitIp : '—',
                  ),
                  const SizedBox(height: 10),
                  _Row(label: 'Exit country', value: _exitCountry(result)),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Text(result.detail, style: Ember.body),
            const SizedBox(height: 16),
            if (onConnect != null && verdict != SandboxVerdict.failed)
              EmberButton(
                label: 'Connect',
                icon: Icons.power_settings_new_rounded,
                onTap: () => onConnect!(),
              ),
            if (onConnect != null && verdict != SandboxVerdict.failed)
              const SizedBox(height: 8),
            Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(
                  'Close',
                  style: Ember.body.copyWith(color: Ember.dim),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _probeTimes(SandboxTestResult r) {
    String ms(int v) => v >= 0 ? latDigits(v) : '—';
    return '${ms(r.p0)} · ${ms(r.p1)} · ${ms(r.p2)} ms';
  }

  static String _exitCountry(SandboxTestResult r) {
    if (r.country.isNotEmpty) return r.country;
    if (r.countryCode.isNotEmpty) return r.countryCode;
    return '—';
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.value, this.caption});

  final String label;
  final String value;
  final String? caption;

  @override
  // Build 2092 (item 57): the value column is bounded
  // (Flexible) and the detail caption capped — a long
  // verdict detail no longer pushes the label off the row.
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(
        child: Text(label, style: Ember.body.copyWith(color: Ember.dim)),
      ),
      const SizedBox(width: 12),
      Flexible(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              value,
              style: Ember.body,
              textAlign: TextAlign.right,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            if (caption != null)
              Text(
                caption!,
                style: Ember.body.copyWith(color: Ember.dim, fontSize: Ember.fontSmall),
                textAlign: TextAlign.right,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
              ),
          ],
        ),
      ),
    ],
  );
}
