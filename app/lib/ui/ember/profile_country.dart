/// Deriving a profile's country for the world-map pins — strictly from
/// what the profile itself says: a flag emoji in its remark, an ISO
/// code token, or a country name (English or Persian). Nothing is
/// guessed from the server address, and a profile whose remark carries
/// no country simply gets no pin.

import '../../xray/xray_models.dart';
import 'world_map_data.dart';

/// 🇩🇪-style flag emoji for an ISO code (🌐 when it is not two letters).
String countryFlagEmoji(String code) {
  final c = code.toUpperCase();
  if (c.length != 2) return '🌐';
  final a = c.codeUnitAt(0), b = c.codeUnitAt(1);
  if (a < 65 || a > 90 || b < 65 || b > 90) return '🌐';
  return String.fromCharCodes([0x1F1E6 + a - 65, 0x1F1E6 + b - 65]);
}

/// The ISO code of the first flag emoji in [text], if any.
String? flagEmojiCode(String text) {
  final units = text.runes.toList();
  for (var i = 0; i + 1 < units.length; i++) {
    final a = units[i], b = units[i + 1];
    if (a >= 0x1F1E6 && a <= 0x1F1FF && b >= 0x1F1E6 && b <= 0x1F1FF) {
      return String.fromCharCodes([65 + a - 0x1F1E6, 65 + b - 0x1F1E6]);
    }
  }
  return null;
}

const _a3toA2 = <String, String>{
  'USA': 'US',
  'GBR': 'GB',
  'DEU': 'DE',
  'NLD': 'NL',
  'FRA': 'FR',
  'TUR': 'TR',
  'IRN': 'IR',
  'RUS': 'RU',
  'CHN': 'CN',
  'JPN': 'JP',
  'KOR': 'KR',
  'IND': 'IN',
  'ARE': 'AE',
  'SGP': 'SG',
  'HKG': 'HK',
  'TWN': 'TW',
  'CAN': 'CA',
  'AUS': 'AU',
  'ITA': 'IT',
  'ESP': 'ES',
  'POL': 'PL',
  'UKR': 'UA',
  'ROU': 'RO',
  'CZE': 'CZ',
  'AUT': 'AT',
  'CHE': 'CH',
  'SWE': 'SE',
  'NOR': 'NO',
  'DNK': 'DK',
  'FIN': 'FI',
  'BEL': 'BE',
  'PRT': 'PT',
  'GRC': 'GR',
  'HUN': 'HU',
  'SVK': 'SK',
  'HRV': 'HR',
  'SRB': 'RS',
  'BGR': 'BG',
  'LTU': 'LT',
  'LVA': 'LV',
  'EST': 'EE',
  'IRL': 'IE',
  'ISL': 'IS',
  'LUX': 'LU',
  'MLT': 'MT',
  'CYP': 'CY',
  'MYS': 'MY',
  'IDN': 'ID',
  'THA': 'TH',
  'VNM': 'VN',
  'PHL': 'PH',
  'PAK': 'PK',
  'BGD': 'BD',
  'LKA': 'LK',
  'KAZ': 'KZ',
  'UZB': 'UZ',
  'AZE': 'AZ',
  'GEO': 'GE',
  'ARM': 'AM',
  'BLR': 'BY',
  'MDA': 'MD',
  'ISR': 'IL',
  'EGY': 'EG',
  'ZAF': 'ZA',
  'NGA': 'NG',
  'KEN': 'KE',
  'MAR': 'MA',
  'DZA': 'DZ',
  'BRA': 'BR',
  'ARG': 'AR',
  'CHL': 'CL',
  'COL': 'CO',
  'PER': 'PE',
  'VEN': 'VE',
  'MEX': 'MX',
  'NZL': 'NZ',
  'IRQ': 'IQ',
  'QAT': 'QA',
  'KWT': 'KW',
  'OMN': 'OM',
  'JOR': 'JO',
  'LBN': 'LB',
  'SAU': 'SA',
};

