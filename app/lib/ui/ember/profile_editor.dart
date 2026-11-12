/// The manual add / edit form for a V2Ray config: every protocol the
/// parser knows, every transport and security field, in Ember cards.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../xray/anti_filter.dart';
import '../../xray/config_builder.dart';
import '../../xray/link_parser.dart' show newProfileId;
import '../../xray/xray_controller.dart';
import '../../xray/xray_models.dart';
import '../../xray/xray_platform.dart';
import 'ember_theme.dart';

Future<void> openProfileEditor(
  BuildContext context,
  XrayController xray, {
  Profile? existing,
}) =>
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ProfileEditorPage(xray: xray, existing: existing),
      ),
    );

class ProfileEditorPage extends StatefulWidget {
  const ProfileEditorPage({super.key, required this.xray, this.existing});
  final XrayController xray;
  final Profile? existing;

  @override
  State<ProfileEditorPage> createState() => _ProfileEditorPageState();
}

class _ProfileEditorPageState extends State<ProfileEditorPage> {
  late Profile _p;
  final Map<String, TextEditingController> _fields = {};

  /// The warned opt-in for an unencrypted VLESS/Trojan profile
  /// (build 2030): the patched core accepts security "none"
  /// where the stock core refused it, so the warning and the
  /// explicit opt-in live here instead. An existing profile
  /// that is already unencrypted starts opted in — it was
  /// saved under someone's decision already; a new one does
  /// not.
  bool _allowUnencrypted = false;

