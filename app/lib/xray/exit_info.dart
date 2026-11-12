/// The exit identity of a running V2Ray tunnel: the IP the outside
/// world sees and the country it geolocates to. Purely informational —
/// looked up best-effort through the tunnel after it connects, hidden
/// whenever the lookup fails.

class ExitInfo {
  final String ip;
  final String countryCode;
  final String countryEn;

  /// The exit city, when the lookup named one (the Windows
  /// backend's ip-api fallback does; kept for the desktop pages).
  final String city;
  const ExitInfo({
    required this.ip,
    required this.countryCode,
    required this.countryEn,
    this.city = '',
  });

  factory ExitInfo.fromMap(Map<String, String> m) => ExitInfo(
    ip: m['ip'] ?? '',
    countryCode: (m['countryCode'] ?? '').toUpperCase(),
    countryEn: m['country'] ?? '',
    city: m['city'] ?? '',
  );

  /// The regional-indicator flag emoji for the country code, or a
  /// globe when the code is missing/unknown.
  String get flag {
    final c = countryCode;
    if (c.length != 2) return '🌐';
    final a = c.codeUnitAt(0);
    final b = c.codeUnitAt(1);
    if (a < 0x41 || a > 0x5A || b < 0x41 || b > 0x5A) return '🌐';
    return String.fromCharCodes([0x1F1E6 + a - 0x41, 0x1F1E6 + b - 0x41]);
  }

  /// The country name for the Home card, always English (2006: the
  /// whole app is English): the English name the lookup returned
  /// (ip-api path), else the table below for the code-only Cloudflare
  /// trace path, else the bare code.
  String get displayName {
    if (countryEn.isNotEmpty) return countryEn;
    return englishCountryNames[countryCode] ?? countryCode;
  }

  /// "185.2.3.4 • Germany" — the Home card's exit line.
  /// Plain text since build 2027 (v7 audit): the regional-
  /// indicator flag emoji this used to embed renders as a
  /// missing-glyph box on fonts without flag support (the
  /// harness font, and several device fonts) — the ▯ the
  /// audit caught before "Netherlands" on the Psiphon page.
  /// The drawn FlagCircle stays for the places that show a
  /// flag as a graphic.
  String get line => displayName.isEmpty ? ip : '$ip • $displayName';
}

/// English country names for the codes a VPN exit commonly lands in;
/// the fallback for lookups that return only a code (Cloudflare
/// trace). Anything missing falls back to the bare code.
const englishCountryNames = <String, String>{
  'DE': 'Germany',
  'NL': 'Netherlands',
  'FR': 'France',
  'GB': 'United Kingdom',
  'UK': 'United Kingdom',
  'US': 'United States',
  'CA': 'Canada',
  'TR': 'Turkey',
  'AE': 'United Arab Emirates',
  'CH': 'Switzerland',
  'SE': 'Sweden',
  'NO': 'Norway',
  'DK': 'Denmark',
  'FI': 'Finland',
  'AT': 'Austria',
  'BE': 'Belgium',
  'IE': 'Ireland',
  'IT': 'Italy',
  'ES': 'Spain',
  'PT': 'Portugal',
  'PL': 'Poland',
  'CZ': 'Czechia',
  'SK': 'Slovakia',
  'HU': 'Hungary',
  'RO': 'Romania',
  'BG': 'Bulgaria',
  'GR': 'Greece',
  'RU': 'Russia',
  'UA': 'Ukraine',
  'JP': 'Japan',
  'SG': 'Singapore',
  'HK': 'Hong Kong',
  'TW': 'Taiwan',
  'KR': 'South Korea',
  'IN': 'India',
  'ID': 'Indonesia',
  'MY': 'Malaysia',
  'TH': 'Thailand',
  'VN': 'Vietnam',
  'AU': 'Australia',
  'NZ': 'New Zealand',
  'BR': 'Brazil',
  'AR': 'Argentina',
  'MX': 'Mexico',
  'CL': 'Chile',
  'ZA': 'South Africa',
  'EG': 'Egypt',
  'IL': 'Israel',
  'SA': 'Saudi Arabia',
  'QA': 'Qatar',
  'KW': 'Kuwait',
  'OM': 'Oman',
  'GE': 'Georgia',
  'AM': 'Armenia',
  'AZ': 'Azerbaijan',
  'KZ': 'Kazakhstan',
  'UZ': 'Uzbekistan',
  'IS': 'Iceland',
  'EE': 'Estonia',
  'LV': 'Latvia',
  'LT': 'Lithuania',
  'HR': 'Croatia',
  'RS': 'Serbia',
  'AL': 'Albania',
  'MD': 'Moldova',
  'CY': 'Cyprus',
  'LU': 'Luxembourg',
  'IR': 'Iran',
};
