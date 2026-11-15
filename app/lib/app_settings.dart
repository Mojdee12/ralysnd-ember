import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import 'atomic_json_store.dart';

/// What the window's close button does.
enum CloseAction { ask, tray, quit }

/// The app's own preferences (language, theme, close button), kept in
/// `app-settings.json` in the data folder beside the core's files. The VPN
/// settings belong to the core.
class AppSettings extends ChangeNotifier {
  AppSettings({this.file});

  final File? file;

  /// A language code (`en`, `fa`, `zh`, `ru`), or empty for the system
  /// language. Ralysnd Ember ships English as the first-run language
  /// (2006: the whole app is English by default); the user can pick
  /// another in Settings.
  String language = 'en';
  ThemeMode themeMode = ThemeMode.dark; // Ralysnd Ember is a dark-first design.
  CloseAction closeAction = CloseAction.ask;

  /// True until the user finished the welcome page.
  bool firstRun = false;

  /// Shows the public IP (the address websites see). Off by default: the
  /// location is shown by its country either way.
  bool showPublicIp = false;

  /// When the user closed the "account running out" notice; it stays away
  /// for a day after.
  DateTime? lowQuotaDismissedAt;

  /// The newer version whose notice the user closed; a later one shows.
  String dismissedUpdate = '';

  /// The last successful look for a newer version, and the newer version it
  /// found ("" for none) with its page, so the notice outlasts a restart.
  DateTime? updateCheckedAt;
  String updateVersion = '';
  String updateUrl = '';

  /// Downloads a newer version in the background and installs it the next
  /// time the app starts (the Windows app, which updates itself); on unless
  /// the user turned it off.
  bool autoUpdate = true;

  /// Starts the app in the tray when the user signs in to Windows; on
  /// unless the user turned it off.
  bool autostart = true;

  /// Connects by itself when started with the computer ([autostart]); off
  /// until the user turns it on. The core decides how (Daemon.AutoConnect).
  bool autoConnect = false;

  /// The home page's card when TUN mode refused a program's call or game
  /// (UDP); on unless the user turned it off.
  bool udpNotice = true;

  /// The columns the Logs page's Connections tab hides (ConnectionsView):
  /// at first all but the time, the destination, the rule, and the
  /// protocol. Kept in this file.
  Set<String> hiddenConnectionColumns = {'inbound', 'traffic', 'duration'};

  /// The engine the Ember panel shows: 0 = Mozilla, 1 = V2Ray,
  /// 2 = Psiphon, 3 = Lantern (2024: Lantern is back as mode 3; a
  /// stored 4 from the WARP era is clamped to 0 at load).
  int emberMode = 0;

  /// The Mozilla bootstrap egress (build 2034): how the core
  /// fetches a Guardian pass when the region blocks it (HTTP 451).
  /// One of [bootstrapChoices]: 'off', 'psiphon', 'v2ray', 'warp',
  /// 'relay' (the user's Cloudflare Worker relay). Persisted here;
  /// the core learns the concrete egress on each prepare call.
  String mozillaBootstrap = 'off';

  /// The bootstrap egress choices, in picker order.
  static const bootstrapChoices = ['off', 'psiphon', 'v2ray', 'warp', 'relay'];

  /// Ember 2's baked-in defaults (VPN mode, smart routing off, DoH on)
  /// have been applied to the core once.
  bool ember2DefaultsApplied = false;

  /// The 2024 one-time transport pin has run: the Mozilla core's
  /// proxy.transport was set to "h2" once (the desktop 2.0.5 pin,
  /// brought to Android — an install whose saved core config says
  /// "h3" pays the core's 20 s ConnectTimeout on every connect on
  /// a UDP-hostile network before falling back). After this flag
  /// is set, the Settings transport choice owns the value again.
  bool transportPinned = false;

  /// The 2006 one-time migration has run: the stored language (which
  /// up to 2005 was the shipped Persian default, not necessarily a
  /// deliberate pick) was reset to English once. After this flag is
  /// set, the language picker owns the value again.
  bool emberEnDefaultApplied = false;

