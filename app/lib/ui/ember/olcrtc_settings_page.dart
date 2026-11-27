// The OLCRTC underlay form (build 2134): the SFU
// provider, transport, room and shared key the client is
// spawned with when OLCRTC is the selected underlay (see
// olcrtc_args.dart for the YAML config these become).
//
// The page states the deployment plainly: the client
// alone does nothing — an olcrtc server (`olcrtc` in
// `mode: srv`) must run on the user's own host, joined
// to the same room with the same key. Both sides meet
// inside a video call on the chosen service (Jitsi,
// Telemost or WBStream), and the tunnel rides the call.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../xray/olcrtc_args.dart';
import '../../xray/olcrtc_platform.dart';
import '../../xray/xray_controller.dart';
import '../../xray/xray_models.dart';
import 'ember_format.dart';
import 'ember_theme.dart';
import 'map_widgets.dart';

Future<void> openOlcrtcSettings(BuildContext context, XrayController xray) =>
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => OlcrtcSettingsPage(xray: xray)),
    );

class OlcrtcSettingsPage extends StatefulWidget {
  const OlcrtcSettingsPage({super.key, required this.xray});
  final XrayController xray;

  @override
  State<OlcrtcSettingsPage> createState() => _OlcrtcSettingsPageState();
}

class _OlcrtcSettingsPageState extends State<OlcrtcSettingsPage> {
  final Map<String, TextEditingController> _fields = {};
  late String _provider = widget.xray.settings.olcrtcProvider;
  late String _transport = widget.xray.settings.olcrtcTransport;
  OlcrtcState _state = const OlcrtcState();
  bool _refreshing = false;
  bool _saving = false;
  bool _logExpanded = false;

