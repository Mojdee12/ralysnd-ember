/// The EmberWarp profile form (build 2030): the one WARP
/// profile the standalone card and the Warp underlay share —
/// protocol, transport, scan, the MASQUE fields, the chain
/// mode's exit shaping, and the identity actions (Renew /
/// Reset). The engine core is patterniha/Aether's design
/// (AGPL-3.0; license + source in Settings → Info).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../xray/warp_args.dart';
import '../../xray/xray_controller.dart';
import '../../xray/xray_models.dart';
import 'ember_dialogs.dart';
import 'ember_theme.dart';
import 'map_widgets.dart';

Future<void> openWarpSettings(BuildContext context, XrayController xray) =>
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => WarpSettingsPage(xray: xray)));

class WarpSettingsPage extends StatefulWidget {
  const WarpSettingsPage({super.key, required this.xray});
  final XrayController xray;

  @override
  State<WarpSettingsPage> createState() => _WarpSettingsPageState();
}

class _WarpSettingsPageState extends State<WarpSettingsPage> {
  // Build 2095 (whole-app journey audit #21): the page
  // edits a COPY — the old alias mutated the live profile
  // with every toggle, so leaving without Save still
  // changed the engine's settings. _persist commits.
  late final WarpProfile _w = widget.xray.warpProfile.copy();
  final Map<String, TextEditingController> _fields = {};
  bool _renewing = false;

  /// Build 2092 (item 8): Save shows its busy state and
  /// cannot stack; Reset identity likewise.
  bool _saving = false;
  bool _resetting = false;
  bool _logExpanded = false;

  /// The last renewal's outcome, shown inline under the
  /// identity actions (build 2056): Renew used to call
  /// [_save], which pops the page, so tapping it ejected the
  /// user from the whole settings page.
  String? _renewNote;

  @override
  void initState() {
    super.initState();
    _field('masqueSni', _w.masqueSni);
    _field('dns', _w.dns);
    _field('exitLoc', _w.exitLoc);
    _field('peer', _w.peer);
    _field('echDns', _w.echDns);
    _field('finalMask', _w.finalMask);
    _field('dialMode', _w.dialMode);
    unawaited(widget.xray.refreshWarpState());
  }