  /// Cross-engine fallback (build 2065, item 5): when on, a power-on
  /// that fails on the selected engine walks [fallbackChain] (engine
  /// modes, in the owner's order) until one connects and carries.
  /// Default off and default order Psiphon → Lantern → WARP →
  /// V2Ray, per the owner's stated chain.
  bool fallbackChainEnabled = false;
  List<int> fallbackChain = [2, 3, 6, 1];

  /// Auto-connect triggers (build 2065, item 14): one master
  /// switch, off by default, with three triggers and a trusted
  /// Wi-Fi exclusion list. Distinct from [autoConnect] above (the
  /// desktop core's own start behaviour).
  bool emberAutoConnect = false;
  bool autoConnectOnBoot = true;
  bool autoConnectOnUntrustedWifi = true;
  bool autoConnectOnNetworkChange = true;
  List<String> trustedSsids = [];

  /// The app's languages, in the order the language menus list them.
  /// 'zh' is Simplified and 'zh_Hant' Traditional Chinese.
  static const supportedLanguages = [
    'en',
    'fa',
    'zh',
    'zh_Hant',
    'ru',
    'tr',
    'ar',
    // The rest by their own names.
    'az',
    'id',
    'es',
    'fr',
    'hu',
    'pt',
    'vi',
    'bn',
  ];

  /// Languages written right to left.
  static const rtlLanguages = {'fa', 'ar'};

  /// The locale of a language code such as 'fa' or 'zh_Hant'.
  static Locale localeOf(String language) {
    final parts = language.split('_');
    return parts.length == 2
        ? Locale.fromSubtags(languageCode: parts[0], scriptCode: parts[1])
        : Locale(language);
  }

  /// The app language for the system's [locale]: Traditional Chinese for
  /// the Hant script or Taiwan, Hong Kong, and Macau; else the language
  /// when the app has it; else English.
  static String languageFor(Locale locale) {
    if (locale.languageCode == 'zh') {
      final traditional =
          locale.scriptCode == 'Hant' ||
          const {'TW', 'HK', 'MO'}.contains(locale.countryCode);
      return traditional ? 'zh_Hant' : 'zh';
    }
    return supportedLanguages.contains(locale.languageCode)
        ? locale.languageCode
        : 'en';
  }

  /// The app language for the system's preferred [locales], in order: the
  /// first one the app has; else English (not Flutter's default, the first
  /// language it was built with).
  static String languageForList(List<Locale>? locales) {
    for (final locale in locales ?? const <Locale>[]) {
      if (locale.languageCode == 'zh' ||
          supportedLanguages.contains(locale.languageCode)) {
        return languageFor(locale);
      }
    }
    return 'en';
  }

  /// The core's routing regions (`routing.region`); empty is none.
  static const regions = ['ir', 'cn', 'ru', 'af', 'tr', 'id', 'br', ''];

  Locale? get locale => language.isEmpty ? null : localeOf(language);

  /// The routing region most users of [language] want: Persian is Iran,
  /// Chinese China, Russian Russia; null when a language says nothing.
  static String? regionForLanguage(String language) => switch (language) {
    'fa' => 'ir',
    'zh' => 'cn',
    'ru' => 'ru',
    'id' => 'id',
    'tr' => 'tr',
    'pt' => 'br',
    _ => null,
  };

  /// The region to offer first: from [language], else from the system's
  /// country ([countryCode], such as IR), else none.
  static String suggestedRegion(String language, String? countryCode) {
    final byLanguage = regionForLanguage(language);
    if (byLanguage != null) return byLanguage;
    final country = (countryCode ?? '').toLowerCase();
    return regions.contains(country) ? country : '';
  }

