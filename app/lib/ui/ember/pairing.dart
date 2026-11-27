/// Build 2095 (feature 15 — device pairing transfer): the
/// config/subscription set travels as a sequence of QR
/// codes carrying ONE sealed payload — the backup JSON
/// encrypted with a user-set password through the
/// protected-share crypto (AES-256-GCM, PBKDF2 120k).
/// Never a plaintext QR of raw keys.
///
/// Chunk format: `EMBERPAIR/<index 1-based>/<total>/<part>`.
/// Build 2097 (post-2096 audit L-i): exports now carry a
/// transfer tag — `EMBERPAIR/t<tag>/<index>/<total>/<part>`
/// — a short FNV-1a fingerprint of the whole sealed
/// payload. Build 2096's chunks carried no transfer
/// identity, so codes from TWO transfers with the same
/// total mixed silently in one collection and the restore
/// then failed blaming the password. The tag segment
/// starts with 't' (never a digit), so a tagged chunk is
/// unambiguous against the legacy shape, which the
/// collector still accepts (keyed by total alone, as
/// before).


import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../aether/aether_controller.dart';
import '../../app_settings.dart';
import '../../openvpn/openvpn_controller.dart';
import '../../psiphon/psiphon_controller.dart';
import '../../xray/shared_link.dart';
import '../../xray/xray_controller.dart';
import '../../xray/xray_platform.dart';
import 'ember_sync.dart';
import 'ember_theme.dart';
import 'map_widgets.dart';
import 'qr_pages.dart';

/// Characters of sealed payload per QR code — small
/// enough for a phone camera to read across a room.
const pairingChunkSize = 700;

/// The transfer tag for a sealed payload (build 2097,
/// audit L-i): FNV-1a 32-bit over the payload, hex. A
/// guard against cross-transfer mixing, not a security
/// control — the sealed payload's own GCM integrity
/// remains the backstop.
String pairingTransferTag(String sealed) {
  var hash = 0x811c9dc5;
  for (final unit in sealed.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return 't${hash.toRadixString(16).padLeft(8, '0')}';
}

List<String> splitPairingPayload(String sealed) {
  final total = (sealed.length / pairingChunkSize).ceil();
  final tag = pairingTransferTag(sealed);
  return [
    for (var i = 0; i < total; i++)
      'EMBERPAIR/$tag/${i + 1}/$total/${sealed.substring(
        i * pairingChunkSize,
        (i + 1) * pairingChunkSize > sealed.length
            ? sealed.length
            : (i + 1) * pairingChunkSize,
      )}',
  ];
}

bool isPairingCode(String code) => code.startsWith('EMBERPAIR/');

/// Parses one pairing chunk (build 2097, audit L-i):
/// the tagged shape `EMBERPAIR/t<tag>/<i>/<n>/<part>` and
/// the legacy `EMBERPAIR/<i>/<n>/<part>` (tag ''). The
/// part itself may contain '/' (the sealed payload's
/// alphabet does), so the split is positional, exactly
/// as the legacy parser did it.
({String tag, int index, int total, String part})? parsePairingChunk(
  String code,
) {
  if (!isPairingCode(code)) return null;
  var rest = code.substring('EMBERPAIR/'.length);
  var tag = '';
  final firstSlash = rest.indexOf('/');
  if (firstSlash < 0) return null;
  final head = rest.substring(0, firstSlash);
  if (head.startsWith('t') && int.tryParse(head) == null) {
    tag = head;
    rest = rest.substring(firstSlash + 1);
  }
  final s1 = rest.indexOf('/');
  if (s1 < 0) return null;
  final s2 = rest.indexOf('/', s1 + 1);
  if (s2 < 0) return null;
  final index = int.tryParse(rest.substring(0, s1));
  final total = int.tryParse(rest.substring(s1 + 1, s2));
  if (index == null || total == null) return null;
  return (tag: tag, index: index, total: total, part: rest.substring(s2 + 1));
}

/// Collects pairing chunks in any order until the set is
/// complete.
class PairingCollector {
  int? _total;
  String? _tag;
  final Map<int, String> _parts = {};

