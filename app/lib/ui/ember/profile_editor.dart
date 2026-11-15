/// The manual add / edit form for a V2Ray config: every protocol the
/// parser knows, every transport and security field, in Ember cards.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../xray/anti_filter.dart';
import '../../xray/config_builder.dart';
import '../../xray/link_parser.dart' show newProfileId;
import '../../xray/tls_cert_pin.dart';
import '../../xray/vless_encryption.dart';
import '../../xray/xray_controller.dart';
import '../../xray/xray_models.dart';
import '../../xray/xray_platform.dart';
import 'ember_theme.dart';
import 'map_widgets.dart';
import 'qr_pages.dart';
import 'sandbox_test_sheet.dart';

Future<void> openProfileEditor(
  BuildContext context,
  XrayController xray, {
  Profile? existing,
}) => Navigator.of(context).push(
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

  /// Build 2074 (audit item 9): busy guards — _save() and the
  /// sandbox test used to stay tappable while running, so a
  /// double-tap could save twice or queue concurrent tests.
  bool _saving = false;
  bool _testing = false;

  @override
  void initState() {
    super.initState();
    _p =
        widget.existing?.copy() ??
        Profile(id: newProfileId(), protocol: Protocol.vless);
    // A stored congestion value outside the set the core
    // honours (build 2036) can never be chosen in the dropdown
    // — clamp it to the default rather than crash the editor.
    if (!hyCongestionChoices.contains(_p.hyCongestion)) {
      _p.hyCongestion = '';
    }
    // Build 2056 (audit F-M9): the same clamp, generalised.
    // Every dropdown in this form only accepts its option list,
    // but the parser freely stores values outside it, and a
    // DropdownButton asserts when its value is not among its
    // items — so an imported profile threw on open. Each stored
    // value below is mapped to the closest valid option (a safe
    // same-meaning rename where one exists, the default where
    // none does) so the profile always opens. The working copy
    // is clamped; the stored original only changes on save.
    _p.network = _clampToOptions(
      _p.network,
      const {
        'splithttp': 'xhttp', // the core reads both identically
        'h2': 'http', // the HTTP/2 transport
        'raw': 'tcp', // a bare stream is plain TCP
      },
      const {
        'tcp',
        'ws',
        'grpc',
        'httpupgrade',
        'xhttp',
        'http',
        'kcp',
        'quic',
      },
      'tcp',
    );
    // The method dropdown only renders for Shadowsocks — and
    // for TUIC the same field stores the password, so a TUIC
    // profile's value must never be touched here.
    if (_p.protocol == Protocol.shadowsocks) {
      _p.method = _clampToOptions(
        _p.method,
        const {'chacha20-poly1305': 'chacha20-ietf-poly1305'},
        const {
          'aes-256-gcm',
          'aes-128-gcm',
          'chacha20-ietf-poly1305',
          'xchacha20-ietf-poly1305',
          '2022-blake3-aes-128-gcm',
          '2022-blake3-aes-256-gcm',
          '2022-blake3-chacha20-poly1305',
          'none',
        },
        'aes-256-gcm',
      );
    }
    // The gRPC mode dropdown only renders for gRPC — and for
    // XHTTP the same field stores the stream mode (auto, …),
    // so only a gRPC profile's value is clamped here.
    if (_p.network == 'grpc' &&
        _p.mode.isNotEmpty &&
        _p.mode != 'gun' &&
        _p.mode != 'multi') {
      _p.mode = 'gun';
    }
    // The TLS-fragmentation dropdown only offers the shipped
    // shapes; a stale id means no shape.
    if (_p.afFragment.isNotEmpty && afShapeById(_p.afFragment) == null) {
      _p.afFragment = '';
    }
    // The Hysteria2 obfs dropdown only offers salamander; any
    // other stored obfs is one the core would not run.
    if (_p.protocol == Protocol.hysteria2 &&
        _p.obfs.isNotEmpty &&
        _p.obfs != 'salamander') {
      _p.obfs = '';
    }
    // Legacy Hysteria2 pin migration (build 2053, audit F-H5):
    // pre-2053 imports stored the `pinSHA256` value in
    // `fingerprint`, a field the core never reads for Hy2. The
    // canonical pin field is tlsCertPin now — move a valid pin
    // there so the form shows it and the save keeps it; a
    // non-pin fingerprint is left alone (nothing else uses it
    // for Hy2). The copy is migrated, the stored original only
    // changes on save.
    if (_p.protocol == Protocol.hysteria2 &&
        _p.tlsCertPin.isEmpty &&
        isValidTlsCertPin(_p.fingerprint)) {
      _p.tlsCertPin = _p.fingerprint;
      _p.fingerprint = '';
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

  /// Maps a stored value onto the closest option a dropdown
  /// offers (build 2056, audit F-M9): [renames] are safe
  /// same-meaning names, anything else outside [options] falls
  /// back to [fallback] so the form always opens.
  static String _clampToOptions(
    String value,
    Map<String, String> renames,
    Set<String> options,
    String fallback,
  ) {
    final renamed = renames[value];
    if (renamed != null) return renamed;
    return options.contains(value) ? value : fallback;
  }

  void _bind() {
    // Build 2045: the Name field shows the name the user sees —
    // their label when one is set — and _save splits it back
    // into the server name and the label for subscription
    // profiles.
    _field('name', _p.displayName);
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
    _field('pqv', _p.pqv);
    _field('aid', '${_p.aid}');
    _field('scy', _p.scy);
    _field('grpcAuthority', _p.grpcAuthority);
    _field('vlessEncryption', _p.vlessEncryption);
    _field('tlsCertPin', _p.tlsCertPin);
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
    _field('username', _p.username);
    _field('congestionControl', _p.congestionControl);
    _field('udpRelayMode', _p.udpRelayMode);
    // Build 2065 (item 8): the AmneziaWG junk fields are EDITABLE
    // now, for any WireGuard profile — the run path has applied
    // them since 2050; until now the editor only displayed them.
    _field('awgJc', _p.awgJc);
    _field('awgJmin', _p.awgJmin);
    _field('awgJmax', _p.awgJmax);
    _field('awgS1', _p.awgS1);
    _field('awgS2', _p.awgS2);
    _field('awgH1', _p.awgH1);
    _field('awgH2', _p.awgH2);
    _field('awgH3', _p.awgH3);
    _field('awgH4', _p.awgH4);
  }

  /// Switching protocols carries the fingerprint across (build
  /// 2057, audit F-M15): a Hy2 pin stored in `fingerprint` (a
  /// pre-2053 import) would land in a TLS profile's uTLS name
  /// and hard-fail the core's TLSConfig.Build at connect. Moving
  /// a pin-shaped value into the pin field on the switch keeps
  /// the control and drops the failure mode. The field texts are
  /// read live — the bound profile values are stale until save.
  void _onProtocolChanged(Protocol v) {
    setState(() {
      if (v != Protocol.hysteria2 &&
          _v('tlsCertPin').isEmpty &&
          isValidTlsCertPin(_v('fingerprint'))) {
        final pin = _v('fingerprint');
        _fields['tlsCertPin']?.text = pin;
        _fields['fingerprint']?.text = '';
      }
      _p.protocol = v;
    });
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
      ..pqv = _v('pqv')
      ..aid = _int('aid', 0)
      ..scy = _v('scy')
      ..grpcAuthority = _v('grpcAuthority')
      ..vlessEncryption = _v('vlessEncryption')
      ..tlsCertPin = _v('tlsCertPin')
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
      ..username = _v('username')
      ..congestionControl = _v('congestionControl')
      ..udpRelayMode = _v('udpRelayMode')
      ..awgJc = _v('awgJc')
      ..awgJmin = _v('awgJmin')
      ..awgJmax = _v('awgJmax')
      ..awgS1 = _v('awgS1')
      ..awgS2 = _v('awgS2')
      ..awgH1 = _v('awgH1')
      ..awgH2 = _v('awgH2')
      ..awgH3 = _v('awgH3')
      ..awgH4 = _v('awgH4');
  }

  /// Build 2074 (audit item 9): the re-entry guard and busy
  /// flag live in this wrapper so _saveInner's many early
  /// returns all release the Save pill through the finally.
  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await _saveInner();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _saveInner() async {
    final l = AppLocalizations.of(context);
    _readBack();
    if (_p.address.isEmpty && _p.protocol != Protocol.wireguard) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l.addressRequired)));
      return;
    }
    // Build 2074 (audit item 21): an out-of-range port refuses
    // the save with the valid range named — it used to be
    // silently rewritten to 443, so the saved profile differed
    // from what was typed.
    if (_p.port < 1 || _p.port > 65535) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Port must be between 1 and 65535.'),
          duration: Duration(seconds: 6),
        ),
      );
      return;
    }
    // Build 2045: a subscription profile's name belongs to the
    // provider — the next refresh recreates it from the link, so
    // a rename written into it would be wiped. The typed name is
    // the user's own label, stored apart so the refresh cannot
    // touch it; the server name is restored and stays the name
    // the share link and the country grouping use. A label
    // identical to the server name (or an empty one) stores as
    // no label at all. A hand-added profile has no provider name,
    // so the typed name IS its name, as before.
    if (widget.existing != null && _p.subscriptionId.isNotEmpty) {
      final serverName = widget.existing!.name.isEmpty
          ? _p.address
          : widget.existing!.name;
      final typed = _v('name');
      _p.name = serverName;
      _p.localName = typed.isEmpty || typed == serverName ? '' : typed;
    } else if (_p.name.isEmpty) {
      _p.name = _p.address;
    }
    // The cipherSuites rule (build 2029A): the core silently
    // ignores cipher suites unless the fingerprint is
    // "unsafe" — saving that combination would promise a
    // shaping that never happens, so it is refused here in
    // plain language instead.
    final csFinding = tlsSettingsCheck(_p)
        .where((f) => f.startsWith('Cipher suites'))
        .firstOrNull;
    if (csFinding != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(csFinding),
          duration: const Duration(seconds: 6),
        ),
      );
      return;
    }
    // The VLESS Encryption value (build 2046) must be a string
    // the bundled core accepts — saving a malformed one would
    // promise encryption that never happens (the core refuses
    // the whole config at connect), so it is refused here in
    // plain language instead. Empty = none, as before.
    if (_p.vlessEncryption.isNotEmpty &&
        !isValidVlessEncryption(_p.vlessEncryption)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'VLESS encryption must look like '
            'mlkem768x25519plus.native.0rtt.… — fix it or clear '
            'the field.',
          ),
          duration: Duration(seconds: 6),
        ),
      );
      return;
    }
    // The certificate pin (build 2047) must be one or more
    // SHA-256 hashes the bundled core accepts — saving a
    // malformed one would make the core refuse every connect
    // for this profile, so it is refused here in plain language
    // instead. Empty = no pinning, as before. A valid pin also
    // replaces "Allow insecure": the core removed that option
    // outright, so the toggle is ignored for a pinned profile.
    if (_p.tlsCertPin.isNotEmpty && !isValidTlsCertPin(_p.tlsCertPin)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Certificate pin must be one or more SHA-256 hashes '
            '(64 hex characters each, comma-separated for '
            'several) — fix it or clear the field.',
          ),
          duration: Duration(seconds: 6),
        ),
      );
      return;
    }
    // A pin-shaped fingerprint is a certificate pin, not a uTLS
    // name (build 2057, audit F-M15): the core's TLSConfig.Build
    // hard-fails on it at connect, so the save is refused here
    // in plain language instead — the value belongs in the
    // Certificate pin field above.
    final pinFinding = fingerprintPinFinding(_p);
    if (pinFinding != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(pinFinding),
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
    // must have seen that sentence to proceed. Build 2046: a
    // VLESS profile carrying a valid VLESS Encryption value is
    // encrypted at the VLESS layer even without TLS, so it
    // needs no opt-in.
    if ((_p.protocol == Protocol.vless || _p.protocol == Protocol.trojan) &&
        _p.security.isEmpty &&
        _p.vlessEncryption.isEmpty &&
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

  Widget _text(
    String key,
    String label, {
    String? hint,
    bool ltr = true,
    // Build 2056: unbroken-string values (keys, UUIDs, ECH,
    // JSON) are multiline + monospace so they can be reviewed
    // instead of scrolled blind in a single line.
    bool multiline = false,
    bool mono = false,
    // Build 2074 (audit item 25): digit-only fields (port,
    // alter ID, MTU, keep-alive, Mbps) open the number
    // keyboard instead of the full text keyboard.
    bool numeric = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 11),
    child: TextField(
      controller: _fields[key],
      style: mono ? Ember.body.copyWith(fontFamily: 'monospace') : Ember.body,
      textDirection: ltr ? TextDirection.ltr : null,
      keyboardType: numeric
          ? TextInputType.number
          : multiline
          ? TextInputType.multiline
          : null,
      maxLines: multiline ? null : 1,
      minLines: multiline ? 2 : 1,
      decoration: emberField(context, hint ?? label).copyWith(
        // Build 2056: a long label wraps to two lines
        // instead of truncating mid-word.
        label: Text(
          label,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Ember.faint, fontSize: 13),
        ),
        floatingLabelStyle: const TextStyle(color: Ember.orange),
      ),
    ),
  );

  Widget _dropdown<T>(
    String label,
    T value,
    List<(T, String)> options,
    ValueChanged<T> onChanged,
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
          // Build 2056: both sides flex — a DropdownButton
          // sizes to its WIDEST menu item (the F15 shape
          // label is 48 chars), so the label + button
          // overflowed the row by 235 px in the editor; on a
          // 360 px phone the same row overflowed by ~150 px.
          // isExpanded makes the button take its share and
          // ellipsise the value.
          Flexible(
            child: Text(
              label,
              style: Ember.dimStyle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 12),
          Flexible(
            flex: 2,
            child: DropdownButton<T>(
              isExpanded: true,
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

  /// A labelled horizontal chip row (build 2050, sample C:
  /// the editor's protocol / transport / security pickers are
  /// chip rows, not dropdowns).
  Widget _chipPicker<T>(
    String label,
    List<(T, String)> options,
    T current,
    ValueChanged<T> onPick,
  ) => Padding(
    padding: const EdgeInsets.only(bottom: 11),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Ember.dimStyle),
        const SizedBox(height: 7),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final (v, name) in options) ...[
                EmberChip(
                  label: name,
                  selected: v == current,
                  onTap: () => onPick(v),
                ),
                const SizedBox(width: 6),
              ],
            ],
          ),
        ),
      ],
    ),
  );

  /// "Test this node" (build 2050, sample C; build 2061: the
  /// full sandbox test): runs the sandbox test on the values
  /// as they stand in the form — no save needed first — and
  /// shows the verdict sheet.
  /// Build 2074 (audit item 9): the re-entry guard and busy
  /// flag, same pattern as _save().
  Future<void> _testNode() async {
    if (_testing) return;
    setState(() => _testing = true);
    try {
      await _testNodeInner();
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _testNodeInner() async {
    _readBack();
    final r = await widget.xray.sandboxTest(_p);
    if (mounted) {
      await showSandboxTestSheet(
        context,
        profile: _p,
        result: r,
        onConnect: () => _connectFromEditor(false),
      );
    }
  }

  /// Connects or disconnects this node from the editor's
  /// status card (build 2050, sample C).
  Future<void> _connectFromEditor(bool connectedThis) async {
    final xray = widget.xray;
    try {
      if (connectedThis) {
        await xray.disconnect();
        return;
      }
      xray.select(_p);
      if (_p.protocol == Protocol.wireguard) {
        await xray.connectWireGuardWithFallback(_p);
      } else {
        await xray.connect();
      }
    } on StateError catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              e.message == 'wg-all-peers-failed'
                  ? 'No peer of this config carried traffic'
                  : e.message,
            ),
          ),
        );
      }
    } catch (e) {
      // Build 2070 (review §3.4): a plain line, not the raw
      // exception — the detail stays in the controller's
      // diagnostics journal and the log page.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).startFailed)),
        );
      }
    }
  }

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
      // Build 2059 (audit §6 appearance low): the body is the map
      // backdrop — extend it behind the transparent app bar so the
      // editor has no flat solid strip over the map.
      extendBodyBehindAppBar: true,
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
          // Sample C (build 2050): an ember Save pill, always in
          // reach at the top of the form.
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  // Build 2074 (audit item 9): while a save is
                  // running the pill is disabled and spins.
                  onTap: _saving ? null : () => unawaited(_save()),
                  borderRadius: BorderRadius.circular(999),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      gradient: Ember.gradient,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: _saving
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Color(0xFF1A1206),
                            ),
                          )
                        : Text(
                            l.saveAction,
                            style: const TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFF1A1206),
                            ),
                          ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      body: EmberBackground(
        child: ListView(
          // Build 2059: the body extends behind the transparent app
          // bar now — keep the first field below it.
          padding: EdgeInsets.fromLTRB(
            18,
            MediaQuery.of(context).padding.top + kToolbarHeight + 6,
            18,
            24,
          ),
          children: [
            if (proto == Protocol.tuic)
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: GlassCard(
                  child: Row(
                    children: [
                      const Icon(
                        Icons.info_outline_rounded,
                        color: Ember.warn,
                        size: 20,
                      ),
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
                      const Icon(
                        Icons.info_outline_rounded,
                        color: Ember.warn,
                        size: 20,
                      ),
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
              _chipPicker<Protocol>(
                l.fieldProtocol,
                [for (final p in Protocol.values) (p, p.label)],
                proto,
                (v) => _onProtocolChanged(v),
              ),
              _text('name', l.fieldName, ltr: false),
              // Build 2045: a subscription profile's rename is a
              // personal label, not a new server name — say so
              // where the rename happens, and show the server
              // name a label is hiding.
              if (widget.existing != null &&
                  widget.existing!.subscriptionId.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 11),
                  child: Text(
                    _p.localName.isEmpty
                        ? 'Your own label for this config — it survives '
                              'subscription refreshes. The server name '
                              'stays on the share link.'
                        : 'Server name: ${_p.name} — your label survives '
                              'subscription refreshes.',
                    style: Ember.dimStyle,
                  ),
                ),
              if (proto == Protocol.wireguard) ...[
                _text(
                  'secretKey',
                  l.fieldSecretKey,
                  multiline: true,
                  mono: true,
                ),
                _text('address', l.fieldAddress),
                _text('port', l.fieldPort, numeric: true),
                _text(
                  'peerPublicKey',
                  l.fieldPeerPublicKey,
                  multiline: true,
                  mono: true,
                ),
                _text(
                  'preSharedKey',
                  l.fieldPreSharedKey,
                  multiline: true,
                  mono: true,
                ),
                _text(
                  'localAddress',
                  l.fieldLocalAddress,
                  multiline: true,
                  mono: true,
                ),
                _text('reserved', l.fieldReserved),
                _text('mtu', 'MTU', numeric: true),
                _text('keepAlive', l.fieldKeepAlive, numeric: true),
                // The .conf's split-tunnel list and DNS (build
                // 2057, audit §6 WG .conf divergences): the
                // AllowedIPs list is applied to the outbound;
                // the DNS is shown but NOT applied — the tunnel's
                // DNS always comes from Settings, so the note
                // says so instead of pretending otherwise.
                if (_p.wgAllowedIPs.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 11),
                    child: Text(
                      'AllowedIPs from the .conf (applied): '
                      '${_p.wgAllowedIPs}',
                      style: Ember.dimStyle,
                    ),
                  ),
                if (_p.wgDns.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 11),
                    child: Text(
                      'DNS from the .conf: ${_p.wgDns} — not used; '
                      'the tunnel uses the DNS in Settings.',
                      style: Ember.dimStyle,
                    ),
                  ),
              ] else ...[
                _text('address', l.fieldAddress),
                _text('port', l.fieldPort, numeric: true),
              ],
              if (proto == Protocol.vless ||
                  proto == Protocol.vmess ||
                  proto == Protocol.tuic)
                _text('cred', 'UUID', multiline: true, mono: true),
              if (proto == Protocol.trojan ||
                  proto == Protocol.hysteria2 ||
                  proto == Protocol.anytls)
                _text('cred', l.fieldPassword, multiline: true, mono: true),
              if (proto == Protocol.shadowsocks) ...[
                _dropdown<String>(
                  l.fieldMethod,
                  _p.method.isEmpty ? 'aes-256-gcm' : _p.method,
                  [
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
                  ],
                  (v) {
                    _p.method = v;
                    _fields['method']?.text = v;
                  },
                ),
                _text('cred', l.fieldPassword, multiline: true, mono: true),
                _text('plugin', l.fieldPlugin, multiline: true, mono: true),
                // The plugin is never applied (build 2057, audit
                // F-M11): the bundled core has no plugin support,
                // so an obfs-local plugin is stored and shared but
                // the session runs without it — the note says so
                // where the field is, instead of the connect
                // failing the handshake with no hint.
                if (_p.plugin.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 11),
                    child: Text(
                      'This plugin is not applied — the core has '
                      'no plugin support. The profile connects '
                      'without it.',
                      style: Ember.dimStyle,
                    ),
                  ),
              ],
              // SOCKS credentials (build 2053, audit F-H7): the
              // parser, store, builder and share codec all
              // supported them, but the editor offered no field
              // at all — a hand-added SOCKS config was always
              // no-auth, and an imported credential was invisible
              // and unfixable in-app. Empty username and password
              // still means no authentication, as before.
              if (proto == Protocol.socks || proto == Protocol.http) ...[
                _text('username', 'Username'),
                _text('cred', l.fieldPassword, multiline: true, mono: true),
                Padding(
                  padding: const EdgeInsets.only(bottom: 11),
                  child: Text(
                    'Empty username and password = no '
                    'authentication.',
                    style: Ember.caption,
                  ),
                ),
              ],
              // VMess aid/scy (build 2057, audit §6 codec drops):
              // the alterId and cipher the link carried — a
              // non-zero alterId server failed silently before,
              // because the builder hardcoded 0/'auto'.
              if (proto == Protocol.vmess) ...[
                _text('aid', 'Alter ID (0 = none)', numeric: true),
                _text('scy', 'Cipher (auto = default)'),
              ],
              if (proto == Protocol.vless) _text('flow', 'Flow'),
              if (proto == Protocol.vless)
                _text(
                  'vlessEncryption',
                  'VLESS encryption (mlkem768…; empty = none)',
                  hint: 'mlkem768x25519plus.native.0rtt.… — from the link; empty = none',
                  multiline: true,
                  mono: true,
                ),
            ]),
            if (streamProtocols) ...[
              _section(l.sectionTransport, [
                _chipPicker<String>(
                  l.fieldNetwork,
                  const [
                    ('tcp', 'TCP'),
                    ('ws', 'WebSocket'),
                    ('grpc', 'gRPC'),
                    ('httpupgrade', 'HTTPUpgrade'),
                    ('xhttp', 'XHTTP'),
                    ('http', 'HTTP/2'),
                    ('kcp', 'mKCP'),
                    ('quic', 'QUIC'),
                  ],
                  _p.network,
                  (v) => setState(() => _p.network = v),
                ),
                if (_p.network == 'ws' ||
                    _p.network == 'httpupgrade' ||
                    _p.network == 'xhttp' ||
                    _p.network == 'http') ...[
                  _text('host', 'Host'),
                  _text('path', l.fieldPath),
                ],
                if (_p.network == 'grpc') ...[
                  _text('serviceName', 'ServiceName'),
                  _dropdown<String>(
                    l.fieldMode,
                    _p.mode.isEmpty ? 'gun' : _p.mode,
                    const [('gun', 'gun'), ('multi', 'multi')],
                    (v) => setState(() => _p.mode = v),
                  ),
                  // gRPC authority (build 2057, audit §6 codec
                  // drop): the `:authority` the core sends on
                  // the handshake; empty = the server name.
                  _text('grpcAuthority', 'Authority (empty = server name)'),
                ],
                if (_p.network == 'kcp' || _p.network == 'quic')
                  _text('headerType', l.fieldHeaderType),
                if (_p.network == 'kcp') _text('path', l.fieldSeed),
              ]),
              _section(l.sectionSecurity, [
                _chipPicker<String>(
                  l.fieldSecurity,
                  const [('', 'None'), ('tls', 'TLS'), ('reality', 'REALITY')],
                  _p.security,
                  (v) => setState(() => _p.security = v),
                ),
                if ((proto == Protocol.vless || proto == Protocol.trojan) &&
                    _p.security.isEmpty &&
                    // Build 2046: a VLESS profile carrying a
                    // VLESS Encryption value is encrypted at the
                    // VLESS layer — the warning is about having
                    // no encryption at all, and it does not apply.
                    // The field text is read live: the bound
                    // profile value is stale until save.
                    !(proto == Protocol.vless &&
                        _v('vlessEncryption').isNotEmpty)) ...[
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
                  _text(
                    'fingerprint',
                    'Fingerprint (uTLS)',
                    multiline: true,
                    mono: true,
                  ),
                ],
                if (_p.security == 'tls') ...[
                  _text(
                    'cipherSuites',
                    'Cipher suites (IANA names, colon-separated)',
                    multiline: true,
                    mono: true,
                  ),
                  _text(
                    'echConfigList',
                    'ECH config list (from the link’s ech parameter)',
                    multiline: true,
                    mono: true,
                  ),
                  // The certificate pin (build 2047): the
                  // SHA-256 hash(es) of the server certificate
                  // the core must see. Only for TLS — REALITY
                  // verifies with its own public key instead.
                  // Skipping the certificate check is not
                  // possible: the core removed it (build 2048),
                  // so a pin is the way to trust a specific
                  // certificate.
                  _text(
                    'tlsCertPin',
                    'Certificate pin (SHA-256; empty = off)',
                    hint: '64 hex characters per pin, comma-separated for several — the server cert must match one',
                    multiline: true,
                    mono: true,
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
                                crossAxisAlignment: CrossAxisAlignment.start,
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
                  _text(
                    'publicKey',
                    l.fieldPublicKey,
                    multiline: true,
                    mono: true,
                  ),
                  _text('shortId', l.fieldShortId, mono: true),
                  _text('spiderX', 'SpiderX'),
                  // REALITY PQ verification (build 2057, audit
                  // F-M13): the ML-DSA-65 key the core verifies
                  // the handshake against; empty = the server
                  // does not require it.
                  _text(
                    'pqv',
                    'PQ verify key (pqv; empty = off)',
                    multiline: true,
                    mono: true,
                  ),
                ],
                if (_p.security == 'tls')
                  // No "skip certificate check" toggle (build
                  // 2048): the core removed it outright and
                  // refuses the whole config when it is set. To
                  // trust a specific certificate, set its
                  // SHA-256 pin above.
                  Text(
                    'Certificate check cannot be skipped — the '
                    'core removed that option. To trust a specific '
                    'certificate, set its SHA-256 pin above.',
                    style: Ember.caption,
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
                  _dropdown<String>('TLS fragmentation', _p.afFragment, [
                    ('', 'Off'),
                    for (final shape in afFragmentShapes)
                      (shape.id, shape.label),
                  ], (v) => setState(() => _p.afFragment = v)),
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
                _text(
                  'dialMode',
                  'Dial mode (exact text)',
                  multiline: true,
                  mono: true,
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 11),
                  child: Wrap(
                    spacing: 8,
                    children: [
                      for (final preset in const ['oob.0', 'oob.0,_,12'])
                        EmberChip(
                          label: preset,
                          onTap: () => setState(
                            () => _fields['dialMode']?.text = preset,
                          ),
                        ),
                      EmberChip(
                        label: 'Off',
                        onTap: () =>
                            setState(() => _fields['dialMode']?.text = ''),
                      ),
                    ],
                  ),
                ),
                _text(
                  'finalMask',
                  'Finalmask (JSON)',
                  multiline: true,
                  mono: true,
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 11),
                  child: Wrap(
                    spacing: 8,
                    children: [
                      EmberChip(
                        label: 'Merge preset',
                        onTap: () => setState(
                          () => _fields['finalMask']?.text =
                              '{"tcp":[{"type":"merge","settings":'
                              '{"times":3,"delayMs":8,"maxBytes":2048}}]}',
                        ),
                      ),
                      EmberChip(
                        label: 'Clear',
                        onTap: () =>
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
                _dropdown<String>('Congestion control', _p.hyCongestion, const [
                  ('', 'Default (BBR standard)'),
                  ('bbr-standard', 'BBR — Standard'),
                  ('bbr-conservative', 'BBR — Conservative'),
                  ('bbr-aggressive', 'BBR — Aggressive'),
                  ('reno', 'Reno'),
                ], (v) => setState(() => _p.hyCongestion = v)),
                Text(
                  'How the QUIC handshake shares the link. '
                  'Conservative is steadier on lossy mobile data; '
                  'aggressive pushes harder on clean links; Reno '
                  'is the plain transport default.',
                  style: Ember.caption,
                ),
                if (_p.obfs.isNotEmpty)
                  _text('obfsPassword', l.fieldObfsPassword),
                _text('upMbps', l.fieldUpMbps, numeric: true),
                _text('downMbps', l.fieldDownMbps, numeric: true),
                // The certificate pin (build 2053, audit F-H5):
                // bound to tlsCertPin now — the old row wrote the
                // value into `fingerprint` under the label
                // "pinSHA256", a key the core has never had, so
                // the pin was silently dropped at connect. The
                // save validation refuses a malformed pin, and an
                // empty field means no pinning, as before.
                _text(
                  'tlsCertPin',
                  'pinSHA256',
                  hint: '64 hex characters per pin, comma-separated for several — the server cert must match one',
                  multiline: true,
                  mono: true,
                ),
                // ECH for the QUIC handshake (build 2033): the
                // core's TLS stack consumes this list for the
                // hysteria dialer — the SNI stops travelling in
                // the clear. Empty = off.
                _text(
                  'echConfigList',
                  'ECH config list (hides the SNI; empty = off)',
                  multiline: true,
                  mono: true,
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
              ]),
            if (proto == Protocol.anytls)
              _section('AnyTLS', [
                _text('sni', 'SNI'),
                _text('alpn', 'ALPN'),
                _text('fingerprint', 'Fingerprint'),
              ]),
            if (proto == Protocol.wireguard)
              // The AmneziaWG handshake-noise parameters (build
              // 2033: imported, shown, preserved; build 2050: the
              // engine really applies them; build 2065, item 8:
              // EDITABLE here for every WireGuard profile, not
              // only ones an import filled). The claim below holds
              // on EVERY connect path since build 2057 (audit
              // F-M10): connect() routes WireGuard selections
              // through the fallback path, so the home toggle
              // tries the AWG engine first too.
              _section('AmneziaWG', [
                _text('awgJc', 'Jc — junk packets before the handshake'),
                _text('awgJmin', 'Jmin — smallest junk packet (bytes)'),
                _text('awgJmax', 'Jmax — largest junk packet (bytes)'),
                _text('awgS1', 'S1 — handshake init padding (bytes)'),
                _text('awgS2', 'S2 — handshake response padding (bytes)'),
                _text('awgH1', 'H1 — init packet magic header'),
                _text('awgH2', 'H2 — response packet magic header'),
                _text('awgH3', 'H3 — underload packet magic header'),
                _text('awgH4', 'H4 — transport packet magic header'),
                Text(
                  'These shape the WireGuard handshake so it does '
                  'not match the plain protocol signature. They '
                  'are applied by the AmneziaWG engine on connect '
                  'and written back on export. The server must be '
                  'an AmneziaWG server with matching values — '
                  'against a plain WireGuard server, leave them '
                  'empty; if the obfuscated tunnel cannot reach '
                  'the server, Ember falls back to plain WireGuard.',
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
              ]),
            // Sample C's foot (build 2050): test / share
            // actions and the live status card. Saving lives
            // in the AppBar's ember pill now.
            Row(
              children: [
                Expanded(
                  child: Center(
                    child: MapActionPill(
                      icon: Icons.speed_rounded,
                      label: _testing ? 'Testing…' : 'Test this node',
                      busy: _testing,
                      onTap: _testing ? null : () => unawaited(_testNode()),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Center(
                    child: MapActionPill(
                      icon: Icons.qr_code_rounded,
                      label: 'Share as QR / link',
                      onTap: () {
                        _readBack();
                        unawaited(showProfileQr(context, _p));
                      },
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            ListenableBuilder(
              listenable: widget.xray,
              builder: (context, _) {
                final xray = widget.xray;
                final saved = widget.existing != null;
                final connectedThis =
                    saved &&
                    xray.state.running &&
                    xray.selectedProfileId == _p.id;
                final selectedThis = saved && xray.selectedProfileId == _p.id;
                return GlassCard(
                  child: Row(
                    children: [
                      Container(
                        width: 9,
                        height: 9,
                        decoration: BoxDecoration(
                          color: connectedThis ? Ember.green : Ember.faint,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 9),
                      Expanded(
                        child: Text(
                          !saved
                              ? 'Save the node to connect it'
                              : connectedThis
                              ? 'Connected via this node'
                              : selectedThis
                              ? 'Selected — not connected'
                              : 'Not connected',
                          style: Ember.body,
                        ),
                      ),
                      EmberChip(
                        label: connectedThis ? 'Disconnect' : 'Connect',
                        selected: connectedThis,
                        onTap: saved
                            ? () => unawaited(_connectFromEditor(connectedThis))
                            : null,
                      ),
                    ],
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