  @override
  void initState() {
    super.initState();
    final s = widget.xray.settings;
    _field('room', s.olcrtcRoom);
    _field('key', s.olcrtcKey);
    _field('token', s.olcrtcToken);
    _field('dns', s.olcrtcDns);
    _field('link', '');
    _field('vp8Fps', s.olcrtcVp8Fps);
    _field('vp8Batch', s.olcrtcVp8Batch);
    _field('seiFps', s.olcrtcSeiFps);
    _field('seiBatch', s.olcrtcSeiBatch);
    _field('seiFrag', s.olcrtcSeiFrag);
    _field('seiAckMs', s.olcrtcSeiAckMs);
    _field('videoWidth', s.olcrtcVideoWidth);
    _field('videoHeight', s.olcrtcVideoHeight);
    _field('videoFps', s.olcrtcVideoFps);
    _field('videoCodec', s.olcrtcVideoCodec);
    _field('videoQrSize', s.olcrtcVideoQrSize);
    _field('videoQrRecovery', s.olcrtcVideoQrRecovery);
    _field('videoTileModule', s.olcrtcVideoTileModule);
    _field('videoTileRs', s.olcrtcVideoTileRs);
    unawaited(_refreshState());
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

  void _set(String key, String value) {
    final c = _fields[key];
    if (c != null && c.text != value) c.text = value;
  }

  Future<void> _refreshState() async {
    if (mounted) setState(() => _refreshing = true);
    final st = await OlcrtcPlatform.state();
    if (mounted) {
      setState(() {
        _state = st;
        _refreshing = false;
      });
    }
  }

  /// Fills the whole form from a pasted `olcrtc://` link
  /// (upstream's client convention — see olcrtc_args.dart).
  void _applyLink() {
    final link = parseOlcrtcLink(_v('link'));
    if (link == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'That is not a complete olcrtc:// link — it needs a '
            'provider, a transport, a room and the 64-hex key.',
          ),
        ),
      );
      return;
    }
    // Route the link's transport parameters through the
    // settings-shaped applier on a THROWAWAY settings
    // object, then mirror them into this form's fields —
    // the stored settings change only on Save.
    final probe = XraySettings();
    applyOlcrtcLinkParams(probe, link);
    setState(() {
      _provider = link.provider;
      _transport = link.transport;
      _set('room', link.room);
      _set('key', link.key);
      _set('vp8Fps', probe.olcrtcVp8Fps);
      _set('vp8Batch', probe.olcrtcVp8Batch);
      _set('seiFps', probe.olcrtcSeiFps);
      _set('seiBatch', probe.olcrtcSeiBatch);
      _set('seiFrag', probe.olcrtcSeiFrag);
      _set('seiAckMs', probe.olcrtcSeiAckMs);
      _set('videoWidth', probe.olcrtcVideoWidth);
      _set('videoHeight', probe.olcrtcVideoHeight);
      _set('videoFps', probe.olcrtcVideoFps);
      _set('videoCodec', probe.olcrtcVideoCodec);
      _set('videoQrSize', probe.olcrtcVideoQrSize);
      _set('videoQrRecovery', probe.olcrtcVideoQrRecovery);
      _set('videoTileModule', probe.olcrtcVideoTileModule);
      _set('videoTileRs', probe.olcrtcVideoTileRs);
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Link applied — review and save.')),
    );
  }

  Future<void> _copyLink() async {
    if (!isOlcrtcKey(_v('key')) || _v('room').isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Fill in the room and a valid key first.'),
        ),
      );
      return;
    }
    // The link is built from THIS FORM's values via a
    // throwaway settings object — nothing is saved or
    // mutated.
    final probe = XraySettings()
      ..olcrtcProvider = _provider
      ..olcrtcTransport = _transport
      ..olcrtcRoom = _v('room')
      ..olcrtcKey = _v('key')
      ..olcrtcVp8Fps = _v('vp8Fps')
      ..olcrtcVp8Batch = _v('vp8Batch')
      ..olcrtcSeiFps = _v('seiFps')
      ..olcrtcSeiBatch = _v('seiBatch')
      ..olcrtcSeiFrag = _v('seiFrag')
      ..olcrtcSeiAckMs = _v('seiAckMs')
      ..olcrtcVideoWidth = _v('videoWidth')
      ..olcrtcVideoHeight = _v('videoHeight')
      ..olcrtcVideoFps = _v('videoFps')
      ..olcrtcVideoCodec = _v('videoCodec')
      ..olcrtcVideoQrSize = _v('videoQrSize')
      ..olcrtcVideoQrRecovery = _v('videoQrRecovery')
      ..olcrtcVideoTileModule = _v('videoTileModule')
      ..olcrtcVideoTileRs = _v('videoTileRs');
    await Clipboard.setData(ClipboardData(text: buildOlcrtcLink(probe)));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('olcrtc:// link copied')),
      );
    }
  }

  Future<void> _save() async {
    final complete = _v('room').isNotEmpty && isOlcrtcKey(_v('key'));
    if (!complete) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Fill in the room and a valid shared key '
            '(64 hex digits) first.',
          ),
        ),
      );
      return;
    }
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await widget.xray.saveOlcrtcSettings(
        provider: _provider,
        transport: _transport,
        room: _v('room'),
        key: _v('key'),
        token: _v('token'),
        dns: _v('dns'),
        params: {
          'vp8Fps': _v('vp8Fps'),
          'vp8Batch': _v('vp8Batch'),
          'seiFps': _v('seiFps'),
          'seiBatch': _v('seiBatch'),
          'seiFrag': _v('seiFrag'),
          'seiAckMs': _v('seiAckMs'),
          'videoWidth': _v('videoWidth'),
          'videoHeight': _v('videoHeight'),
          'videoFps': _v('videoFps'),
          'videoCodec': _v('videoCodec'),
          'videoQrSize': _v('videoQrSize'),
          'videoQrRecovery': _v('videoQrRecovery'),
          'videoTileModule': _v('videoTileModule'),
          'videoTileRs': _v('videoTileRs'),
        },
      );
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
      onChanged: (_) => setState(() {}),
      decoration: emberField(context, hint ?? label).copyWith(
        labelText: label,
        labelStyle: const TextStyle(color: Ember.faint, fontSize: Ember.fontBody),
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
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Ember.line),
      ),
      child: Row(
        children: [
          Text(label, style: Ember.dimStyle),
          const SizedBox(width: 12),
          Expanded(
            child: DropdownButton<String>(
              value: value,
              isExpanded: true,
              dropdownColor: Ember.card,
              underline: const SizedBox.shrink(),
              style: Ember.body,
              items: [
                for (final (v, name) in options)
                  DropdownMenuItem(value: v, child: Text(name)),
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

  Widget _section(String title, List<Widget> children) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: MapGlass(
        blur: false,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Ember.heading.copyWith(fontSize: Ember.fontTitle)),
          const SizedBox(height: 13),
          ...children,
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final keyOk = isOlcrtcKey(_v('key'));
    final complete = _v('room').isNotEmpty && keyOk;
    final roomHint = switch (_provider) {
      'jitsi' => 'Full room URL, e.g. https://meet.jit.si/myroom',
      'telemost' => 'Room ID or link from Telemost',
      _ => 'Room ID from WBStream',
    };
    final stateLine = !_state.available
        ? 'The OLCRTC client is not available in this build.'
        : _state.ready
        ? 'Client running — the call link is up, listening on '
              '127.0.0.1:${latDigits(olcrtcListenPort)}.'
        : _state.running
        ? 'Client is starting (joining the call)…'
        : _state.stage == 'error'
        ? 'Client stopped unexpectedly.'
        : 'Client is not running. It starts with the next '
              'V2Ray session while OLCRTC is the underlay.';
    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Ember.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Ember.text,
        title: Text('OLCRTC settings', style: Ember.heading),
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
      body: EmberBackground(
        child: ListenableBuilder(
          listenable: widget.xray,
          builder: (context, _) => ListView(
            padding: EdgeInsets.fromLTRB(18, MediaQuery.of(context).padding.top + kToolbarHeight + 6, 18, 24),
            children: [
              _section('How OLCRTC works', [
                Text(
                  'OLCRTC hides the tunnel inside a video call. '
                  'This phone and your server both join the same '
                  'call room with the same shared key, and the '
                  'traffic rides the call\'s data/video channels, '
                  'encrypted end to end. An olcrtc server (the '
                  'same program in srv mode) must run on your '
                  'host — the client alone does nothing. Ember '
                  'runs the client on '
                  '127.0.0.1:${latDigits(olcrtcListenPort)} and '
                  'dials the V2Ray session through it. Jitsi + '
                  'Data channel is upstream\'s recommended '
                  'combination.',
                  style: Ember.caption,
                ),
              ]),
              _section('Share link', [
                _text(
                  'link',
                  'olcrtc:// link',
                  hint: 'Paste a link to fill the form below',
                ),
                Row(
                  children: [
                    TextButton.icon(
                      style: TextButton.styleFrom(
                        minimumSize: const Size(0, 48),
                      ),
                      onPressed: _applyLink,
                      icon: const Icon(
                        Icons.download_rounded,
                        size: 16,
                        color: Ember.dim,
                      ),
                      label: Text('Apply link', style: Ember.caption),
                    ),
                    TextButton.icon(
                      style: TextButton.styleFrom(
                        minimumSize: const Size(0, 48),
                      ),
                      onPressed: () => unawaited(_copyLink()),
                      icon: const Icon(
                        Icons.copy_rounded,
                        size: 16,
                        color: Ember.dim,
                      ),
                      label: Text('Copy my link', style: Ember.caption),
                    ),
                  ],
                ),
                Text(
                  'Copy builds the link from the values in '
                  'this form.',
                  style: Ember.caption,
                ),
              ]),
              _section('Call', [
                _dropdown('Provider', _provider, const [
                  ('jitsi', 'Jitsi'),
                  ('telemost', 'Yandex Telemost'),
                  ('wbstream', 'WBStream'),
                ], (v) => setState(() => _provider = v)),
                _dropdown('Transport', _transport, const [
                  ('datachannel', 'Data channel'),
                  ('vp8channel', 'VP8 video channel'),
                  ('seichannel', 'SEI video channel'),
                  ('videochannel', 'Video channel (QR/tile)'),
                ], (v) => setState(() => _transport = v)),
                _text('room', 'Room', hint: roomHint),
                _text(
                  'key',
                  'Shared key',
                  hint: '64 hex digits, same as the server',
                ),
                Text(
                  _v('key').isEmpty
                      ? 'The shared key is required — the client '
                            'refuses to start without it. Generate '
                            'one with: openssl rand -hex 32'
                      : keyOk
                      ? 'Shared key looks valid.'
                      : 'Not a valid key yet: it must be exactly '
                            '64 hex digits.',
                  style: Ember.caption.copyWith(
                    color: _v('key').isNotEmpty && !keyOk
                        ? Ember.orange
                        : null,
                  ),
                ),
                const SizedBox(height: 11),
                _text(
                  'token',
                  'Provider token (optional)',
                  hint: 'Only for accounts that issue one (WBStream)',
                ),
                _text(
                  'dns',
                  'Resolver for the call service',
                  hint: 'e.g. 8.8.8.8:53 — used by the client itself',
                ),
              ]),
              if (_transport == 'vp8channel')
                _section('VP8 channel', [
                  _text('vp8Fps', 'FPS (blank = default)'),
                  _text('vp8Batch', 'Frames per tick (blank = default)'),
                ]),
              if (_transport == 'seichannel')
                _section('SEI channel', [
                  _text('seiFps', 'FPS (blank = default)'),
                  _text('seiBatch', 'Frames per tick (blank = default)'),
                  _text('seiFrag', 'Fragment size, bytes (blank = default)'),
                  _text('seiAckMs', 'ACK timeout, ms (blank = default)'),
                ]),
              if (_transport == 'videochannel')
                _section('Video channel', [
                  _text('videoWidth', 'Width, px (blank = default)'),
                  _text('videoHeight', 'Height, px (blank = default)'),
                  _text('videoFps', 'FPS (blank = default)'),
                  _text(
                    'videoCodec',
                    'Codec: qrcode or tile (blank = default)',
                  ),
                  _text('videoQrSize', 'QR fragment size (blank = default)'),
                  _text(
                    'videoQrRecovery',
                    'QR recovery: low/medium/high/highest',
                  ),
                  _text('videoTileModule', 'Tile size, px (tile only)'),
                  _text('videoTileRs', 'Tile parity % (tile only)'),
                ]),
              _section('Client', [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: Text(stateLine, style: Ember.caption)),
                    if (_refreshing)
                      const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Ember.orange,
                          ),
                        ),
                      )
                    else
                      IconButton(
                        onPressed: () => unawaited(_refreshState()),
                        icon: const Icon(
                          Icons.refresh_rounded,
                          size: 18,
                          color: MapUi.dim,
                        ),
                        tooltip: 'Refresh',
                      ),
                  ],
                ),
                if (_state.logTail.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    _state.logTail,
                    style: Ember.caption,
                    maxLines: _logExpanded ? null : 6,
                    overflow: _logExpanded
                        ? TextOverflow.visible
                        : TextOverflow.ellipsis,
                  ),
                  Row(
                    children: [
                      TextButton.icon(
                        style: TextButton.styleFrom(
                          minimumSize: const Size(0, 48),
                        ),
                        onPressed: () async {
                          await Clipboard.setData(
                            ClipboardData(text: _state.logTail),
                          );
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Client log copied'),
                              ),
                            );
                          }
                        },
                        icon: const Icon(
                          Icons.copy_rounded,
                          size: 16,
                          color: Ember.dim,
                        ),
                        label: Text('Copy', style: Ember.caption),
                      ),
                      TextButton.icon(
                        style: TextButton.styleFrom(
                          minimumSize: const Size(0, 48),
                        ),
                        onPressed: () =>
                            setState(() => _logExpanded = !_logExpanded),
                        icon: Icon(
                          _logExpanded
                              ? Icons.expand_less_rounded
                              : Icons.expand_more_rounded,
                          size: 16,
                          color: Ember.dim,
                        ),
                        label: Text(
                          _logExpanded ? 'Show less' : 'Show more',
                          style: Ember.caption,
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 4),
                Text(
                  complete
                      ? 'Ready: the next V2Ray session with the '
                            'OLCRTC underlay will start this client.'
                      : 'Fill in the room and the shared key to '
                            'use the OLCRTC underlay.',
                  style: Ember.caption,
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}