const _aliases = <String, String>{
  'USA': 'US',
  'UK': 'GB',
  'UAE': 'AE',
  'AMERICA': 'US',
  'ENGLAND': 'GB',
  'HOLLAND': 'NL',
  'TURKIYE': 'TR',
};

const _englishNames = <String, String>{
  'US': 'United States',
  'GB': 'United Kingdom',
  'DE': 'Germany',
  'NL': 'Netherlands',
  'FR': 'France',
  'TR': 'Turkey',
  'IR': 'Iran',
  'RU': 'Russia',
  'CN': 'China',
  'JP': 'Japan',
  'KR': 'South Korea',
  'IN': 'India',
  'AE': 'Emirates',
  'SG': 'Singapore',
  'HK': 'Hong Kong',
  'TW': 'Taiwan',
  'CA': 'Canada',
  'AU': 'Australia',
  'IT': 'Italy',
  'ES': 'Spain',
  'PL': 'Poland',
  'UA': 'Ukraine',
  'RO': 'Romania',
  'CZ': 'Czech',
  'AT': 'Austria',
  'CH': 'Switzerland',
  'SE': 'Sweden',
  'NO': 'Norway',
  'DK': 'Denmark',
  'FI': 'Finland',
  'BE': 'Belgium',
  'PT': 'Portugal',
  'GR': 'Greece',
  'HU': 'Hungary',
  'SK': 'Slovakia',
  'HR': 'Croatia',
  'RS': 'Serbia',
  'BG': 'Bulgaria',
  'LT': 'Lithuania',
  'LV': 'Latvia',
  'EE': 'Estonia',
  'IE': 'Ireland',
  'IS': 'Iceland',
  'LU': 'Luxembourg',
  'MT': 'Malta',
  'CY': 'Cyprus',
  'MY': 'Malaysia',
  'ID': 'Indonesia',
  'TH': 'Thailand',
  'VN': 'Vietnam',
  'PH': 'Philippines',
  'PK': 'Pakistan',
  'BD': 'Bangladesh',
  'LK': 'Sri Lanka',
  'KZ': 'Kazakhstan',
  'UZ': 'Uzbekistan',
  'AZ': 'Azerbaijan',
  'GE': 'Georgia',
  'AM': 'Armenia',
  'BY': 'Belarus',
  'MD': 'Moldova',
  'IL': 'Israel',
  'EG': 'Egypt',
  'ZA': 'South Africa',
  'NG': 'Nigeria',
  'KE': 'Kenya',
  'MA': 'Morocco',
  'DZ': 'Algeria',
  'BR': 'Brazil',
  'AR': 'Argentina',
  'CL': 'Chile',
  'CO': 'Colombia',
  'PE': 'Peru',
  'VE': 'Venezuela',
  'MX': 'Mexico',
  'NZ': 'New Zealand',
  'IQ': 'Iraq',
  'QA': 'Qatar',
  'KW': 'Kuwait',
  'OM': 'Oman',
  'JO': 'Jordan',
  'LB': 'Lebanon',
  'SA': 'Saudi Arabia',
};

/// The English display name for an ISO country code (the code
/// itself when unknown) — for group titles (build 2032).
String countryDisplayName(String code) =>
    _englishNames[code.toUpperCase()] ?? code.toUpperCase();

/// Build 2095 (third-pass audit 7-3): the ONE country a
/// DISPLAY surface shows for a profile — the measured
/// exit country when a test recorded one, else the
/// remark's claim. Three surfaces (the list flag, the
/// shell map, the home card) used to derive it
/// differently, so the same profile showed different
/// countries on different screens. [profileCountryCode]
/// itself keeps its remark-only semantics for its other
/// callers (grouping keys, chain logic).
String? profileDisplayCountryCode(Profile p) {
  if (p.exitCountryCode.isNotEmpty) {
    return p.exitCountryCode.toUpperCase();
  }
  return profileCountryCode(p);
}