  static Future<AppSettings> load(String dataDir) async {
    final s = AppSettings(
      file: File('$dataDir${Platform.pathSeparator}app-settings.json'),
    );
    try {
      final j = jsonDecode(await s.file!.readAsString());
      if (j is Map<String, Object?>) {
        if (j['language'] case final String l
            when supportedLanguages.contains(l)) {
          s.language = l;
        }
        s.themeMode =
            ThemeMode.values.asNameMap()[j['theme']] ?? ThemeMode.system;
        s.closeAction =
            CloseAction.values.asNameMap()[j['close']] ?? CloseAction.ask;
        s.firstRun = j['welcome_done'] != true;
        s.showPublicIp = j['show_public_ip'] == true;
        if (j['dismissed_update'] case final String v) s.dismissedUpdate = v;
        if (j['update_version'] case final String v) s.updateVersion = v;
        if (j['update_url'] case final String v) s.updateUrl = v;
        s.updateCheckedAt = switch (j['update_checked_at']) {
          final String t => DateTime.tryParse(t),
          _ => null,
        };
        s.lowQuotaDismissedAt = switch (j['low_quota_dismissed_at']) {
          final String t => DateTime.tryParse(t),
          _ => null,
        };
        s.autostart = j['autostart'] != false;
        s.autoConnect = j['auto_connect'] == true;
        s.autoUpdate = j['auto_update'] != false;
        s.udpNotice = j['udp_notice'] != false;
        if (j['hidden_connection_columns'] case final List<Object?> v) {
          s.hiddenConnectionColumns = {...v.whereType<String>()};
        }
        if (j['ember_mode'] case final int v) {
          // 2024: Lantern is back as mode 3 (its pre-2023 stored
          // values are valid again); WARP (4) stays gone. A stored
          // mode pointing outside 0..3 falls back to Mozilla,
          // never a crash or a dead page.
          s.emberMode = v >= 0 && v <= 7 ? v : 0;
        }
        if (j['mozilla_bootstrap'] case final String v
            when bootstrapChoices.contains(v)) {
          s.mozillaBootstrap = v;
        }
        s.ember2DefaultsApplied = j['ember2_defaults'] == true;
        s.transportPinned = j['transport_pinned'] == true;
        s.fallbackChainEnabled = j['fallback_chain_enabled'] == true;
        if (j['fallback_chain'] case final List<Object?> v) {
          final chain = v.whereType<int>().where((m) => m >= 0 && m <= 7).toList();
          if (chain.isNotEmpty) s.fallbackChain = chain;
        }
        s.emberAutoConnect = j['ember_auto_connect'] == true;
        s.autoConnectOnBoot = j['auto_connect_boot'] != false;
        s.autoConnectOnUntrustedWifi = j['auto_connect_untrusted_wifi'] != false;
        s.autoConnectOnNetworkChange = j['auto_connect_network_change'] != false;
        if (j['trusted_ssids'] case final List<Object?> v) {
          s.trustedSsids = v.whereType<String>().toList();
        }
        if (j['ember_en_default'] == true) {
          s.emberEnDefaultApplied = true;
        } else {
          // One-time 2006 migration: English is the default language.
          // Builds up to 2005 shipped 'fa' as the baked-in default, so
          // a stored 'fa' was the default, not a choice; reset it once
          // and persist, after which the picker owns the value.
          s.language = 'en';
          s.emberEnDefaultApplied = true;
          await s._save();
        }
      }
    } on FileSystemException {
      // First run: defaults, and the welcome page.
      s.firstRun = true;
      s.emberEnDefaultApplied = true;
    } on FormatException {
      // A broken file: defaults, rewritten on the next change.
      s.emberEnDefaultApplied = true;
    }
    return s;
  }