  int get received => _parts.length;
  int? get total => _total;
  bool get isComplete =>
      _total != null && _parts.length == _total && _total! > 0;

  /// Build 2096 (post-2095 audit L14): drop everything
  /// collected so far — the recovery when a foreign
  /// transfer's codes were scanned into this one.
  void reset() {
    _total = null;
    _tag = null;
    _parts.clear();
  }

  /// True when [code] is a pairing chunk that belongs to
  /// a DIFFERENT transfer than the set being collected —
  /// a different set total, or (build 2097, audit L-i) a
  /// different transfer tag, or a tagged/legacy shape
  /// mismatch (build 2096, audit L14: [add] used to refuse
  /// foreign chunks silently, leaving the user stuck with
  /// a half-collected set and no explanation).
  bool isForeignChunk(String code) {
    if (_total == null) return false;
    final chunk = parsePairingChunk(code);
    if (chunk == null) return false;
    if (chunk.total != _total) return true;
    if (chunk.tag.isNotEmpty || _tag != null) {
      return chunk.tag != (_tag ?? '');
    }
    // Build 2098 (post-2097 audit L15): an untagged chunk
    // whose index is already collected with different
    // content is another (legacy) transfer's — the only
    // splice signal untagged sets carry.
    final existing = _parts[chunk.index];
    if (existing != null && existing != chunk.part) return true;
    return false;
  }

  /// Adds one scanned code. Returns false when [code] is
  /// not a pairing chunk (the caller routes it elsewhere).
  bool add(String code) {
    final chunk = parsePairingChunk(code);
    if (chunk == null) return false;
    if (chunk.total < 1) return false;
    if (chunk.index < 1 || chunk.index > chunk.total) return false;
    if (_total != null && _total != chunk.total) return false;
    // Build 2097 (audit L-i): the transfer tag must match
    // the collection's — a same-total chunk from another
    // transfer no longer mixes in silently.
    if (chunk.tag.isNotEmpty) {
      if (_tag != null && _tag != chunk.tag) return false;
      if (_tag == null && _parts.isNotEmpty) return false;
      _tag = chunk.tag;
    } else if (_tag != null) {
      return false;
    }
    // Build 2098 (post-2097 audit L15): never splice — a
    // chunk whose index is already collected with DIFFERENT
    // content belongs to another transfer (for legacy,
    // tagless sets this is the only signal there is) and is
    // refused like a tag mismatch. Re-scanning the same
    // code (identical content) stays an accepted no-op.
    final existingPart = _parts[chunk.index];
    if (existingPart != null && existingPart != chunk.part) return false;
    _total = chunk.total;
    _parts[chunk.index] = chunk.part;
    return true;
  }

  /// The reassembled sealed payload, or null while
  /// incomplete.
  String? assemble() {
    if (!isComplete) return null;
    return [for (var i = 1; i <= _total!; i++) _parts[i]!].join();
  }
}

/// Export side: password → sealed backup → paged QRs.
class PairingExportPage extends StatefulWidget {
  const PairingExportPage({
    super.key,
    required this.xray,
    required this.settings,
    this.openvpn,
    this.psiphon,
    this.warp,
    this.masque,
  });

  final XrayController xray;
  final AppSettings settings;

  /// Build 2116 (AB-05): the other engines' controllers —
  /// their sections ride the transfer (see ember_sync's
  /// buildEngineSections).
  final OpenVpnController? openvpn;
  final PsiphonController? psiphon;
  final AetherController? warp;
  final AetherController? masque;

  @override
  State<PairingExportPage> createState() => _PairingExportPageState();
}

