/// The manual add / edit form for a V2Ray config: every protocol the
/// parser knows, every transport and security field, in Ember cards.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../xray/anti_filter.dart';
import '../../xray/config_builder.dart';
import '../../xray/dns_presets.dart';
import '../../xray/link_parser.dart' show newProfileId;
import '../../xray/profile_validation.dart';
import '../../xray/tls_cert_pin.dart';
import '../../xray/vless_encryption.dart';
import '../../xray/xray_controller.dart';
import '../../xray/xray_models.dart';
import '../../xray/xray_platform.dart';
import 'ember_format.dart';
import 'ember_theme.dart';
import 'map_widgets.dart';
import 'qr_pages.dart';
import 'sandbox_test_sheet.dart';

Future<void> openProfileEditor(
  BuildContext context,
  XrayController xray, {
  Profile? existing,
  Profile? draft,
}) => Navigator.of(context).push(
  MaterialPageRoute(
    builder: (_) =>
        ProfileEditorPage(xray: xray, existing: existing, draft: draft),
  ),
);

class ProfileEditorPage extends StatefulWidget {
  const ProfileEditorPage({
    super.key,
    required this.xray,
    this.existing,
    this.draft,
  });
  final XrayController xray;
  final Profile? existing;

  /// Build 2095 (V2Ray journey audit #9): a pre-filled NEW
  /// profile (e.g. the CF scanner's clean IP) — the editor
  /// opens on it but still saves through addProfile.
  final Profile? draft;

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

  /// Build 2092 (item 42): the editor connect chip's
  /// re-entry guard.
  bool _connecting = false;

  /// Build 2147 (feature #11): a pin-capture read is in
  /// flight.
  bool _pinning = false;

  /// Build 2149 (per-config diagnostics): the node speed
  /// test / DNS check are in flight, and the DNS check's
  /// verdict line once it has run.
  bool _speedTesting = false;
  bool _dnsChecking = false;
  bool _dnsPinging = false;
  String _dnsVerdict = '';

  /// The STORED profile this editor edits (the working
  /// copy [_p] is a clone): diagnostics read and test the
  /// stored one, so results land where the list shows
  /// them.
  Profile? get _savedProfile {
    final existing = widget.existing;
    if (existing == null) return null;
    for (final p in widget.xray.profiles) {
      if (p.id == existing.id) return p;
    }
    return existing;
  }

  Future<void> _runSpeedTest() async {
    final saved = _savedProfile;
    if (saved == null || _speedTesting) return;
    setState(() => _speedTesting = true);
    try {
      await widget.xray.testSpeed(saved);
    } finally {
      if (mounted) setState(() => _speedTesting = false);
    }
  }

  /// The per-server DNS ping (build 2149 refinement): each
  /// server in the generated config is asked one real query
  /// through this config and timed on its own row — the
  /// controller stamps the results on the stored profile.
  Future<void> _runDnsPings() async {
    final saved = _savedProfile;
    if (saved == null || _dnsPinging) return;
    setState(() => _dnsPinging = true);
    try {
      await widget.xray.testDnsPings(saved);
    } finally {
      if (mounted) setState(() => _dnsPinging = false);
    }
  }

  /// The DNS check: the sandbox's staged request crosses
  /// a throwaway core of this config BY DOMAIN NAME,
  /// resolved by the core itself (the guided diagnosis's
  /// stage-3 proof) — so an ok verdict means this
  /// config's own DNS answers inside its tunnel.
  Future<void> _runDnsCheck() async {
    final saved = _savedProfile;
    if (saved == null || _dnsChecking) return;
    setState(() => _dnsChecking = true);
    try {
      final r = await widget.xray.sandboxTest(saved);
      if (!mounted) return;
      setState(
        () => _dnsVerdict = r.ok
            ? 'A request by name crossed this config — '
                  'its DNS resolves inside the tunnel.'
            : 'The check did not complete: ${r.error}',
      );
    } finally {
      if (mounted) setState(() => _dnsChecking = false);
    }
  }

