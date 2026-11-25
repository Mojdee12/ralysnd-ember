/// Build 2149 (owner expansion 5): the full-page DNS
/// preset picker. Opened from the Xray DNS settings for
/// the remote and the local DNS field; a tap pops the
/// page with the value the field should take, and the
/// settings row applies and saves it. Nothing is written
/// anywhere until a tap — opening and leaving the page
/// changes nothing, and both fields stay freely editable
/// in Settings exactly as before (the catalogue in
/// lib/xray/dns_presets.dart holds the data and the hard
/// no-default-change rule).
///
/// Build 2149 (owner refinement, the Karing screenshot):
/// a Test all action probes every preset individually —
/// through the current connection when one is up, direct
/// otherwise — and each row shows its own latency in ms
/// or a failed mark, at the 2148 small-size/colour rules.
/// Those results are session-only: they live in this
/// page's state and are never stored (persistence exists
/// only in the config detail, per profile).
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../xray/dns_presets.dart';
import '../../xray/xray_controller.dart';
import '../../xray/xray_platform.dart';
import 'ember_format.dart';
import 'ember_theme.dart';
import 'map_widgets.dart';

/// Which DNS field the picker fills — the value a preset
/// contributes differs per field (see [DnsPreset]).
enum DnsPresetTarget { remote, local }

class DnsPresetsPage extends StatefulWidget {
  const DnsPresetsPage({
    super.key,
    required this.target,
    required this.currentValue,
    this.xray,
  });

  final DnsPresetTarget target;

  /// The field's current value, for the SELECTED pill.
  final String currentValue;

  /// The controller, for Test all's transport choice (the
  /// live tunnel when one is up, direct otherwise). Null
  /// in tests — Test all then probes direct.
  final XrayController? xray;

  @override
  State<DnsPresetsPage> createState() => _DnsPresetsPageState();
}

class _DnsPresetsPageState extends State<DnsPresetsPage> {
  /// Session-only per-preset results (preset name → ms,
  /// -1 failed, -2 not probed). Never persisted.
  Map<String, int> _results = const {};
  bool _testing = false;

  String _valueOf(DnsPreset p) =>
      widget.target == DnsPresetTarget.remote ? p.remoteValue : p.localValue;

  bool _selected(DnsPreset p) => widget.currentValue.trim() == _valueOf(p);

  /// The resolver entry a preset is probed by: what a tap
  /// would put to work — the DoH URL for the remote field
  /// when one is published, else the primary address.
  String _probeEntryOf(DnsPreset p) =>
      widget.target == DnsPresetTarget.remote
      ? (p.doh ?? p.primary)
      : p.primary;

  Future<void> _testAll() async {
    if (_testing) return;
    setState(() => _testing = true);
    try {
      final entries = [for (final p in allDnsPresets) _probeEntryOf(p)];
      final byEntry =
          await (widget.xray?.testPresetDns(entries) ??
              XrayPlatform.dnsPingDirect(entries));
      if (!mounted) return;
      setState(() {
        _results = {
          for (final p in allDnsPresets)
            if (byEntry[_probeEntryOf(p)] != null)
              p.name: byEntry[_probeEntryOf(p)]!,
        };
      });
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Widget _section(
    BuildContext context,
    String title,
    String? caption,
    List<DnsPreset> presets,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: Ember.heading.copyWith(fontSize: Ember.fontTitle),
        ),
        if (caption != null) ...[
          const SizedBox(height: 4),
          Text(caption, style: Ember.caption),
        ],
        const SizedBox(height: 10),
        MapGlass(
          blur: false,
          padding: const EdgeInsets.fromLTRB(14, 4, 14, 4),
          child: Column(
            children: [
              for (var i = 0; i < presets.length; i++) ...[
                if (i > 0) const Divider(color: MapUi.line, height: 1),
                _presetRow(context, presets[i]),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _presetRow(BuildContext context, DnsPreset p) {
    final value = _valueOf(p);
    final selected = _selected(p);
    // The second caption line names what the tap actually
    // writes when it is not just the address pair — the
    // DoH URL for the remote field.
    final fillLine = value.contains('://') ? value : null;
    final result = _results[p.name];
    return InkWell(
      onTap: () => Navigator.of(context).pop(value),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          p.name,
                          style: const TextStyle(
                            fontSize: Ember.fontTitle,
                            fontWeight: FontWeight.w500,
                            color: MapUi.text,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (selected) ...[
                        const SizedBox(width: 9),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: Ember.orange,
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: const Text(
                            'SELECTED',
                            style: TextStyle(
                              fontSize: Ember.fontMicro,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.8,
                              color: Color(0xFF1A1206),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    p.addressLine,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: Ember.fontSmall,
                      color: MapUi.dim,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (fillLine != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      fillLine,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: Ember.fontSmall,
                        color: MapUi.dim,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            // The session-only per-preset ping (owner
            // refinement): the same small-size/colour rules
            // as the config rows.
            if (result != null) ...[
              const SizedBox(width: 10),
              if (result >= 0)
                Text(
                  '${latDigits(result)} ms',
                  style: TextStyle(
                    fontSize: Ember.fontSmall,
                    fontWeight: FontWeight.w600,
                    color: pingColor(result),
                  ),
                )
              else if (result == -1)
                const Text(
                  'Failed',
                  style: TextStyle(
                    fontSize: Ember.fontSmall,
                    fontWeight: FontWeight.w600,
                    color: Ember.red,
                  ),
                )
              else
                Text('—', style: Ember.caption),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final remote = widget.target == DnsPresetTarget.remote;
    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Ember.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Ember.text,
        // Build 2150 (engine appearance audit E49-10): the
        // centered, enlarged title aligned to the app
        // dialect — left-aligned plain Ember.heading.
        title: Text('DNS presets', style: Ember.heading),
      ),
      // Build 2150 (audit E49-14): the intro prose sat on
      // unsettled dot clusters; the page takes the short
      // band, the prose settling on the near-black base.
      body: EmberBackground(
        bandShort: true,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 110, 16, 24),
          children: [
            Text(
              remote
                  ? 'Tap a preset to fill the remote DNS field. '
                        'Providers with a published DoH address fill '
                        'that URL; the rest fill both addresses. '
                        'Nothing changes until you tap, and the '
                        'field itself stays editable for your own '
                        'value.'
                  : 'Tap a preset to fill the local DNS field '
                        'with its first address. Nothing changes '
                        'until you tap, and the field itself stays '
                        'editable for your own value.',
              style: Ember.caption,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                MapActionPill(
                  icon: Icons.network_ping,
                  label: _testing ? 'Testing…' : 'Test all',
                  busy: _testing,
                  onTap: _testing ? null : () => unawaited(_testAll()),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    widget.xray?.state.running == true
                        ? 'Probed through the current connection.'
                        : 'Probed directly — no connection is up.',
                    style: Ember.caption,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _section(context, 'Global', null, dnsPresetsGlobal),
            const SizedBox(height: 18),
            _section(
              context,
              'Iran',
              'Anti-sanctions resolvers run from inside Iran. '
                  'They answer on Iranian networks; the private '
                  '10.202 addresses never answer from abroad.',
              dnsPresetsIran,
            ),
          ],
        ),
      ),
    );
  }
}