class _PairingExportPageState extends State<PairingExportPage> {
  final _password = TextEditingController();
  List<String> _codes = const [];
  int _page = 0;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _build() async {
    final pw = _password.text;
    if (pw.length < 4) {
      setState(() => _error = 'Use a password of at least 4 characters.');
      return;
    }
    final docText = await widget.xray.exportBackup(
      appSettingsJson: widget.settings.toJson(),
      engineSections: buildEngineSections(
        openvpn: widget.openvpn,
        psiphon: widget.psiphon,
        warp: widget.warp,
        masque: widget.masque,
      ),
    );
    // Build 2098 (post-2097 audit M11): a protected store
    // exports nothing — pairing its empty in-memory state
    // would hand the other device an empty account.
    if (docText == null) {
      setState(
        () => _error =
            widget.xray.storeError ??
            'The saved data could not be read, so there is '
                'nothing to send.',
      );
      return;
    }
    final sealed = sealPayload(docText, pw);
    setState(() {
      _codes = splitPairingPayload(sealed);
      _page = 0;
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Ember.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Ember.text,
        title: Text('Send to another device', style: Ember.heading),
      ),
      body: EmberBackground(child: ListView(
        padding: EdgeInsets.fromLTRB(16, MediaQuery.of(context).padding.top + kToolbarHeight + 8, 16, 24),
        children: [
          Text(
            'Your configs and subscriptions are sealed with a '
            'password only you know — the QR codes alone reveal '
            'nothing. On the other device: Settings → Restore → '
            'Receive from another device.',
            style: Ember.body,
          ),
          const SizedBox(height: 14),
          if (_codes.isEmpty) ...[
            TextField(
              controller: _password,
              obscureText: true,
              style: Ember.body,
              // Build 2116 (AP-08): the shared field.
              decoration: emberField(context, 'Transfer password'),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: Ember.caption.copyWith(color: Ember.red)),
            ],
            const SizedBox(height: 12),
            EmberButton(label: 'Create transfer codes', onTap: _build),
          ] else ...[
            Center(
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: QrImageView(
                  data: _codes[_page],
                  version: QrVersions.auto,
                  size: 240,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Code ${_page + 1} of ${_codes.length} — scan them in any '
              'order on the other device.',
              style: Ember.caption,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                EmberChip(
                  label: 'Previous',
                  onTap: _page > 0 ? () => setState(() => _page--) : null,
                ),
                const SizedBox(width: 8),
                EmberChip(
                  label: 'Next',
                  onTap: _page < _codes.length - 1
                      ? () => setState(() => _page++)
                      : null,
                ),
              ],
            ),
          ],
        ],
      )),
    );
  }
}

/// Import side: scan chunks → password → restore.
class PairingImportPage extends StatefulWidget {
  const PairingImportPage({
    super.key,
    required this.xray,
    required this.settings,
    this.openvpn,
    this.psiphon,
    this.warp,
    this.masque,
  });

  final XrayController xray;
  final AppSettings settings;

  /// Build 2116 (AB-05): the other engines' controllers —
  /// a restored transfer's sections land on them.
  final OpenVpnController? openvpn;
  final PsiphonController? psiphon;
  final AetherController? warp;
  final AetherController? masque;

  @override
  State<PairingImportPage> createState() => _PairingImportPageState();
}

class _PairingImportPageState extends State<PairingImportPage> {
  final _collector = PairingCollector();
  final _scanner = MobileScannerController();
  final _password = TextEditingController();
  bool _restoring = false;
  String _status = 'Point the camera at the transfer codes.';

  @override
  void dispose() {
    _scanner.dispose();
    _password.dispose();
    super.dispose();
  }

  /// One incoming code (camera or gallery): collect it,
  /// or — build 2096 (post-2095 audit L14) — explain a
  /// foreign transfer's code instead of swallowing it.
  void _ingest(String v) {
    if (_collector.add(v)) {
      setState(() {
        _status = _collector.isComplete
            ? 'All codes received — enter the password.'
            : 'Got ${_collector.received} of '
                  '${_collector.total} codes…';
      });
    } else if (_collector.isForeignChunk(v)) {
      setState(() {
        _status = 'That code belongs to a different transfer '
            '(${_collector.received} of ${_collector.total} collected '
            'here). Start over to receive that one instead.';
      });
    }
  }

  void _resetCollection() {
    _collector.reset();
    setState(() {
      _status = 'Cleared — point the camera at the transfer codes.';
    });
  }

