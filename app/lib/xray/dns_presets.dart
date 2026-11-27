/// Build 2149 (owner expansion 5 — «چند تا dns خوب چند
/// تا دی ان اس واسه ایرانم بزار», 2026-11-25): the curated
/// DNS preset catalogue behind the Settings preset picker
/// (lib/ui/ember/dns_presets_page.dart) and the preset-name
/// labels on the per-config DNS list (expansion 2).
///
/// HARD RULE (the owner's standing DNS law — «dns همون
/// باشه», defaults are v2rayNG's, verbatim): this catalogue
/// changes NO default and NO stored value. A preset reaches
/// a DNS field only when the user taps it in the picker;
/// the fields stay freely editable exactly as before.
///
/// Iran entries verified 2026-11-25 against official
/// sources where reachable: Begzar's pair is begzar.ir's
/// own headline (185.55.226.26 | 185.55.225.25 — the
/// brief's 185.55.226.25 secondary appears nowhere and is
/// NOT shipped); Shecan's pair and its officially
/// published free DoH (https://free.shecan.ir/dns-query)
/// are as shecan.ir publishes them, via the sources that
/// quote it (the site itself was unreachable from the
/// build host that day); Electro (electrotm.org),
/// 403.online and RadarGame pairs are the ones every
/// current listing agrees on. A DoH URL is carried ONLY
/// where the provider officially publishes one — the Iran
/// services other than Shecan publish none, so theirs
/// stay plain addresses.
library;

/// One preset resolver service: a display name, its
/// primary and secondary plain addresses, and its
/// officially published DoH URL when it has one.
class DnsPreset {
  const DnsPreset({
    required this.name,
    required this.primary,
    required this.secondary,
    this.doh,
  });

  final String name;
  final String primary;
  final String secondary;
  final String? doh;

  /// What a tap writes into the REMOTE DNS field: the DoH
  /// URL when the provider publishes one (the shape the
  /// field's own provider rows have always written), else
  /// the plain pair as the field's comma-separated list
  /// (build 2103: the stored remote DNS is a list, each
  /// entry emitted as stored).
  String get remoteValue => doh ?? '$primary,$secondary';

  /// What a tap writes into the LOCAL DNS field, which
  /// holds a single address: the primary.
  String get localValue => primary;

  /// Both plain addresses, for the picker's caption line.
  String get addressLine => '$primary · $secondary';
}

/// The global resolvers, in the owner's order.
const dnsPresetsGlobal = <DnsPreset>[
  DnsPreset(
    name: 'Cloudflare',
    primary: '1.1.1.1',
    secondary: '1.0.0.1',
    doh: 'https://cloudflare-dns.com/dns-query',
  ),
  DnsPreset(
    name: 'Google',
    primary: '8.8.8.8',
    secondary: '8.8.4.4',
    doh: 'https://dns.google/dns-query',
  ),
  DnsPreset(
    name: 'Quad9',
    primary: '9.9.9.9',
    secondary: '149.112.112.112',
    doh: 'https://dns.quad9.net/dns-query',
  ),
  DnsPreset(
    name: 'AdGuard',
    primary: '94.140.14.14',
    secondary: '94.140.15.15',
    doh: 'https://dns.adguard-dns.com/dns-query',
  ),
  DnsPreset(name: 'Control D', primary: '76.76.2.0', secondary: '76.76.10.0'),
];

/// The Iranian anti-sanctions resolvers, in the owner's
/// order. Shecan's pair is listed as the brief gave it
/// (185.51.200.2 first); shecan.ir's own material usually
/// leads with 178.22.122.100 — both addresses are the
/// service's pair either way, and the remote fill uses
/// the DoH URL, so the order only shows in the caption.
const dnsPresetsIran = <DnsPreset>[
  DnsPreset(
    name: 'Shecan',
    primary: '185.51.200.2',
    secondary: '178.22.122.100',
    doh: 'https://free.shecan.ir/dns-query',
  ),
  DnsPreset(
    name: 'Electro',
    primary: '78.157.42.100',
    secondary: '78.157.42.101',
  ),
  DnsPreset(
    name: '403.online',
    primary: '10.202.10.202',
    secondary: '10.202.10.102',
  ),
  DnsPreset(
    name: 'RadarGame',
    primary: '10.202.10.10',
    secondary: '10.202.10.11',
  ),
  DnsPreset(
    name: 'Begzar',
    primary: '185.55.226.26',
    secondary: '185.55.225.25',
  ),
];

/// Every preset, Global first — the matcher's search space.
const allDnsPresets = <DnsPreset>[...dnsPresetsGlobal, ...dnsPresetsIran];

/// The preset name claiming a resolver entry as it appears
/// in a generated config's DNS server list (expansion 2's
/// per-config list labels its rows with this). A plain
/// address matches a preset's primary or secondary; a URL
/// entry matches by host against a preset's DoH host (the
/// `https+one://` spellings share the host, and a `tcp://`
/// entry's host IS its address). Null when no preset
/// claims the entry — most entries stay unlabelled.
String? dnsPresetNameFor(String server) {
  final entry = server.trim();
  if (entry.isEmpty) return null;
  for (final p in allDnsPresets) {
    if (entry == p.primary || entry == p.secondary) return p.name;
  }
  final uri = Uri.tryParse(entry);
  final host = uri?.host ?? '';
  if (host.isEmpty) return null;
  for (final p in allDnsPresets) {
    if (host == p.primary || host == p.secondary) return p.name;
    final doh = p.doh;
    if (doh != null && Uri.parse(doh).host == host) return p.name;
  }
  return null;
}
