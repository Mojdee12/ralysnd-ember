// Per-route SNI spoofing rules (build 2127, H3 — the
// 2126 audit's D5 park, landed with its rules model).
//
// A rule names a domain and the decoy SNI the sing-box
// sidecar shows a filter instead of the real one: the
// sidecar's route gains a route-options rule matching
// the domain (and its subdomains) carrying `tls_spoof`
// (+ `tls_spoof_method` when the rule picks one) —
// sing-box 1.14.4's desync action, which injects a fake
// ClientHello with the decoy name ahead of the real
// handshake on the connections it dials. The grammar is
// the vendored 1.14.4's own (its RawRouteOptionsActionOptions
// carries both fields; the method enum is the core's).
//
// The rules live in [XraySettings.sniSpoofRules] and are
// emitted by singbox_config.dart ONLY while
// XraySettings.sniSpoofEnabled is on; off, or with no
// rules, the sidecar config is byte-identical to 2126's.

/// The `tls_spoof_method` values sing-box 1.14.4 accepts
/// (its option enum). A rule with no method emits no
/// `tls_spoof_method` key and the core applies its own
/// default.
const sniSpoofMethods = <String>[
  'wrong-sequence',
  'wrong-checksum',
  'wrong-ack',
  'wrong-md5',
  'wrong-timestamp',
];

class SniSpoofRule {
  SniSpoofRule({
    required this.id,
    this.domain = '',
    this.spoof = '',
    this.method = '',
  });

  String id;

  /// The domain whose TLS connections are spoofed; the
  /// emitted rule matches it and its subdomains
  /// (domain_suffix).
  String domain;

  /// The decoy SNI shown instead of the real one.
  String spoof;

  /// One of [sniSpoofMethods], or '' for the core default.
  String method;

  /// The row's one-line summary on the editor page.
  String get label {
    final d = domain.trim();
    final s = spoof.trim();
    if (d.isEmpty && s.isEmpty) return 'Empty rule';
    return '${d.isEmpty ? '…' : d} → ${s.isEmpty ? '…' : s}';
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'domain': domain,
    'spoof': spoof,
    'method': method,
  };

  /// Defensive store read (the SmartGroupRule precedent):
  /// a malformed entry is dropped, never fatal; an unknown
  /// method reads as the core default rather than breaking
  /// the sidecar's config load.
  static SniSpoofRule? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    if (id is! String || id.isEmpty) return null;
    String str(String key) {
      final v = raw[key];
      return v is String ? v : '';
    }

    final method = str('method');
    return SniSpoofRule(
      id: id,
      domain: str('domain'),
      spoof: str('spoof'),
      method: sniSpoofMethods.contains(method) ? method : '',
    );
  }
}
