/// Custom DNS host entries (build 2041).
///
/// The user's own domain-to-IP map, answered by the tunnel's DNS
/// before any resolver is asked — the LxBox "Custom DNS Hosts"
/// feature (2026-11-12). Use it to pin a name to a known-good IP
/// when the local network's DNS lies about it: a poisoned answer
/// for a subscription host, a provider's SNI name, or a local name
/// like `wg.home`.
///
/// The mechanism is the core's own: the bundled Xray-core
/// v26.10.29 takes a `hosts` map in its DNS config
/// (`infra/conf/dns.go` HostsWrapper / HostAddress — one address
/// string or a list of addresses per name), and the app already
/// emits one for the built-in resolver pins (`_dnsHostPins` in
/// config_builder.dart). User entries ride the same map, so no
/// core change and no new engine are involved.
///
/// Rules, enforced wherever an entry is read or written:
/// - domains are plain names (labels of letters, digits and
///   hyphens, never starting or ending with one; no wildcard,
///   no trailing dot, and never an IP address itself);
/// - values are single IPs (v4 or v6, no zone id, no CIDR);
/// - an entry that fails either check is dropped, never trusted
///   into a config — a corrupt store cannot break a connect.

import 'dart:io';

/// A domain name the core's hosts map can answer: labels of
/// letters, digits and hyphens, 1-63 chars each, 1-253 total.
/// Single-label local names (`nas`, `wg.home`) are allowed —
/// that is the point for a home network. A wildcard, a trailing
/// dot, or an IP address in the domain slot is rejected.
bool dnsHostDomainValid(String domain) {
  if (domain.isEmpty || domain.length > 253) return false;
  if (domain.startsWith('.') || domain.endsWith('.')) return false;
  if (domain.contains(' ') || domain.contains('_')) return false;
  // An IP address is not a domain name.
  if (InternetAddress.tryParse(domain) != null) return false;
  final label = RegExp(r'^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$');
  for (final part in domain.split('.')) {
    if (part.isEmpty || part.length > 63) return false;
    if (!label.hasMatch(part)) return false;
  }
  return true;
}

/// A single IP address (v4 or v6). No zone id (`fe80::1%eth0`),
/// no CIDR, no hostname.
bool dnsHostIpValid(String ip) {
  if (ip.isEmpty || ip.contains('%') || ip.contains('/')) return false;
  return InternetAddress.tryParse(ip) != null;
}

/// Only the well-formed pairs survive — the final gate the
/// model and the builder both run, so a corrupt in-memory map
/// can never reach a config. Keys are lower-cased on the way
/// in; a later duplicate wins.
Map<String, String> validDnsHosts(Map<String, String> hosts) {
  final out = <String, String>{};
  hosts.forEach((key, value) {
    final domain = key.trim().toLowerCase();
    final ip = value.trim();
    if (dnsHostDomainValid(domain) && dnsHostIpValid(ip)) {
      out[domain] = ip;
    }
  });
  return out;
}

/// One entry per line, `name = IP`. Blank lines are skipped.
/// Returns the valid entries plus the lines that failed, so the
/// editor can name them instead of silently dropping them.
({Map<String, String> entries, List<String> invalidLines}) parseDnsHostsText(
  String text,
) {
  final entries = <String, String>{};
  final invalid = <String>[];
  for (final raw in text.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    final eq = line.indexOf('=');
    if (eq <= 0) {
      invalid.add(line);
      continue;
    }
    final domain = line.substring(0, eq).trim().toLowerCase();
    final ip = line.substring(eq + 1).trim();
    if (dnsHostDomainValid(domain) && dnsHostIpValid(ip)) {
      entries[domain] = ip;
    } else {
      invalid.add(line);
    }
  }
  return (entries: entries, invalidLines: invalid);
}

/// The editor's text for a stored map: sorted, one `name = IP`
/// per line, so a round trip through [parseDnsHostsText] is
/// exact.
String dnsHostsText(Map<String, String> hosts) {
  final keys = hosts.keys.toList()..sort();
  return keys.map((k) => '$k = ${hosts[k]}').join('\n');
}