  void update({
    String? language,
    ThemeMode? themeMode,
    CloseAction? closeAction,
    bool? firstRun,
    bool? showPublicIp,
    DateTime? lowQuotaDismissedAt,
    String? dismissedUpdate,
    DateTime? updateCheckedAt,
    String? updateVersion,
    String? updateUrl,
    bool? autostart,
    bool? autoConnect,
    bool? autoUpdate,
    bool? udpNotice,
    Set<String>? hiddenConnectionColumns,
    int? emberMode,
    String? mozillaBootstrap,
    bool? ember2DefaultsApplied,
    bool? emberEnDefaultApplied,
    bool? transportPinned,
    bool? fallbackChainEnabled,
    List<int>? fallbackChain,
    bool? emberAutoConnect,
    bool? autoConnectOnBoot,
    bool? autoConnectOnUntrustedWifi,
    bool? autoConnectOnNetworkChange,
    List<String>? trustedSsids,
  }) {
    this.fallbackChainEnabled =
        fallbackChainEnabled ?? this.fallbackChainEnabled;
    this.fallbackChain = fallbackChain ?? this.fallbackChain;
    this.emberAutoConnect = emberAutoConnect ?? this.emberAutoConnect;
    this.autoConnectOnBoot = autoConnectOnBoot ?? this.autoConnectOnBoot;
    this.autoConnectOnUntrustedWifi =
        autoConnectOnUntrustedWifi ?? this.autoConnectOnUntrustedWifi;
    this.autoConnectOnNetworkChange =
        autoConnectOnNetworkChange ?? this.autoConnectOnNetworkChange;
    this.trustedSsids = trustedSsids ?? this.trustedSsids;
    this.mozillaBootstrap = mozillaBootstrap ?? this.mozillaBootstrap;
    this.emberMode = emberMode ?? this.emberMode;
    this.transportPinned = transportPinned ?? this.transportPinned;
    this.emberEnDefaultApplied =
        emberEnDefaultApplied ?? this.emberEnDefaultApplied;
    this.ember2DefaultsApplied =
        ember2DefaultsApplied ?? this.ember2DefaultsApplied;
    this.hiddenConnectionColumns =
        hiddenConnectionColumns ?? this.hiddenConnectionColumns;
    this.udpNotice = udpNotice ?? this.udpNotice;
    this.autoUpdate = autoUpdate ?? this.autoUpdate;
    this.autostart = autostart ?? this.autostart;
    this.autoConnect = autoConnect ?? this.autoConnect;
    this.showPublicIp = showPublicIp ?? this.showPublicIp;
    this.lowQuotaDismissedAt = lowQuotaDismissedAt ?? this.lowQuotaDismissedAt;
    this.dismissedUpdate = dismissedUpdate ?? this.dismissedUpdate;
    this.updateCheckedAt = updateCheckedAt ?? this.updateCheckedAt;
    this.updateVersion = updateVersion ?? this.updateVersion;
    this.updateUrl = updateUrl ?? this.updateUrl;
    this.firstRun = firstRun ?? this.firstRun;
    this.language = language ?? this.language;
    this.themeMode = themeMode ?? this.themeMode;
    this.closeAction = closeAction ?? this.closeAction;
    notifyListeners();
    _save();
  }

  /// The shared atomic store for this file (build 2054, audit
  /// F-H8), created once so every write for this file goes
  /// through one serialization chain. Writes are fire-and-
  /// forget from update(), so serialization is what keeps two
  /// quick setting changes from interleaving bytes.
  AtomicJsonStore? _store;

  Future<void> _save() async {
    final f = file;
    if (f == null) return;
    try {
      // Build 2054 (audit F-H8): tmp + flush + rename through
      // the shared store — the old direct writeAsString could
      // tear the file mid-save and silently reset every setting
      // on the next launch.
      _store ??= AtomicJsonStore(f);
      await _store!.write({
        'language': language,
        'theme': themeMode.name,
        'close': closeAction.name,
        'welcome_done': !firstRun,
        'show_public_ip': showPublicIp,
        'low_quota_dismissed_at': lowQuotaDismissedAt?.toIso8601String(),
        'dismissed_update': dismissedUpdate,
        'update_checked_at': updateCheckedAt?.toIso8601String(),
        'update_version': updateVersion,
        'update_url': updateUrl,
        'autostart': autostart,
        'auto_connect': autoConnect,
        'auto_update': autoUpdate,
        'udp_notice': udpNotice,
        'hidden_connection_columns': hiddenConnectionColumns.toList(),
        'ember_mode': emberMode,
        'mozilla_bootstrap': mozillaBootstrap,
        'ember2_defaults': ember2DefaultsApplied,
        'ember_en_default': emberEnDefaultApplied,
        'transport_pinned': transportPinned,
        'fallback_chain_enabled': fallbackChainEnabled,
        'fallback_chain': fallbackChain,
        'ember_auto_connect': emberAutoConnect,
        'auto_connect_boot': autoConnectOnBoot,
        'auto_connect_untrusted_wifi': autoConnectOnUntrustedWifi,
        'auto_connect_network_change': autoConnectOnNetworkChange,
        'trusted_ssids': trustedSsids,
      });
    } on FileSystemException {
      // Not fatal: the choice holds until the app quits.
    }
  }
}
