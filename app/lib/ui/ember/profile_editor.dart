/// The manual add / edit form for a V2Ray config: every protocol the
/// parser knows, every transport and security field, in Ember cards.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../xray/link_parser.dart' show newProfileId;
import '../../xray/xray_controller.dart';
import '../../xray/xray_models.dart';
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

  @override
  void initState() {
    super.initState();
    _p = widget.existing?.copy() ??
        Profile(id: newProfileId(), protocol: Protocol.vless);
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
              if (proto == Protocol.trojan || proto == Protocol.hysteria2)
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
                if (_p.security == 'tls' || _p.security == 'reality') ...[
                  _text('sni', 'SNI'),
                  _text('alpn', 'ALPN'),
                  _text('fingerprint', 'Fingerprint (uTLS)'),
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
            if (proto == Protocol.hysteria2)
              _section('Hysteria2', [
                _text('sni', 'SNI'),
                _dropdown<String>('Obfs', _p.obfs, const [
                  ('', '—'),
                  ('salamander', 'salamander'),
                ], (v) => setState(() => _p.obfs = v)),
                if (_p.obfs.isNotEmpty) _text('obfsPassword', l.fieldObfsPassword),
                _text('upMbps', l.fieldUpMbps),
                _text('downMbps', l.fieldDownMbps),
                _text('fingerprint', 'pinSHA256'),
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