/// The country a profile's remark claims, or null when it claims none.
/// Only codes the map has coordinates for are returned.
String? profileCountryCode(Profile p) {
  final name = p.name;

  final byFlag = flagEmojiCode(name);
  if (byFlag != null && countryPinLatLon.containsKey(byFlag)) return byFlag;

  final upper = name.toUpperCase();
  for (final token in upper.split(RegExp(r'[^A-Z0-9]+'))) {
    if (token.length == 2 && countryPinLatLon.containsKey(token)) {
      return token;
    }
    if (token.length == 3 && _a3toA2.containsKey(token)) {
      final code = _a3toA2[token]!;
      if (countryPinLatLon.containsKey(code)) return code;
    }
    final alias = _aliases[token];
    if (alias != null && countryPinLatLon.containsKey(alias)) return alias;
  }

  // Country names, longest first so "South Korea" beats "Korea"-style
  // partial hits and Persian names match as whole words.
  final english = _englishNames.entries.toList()
    ..sort((a, b) => b.value.length.compareTo(a.value.length));
  for (final e in english) {
    if (upper.contains(e.value.toUpperCase()) &&
        countryPinLatLon.containsKey(e.key)) {
      return e.key;
    }
  }
  final persian =
      _persianRemarkNames.entries.where((e) => e.value.length >= 3).toList()
        ..sort((a, b) => b.value.length.compareTo(a.value.length));
  for (final e in persian) {
    if (name.contains(e.value) && countryPinLatLon.containsKey(e.key)) {
      return e.key;
    }
  }
  return null;
}

/// Persian country names, used ONLY to recognize a country written in
/// Persian inside a profile's remark (the user's own subscription
/// content) when placing map pins. Never displayed: the UI shows
/// English names (2006). Moved here from exit_info.dart, whose
/// display table is English now.
const _persianRemarkNames = <String, String>{
  'DE': 'آلمان',
  'NL': 'هلند',
  'FR': 'فرانسه',
  'GB': 'بریتانیا',
  'UK': 'بریتانیا',
  'US': 'آمریکا',
  'CA': 'کانادا',
  'TR': 'ترکیه',
  'AE': 'امارات',
  'CH': 'سوئیس',
  'SE': 'سوئد',
  'NO': 'نروژ',
  'DK': 'دانمارک',
  'FI': 'فنلاند',
  'AT': 'اتریش',
  'BE': 'بلژیک',
  'IE': 'ایرلند',
  'IT': 'ایتالیا',
  'ES': 'اسپانیا',
  'PT': 'پرتغال',
  'PL': 'لهستان',
  'CZ': 'چک',
  'SK': 'اسلواکی',
  'HU': 'مجارستان',
  'RO': 'رومانی',
  'BG': 'بلغارستان',
  'GR': 'یونان',
  'RU': 'روسیه',
  'UA': 'اوکراین',
  'JP': 'ژاپن',
  'SG': 'سنگاپور',
  'HK': 'هنگ‌کنگ',
  'TW': 'تایوان',
  'KR': 'کره جنوبی',
  'IN': 'هند',
  'ID': 'اندونزی',
  'MY': 'مالزی',
  'TH': 'تایلند',
  'VN': 'ویتنام',
  'AU': 'استرالیا',
  'NZ': 'نیوزیلند',
  'BR': 'برزیل',
  'AR': 'آرژانتین',
  'MX': 'مکزیک',
  'CL': 'شیلی',
  'ZA': 'آفریقای جنوبی',
  'EG': 'مصر',
  'IL': 'اسرائیل',
  'SA': 'عربستان',
  'QA': 'قطر',
  'KW': 'کویت',
  'OM': 'عمان',
  'GE': 'گرجستان',
  'AM': 'ارمنستان',
  'AZ': 'آذربایجان',
  'KZ': 'قزاقستان',
  'UZ': 'ازبکستان',
  'IS': 'ایسلند',
  'EE': 'استونی',
  'LV': 'لتونی',
  'LT': 'لیتوانی',
  'HR': 'کرواسی',
  'RS': 'صربستان',
  'AL': 'آلبانی',
  'MD': 'مولداوی',
  'CY': 'قبرس',
  'LU': 'لوکزامبورگ',
};