  @override
  void initState() {
    super.initState();
    _p = widget.existing?.copy() ??
        Profile(id: newProfileId(), protocol: Protocol.vless);
    // A stored congestion value outside the set the core
    // honours (build 2036) can never be chosen in the dropdown
    // — clamp it to the default rather than crash the editor.
    if (!hyCongestionChoices.contains(_p.hyCongestion)) {
      _p.hyCongestion = '';
    }
    _allowUnencrypted =
        widget.existing != null &&
        _p.security.isEmpty &&
        (_p.protocol == Protocol.vless || _p.protocol == Protocol.trojan);
    _bind();
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

  void _bind() {
    _field('name', _p.name);
    _field('address', _p.address);
    _field('port', '${_p.port}');
    _field('cred', _p.uuidOrPassword);
    _field('method', _p.method);
    _field('host', _p.host);
    _field('path', _p.path);
    _field('serviceName', _p.serviceName);
    _field('headerType', _p.headerType);
    _field('sni', _p.sni);
    _field('alpn', _p.alpn);
    _field('fingerprint', _p.fingerprint);
    _field('cipherSuites', _p.cipherSuites);
    _field('echConfigList', _p.echConfigList);
    _field('dialMode', _p.dialMode);
    _field('finalMask', _p.finalMask);
    _field('publicKey', _p.publicKey);
    _field('shortId', _p.shortId);
    _field('spiderX', _p.spiderX);
    _field('flow', _p.flow);
    _field('plugin', _p.plugin);
    _field('secretKey', _p.secretKey);
    _field('peerPublicKey', _p.peerPublicKey);
    _field('preSharedKey', _p.preSharedKey);
    _field('localAddress', _p.localAddress);
    _field('reserved', _p.reserved);
    _field('mtu', '${_p.mtu}');
    _field('keepAlive', '${_p.keepAlive}');
    _field('obfsPassword', _p.obfsPassword);
    _field('upMbps', '${_p.upMbps}');
    _field('downMbps', '${_p.downMbps}');
    _field('congestionControl', _p.congestionControl);
    _field('udpRelayMode', _p.udpRelayMode);
  }

  String _v(String key) => _fields[key]?.text.trim() ?? '';
  int _int(String key, int fallback) => int.tryParse(_v(key)) ?? fallback;

  void _readBack() {
    _p
      ..name = _v('name')
      ..address = _v('address')
      ..port = _int('port', 443)
      ..uuidOrPassword = _v('cred')
      ..method = _v('method')
      ..host = _v('host')
      ..path = _v('path')
      ..serviceName = _v('serviceName')
      ..headerType = _v('headerType')
      ..sni = _v('sni')
      ..alpn = _v('alpn')
      ..fingerprint = _v('fingerprint')
      ..cipherSuites = _v('cipherSuites')
      ..echConfigList = _v('echConfigList')
      // Exact text (build 2030): the core reads dialMode as
      // written — no trim, no case folding (PattNG's EXACT
      // rule). The finalmask JSON is likewise kept verbatim.
      ..dialMode = _fields['dialMode']?.text ?? ''
      ..finalMask = _fields['finalMask']?.text ?? ''
      ..publicKey = _v('publicKey')
      ..shortId = _v('shortId')
      ..spiderX = _v('spiderX')
      ..flow = _v('flow')
      ..plugin = _v('plugin')
      ..secretKey = _v('secretKey')
      ..peerPublicKey = _v('peerPublicKey')
      ..preSharedKey = _v('preSharedKey')
      ..localAddress = _v('localAddress')
      ..reserved = _v('reserved')
      ..mtu = _int('mtu', 1420)
      ..keepAlive = _int('keepAlive', 0)
      ..obfsPassword = _v('obfsPassword')
      ..upMbps = _int('upMbps', 0)
      ..downMbps = _int('downMbps', 0)
      ..congestionControl = _v('congestionControl')
      ..udpRelayMode = _v('udpRelayMode');
  }

  Future<void> _save() async {
    final l = AppLocalizations.of(context);
    _readBack();
    if (_p.address.isEmpty && _p.protocol != Protocol.wireguard) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l.addressRequired)),
      );
      return;
    }
    if (_p.port < 1 || _p.port > 65535) _p.port = 443;
    if (_p.name.isEmpty) _p.name = _p.address;
    // The cipherSuites rule (build 2029A): the core silently
    // ignores cipher suites unless the fingerprint is
    // "unsafe" — saving that combination would promise a
    // shaping that never happens, so it is refused here in
    // plain language instead.
    final csFinding = tlsSettingsCheck(
      _p,
    ).where((f) => f.startsWith('Cipher suites')).firstOrNull;
    if (csFinding != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(csFinding),
          duration: const Duration(seconds: 6),
        ),
      );
      return;
    }
    // The unencrypted warning (build 2030): the patched core
    // accepts a VLESS/Trojan profile with no TLS where the
    // stock core refused it outright. Saving one is possible
    // only with the explicit opt-in switched on in the form —
    // the traffic is visible to the network, and the user
    // must have seen that sentence to proceed.
    if ((_p.protocol == Protocol.vless ||
            _p.protocol == Protocol.trojan) &&
        _p.security.isEmpty &&
        !_allowUnencrypted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'This profile has no encryption. Turn on “Allow '
            'unencrypted” in the Security section to save it.',
          ),
          duration: Duration(seconds: 6),
        ),
      );
      return;
    }
    // The finalmask text must at least be a JSON object
    // (build 2030); the core check below judges the rest.
    if (_p.finalMask.isNotEmpty) {
      var ok = false;
      try {
        ok = jsonDecode(_p.finalMask) is Map;
      } catch (_) {
        ok = false;
      }
      if (!ok) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('The finalmask must be a JSON object.'),
            duration: Duration(seconds: 6),
          ),
        );
        return;
      }
    }
    // Stage A save gate (2026): a shaped config must be accepted
    // by the bundled core itself before it is saved — a shape the
    // core rejects is refused here, with the core's own words,
    // never silently applied. Profiles whose test config cannot
    // be built at all (TUIC) skip the gate. Build 2030: the
    // patched-core fields (dialMode / finalmask) go through the
    // same gate — the bundled core IS the patched one now.
    if (_p.hasShaping || _p.dialMode.isNotEmpty || _p.finalMask.isNotEmpty) {
      String? rejection;
      try {
        rejection = await XrayPlatform.validateConfig(
          buildTestConfig(_p, widget.xray.settings),
        );
      } catch (_) {
        rejection = null;
      }
      if (rejection != null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('The core rejected this config: $rejection'),
              duration: const Duration(seconds: 6),
            ),
          );
        }
        return;
      }
    }
    if (widget.existing == null) {
      await widget.xray.addProfile(_p);
    } else {
      await widget.xray.updateProfile(_p);
    }
    if (mounted) Navigator.of(context).pop();
  }

  Widget _text(String key, String label, {String? hint, bool ltr = true}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 11),
        child: TextField(
          controller: _fields[key],
          style: Ember.body,
          textDirection: ltr ? TextDirection.ltr : null,
          decoration: emberField(context, hint ?? label).copyWith(
            labelText: label,
            labelStyle: const TextStyle(color: Ember.faint, fontSize: 13),
            floatingLabelStyle: const TextStyle(color: Ember.orange),
          ),
        ),
      );

  Widget _dropdown<T>(
    String label,
    T value,
    List<(T, String)> options,
    ValueChanged<T> onChanged,
  ) =>
      Padding(
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
              const Spacer(),
              DropdownButton<T>(
                value: value,
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
            ],
          ),
        ),
      );

  Widget _toggleRow(
    String label,
    bool value,
    ValueChanged<bool> onChanged,
  ) =>
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

  Widget _section(String title, List<Widget> children) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Ember.heading.copyWith(fontSize: 14.5)),
              const SizedBox(height: 13),
              ...children,
            ],
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final proto = _p.protocol;
    final streamProtocols = {
      Protocol.vless,
      Protocol.vmess,
      Protocol.trojan,
    }.contains(proto);
    return Scaffold(
      backgroundColor: Ember.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Ember.text,
        title: Text(
          widget.existing == null ? l.addManual : l.editProfile,
          style: Ember.heading,
        ),
        actions: [
          IconButton(
            onPressed: () => unawaited(_save()),
            icon: const Icon(Icons.check_rounded, color: Ember.orange),
            tooltip: l.saveAction,
          ),
        ],
      ),
      body: EmberBackground(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 6, 18, 24),
          children: [
            if (proto == Protocol.tuic)
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: GlassCard(
                  child: Row(
                    children: [
                      const Icon(Icons.info_outline_rounded, color: Ember.warn, size: 20),
                      const SizedBox(width: 10),
                      Expanded(child: Text(l.tuicNote, style: Ember.dimStyle)),
                    ],
                  ),
                ),
              ),
            if (proto == Protocol.anytls)
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: GlassCard(
                  child: Row(
                    children: [
                      const Icon(Icons.info_outline_rounded, color: Ember.warn, size: 20),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'AnyTLS is saved and can be shared, but the '
                          'Xray core has no AnyTLS outbound, so it '
                          'cannot connect yet.',
                          style: Ember.dimStyle,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            _section(l.sectionBasic, [
              _dropdown<Protocol>(l.fieldProtocol, proto, [
                for (final p in Protocol.values) (p, p.label),
              ], (v) => setState(() => _p.protocol = v)),
              _text('name', l.fieldName, ltr: false),
              if (proto == Protocol.wireguard) ...[
                _text('secretKey', l.fieldSecretKey),
                _text('address', l.fieldAddress),
                _text('port', l.fieldPort),
                _text('peerPublicKey', l.fieldPeerPublicKey),
                _text('preSharedKey', l.fieldPreSharedKey),
                _text('localAddress', l.fieldLocalAddress),
                _text('reserved', l.fieldReserved),
                _text('mtu', 'MTU'),
                _text('keepAlive', l.fieldKeepAlive),
              ] else ...[
                _text('address', l.fieldAddress),
                _text('port', l.fieldPort),
              ],
              if (proto == Protocol.vless ||
                  proto == Protocol.vmess ||
                  proto == Protocol.tuic)
                _text('cred', 'UUID'),
              if (proto == Protocol.trojan ||
                  proto == Protocol.hysteria2 ||
                  proto == Protocol.anytls)
                _text('cred', l.fieldPassword),
              if (proto == Protocol.shadowsocks) ...[
                _dropdown<String>(l.fieldMethod, _p.method.isEmpty ? 'aes-256-gcm' : _p.method, [
                  for (final m in const [
                    'aes-256-gcm',
                    'aes-128-gcm',
                    'chacha20-ietf-poly1305',
                    'xchacha20-ietf-poly1305',
                    '2022-blake3-aes-128-gcm',
                    '2022-blake3-aes-256-gcm',
                    '2022-blake3-chacha20-poly1305',
                    'none',
                  ])
                    (m, m),
                ], (v) {
                  _p.method = v;
                  _fields['method']?.text = v;
                }),
                _text('cred', l.fieldPassword),
                _text('plugin', l.fieldPlugin),
              ],
              if (proto == Protocol.vless) _text('flow', 'Flow'),
            ]),
            if (streamProtocols) ...[
              _section(l.sectionTransport, [
                _dropdown<String>(l.fieldNetwork, _p.network, const [
                  ('tcp', 'TCP'),
                  ('ws', 'WebSocket'),
                  ('grpc', 'gRPC'),
                  ('httpupgrade', 'HTTPUpgrade'),
                  ('xhttp', 'XHTTP / SplitHTTP'),
                  ('http', 'HTTP/2'),
                  ('kcp', 'mKCP'),
                  ('quic', 'QUIC'),
                ], (v) => setState(() => _p.network = v)),
                if (_p.network == 'ws' ||
                    _p.network == 'httpupgrade' ||
                    _p.network == 'xhttp' ||
                    _p.network == 'http') ...[
                  _text('host', 'Host'),
                  _text('path', l.fieldPath),
                ],
                if (_p.network == 'grpc') ...[
                  _text('serviceName', 'ServiceName'),
                  _dropdown<String>(l.fieldMode, _p.mode.isEmpty ? 'gun' : _p.mode, const [
                    ('gun', 'gun'),
                    ('multi', 'multi'),
                  ], (v) => setState(() => _p.mode = v)),
                ],
                if (_p.network == 'kcp' || _p.network == 'quic')
                  _text('headerType', l.fieldHeaderType),
                if (_p.network == 'kcp') _text('path', l.fieldSeed),
              ]),
              _section(l.sectionSecurity, [
                _dropdown<String>(l.fieldSecurity, _p.security, const [
                  ('', '—'),
                  ('tls', 'TLS'),
                  ('reality', 'REALITY'),
                ], (v) => setState(() => _p.security = v)),
                if ((proto == Protocol.vless ||
                        proto == Protocol.trojan) &&
                    _p.security.isEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.only(bottom: 11),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(
                          Icons.warning_amber_rounded,
                          color: Ember.warn,
                          size: 19,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'No encryption: this connection is '
                            'visible to the network — anyone on '
                            'the path can read it. The patched '
                            'core accepts such profiles only '
                            'because some servers still use them.',
                            style: Ember.dimStyle,
                          ),
                        ),
                      ],
                    ),
                  ),
                  _toggleRow(
                    'Allow unencrypted',
                    _allowUnencrypted,
                    (v) => _allowUnencrypted = v,
                  ),
                ],
                if (_p.security == 'tls' || _p.security == 'reality') ...[
                  _text('sni', 'SNI'),
                  _text('alpn', 'ALPN'),
                  _text('fingerprint', 'Fingerprint (uTLS)'),
                ],
                if (_p.security == 'tls') ...[
                  _text(
                    'cipherSuites',
                    'Cipher suites (IANA names, colon-separated)',
                  ),
                  _text(
                    'echConfigList',
                    'ECH config list (from the link’s ech parameter)',
                  ),
                  // TlsSettingsCheck findings (build 2029A),
                  // computed from the fields as they stand.
                  Builder(
                    builder: (context) {
                      final probe = _p.copy()
                        ..fingerprint = _v('fingerprint')
                        ..cipherSuites = _v('cipherSuites')
                        ..alpn = _v('alpn');
                      final findings = tlsSettingsCheck(probe);
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final f in findings)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 11),
                              child: Row(
                                crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                children: [
                                  const Icon(
                                    Icons.info_outline_rounded,
                                    color: Ember.warn,
                                    size: 17,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(f, style: Ember.dimStyle),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                ],
                if (_p.security == 'reality') ...[
                  _text('publicKey', l.fieldPublicKey),
                  _text('shortId', l.fieldShortId),
                  _text('spiderX', 'SpiderX'),
                ],
                if (_p.security == 'tls')
                  Row(
                    children: [
                      Expanded(child: Text(l.allowInsecure, style: Ember.body)),
                      EmberToggle(
                        value: _p.allowInsecure,
                        onChanged: (v) => setState(() => _p.allowInsecure = v),
                      ),
                    ],
                  ),
              ]),
            ],
            if (streamProtocols)
              // Anti-filter shaping (build 2026, Stage A): per-profile
              // and opt-in — an untouched profile generates exactly
              // the config it did in 2025. The TLS shapes apply only
              // when security is TLS; TCP noise rides the fragment
              // chain for any transport. On save, a shaped config is
              // validated by the core itself (see _save).
              _section('Anti-filter', [
                if (_p.security == 'tls') ...[
                  _toggleRow(
                    'Unfilter SNI shape',
                    _p.afUnfilter,
                    (v) => _p.afUnfilter = v,
                  ),
                  // ECH wins over the unfilter shape in the
                  // generator when both are on (the source's
                  // precedence); both toggles stay independent.
                  _toggleRow(
                    'ECH (encrypted ClientHello)',
                    _p.afEch,
                    (v) => _p.afEch = v,
                  ),
                  _dropdown<String>(
                    'TLS fragmentation',
                    _p.afFragment,
                    [
                      ('', 'Off'),
                      for (final shape in afFragmentShapes)
                        (shape.id, shape.label),
                    ],
                    (v) => setState(() => _p.afFragment = v),
                  ),
                  _toggleRow(
                    'Mixed-case SNI',
                    _p.afMixedSni,
                    (v) => _p.afMixedSni = v,
                  ),
                ] else
                  Padding(
                    padding: const EdgeInsets.only(bottom: 11),
                    child: Text(
                      'TLS shaping needs security set to TLS. TCP noise '
                      'below works with any security.',
                      style: Ember.caption,
                    ),
                  ),
                _toggleRow(
                  'TCP noise packets',
                  _p.afTcpNoise,
                  (v) => _p.afTcpNoise = v,
                ),
                Text(
                  'Shaped configs are checked by the core before they '
                  'can be saved.',
                  style: Ember.caption,
                ),
              ]),
            if (streamProtocols)
              // The patched core's per-profile fields (build
              // 2030): dialMode is exact text the core reads
              // verbatim; the finalmask is the whole JSON
              // object. A stock core would silently ignore
              // both — the bundled core is the patched one.
              _section('Patched core', [
                _text('dialMode', 'Dial mode (exact text)'),
                Padding(
                  padding: const EdgeInsets.only(bottom: 11),
                  child: Wrap(
                    spacing: 8,
                    children: [
                      for (final preset in const ['oob.0', 'oob.0,_,12'])
                        ActionChip(
                          label: Text(preset, style: Ember.caption),
                          backgroundColor: Ember.field,
                          side: const BorderSide(color: Ember.line),
                          onPressed: () => setState(
                            () => _fields['dialMode']?.text = preset,
                          ),
                        ),
                      ActionChip(
                        label: Text('Off', style: Ember.caption),
                        backgroundColor: Ember.field,
                        side: const BorderSide(color: Ember.line),
                        onPressed: () =>
                            setState(() => _fields['dialMode']?.text = ''),
                      ),
                    ],
                  ),
                ),
                _text('finalMask', 'Finalmask (JSON)'),
                Padding(
                  padding: const EdgeInsets.only(bottom: 11),
                  child: Wrap(
                    spacing: 8,
                    children: [
                      ActionChip(
                        label: Text(
                          'Merge preset',
                          style: Ember.caption,
                        ),
                        backgroundColor: Ember.field,
                        side: const BorderSide(color: Ember.line),
                        onPressed: () => setState(
                          () => _fields['finalMask']?.text =
                              '{"tcp":[{"type":"merge","settings":'
                              '{"times":3,"delayMs":8,"maxBytes":2048}}]}',
                        ),
                      ),
                      ActionChip(
                        label: Text('Clear', style: Ember.caption),
                        backgroundColor: Ember.field,
                        side: const BorderSide(color: Ember.line),
                        onPressed: () =>
                            setState(() => _fields['finalMask']?.text = ''),
                      ),
                    ],
                  ),
                ),
                Text(
                  'Dial mode appends one urgent byte per leading '
                  'write (oob.<byte>,…; “_” leaves that write '
                  'untouched). Both fields are checked by the '
                  'core before they can be saved.',
                  style: Ember.caption,
                ),
              ]),
            if (proto == Protocol.hysteria2)
              _section('Hysteria2', [
                _text('sni', 'SNI'),
                _dropdown<String>('Obfs', _p.obfs, const [
                  ('', '—'),
                  ('salamander', 'salamander'),
                ], (v) => setState(() => _p.obfs = v)),
                // Congestion control (build 2036, queue 2d):
                // the QUIC congestion control the core runs for
                // this profile's Hysteria2 handshake. Default
                // is BBR standard — today's behaviour.
                _dropdown<String>(
                  'Congestion control',
                  _p.hyCongestion,
                  const [
                    ('', 'Default (BBR standard)'),
                    ('bbr-standard', 'BBR — Standard'),
                    ('bbr-conservative', 'BBR — Conservative'),
                    ('bbr-aggressive', 'BBR — Aggressive'),
                    ('reno', 'Reno'),
                  ],
                  (v) => setState(() => _p.hyCongestion = v),
                ),
                Text(
                  'How the QUIC handshake shares the link. '
                  'Conservative is steadier on lossy mobile data; '
                  'aggressive pushes harder on clean links; Reno '
                  'is the plain transport default.',
                  style: Ember.caption,
                ),
                if (_p.obfs.isNotEmpty) _text('obfsPassword', l.fieldObfsPassword),
                _text('upMbps', l.fieldUpMbps),
                _text('downMbps', l.fieldDownMbps),
                _text('fingerprint', 'pinSHA256'),
                // ECH for the QUIC handshake (build 2033): the
                // core's TLS stack consumes this list for the
                // hysteria dialer — the SNI stops travelling in
                // the clear. Empty = off.
                _text(
                  'echConfigList',
                  'ECH config list (hides the SNI; empty = off)',
                ),
                // The mixed-case half of the TLS tricks for
                // Hysteria2 (build 2033): the same switch the
                // anti-filter section offers TCP TLS profiles —
                // Hysteria2 builds its own stream settings, so
                // it lives here. The padding-extension half has
                // no core switch and is not offered anywhere.
                _toggleRow(
                  'Mixed-case SNI',
                  _p.afMixedSni,
                  (v) => _p.afMixedSni = v,
                ),
                Row(
                  children: [
                    Expanded(child: Text(l.allowInsecure, style: Ember.body)),
                    EmberToggle(
                      value: _p.allowInsecure,
                      onChanged: (v) => setState(() => _p.allowInsecure = v),
                    ),
                  ],
                ),
              ]),
            if (proto == Protocol.anytls)
              _section('AnyTLS', [
                _text('sni', 'SNI'),
                _text('alpn', 'ALPN'),
                _text('fingerprint', 'Fingerprint'),
                Row(
                  children: [
                    Expanded(child: Text(l.allowInsecure, style: Ember.body)),
                    EmberToggle(
                      value: _p.allowInsecure,
                      onChanged: (v) => setState(() => _p.allowInsecure = v),
                    ),
                  ],
                ),
              ]),
            if (proto == Protocol.wireguard && _p.hasAmneziaParams)
              // The AmneziaWG parameters an import carried
              // (build 2033): shown, preserved and exported —
              // not applied (the carrier runs plain WireGuard),
              // and the section says exactly that.
              _section('AmneziaWG', [
                for (final (label, value) in [
                  ('Jc', _p.awgJc),
                  ('Jmin', _p.awgJmin),
                  ('Jmax', _p.awgJmax),
                  ('S1', _p.awgS1),
                  ('S2', _p.awgS2),
                  ('H1', _p.awgH1),
                  ('H2', _p.awgH2),
                  ('H3', _p.awgH3),
                  ('H4', _p.awgH4),
                ])
                  if (value.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 52,
                            child: Text(label, style: Ember.dimStyle),
                          ),
                          Expanded(child: Text(value, style: Ember.body)),
                        ],
                      ),
                    ),
                Text(
                  'Stored on the profile and written back on '
                  'export, so an AmneziaWG client receives them '
                  'intact. Ember’s WireGuard carrier cannot apply '
                  'them — this profile runs as plain WireGuard.',
                  style: Ember.caption,
                ),
              ]),
            if (proto == Protocol.tuic)
              _section('TUIC', [
                _text('method', l.fieldPassword),
                _text('congestionControl', l.fieldCongestion),
                _text('udpRelayMode', l.fieldUdpRelayMode),
                _text('sni', 'SNI'),
                _text('alpn', 'ALPN'),
                Row(
                  children: [
                    Expanded(child: Text(l.allowInsecure, style: Ember.body)),
                    EmberToggle(
                      value: _p.allowInsecure,
                      onChanged: (v) => setState(() => _p.allowInsecure = v),
                    ),
                  ],
                ),
              ]),
            EmberButton(
              label: l.saveAction,
              icon: Icons.check_rounded,
              onTap: () => unawaited(_save()),
            ),
          ],
        ),
      ),
    );
  }
}