  /// Build 2096 (post-2095 audit L15): receive from a
  /// gallery image too, not only the camera — the codes
  /// may arrive as screenshots.
  Future<void> _fromGallery() async {
    final path = await XrayPlatform.pickImageFile();
    if (path == null || !mounted) return;
    final values = await decodeQrValuesFromImageFile(path);
    if (!mounted) return;
    if (values.isEmpty) {
      setState(() {
        _status = 'No transfer code found in that image.';
      });
      return;
    }
    for (final v in values) {
      _ingest(v);
    }
  }

  Future<void> _restore() async {
    final sealed = _collector.assemble();
    if (sealed == null) return;
    final plain = openSealedPayload(sealed, _password.text);
    if (plain == null) {
      setState(() => _status = 'Wrong password, or the codes are damaged.');
      return;
    }
    setState(() => _restoring = true);
    try {
      final result = await widget.xray.importBackup(plain);
      if (result == null) {
        setState(() => _status = 'That payload is not an Ember backup.');
        return;
      }
      if (result.appSettingsJson != null) {
        await widget.settings.applyRestoredSettings(result.appSettingsJson!);
      }
      // Build 2125 (audit A25-07): engine sections that
      // could not be applied are named, not swallowed.
      var engineFailures = const <String>[];
      if (result.engineSections != null) {
        engineFailures = await applyEngineSections(
          result.engineSections!,
          openvpn: widget.openvpn,
          psiphon: widget.psiphon,
          warp: widget.warp,
          masque: widget.masque,
        );
      }
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Transferred: ${result.profiles} configs, '
              '${result.subscriptions} subscriptions'
              '${result.skipped > 0 ? ' (${result.skipped} skipped)' : ''}'
              // Build 2095 (audit 4a-3): transform notes.
              '${result.notes.isNotEmpty ? ' ${result.notes.join(' ')}' : ''}'
              '${engineFailures.isEmpty ? '' : ' These sections could not be applied: ${engineFailures.join(', ')}.'}',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _restoring = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final complete = _collector.isComplete;
    return OverlayGuard(
      child: Scaffold(
        extendBodyBehindAppBar: true,
        backgroundColor: Ember.bg,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          foregroundColor: Ember.text,
          title: Text('Receive from another device', style: Ember.heading),
        ),
        body: EmberBackground(child: ListView(
          padding: EdgeInsets.fromLTRB(16, MediaQuery.of(context).padding.top + kToolbarHeight + 8, 16, 24),
          children: [
            if (!complete)
              SizedBox(
                height: 300,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(18),
                  child: MobileScanner(
                    controller: _scanner,
                    onDetect: (capture) {
                      for (final b in capture.barcodes) {
                        final v = b.rawValue;
                        if (v != null) _ingest(v);
                      }
                    },
                  ),
                ),
              ),
            const SizedBox(height: 12),
            Text(_status, style: Ember.body),
            if (!complete) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  MapActionPill(
                    icon: Icons.photo_library_rounded,
                    label: 'From gallery',
                    onTap: _fromGallery,
                  ),
                  if (_collector.received > 0) ...[
                    const SizedBox(width: 8),
                    MapActionPill(
                      icon: Icons.restart_alt_rounded,
                      label: 'Start over',
                      onTap: _resetCollection,
                    ),
                  ],
                ],
              ),
            ],
            if (complete) ...[
              const SizedBox(height: 14),
              TextField(
                controller: _password,
                obscureText: true,
                style: Ember.body,
                // Build 2116 (AP-08): the shared field.
                decoration: emberField(context, 'Transfer password'),
              ),
              const SizedBox(height: 12),
              EmberButton(
                label: _restoring ? 'Restoring…' : 'Restore',
                onTap: _restoring ? null : _restore,
              ),
              // Build 2097 (post-2096 audit L-j): the
              // complete state offers Start over too — a
              // completed set that turns out to be the wrong
              // transfer (the restore fails) used to trap
              // the user here with no way back short of
              // leaving the page; the collecting state had
              // the button all along.
              const SizedBox(height: 10),
              MapActionPill(
                icon: Icons.restart_alt_rounded,
                label: 'Start over',
                onTap: _resetCollection,
              ),
            ],
          ],
        )),
      ),
    );
  }
}