  /// Reads the certificate the profile's endpoint presents
  /// right now and fills the pin field with its SHA-256.
  /// The address/port/SNI are read from the fields as they
  /// stand (unsaved edits included).
  Future<void> _pinCurrent() async {
    setState(() => _pinning = true);
    try {
      final pin = await fetchCurrentTlsCertPin(
        _v('address'),
        _int('port', 443),
        serverName: _v('sni'),
      );
      if (!mounted) return;
      if (pin == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'The server did not present a certificate — '
              'check the address and port.',
            ),
          ),
        );
      } else {
        setState(() => _fields['tlsCertPin']?.text = pin);
      }
    } finally {
      if (mounted) setState(() => _pinning = false);
    }
  }

  /// Build 2127 (H2): the Sudoku section's dropdown state,
  /// seeded from the profile's stored options in initState
  /// and composed back into Profile.sudokuOptions at
  /// read-back. '' = the core's default for each.
  String _sudokuAead = '';
  String _sudokuTable = '';
  String _sudokuPure = '';
  // Build 2147 (feature #8): the XICMP dropdown states.
  String _xicmpMode = 'off';
  String _xicmpDgramMode = 'off';
  String _sudokuMask = '';
  String _sudokuMaskMode = '';

  @override
  void initState() {
    super.initState();
    _p =
        widget.existing?.copy() ??
        widget.draft?.copy() ??
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
    // Build 2103 (verification iteration 1, H2): the field is
    // seeded from the STORED editable name (label, else the
    // stored name) — never from displayName. Since 2103
    // displayName falls back to the server address at render
    // time for a nameless profile; seeding that fallback
    // would write the address back as a stored name/label
    // on an untouched save, re-manufacturing exactly the
    // address-as-name the heal removes (and into localName,
    // which the heal never touches). A nameless profile
    // opens with the field empty.
    _field('name', _p.localName.isNotEmpty ? _p.localName : _p.name);
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
    // Build 2095 (whole-app journey audit #31/#32): the
    // .conf's AllowedIPs and DNS are editable fields now,
    // not read-only captions.
    _field('wgAllowedIPs', _p.wgAllowedIPs);
    _field('wgDns', _p.wgDns);
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
    // Build 2075: the sidecar protocols' own fields — the
    // Tailscale auth key and the Snell version (sing-box
    // accepts 4; 5 is refused by the core, so the editor
    // says so at the field).
    _field('tsAuthKey', _p.tailscaleAuthKey);
    // Build 2147: the SSH fields (#6), the XDNS resolver
    // (#7) and the WireGuard fallback endpoints (#10).
    _field('sshUser', _p.sshUser);
    _field('sshPassword', _p.sshPassword);
    _field('sshPrivateKey', _p.sshPrivateKey);
    _field('sshPrivateKeyPassphrase', _p.sshPrivateKeyPassphrase);
    _field('sshHostKeyPin', _p.sshHostKeyPin);
    _field('xdnsDomain', _p.xdnsDomain);
    _field('xdnsResolver', _p.xdnsResolver);
    _field('wgFallbackEndpoints', _p.wgFallbackEndpoints);
    _xicmpMode = _p.xicmpEnabled ? 'on' : 'off';
    _xicmpDgramMode = _p.xicmpDgram ? 'on' : 'off';
    _field('snellVersion', '${_p.snellVersion}');
    _field('mieruTransport', _p.network == 'udp' ? 'udp' : 'tcp');
    // Build 2127 (H2): the Sudoku options, decoded from
    // the profile's stored JSON ({} = core defaults).
    final sudokuOpts = _p.sudokuOpts;
    _field('sudokuPadMin', '${sudokuOpts['paddingMin'] ?? ''}');
    _field('sudokuPadMax', '${sudokuOpts['paddingMax'] ?? ''}');
    _field('sudokuCustomTable', '${sudokuOpts['customTable'] ?? ''}');
    _field('sudokuMaskHost', '${sudokuOpts['httpMaskHost'] ?? ''}');
    _field('sudokuMaskPath', '${sudokuOpts['httpMaskPathRoot'] ?? ''}');
    _sudokuAead = '${sudokuOpts['aeadMethod'] ?? ''}';
    _sudokuTable = '${sudokuOpts['tableType'] ?? ''}';
    _sudokuPure = sudokuOpts['pureDownlink'] == true
        ? 'on'
        : sudokuOpts['pureDownlink'] == false
        ? 'off'
        : '';
    _sudokuMask = sudokuOpts['httpMask'] == true ? 'on' : '';
    _sudokuMaskMode = '${sudokuOpts['httpMaskMode'] ?? ''}';
    // Build 2065 (item 8): the AmneziaWG junk fields are EDITABLE
    // now, for any WireGuard profile — the run path has applied
    // them since 2050; until now the editor only displayed them.
    _field('awgJc', _p.awgJc);
    _field('awgJmin', _p.awgJmin);
    _field('awgJmax', _p.awgJmax);
    _field('awgS1', _p.awgS1);
    _field('awgS2', _p.awgS2);
    _field('awgS3', _p.awgS3);
    _field('awgS4', _p.awgS4);
    _field('awgH1', _p.awgH1);
    _field('awgH2', _p.awgH2);
    _field('awgH3', _p.awgH3);
    _field('awgH4', _p.awgH4);
    // Build 2098 (Item A): the AWG 2.0 signature fields are
    // editable too — before this build the values were not
    // even stored, so there was nothing to edit.
    _field('awgI1', _p.awgI1);
    _field('awgI2', _p.awgI2);
    _field('awgI3', _p.awgI3);
    _field('awgI4', _p.awgI4);
    _field('awgI5', _p.awgI5);
    _field('awgJ1', _p.awgJ1);
    _field('awgJ2', _p.awgJ2);
    _field('awgJ3', _p.awgJ3);
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
      ..sshUser = _v('sshUser')
      ..sshPassword = _v('sshPassword')
      ..sshPrivateKey = _v('sshPrivateKey')
      ..sshPrivateKeyPassphrase = _v('sshPrivateKeyPassphrase')
      ..sshHostKeyPin = _v('sshHostKeyPin')
      ..xdnsDomain = _v('xdnsDomain')
      ..xdnsResolver = _v('xdnsResolver')
      ..wgFallbackEndpoints = _v('wgFallbackEndpoints')
      ..xicmpEnabled = _xicmpMode == 'on'
      ..xicmpDgram = _xicmpDgramMode == 'on'
      ..wgAllowedIPs = _v('wgAllowedIPs')
      ..wgDns = _v('wgDns')
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
      ..tailscaleAuthKey = _v('tsAuthKey')
      ..snellVersion = _int('snellVersion', 4)
      ..awgJc = _v('awgJc')
      ..awgJmin = _v('awgJmin')
      ..awgJmax = _v('awgJmax')
      ..awgS1 = _v('awgS1')
      ..awgS2 = _v('awgS2')
      ..awgS3 = _v('awgS3')
      ..awgS4 = _v('awgS4')
      ..awgH1 = _v('awgH1')
      ..awgH2 = _v('awgH2')
      ..awgH3 = _v('awgH3')
      ..awgH4 = _v('awgH4')
      ..awgI1 = _v('awgI1')
      ..awgI2 = _v('awgI2')
      ..awgI3 = _v('awgI3')
      ..awgI4 = _v('awgI4')
      ..awgI5 = _v('awgI5')
      ..awgJ1 = _v('awgJ1')
      ..awgJ2 = _v('awgJ2')
      ..awgJ3 = _v('awgJ3');
    // Build 2075: a Mieru profile's transport rides the
    // network field, but the generic transport section does
    // not render for Mieru — its own section's picker does.
    if (_p.protocol == Protocol.mieru) {
      _p.network = _v('mieruTransport') == 'udp' ? 'udp' : 'tcp';
    }
    // Build 2127 (H2): compose the Sudoku options JSON
    // from the section's fields — only non-default
    // entries are stored, so an untouched section keeps
    // sudokuOptions '' (the core's defaults throughout).
    if (_p.protocol == Protocol.sudoku) {
      final opts = <String, dynamic>{};
      if (_sudokuAead.isNotEmpty) opts['aeadMethod'] = _sudokuAead;
      final padMin = int.tryParse(_v('sudokuPadMin'));
      if (padMin != null) opts['paddingMin'] = padMin;
      final padMax = int.tryParse(_v('sudokuPadMax'));
      if (padMax != null) opts['paddingMax'] = padMax;
      if (_sudokuTable.isNotEmpty) opts['tableType'] = _sudokuTable;
      if (_sudokuPure == 'on') opts['pureDownlink'] = true;
      if (_sudokuPure == 'off') opts['pureDownlink'] = false;
      if (_v('sudokuCustomTable').isNotEmpty) {
        opts['customTable'] = _v('sudokuCustomTable');
      }
      if (_sudokuMask == 'on') {
        opts['httpMask'] = true;
        if (_sudokuMaskMode.isNotEmpty) {
          opts['httpMaskMode'] = _sudokuMaskMode;
        }
        if (_v('sudokuMaskHost').isNotEmpty) {
          opts['httpMaskHost'] = _v('sudokuMaskHost');
        }
        if (_v('sudokuMaskPath').isNotEmpty) {
          opts['httpMaskPathRoot'] = _v('sudokuMaskPath');
        }
      }
      _p.sudokuOptions = opts.isEmpty ? '' : jsonEncode(opts);
    }
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

  /// Build 2092 (UI audit 2026-11-16 item 3): the first
  /// invalid numeric field's message, or null. _int()'s
  /// parse fallback substitutes 443/1420/0 for unparseable
  /// text BEFORE the range gates run, so "abc" — or an
  /// empty port — used to save as 443 with no message: the
  /// saved profile differed from what was typed (the 2074
  /// range gate never saw the bad text). Every numeric
  /// field now validates as typed; an empty OPTIONAL field
  /// still takes its documented fallback.
  String? _numericFieldError() {
    String? check(
      String key,
      String label, {
      int? min,
      int? max,
      bool required = false,
    }) {
      final text = _v(key);
      if (text.isEmpty) {
        return required ? '$label is required.' : null;
      }
      final value = int.tryParse(text);
      if (value == null) return '$label must be a whole number.';
      if (min != null && value < min) {
        return '$label must be between $min and $max.';
      }
      if (max != null && value > max) {
        return '$label must be between $min and $max.';
      }
      return null;
    }

    return check('port', 'Port', min: 1, max: 65535, required: true) ??
        // Build 2125 (audit A25-38 / P-42): the MTU range
        // is the app's TUN range (1280–1500) — the editor
        // used to accept 576–9000, which the connect paths
        // now clamp anyway; the editor says the real range
        // up front instead.
        check('mtu', 'MTU', min: 1280, max: 1500) ??
        // Build 2096 (post-2095 audit L21): the maxima
        // are the validation module's own caps — the
        // editor used to accept values the boundary then
        // clamped silently at import/connect.
        check('aid', 'Alter ID', min: 0, max: 65535) ??
        check('keepAlive', 'Keep-alive', min: 0) ??
        check('upMbps', 'Upload speed', min: 0, max: 100000) ??
        check('downMbps', 'Download speed', min: 0, max: 100000) ??
        // The Snell section's own caption: the bundled
        // engine refuses version 5 — it used to save
        // unvalidated.
        (_p.protocol == Protocol.snell
            ? check('snellVersion', 'Snell version', min: 1, max: 4)
            : null);
  }

  Future<void> _saveInner() async {
    final l = AppLocalizations.of(context);
    // Build 2092 (item 3): validate the numeric fields as
    // typed, before _readBack's fallbacks can rewrite them.
    final numericError = _numericFieldError();
    if (numericError != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(numericError),
          duration: const Duration(seconds: 6),
        ),
      );
      return;
    }
    _readBack();
    // Build 2075: Tailscale joins WireGuard here — it has
    // no server address at all (the auth key is the config).
    if (_p.address.isEmpty &&
        _p.protocol != Protocol.wireguard &&
        _p.protocol != Protocol.tailscale) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l.addressRequired)));
      return;
    }
    // Build 2095 (whole-app journey audit #48): a WireGuard
    // config without its private key, the peer key or the
    // endpoint can never connect — refuse the save here
    // instead of letting a dead config into the list.
    if (_p.protocol == Protocol.wireguard &&
        (_p.secretKey.isEmpty ||
            _p.peerPublicKey.isEmpty ||
            _p.address.isEmpty)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'A WireGuard config needs its private key, the peer '
            'public key and the peer endpoint.',
          ),
          duration: Duration(seconds: 6),
        ),
      );
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
      // Build 2103 (diagnosis N2): a provider name that
      // never arrived stays empty — builds ≤2102 put the
      // address in its place here, cementing the
      // manufactured address-as-name into the store even
      // after a manual edit-save. The user's typed name
      // still lands in localName below, where it belongs.
      final serverName = widget.existing!.name;
      final typed = _v('name');
      _p.name = serverName;
      // Build 2097 (post-2096 audit C-L15): the label goes
      // through the same name sanitizer as every other
      // write path — a pasted label carrying a newline
      // used to be stored raw.
      final cleanTyped = sanitizeProfileName(typed);
      _p.localName =
          cleanTyped.isEmpty || cleanTyped == serverName ? '' : cleanTyped;
    }
    // Build 2103 (diagnosis N2): a hand-added profile
    // whose name field was left empty keeps an empty
    // stored name — builds ≤2102 stored the address
    // here, manufacturing the address-as-name value the
    // import routes no longer make. The row identifies
    // it by its address at render time
    // (Profile.displayName); the stored field stays
    // honest, so a later share/re-import names it
    // positionally instead of re-deriving the address.
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
    // Build 2095 (fourth-pass audit 2.1): the gate runs
    // for EVERY profile whose test config can be built,
    // not only shaped ones — an imported enum or number
    // the core refuses is caught here, at save, instead
    // of surfacing as a failed start. Profiles whose
    // test config cannot be built at all (TUIC) throw
    // inside the try and skip the gate, as before.
    {
      String? rejection;
      try {
        // Build 2095 fix (full-suite catch): the wait is
        // bounded — a validator that never answers (a
        // wedged native side) reads as unavailable, never
        // as a save that hangs forever on the spinner.
        rejection = await XrayPlatform.validateConfig(
          buildTestConfig(_p, widget.xray.settings),
        ).timeout(
          const Duration(seconds: 10),
          onTimeout: () => null,
        );
        // Build 2095 fix (full-suite catch): validateConfig
        // reports a missing validator as an 'unavailable'
        // STRING, not a rejection — with the gate now
        // running on every save, treating unavailable as
        // rejected would refuse every save anywhere the
        // native check cannot run. Only the core's own
        // verdict refuses.
        if (rejection != null &&
            rejection.startsWith('config validation unavailable')) {
          rejection = null;
        }
      } catch (_) {
        rejection = null;
      }
      if (rejection != null) {
        // Build 2092 (UI audit item 19): the SnackBar carries
        // a plain sentence; the core's own words go to the
        // diagnostics journal, where the detail belongs.
        widget.xray.diagnostics.add(
          'editor',
          'Core rejected the shaped config: $rejection',
          ok: false,
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'The core rejected this config — the shaping '
                'details are in the diagnostics log.',
              ),
              duration: Duration(seconds: 6),
            ),
          );
        }
        return;
      }
    }
    // Build 2097 (post-2096 audit C-L15): editor saves run
    // the import-boundary sanitizer too — it is idempotent
    // for editor-shaped profiles by the module's own
    // contract, and it closes the same-session hole where
    // an editor-written field (a newline in an AmneziaWG
    // value, say) reached a .conf export verbatim because
    // the store-load sanitizer only runs at load.
    sanitizeImportedProfile(_p);
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
          style: const TextStyle(color: Ember.faint, fontSize: Ember.fontBody),
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
  /// Build 2092 (item 42): the re-entry guard — repeated
  /// taps used to queue concurrent connect/disconnect cycles.
  Future<void> _connectFromEditor(bool connectedThis) async {
    if (_connecting) return;
    setState(() => _connecting = true);
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
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  Widget _section(String title, List<Widget> children) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: GlassCard(
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

  /// Build 2149 (owner expansion 2 — per-config
  /// diagnostics): the saved profile's last node test
  /// (delay · download · upload, with its timestamp), a
  /// button to run it again, the DNS servers this
  /// config's generated core config actually uses (read
  /// back out of the generated config — display only,
  /// nothing here edits DNS), and the per-config DNS
  /// check. Saved profiles only: a draft has no stored
  /// results and no generated config of its own yet.
  Widget _diagnosticsSection() {
    Widget line(String label, String value) => Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 92,
            child: Text(label, style: Ember.caption),
          ),
          Expanded(child: Text(value, style: Ember.body)),
        ],
      ),
    );
    return ListenableBuilder(
      listenable: widget.xray,
      builder: (context, _) {
        final saved = _savedProfile;
        if (saved == null) return const SizedBox.shrink();
        final tested = saved.speedTestedAtMs > 0
            ? DateTime.fromMillisecondsSinceEpoch(saved.speedTestedAtMs)
            : null;
        String two(int v) => v.toString().padLeft(2, '0');
        // A profile the builder refuses (an incomplete
        // hand-made one) shows no list rather than
        // breaking the page.
        var dnsServers = const <String>[];
        try {
          dnsServers = dnsServersOfConfigJson(
            buildTunnelConfig(saved, widget.xray.settings),
          );
        } catch (_) {
          dnsServers = const <String>[];
        }
        return _section('Diagnostics', [
          line(
            'Delay',
            saved.delayMs >= 0
                ? '${latDigits(saved.delayMs)} ms'
                : saved.delayFailed
                ? 'Failed'
                : 'Not tested',
          ),
          line(
            'Download',
            saved.lastSpeedBps >= 0 ? fmtRate(saved.lastSpeedBps) : '—',
          ),
          line(
            'Upload',
            saved.lastSpeedUpBps >= 0 ? fmtRate(saved.lastSpeedUpBps) : '—',
          ),
          if (tested != null)
            line(
              'Tested',
              '${tested.year}-${two(tested.month)}-${two(tested.day)} '
              '${two(tested.hour)}:${two(tested.minute)}',
            ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: Center(
                  child: MapActionPill(
                    icon: Icons.speed_rounded,
                    label: _speedTesting ? 'Testing…' : 'Run speed test',
                    busy: _speedTesting,
                    onTap: _speedTesting
                        ? null
                        : () => unawaited(_runSpeedTest()),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text('DNS servers', style: Ember.body),
          const SizedBox(height: 4),
          Text(
            'From this config\u2019s generated core config — '
            'what the core will use, in order.',
            style: Ember.caption,
          ),
          const SizedBox(height: 8),
          if (dnsServers.isEmpty)
            Text('None in the generated config.', style: Ember.caption)
          else
            for (final server in dnsServers)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                // Build 2149 (expansion 5, display bonus):
                // an entry a preset claims carries the
                // preset's name beside the address — the
                // catalogue's matcher, display only.
                // Build 2149 (owner refinement): after a
                // Test DNS run the row also carries that
                // server's own through-config latency — the
                // 2148 small-size/colour rules (pingColor for
                // an answer, the failure red for none).
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        server,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: Ember.fontSmall,
                          color: MapUi.text,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (dnsPresetNameFor(server) != null) ...[
                      const SizedBox(width: 8),
                      Text(
                        dnsPresetNameFor(server)!,
                        style: Ember.caption.copyWith(color: Ember.orange),
                      ),
                    ],
                    if (saved.dnsPingMs[server] != null) ...[
                      const SizedBox(width: 8),
                      if (saved.dnsPingMs[server]! >= 0)
                        Text(
                          '${latDigits(saved.dnsPingMs[server]!)} ms',
                          style: TextStyle(
                            fontSize: Ember.fontSmall,
                            fontWeight: FontWeight.w600,
                            color: pingColor(saved.dnsPingMs[server]!),
                          ),
                        )
                      else if (saved.dnsPingMs[server]! == -1)
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
          if (saved.dnsPingAtMs > 0) ...[
            const SizedBox(height: 2),
            Text(
              'Per-server ping through this config · tested '
              '${DateTime.fromMillisecondsSinceEpoch(saved.dnsPingAtMs).year}'
              '-${two(DateTime.fromMillisecondsSinceEpoch(saved.dnsPingAtMs).month)}'
              '-${two(DateTime.fromMillisecondsSinceEpoch(saved.dnsPingAtMs).day)} '
              '${two(DateTime.fromMillisecondsSinceEpoch(saved.dnsPingAtMs).hour)}'
              ':${two(DateTime.fromMillisecondsSinceEpoch(saved.dnsPingAtMs).minute)}',
              style: Ember.caption,
            ),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Center(
                  child: MapActionPill(
                    icon: Icons.network_ping,
                    label: _dnsPinging ? 'Pinging…' : 'Test DNS',
                    busy: _dnsPinging,
                    onTap: _dnsPinging
                        ? null
                        : () => unawaited(_runDnsPings()),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Center(
                  child: MapActionPill(
                    icon: Icons.dns_rounded,
                    label: _dnsChecking ? 'Checking…' : 'Check DNS',
                    busy: _dnsChecking,
                    onTap: _dnsChecking
                        ? null
                        : () => unawaited(_runDnsCheck()),
                  ),
                ),
              ),
            ],
          ),
          if (_dnsVerdict.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(_dnsVerdict, style: Ember.caption),
          ],
          const SizedBox(height: 6),
          Text(
            'The check sends one request by name through a '
            'test core of this config. The full leak test '
            'for the connected config is in Settings.',
            style: Ember.caption,
          ),
        ]);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final proto = _p.protocol;
    final streamProtocols = {
      Protocol.vless,
      Protocol.vmess,
      Protocol.trojan,
    }.contains(proto);
    // Build 2075 (item 30): the editor shows full config
    // credentials — overlay-guarded while it is open.
    return OverlayGuard(
      child: Scaffold(
      // Build 2059 (audit §6 appearance low): the body is the map
      // backdrop — extend it behind the transparent app bar so the
      // editor has no flat solid strip over the map.
      extendBodyBehindAppBar: true,
      backgroundColor: Ember.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Ember.text,
        // Build 2150 (engine appearance audit E49-09): the
        // settle scrim for this bar lives in the BODY as a
        // top overlay (see the body below) — a probe in
        // this build proved the AppBar's own background
        // (flexibleSpace) paints UNDER the extended body
        // in this configuration, so a scrim there never
        // reaches the scrolled content it exists to dim.
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
                  // Build 2092 (item 42): transparent vertical
                  // padding — the pill's hit height is 48 dp;
                  // its visual size (~33 dp) is unchanged.
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 7.5),
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
                              fontSize: Ember.fontBody,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFF1A1206),
                            ),
                          ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      // Build 2150 (audit E49-09): the body is a Stack so
      // the settle scrim can ride OVER the scrolled list
      // in the app-bar zone (the overlay below) — the
      // transparent bar let content slide under the title
      // with no separation, Finalmask chips striking
      // through "Edit config" mid-scroll.
      body: Stack(
        children: [
          EmberBackground(
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
                      Expanded(
                        child: Text(
                          'TUIC connects through the sing-box engine '
                          'built into the app.',
                          style: Ember.dimStyle,
                        ),
                      ),
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
                          'AnyTLS connects through the sing-box engine '
                          'built into the app.',
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
                // Build 2147 (feature #10): fallback endpoints
                // for this peer — tried in order when the
                // primary endpoint does not answer.
                _text(
                  'wgFallbackEndpoints',
                  'Fallback endpoints (host:port, comma-separated)',
                  multiline: true,
                  mono: true,
                ),
                // Build 2095 (whole-app journey audit
                // #31/#32): the .conf's split-tunnel list and
                // DNS are EDITABLE. AllowedIPs is applied to
                // the outbound. The DNS is stored with the
                // config and round-trips through share links
                // and .conf export, but the live tunnel's DNS
                // still comes from Settings — the caption says
                // so instead of pretending otherwise.
                _text(
                  'wgAllowedIPs',
                  'Allowed IPs (applied)',
                  multiline: true,
                  mono: true,
                ),
                _text('wgDns', 'DNS (stored with the config)', mono: true),
                const Padding(
                  padding: EdgeInsets.only(bottom: 11),
                  child: Text(
                    'The DNS above travels with this config; the '
                    'tunnel itself uses the DNS from Settings.',
                    style: TextStyle(fontSize: Ember.fontSmall, color: Ember.dim),
                  ),
                ),
              ] else ...[
                // Build 2075: a Tailscale profile has no
                // server to point at — the auth key in its
                // own section below is the whole config.
                if (proto != Protocol.tailscale) ...[
                  _text('address', l.fieldAddress),
                  _text('port', l.fieldPort, numeric: true),
                ],
              ],
              if (proto == Protocol.vless ||
                  proto == Protocol.vmess ||
                  proto == Protocol.tuic)
                _text('cred', 'UUID', multiline: true, mono: true),
              if (proto == Protocol.trojan ||
                  proto == Protocol.hysteria2 ||
                  proto == Protocol.anytls)
                _text('cred', l.fieldPassword, multiline: true, mono: true),
              // Build 2075: the sidecar protocols' credentials
              // in the basic section — Snell's key, and the
              // username + password pairs of Naive, Mieru and
              // OpenConnect.
              if (proto == Protocol.snell)
                _text('cred', 'PSK', multiline: true, mono: true),
              // Build 2127 (H2): Sudoku's key — a password
              // or a keypair, exactly what the server gave.
              if (proto == Protocol.sudoku)
                _text(
                  'cred',
                  'Key (password or keypair)',
                  multiline: true,
                  mono: true,
                ),
              if (proto == Protocol.naive ||
                  proto == Protocol.mieru ||
                  proto == Protocol.openconnect) ...[
                _text('username', 'Username'),
                _text('cred', l.fieldPassword, multiline: true, mono: true),
              ],
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
                if (_p.network == 'tcp') ...[
                  // Build 2095 (V2Ray journey audit #16): the
                  // TCP header type — the builder honours
                  // headerType 'http' (camouflage) for tcp,
                  // but the editor rendered the field only
                  // for kcp/quic, so a TCP profile's header
                  // type could never be set or even seen.
                  _dropdown<String>(
                    'TCP header type',
                    _p.headerType == 'http' ? 'http' : 'none',
                    const [('none', 'None'), ('http', 'HTTP camouflage')],
                    (v) => setState(() {
                      _p.headerType = v;
                      // _readBack reads the text field; keep
                      // the two in step.
                      _fields['headerType']?.text = v;
                    }),
                  ),
                ],
                if (_p.network == 'xhttp') ...[
                  // Build 2095 (V2Ray journey audit #17): the
                  // XHTTP mode — the builder writes p.mode
                  // into xhttpSettings, but the mode dropdown
                  // rendered only for gRPC, so an XHTTP
                  // profile's mode was stuck at whatever the
                  // link carried.
                  _dropdown<String>(
                    'XHTTP mode',
                    const [
                          'auto',
                          'packet-up',
                          'stream-up',
                          'stream-one',
                        ].contains(_p.mode)
                        ? _p.mode
                        : 'auto',
                    const [
                      ('auto', 'Auto'),
                      ('packet-up', 'Packet up'),
                      ('stream-up', 'Stream up'),
                      ('stream-one', 'Stream one'),
                    ],
                    (v) => setState(() => _p.mode = v),
                  ),
                ],
                if (_p.network == 'quic') ...[
                  // Build 2095 (V2Ray journey audit #18): the
                  // QUIC security/key — the codec carries
                  // them in host/path (the standard link
                  // parameters security/key), but the editor
                  // rendered host/path only for the ws
                  // family, so a QUIC profile's security and
                  // key were invisible and uneditable.
                  _text(
                    'host',
                    'QUIC security (none / aes-128-gcm / chacha20-poly1305)',
                  ),
                  _text('path', 'QUIC key'),
                ],
                if (_p.network == 'kcp' || _p.network == 'quic')
                  _text('headerType', l.fieldHeaderType),
                if (_p.network == 'kcp') _text('path', l.fieldSeed),
                // Build 2095 (V2Ray journey audit #27): the
                // per-profile mux override — mux was a
                // global-only switch buried in Settings, so
                // one profile could not opt in or out.
                if (proto == Protocol.vless ||
                    proto == Protocol.vmess ||
                    proto == Protocol.trojan ||
                    proto == Protocol.shadowsocks)
                  _dropdown<String>(
                    'Mux (this config)',
                    _p.muxOverride,
                    const [
                      ('', 'Use the global setting'),
                      ('on', 'On for this config'),
                      ('off', 'Off for this config'),
                    ],
                    (v) => setState(() => _p.muxOverride = v),
                  ),
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
                  // Build 2147 (feature #11): capture the pin
                  // of the certificate the server presents
                  // right now, so the field can be filled
                  // without a desktop tool.
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: _pinning ? null : () => unawaited(_pinCurrent()),
                      child: Text(
                        _pinning ? 'READING…' : 'PIN CURRENT CERTIFICATE',
                      ),
                    ),
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
                _text('awgJc', 'Jc — junk packets before the handshake', numeric: true),
                _text('awgJmin', 'Jmin — smallest junk packet (bytes)', numeric: true),
                _text('awgJmax', 'Jmax — largest junk packet (bytes)', numeric: true),
                _text('awgS1', 'S1 — handshake init padding (bytes)', numeric: true),
                _text('awgS2', 'S2 — handshake response padding (bytes)', numeric: true),
                _text('awgS3', 'S3 — cookie reply padding (bytes)', numeric: true),
                _text('awgS4', 'S4 — data packet padding (bytes)', numeric: true),
                _text('awgH1', 'H1 — init packet magic header', numeric: true),
                _text('awgH2', 'H2 — response packet magic header', numeric: true),
                _text('awgH3', 'H3 — underload packet magic header', numeric: true),
                _text('awgH4', 'H4 — transport packet magic header', numeric: true),
                _text('awgI1', 'I1 — signature packet before the handshake'),
                _text('awgI2', 'I2 — signature packet (response side)'),
                _text('awgI3', 'I3 — signature packet (underload)'),
                _text('awgI4', 'I4 — signature packet (transport)'),
                _text('awgI5', 'I5 — signature packet (extra)'),
                _text('awgJ1', 'J1 — controlled junk packet'),
                _text('awgJ2', 'J2 — controlled junk packet'),
                _text('awgJ3', 'J3 — controlled junk packet'),
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
                Text(
                  // Build 2106 (verification iteration 1, M2):
                  // the blanket claim above does not hold for
                  // J1–J3 — the WG Tunnel engine has no slot
                  // for them. The editor is where J values are
                  // deliberately entered, so it is where the
                  // exception must be stated.
                  'Exception: J1–J3 are NOT applied — this '
                  'engine does not support them. They are kept '
                  'in the profile and written back on export '
                  '(other clients can use them), but a profile '
                  'whose only AmneziaWG values are J1–J3 '
                  'connects as plain WireGuard.',
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
            // Build 2075: the sidecar protocols' own
            // sections. These profiles are served by the
            // sing-box / Mieru engines, not the Xray core —
            // the fields shown are exactly the ones those
            // engines read.
            if (proto == Protocol.snell)
              _section('Snell (via sing-box)', [
                _text('snellVersion', 'Version', numeric: true),
                _dropdown<String>('Obfs', _p.obfs, const [
                  ('', '—'),
                  ('http', 'http'),
                  ('tls', 'tls'),
                ], (v) => setState(() => _p.obfs = v)),
                if (_p.obfs.isNotEmpty)
                  _text('obfsPassword', 'Obfs host'),
                Text(
                  'Version 4 is what the bundled engine accepts; '
                  'version 5 is refused by it.',
                  style: Ember.caption,
                ),
              ]),
            if (proto == Protocol.naive)
              _section('NaiveProxy (via sing-box)', [
                _text('sni', 'SNI'),
                Text(
                  'Leave SNI empty to use the server address. '
                  'The connection is HTTPS-shaped by design.',
                  style: Ember.caption,
                ),
              ]),
            if (proto == Protocol.mieru)
              _section('Mieru', [
                _dropdown<String>(
                  'Transport',
                  _v('mieruTransport'),
                  const [('tcp', 'TCP'), ('udp', 'UDP')],
                  (v) => setState(() => _fields['mieruTransport']?.text = v),
                ),
                Text(
                  'Served by the bundled Mieru client. The '
                  'username and password are in the basic '
                  'section above.',
                  style: Ember.caption,
                ),
              ]),
            if (proto == Protocol.tailscale)
              _section('Tailscale (via sing-box)', [
                _text('tsAuthKey', 'Auth key', multiline: true, mono: true),
                Text(
                  'No server is needed: the key joins this '
                  'device to your tailnet, and the tunnel exits '
                  'through the exit node you pick in Tailscale. '
                  'The key is stored with the profile.',
                  style: Ember.caption,
                ),
              ]),
            if (proto == Protocol.openconnect)
              _section('OpenConnect (via sing-box)', [
                Text(
                  'The server and port are in the basic section '
                  'above, with the username and password. AnyConnect / '
                  'ocserv servers are the usual targets.',
                  style: Ember.caption,
                ),
              ]),
            // Build 2147 (feature #6): the SSH section —
            // served by the sing-box sidecar while the SSH
            // engine gate is on in Settings.
            if (proto == Protocol.ssh)
              _section('SSH (via sing-box)', [
                _text('sshUser', 'User'),
                _text('sshPassword', 'Password'),
                _text(
                  'sshPrivateKey',
                  'Private key (PEM)',
                  multiline: true,
                  mono: true,
                ),
                _text('sshPrivateKeyPassphrase', 'Key passphrase'),
                _text(
                  'sshHostKeyPin',
                  'Host key pin (SHA256:…)',
                  mono: true,
                ),
                Text(
                  'SSH tunnels TCP only — UDP traffic is not '
                  'carried. A password or a private key is '
                  'required; the host key pin is optional but '
                  'recommended.',
                  style: Ember.caption,
                ),
              ]),
            // Build 2147 (features #7/#8): the typed
            // FinalMask transports on mKCP — the tunnel's
            // UDP rides DNS queries (XDNS) or ICMP echoes
            // (XICMP) instead of plain UDP.
            if (streamProtocols && _p.network == 'kcp')
              _section('FinalMask transports (mKCP)', [
                _text('xdnsDomain', 'XDNS tunnel domain'),
                _text(
                  'xdnsResolver',
                  'XDNS resolver (host or host:port)',
                ),
                _dropdown<String>('XICMP', _xicmpMode, const [
                  ('off', 'Off'),
                  ('on', 'On'),
                ], (v) => setState(() => _xicmpMode = v)),
                if (_xicmpMode == 'on')
                  _dropdown<String>(
                    'XICMP datagram mode',
                    _xicmpDgramMode,
                    const [('off', 'Off'), ('on', 'On')],
                    (v) => setState(() => _xicmpDgramMode = v),
                  ),
                Text(
                  'XDNS needs a domain whose NS records point '
                  'at an XDNS-capable server. XICMP is '
                  'experimental: many kernels and carriers '
                  'drop echo payloads, so a profile can pass '
                  'every check and still carry nothing — if '
                  'it connects but nothing loads, turn it off.',
                  style: Ember.caption,
                ),
              ]),
            if (proto == Protocol.sudoku)
              _section('Sudoku (Hiddify engine)', [
                _dropdown<String>('AEAD method', _sudokuAead, const [
                  ('', 'Default (chacha20-poly1305)'),
                  ('chacha20-poly1305', 'chacha20-poly1305'),
                  ('aes-128-gcm', 'aes-128-gcm'),
                  ('none', 'none'),
                ], (v) => setState(() => _sudokuAead = v)),
                _text('sudokuPadMin', 'Padding min (empty = 10)', numeric: true),
                _text('sudokuPadMax', 'Padding max (empty = 30)', numeric: true),
                _dropdown<String>('Table type', _sudokuTable, const [
                  ('', 'Default (prefer_entropy)'),
                  ('prefer_entropy', 'prefer_entropy'),
                  ('prefer_ascii', 'prefer_ascii'),
                  ('up_ascii_down_entropy', 'up_ascii_down_entropy'),
                  ('up_entropy_down_ascii', 'up_entropy_down_ascii'),
                ], (v) => setState(() => _sudokuTable = v)),
                _dropdown<String>('Pure downlink', _sudokuPure, const [
                  ('', 'Default (on)'),
                  ('on', 'On'),
                  ('off', 'Off'),
                ], (v) => setState(() => _sudokuPure = v)),
                _text('sudokuCustomTable', 'Custom table (advanced)'),
                _dropdown<String>('HTTP mask', _sudokuMask, const [
                  ('', 'Off'),
                  ('on', 'On'),
                ], (v) => setState(() => _sudokuMask = v)),
                if (_sudokuMask == 'on') ...[
                  _dropdown<String>('Mask mode', _sudokuMaskMode, const [
                    ('', 'Default (legacy)'),
                    ('legacy', 'legacy'),
                    ('stream', 'stream'),
                    ('poll', 'poll'),
                    ('ws', 'ws'),
                    ('auto', 'auto'),
                  ], (v) => setState(() => _sudokuMaskMode = v)),
                  _text('sudokuMaskHost', 'Mask host'),
                  _text('sudokuMaskPath', 'Mask path root'),
                ],
                Text(
                  'Served by the bundled Sudoku engine '
                  '(Hiddify\'s sing-box fork) when the Sudoku '
                  'switch in Settings is on. The key is in '
                  'the basic section above.',
                  style: Ember.caption,
                ),
              ]),
            // Build 2149: per-config diagnostics (saved
            // profiles only) — node-test results, the
            // generated config's DNS servers, the DNS
            // check.
            if (widget.existing != null) _diagnosticsSection(),
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
                        // Build 2092 (item 42): inert while a
                        // connect cycle is in flight.
                        onTap: saved && !_connecting
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
          // Build 2150 (audit E49-09): the settle scrim —
          // the base colour at near-full strength over the
          // app-bar zone, easing to clear just below it.
          // Content scrolling beneath the title settles
          // behind this instead of striking through; the
          // AppBar's own foreground (title, Save) paints
          // above it. IgnorePointer: it never eats a tap.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height:
                MediaQuery.of(context).padding.top + kToolbarHeight + 18,
            child: const IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: [0, 0.7, 1],
                    colors: [
                      Color(0xE6050607),
                      Color(0xC2050607),
                      Color(0x00050607),
                    ],
                  ),
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
