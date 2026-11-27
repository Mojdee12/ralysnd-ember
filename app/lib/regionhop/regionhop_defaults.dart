/// Built-in RegionHop defaults (build 2141, leg 2 —
/// added at the owner's explicit order): when no panel
/// values are stored, the RegionHop page starts from
/// these, so with the feature switch on, opening the
/// page connects with zero typing. Stored settings
/// always win — these are only the fallback for an
/// empty field, and the setup form's Edit flow keeps
/// working exactly as before.
///
/// Build 2143: the panel now serves TLS (the carrier
/// DPI-dropped the plain-HTTP status exchange on the
/// direct path), so the baked address is the https
/// form and the panel's PUBLIC certificate is embedded
/// below for the client's pinning (see
/// regionhop_client.dart). The pre-2143 http address is
/// kept as [RegionHopDefaults.legacyPanelUrl] purely so
/// a stored copy of it can be migrated to the https
/// form (see the page's URL resolution).
///
/// This file is the ONLY place these values live in
/// the codebase: they are never written to the journal,
/// a log, or a diagnostics export (the journal's
/// vocabulary has no slot for them). The certificate is
/// public material — a certificate is safe to publish;
/// its private key never leaves the server.
library;

class RegionHopDefaults {
  const RegionHopDefaults._();

  /// The panel address, path prefix included.
  static const String panelUrl =
      'https://example.invalid:25000/placeholder/';

  /// The pre-2143 baked panel address (plain HTTP).
  /// Never used to connect — only compared against a
  /// stored panel URL so a device that stored the old
  /// default migrates to [panelUrl] (build 2143).
  static const String legacyPanelUrl =
      'http://example.invalid:25000/placeholder/';

  /// The panel's self-signed certificate (PEM), public
  /// material. The client trusts exactly this
  /// certificate when — and only when — it talks to the
  /// baked https endpoint above (build 2143).
  static const String panelCertificatePem =
      '-----BEGIN CERTIFICATE-----\n' 'PLACEHOLDER\n' '-----END CERTIFICATE-----\n';

  /// The panel's admin password.
  static const String panelPassword =
      'placeholder';

  /// The bridge credentials block, one line per
  /// location in the form's `name port user password`
  /// format.
  static const String bridgeCredentials =
      'placeholder';
}