  @override
  void dispose() {
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController _field(String key, String initial) =>
      _fields.putIfAbsent(key, () => TextEditingController(text: initial));

  String _v(String key) => _fields[key]?.text.trim() ?? '';

  /// Reads the form back into the profile and persists it —
  /// without leaving the page. The Save actions add the pop;
  /// Renew must not (build 2056, audit §5 Editors).
  Future<void> _persist() async {
    _w
      ..masqueSni = _v('masqueSni').isEmpty
          ? 'www.cloudflare.com'
          : _v('masqueSni')
      ..dns = _v('dns')
      ..exitLoc = _v('exitLoc')
      ..peer = _v('peer')
      ..echDns = _v('echDns')
      // Exact text, like the profile editor's fields.
      ..finalMask = _fields['finalMask']?.text ?? ''
      ..dialMode = _fields['dialMode']?.text ?? '';
    // Build 2095 (audit #21): commit the copy to the live
    // profile — this is the only door edits leave through.
    widget.xray.warpProfile.absorb(_w);
    await widget.xray.saveWarpProfile();
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await _persist();
      if (mounted) Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _text(String key, String label, {String? hint}) => Padding(
    padding: const EdgeInsets.only(bottom: 11),
    child: TextField(
      controller: _fields[key],
      style: Ember.body,
      textDirection: TextDirection.ltr,
      decoration: emberField(context, hint ?? label).copyWith(
        labelText: label,
        labelStyle: const TextStyle(
          color: Ember.faint,
          fontSize: Ember.fontBody,
        ),
        floatingLabelStyle: const TextStyle(color: Ember.orange),
      ),
    ),
  );

  Widget _dropdown(
    String label,
    String value,
    List<(String, String)> options,
    ValueChanged<String> onChanged,
  ) => Padding(
    padding: const EdgeInsets.only(bottom: 11),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      decoration: BoxDecoration(
        color: Ember.field,
        // Build 2144: the dropdown shell takes the shared
        // control radius and the hairline line token.
        borderRadius: BorderRadius.circular(Ember.radiusControl),
        border: Border.all(color: MapUi.line),
      ),
      child: Row(
        children: [
          // Build 2074 (audit item 16): the label is bounded and
          // the dropdown flexes — long value names ("Gool (WG
          // over MASQUE)") ellipsize inside the dropdown instead
          // of overflowing the row at 320–360dp widths.
          Expanded(
            child: Text(
              label,
              style: Ember.dimStyle,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: DropdownButton<String>(
              value: value,
              isExpanded: true,
              dropdownColor: Ember.card,
              underline: const SizedBox.shrink(),
              style: Ember.body,
              items: [
                for (final (v, name) in options)
                  DropdownMenuItem(
                    value: v,
                    child: Text(name, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (v) {
                if (v != null) onChanged(v);
              },
            ),
          ),
        ],
      ),
    ),
  );

  Widget _toggleRow(String label, bool value, ValueChanged<bool> onChanged) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 11),
        child: Row(
          children: [
            Expanded(child: Text(label, style: Ember.body)),
            EmberToggle(
              value: value,
              onChanged: (v) => setState(() => onChanged(v)),
            ),
          ],
        ),
      );

  // Build 2145 (composition rebuild, pro6-settings): sections
  // are hairline GROUPS, not glass — the tracked orange
  // section label over the form rows, closed by a hairline,
  // matching the shared MapSettingsPanel language (build
  // 2145, coordinator decision 6). The form fields keep
  // their own control chrome; no hero elements are invented
  // for a profile form. Section titles keep their exact
  // existing text (finders pin them).
  Widget _section(String title, List<Widget> children) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Build 2144 (reskin): section titles are the
        // samples' tracked orange micro-labels.
        Text(title, style: Ember.microLabelOrange),
        const SizedBox(height: 13),
        ...children,
        const Divider(color: MapUi.line, height: 1, thickness: 1),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final masqueFamily =
        _w.protocol == 'masque' ||
        _w.protocol == 'gool' ||
        _w.protocol == 'mim';
    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Ember.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Ember.text,
        title: Text(
          'EmberWarp settings',
          // Build 2144: the page title in the samples' light
          // display type (hero style at the display step).
          style: Ember.hero.copyWith(fontSize: Ember.fontDisplay),
        ),
        actions: [
          IconButton(
            onPressed: _saving ? null : () => unawaited(_save()),
            icon: _saving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Ember.orange,
                    ),
                  )
                : const Icon(Icons.check_rounded, color: Ember.orange),
            tooltip: 'Save',
          ),
        ],
      ),
      body: EmberBackground(banded: true, 
        // Build 2074 (audit item 20): the body listens to the
        // controller, like the sibling pages — the Identity
        // section used to keep its first-render text until an
        // unrelated setState. warpState is read inside the
        // builder so a controller notice re-reads it.
        child: ListenableBuilder(
          listenable: widget.xray,
          builder: (context, _) {
            final ws = widget.xray.warpState;
            return ListView(
              padding: EdgeInsets.fromLTRB(
                18,
                MediaQuery.of(context).padding.top + kToolbarHeight + 6,
                18,
                24,
              ),
              children: [
                _section('Connection', [
                  _dropdown('Protocol', _w.protocol, const [
                    ('masque', 'MASQUE'),
                    ('wg', 'WireGuard'),
                    ('gool', 'Gool (WG over MASQUE)'),
                    ('mim', 'MiM (MASQUE over MASQUE)'),
                  ], (v) => setState(() => _w.protocol = v)),
                  if (masqueFamily) ...[
                    _dropdown('Transport', _w.transport, const [
                      ('h2', 'HTTP/2 (TCP)'),
                      ('h3', 'QUIC (H3)'),
                    ], (v) => setState(() => _w.transport = v)),
                    if (_w.transport == 'h2')
                      _toggleRow(
                        'Fragment the first flight (H2)',
                        _w.fragment,
                        (v) => _w.fragment = v,
                      ),
                    _text('masqueSni', 'MASQUE SNI'),
                    _dropdown('Obfuscation', _w.obfuscation, const [
                      ('auto', 'Auto'),
                      ('off', 'Off'),
                      ('quic', 'QUIC'),
                      ('http', 'HTTP'),
                    ], (v) => setState(() => _w.obfuscation = v)),
                  ],
                  _dropdown('Gateway scan', _w.scan, const [
                    ('balanced', 'Balanced'),
                    ('performance', 'Performance'),
                    ('random', 'Random'),
                  ], (v) => setState(() => _w.scan = v)),
                  _dropdown('IP version', _w.ipVersion, const [
                    ('v4', 'IPv4'),
                    ('v6', 'IPv6'),
                    ('dual', 'Dual'),
                  ], (v) => setState(() => _w.ipVersion = v)),
                  _text('peer', 'Pinned gateway (host:port, empty = scan)'),
                  // Build 2065 (item 10): the known WARP endpoints as
                  // one-tap pins. Unpinned (empty peer) the core scans
                  // for a gateway itself — that scan IS the endpoint
                  // search; the app cannot probe WireGuard handshakes
                  // outside the core, so no fake latency is shown here.
                  // Port racing is not offered: neither bundled core
                  // exposes a racing control (parked, see BUILD-LOG).
                  Text('Known endpoints', style: Ember.body),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      // Build 2074 (audit item 15): EmberChip, not a
                      // stock Material ChoiceChip — palette colours
                      // and the shared ≥48dp tappable-chip hit area.
                      for (final ep in kKnownWarpEndpoints)
                        EmberChip(
                          label: ep,
                          selected: _v('peer') == ep,
                          onTap: () {
                            _fields['peer']?.text = _v('peer') == ep ? '' : ep;
                            setState(() {});
                          },
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Pinning sets the gateway above; clearing it hands '
                    'the search back to the core scan.',
                    style: Ember.caption,
                  ),
                  _text('exitLoc', 'Exit location (empty = any)'),
                  _text('dns', 'In-tunnel DNS (empty = core default)'),
                ]),
                _section('Privacy', [
                  _toggleRow(
                    'ECH (encrypted ClientHello)',
                    _w.ech,
                    (v) => _w.ech = v,
                  ),
                  if (_w.ech) _text('echDns', 'ECH lookup resolver (DoH)'),
                  Text(
                    'With ECH on, the gateway lookup always uses an '
                    'encrypted resolver — never plain DNS.',
                    style: Ember.caption,
                  ),
                ]),
                // Build 2095 (whole-app journey audit #58):
                // the underlay choice itself lives here too —
                // it used to exist only on the home card, so
                // from this page the chain could be shaped but
                // never switched on.
                _section('Underlay', [
                  ListenableBuilder(
                    listenable: widget.xray,
                    builder: (context, _) {
                      final underlay = widget.xray.settings.underlay;
                      return Wrap(
                        spacing: 7,
                        runSpacing: 7,
                        children: [
                          EmberChip(
                            label: 'None',
                            selected: underlay == 'none',
                            onTap: () => widget.xray.setUnderlay('none'),
                          ),
                          EmberChip(
                            label: 'Psiphon',
                            selected: underlay == 'psiphon',
                            onTap: () => widget.xray.setUnderlay('psiphon'),
                          ),
                          EmberChip(
                            label: 'EmberWarp',
                            selected: underlay == 'warp',
                            onTap: () => widget.xray.setUnderlay('warp'),
                          ),
                          EmberChip(
                            label: 'DNSTT',
                            selected: underlay == 'dnstt',
                            onTap: () => widget.xray.setUnderlay('dnstt'),
                          ),
                          EmberChip(
                            label: 'OLCRTC',
                            selected: underlay == 'olcrtc',
                            onTap: () => widget.xray.setUnderlay('olcrtc'),
                          ),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'The underlay every V2Ray session dials '
                    'through. Applies to the next session.',
                    style: Ember.caption,
                  ),
                ]),
                _section('Chain exit shaping', [
                  _text('dialMode', 'Exit dial mode (exact text)'),
                  _text('finalMask', 'Exit finalmask (JSON)'),
                  Text(
                    'These two shape the exit hop when EmberWarp '
                    'runs as the V2Ray underlay: the exit-node is '
                    'the hop that really dials. In standalone '
                    'EmberWarp mode there is no Xray in the path, '
                    'so they rest.',
                    style: Ember.caption,
                  ),
                ]),
                _section('Identity', [
                  Text(
                    ws.identityPresent
                        ? 'A WARP identity is saved on this device. '
                              'It is never re-registered silently — '
                              'only the Renew button below replaces it.'
                        : 'No identity yet: the first connect '
                              'registers one anonymously with '
                              'Cloudflare.',
                    style: Ember.dimStyle,
                  ),
                  const SizedBox(height: 12),
                  // Build 2074 (audit item 16): a Wrap, not a fixed
                  // Row — the two identity chips wrap instead of
                  // overflowing at 320–360dp widths.
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      EmberChip(
                        label: _renewing ? 'Renewing…' : 'Renew WARP Key',
                        onTap: _renewing
                            ? null
                            : () async {
                                setState(() {
                                  _renewing = true;
                                  _renewNote = null;
                                });
                                // Build 2056: renew persists the form
                                // but stays on this page — the old
                                // call saved through [_save], whose
                                // pop closed the whole settings page.
                                await _persist();
                                final ok = await widget.xray
                                    .renewWarpIdentity();
                                if (mounted) {
                                  setState(() {
                                    _renewing = false;
                                    _renewNote = ok
                                        ? 'A fresh WARP identity is saved.'
                                        : 'The renewal did not complete — '
                                              'check the connection and try '
                                              'again.';
                                  });
                                }
                              },
                      ),
                      EmberChip(
                        label: _resetting ? 'Resetting…' : 'Reset identity',
                        // Build 2092 (item 27): the reset
                        // discards the saved identity — it
                        // confirms first and shows busy.
                        onTap: _resetting
                            ? null
                            : () async {
                                final confirmed = await showEmberConfirm(
                                  context,
                                  title: 'Reset identity?',
                                  message:
                                      'The saved WARP identity is '
                                      'discarded. The next connect '
                                      'registers a fresh one.',
                                  confirmLabel: 'Reset',
                                );
                                if (!confirmed) return;
                                setState(() => _resetting = true);
                                try {
                                  await widget.xray.resetWarpIdentity();
                                } finally {
                                  if (mounted) {
                                    setState(() => _resetting = false);
                                  }
                                }
                              },
                      ),
                    ],
                  ),
                  if (_renewNote != null) ...[
                    const SizedBox(height: 10),
                    Text(_renewNote!, style: Ember.caption),
                  ],
                  if (ws.logTail.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    // Build 2092 (item 60): the tail is
                    // capped like the DNSTT page's log —
                    // last 14 lines, with Show more and Copy.
                    Builder(
                      builder: (context) {
                        final lines = ws.logTail.split('\n');
                        final clipped = !_logExpanded && lines.length > 14;
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    'Core log (tail)',
                                    style: Ember.caption,
                                  ),
                                ),
                                if (lines.length > 14)
                                  MapActionPill(
                                    icon: _logExpanded
                                        ? Icons.expand_less_rounded
                                        : Icons.expand_more_rounded,
                                    label: _logExpanded
                                        ? 'Show less'
                                        : 'Show more',
                                    onTap: () => setState(
                                      () => _logExpanded = !_logExpanded,
                                    ),
                                  ),
                                const SizedBox(width: 8),
                                MapActionPill(
                                  icon: Icons.copy_rounded,
                                  label: 'Copy',
                                  onTap: () => Clipboard.setData(
                                    ClipboardData(text: ws.logTail),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            SelectableText(
                              clipped
                                  ? lines.skip(lines.length - 14).join('\n')
                                  : ws.logTail,
                              style: Ember.caption,
                            ),
                          ],
                        );
                      },
                    ),
                  ],
                ]),
                EmberButton(
                  label: _saving ? 'Saving…' : 'Save',
                  icon: Icons.check_rounded,
                  onTap: _saving ? null : () => unawaited(_save()),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
