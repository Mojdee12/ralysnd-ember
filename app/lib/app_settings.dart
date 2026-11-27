import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'atomic_json_store.dart';
import 'core/android_core.dart';

/// What the window's close button does.
enum CloseAction { ask, tray, quit }

/// The app's own preferences (language, theme, close button), kept in
/// `app-settings.json` in the data folder beside the core's files. The VPN
/// settings belong to the core.
/// Build 2095 (feature 4 — custom multi-hop chains): one
/// saved chain entry. Hop 1 is an underlay ENGINE (the only
/// first hops the chain machinery supports); hop 2 is the
/// exit config. Validation lives in
/// [validateChainEntry] (chain_builder_page.dart).
class ChainEntry {
  ChainEntry({required this.name, required this.underlay, required this.profileId});

  String name;
  String underlay;
  String profileId;

  Map<String, Object?> toJson() => {
    'name': name,
    'underlay': underlay,
    'profileId': profileId,
  };

  static ChainEntry? fromJson(Object? j) {
    if (j is! Map) return null;
    final name = j['name'];
    final underlay = j['underlay'];
    final profileId = j['profileId'];
    if (name is! String || underlay is! String || profileId is! String) {
      return null;
    }
    return ChainEntry(name: name, underlay: underlay, profileId: profileId);
  }
}

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

  /// Build 2095 (feature 13 — update channels): 'stable'
  /// reads the repo's latest release; 'beta' reads the
  /// newest release including pre-releases. Default stable.
  String updateChannel = 'stable';

  /// Build 2095 (feature 7 — session data budget): per-
  /// session cap in megabytes; 0 = off. The shell warns at
  /// 80% and disconnects at the cap.
  int sessionBudgetMb = 0;

  /// Build 2095 (feature 4): saved multi-hop chain entries.
  List<ChainEntry> chains = [];

  /// Starts the app in the tray when the user signs in to Windows; on
  /// unless the user turned it off.
  bool autostart = true;

  /// Connects by itself when started with the computer ([autostart]); off
  /// until the user turns it on. The core decides how (Daemon.AutoConnect).
  bool autoConnect = false;

  /// The home page's card when TUN mode refused a program's call or game
  /// (UDP); on unless the user turned it off. Build 2114
  /// (defaults reset): default OFF — an Ember extra; the
  /// defaultsReset2114 migration in the load below moves a
  /// stored on to OFF once. A value set afterwards is kept.
  bool udpNotice = false;

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

  /// Build 2112: the one-time upstream-connections pin has
  /// run: the Mozilla core's proxy.upstream_connections was
  /// raised once from the shipped 1 (the core's desktop
  /// default — one H2 session carrying the whole phone) to 4.
  /// An install's saved core config holds 1, so the core's
  /// own raised Default() never reaches it. After this flag
  /// is set, the core config owns the value again.
  bool upstreamConnectionsPinned = false;

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

  /// Build 2075: when the in-app updater last checked the
  /// GitHub Releases feed (epoch ms). The launch auto-check is
  /// throttled to once per 24 h against this stamp.
  int lastEmberUpdateCheckMs = 0;

  /// Build 2075 (feature item 11): the app lock's PIN, stored
  /// only as its SHA-256 hex (the tree's pure-Dart sha256Hex).
  /// '' = no lock. The lock screen gates the app at launch.
  String appLockPinHash = '';

  bool get appLockEnabled => appLockPinHash.isNotEmpty;

  /// Build 2077 (feature queue #7, biometric half): unlock
  /// with the device's fingerprint or face instead of typing
  /// the PIN. Only a preference — the PIN always still works,
  /// so a biometric failure, cancel or lockout can never
  /// strand the user out of the app. Forced off whenever the
  /// PIN is cleared (see update()).
  bool appLockBiometric = false;

  /// Build 2096 (post-2095 audit M9): the lock page's
  /// failed-attempt count and cooldown deadline persist
  /// here — build 2095 kept them in the lock page's
  /// State, so recreating the page (rotation, process
  /// death, re-lock) reset both and the cooldown could
  /// be waited out by recreating the page.
  int appLockFailedAttempts = 0;
  int appLockCooldownUntilMs = 0;

  /// Build 2075 (feature item 20): multi-device sync through
  /// the owner's own GitHub — a personal access token he
  /// pastes (stored here like a subscription URL: app-private
  /// settings, never logged), the gist holding the encrypted
  /// backup, and the last successful sync stamp.
  String syncGithubToken = '';

  /// Build 2125 (audit A25-56 / P-60): true when the last
  /// vault write for the sync token FAILED. The settings
  /// document no longer carries the token, so a failed
  /// Keystore write used to lose it silently — the result
  /// was discarded at the update() call site. The Sync page
  /// reads this flag and tells the user to re-paste.
  bool syncTokenVaultWriteFailed = false;
  String syncGistId = '';

  /// Build 2116 (E-7): the loaded document still carried
  /// the sync token in plaintext (a pre-2116 store) — the
  /// load-time migration's trigger. The token's home is
  /// the Keystore vault now; this document never writes
  /// it again (see toJson).
  bool _legacySyncTokenPresent = false;
  int syncLastMs = 0;
  // Build 2116 (B9-2): the three auto-connect triggers
  // default OFF — they shipped default-ON and were left
  // out of the 2114 reset, so one tap on the auto-connect
  // master armed boot/Wi-Fi/network-change connects
  // nobody chose. The defaultsReset2116 migration below
  // moves a stored ON to OFF once; a value set afterwards
  // is kept.
  bool autoConnectOnBoot = false;
  bool autoConnectOnUntrustedWifi = false;
  bool autoConnectOnNetworkChange = false;

  /// Set once the build-2116 defaults reset has run on
  /// this store (the three triggers above). In-memory
  /// true: a fresh install has nothing to migrate.
  bool defaultsReset2116 = true;

  /// Launcher shortcuts (build 2093): the starred configs are
  /// published as long-press app-icon shortcuts while this is on;
  /// off removes them. On by default until build 2114
  /// (defaults reset): default OFF — an Ember extra; the
  /// defaultsReset2114 migration in the load below moves a
  /// stored on to OFF once. A value set afterwards is kept.
  bool launcherShortcutsEnabled = false;

  /// Set once the build-2114 defaults reset has run on this
  /// store: udpNotice and launcherShortcutsEnabled shipped
  /// default-ON and are written on every save, so a stored on
  /// cannot be told apart from the shipped default — both
  /// move to OFF exactly once (see the load below). In-memory
  /// true: a fresh install has nothing to migrate.
  bool defaultsReset2114 = true;

  /// Build 2105 (Mozilla feature 1): on the sign-in dialog's
  /// failure screen, offer "Sign in with browser instead" as the
  /// remedy for a refused native sign-in. The browser route
  /// itself is shipped behaviour (the dialog's primary button
  /// since 2033) and is not gated; only this new failure-screen
  /// offer is. Default OFF — off, the failure screen is exactly
  /// the pre-2105 one (Try again / Close).
  bool signinBrowserFallbackOffer = false;

  /// Build 2105: the battery usage report. When on, each engine
  /// session's start/end battery levels are recorded
  /// (battery_report.dart) and the report page attributes the
  /// device drain of each session window to the engine that was
  /// connected — an estimate, labelled as one in the product.
  /// Default OFF — off, nothing is recorded.
  bool batteryReportEnabled = false;
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

  /// Build 2095 (third-pass audit 1.3): the load-time
  /// damage surface — the settings file was torn and has
  /// been quarantined; the app started from defaults
  /// (which include NO app lock and NO sync token, so the
  /// user must hear about it, not discover it).
  bool storeDamaged = false;

  /// Build 2095 (audit 1.3): the last save's failure, if
  /// any — a disk-full settings save is no longer invisible.
  Object? saveError;

  /// Build 2096 (post-2095 audit M14): the settings file
  /// exists but could not be read ('unreadable' — the
  /// atomic store distinguishes it from 'damaged', where
  /// the torn bytes are quarantined, and from absent).
  /// The intact file must never be overwritten by a
  /// defaults save, so every save is refused while this
  /// holds; the damage surface (storeDamaged) tells the
  /// user at start.
  bool storeUnreadable = false;

  static Future<AppSettings> load(String dataDir) async {
    final s = AppSettings(
      file: File('$dataDir${Platform.pathSeparator}app-settings.json'),
    );
    try {
      // Build 2095 (audit 1.3): read through the atomic
      // store — a torn file is quarantined to .corrupt
      // instead of being silently overwritten by the next
      // update() with defaults.
      final store = AtomicJsonStore(s.file!);
      s._store = store;
      final j = await store.read();
      // Build 2097 (post-2096 audit L-c/C-L10): 'damaged'
      // and 'unreadable' are distinct states with distinct
      // user copy — build 2096 set storeDamaged for BOTH,
      // so an intact-but-unreadable file was announced as
      // "damaged, did not survive".
      if (store.lastReadProblem == 'damaged') s.storeDamaged = true;
      if (j == null && store.lastReadProblem == 'unreadable') {
        // Build 2096 (post-2095 audit M14): an intact but
        // unreadable file is NOT a first run — build 2095
        // fell into the branch below, and the first save
        // overwrote the original (PIN hash, sync token,
        // everything) with defaults, no .corrupt copy.
        // Now: defaults in memory, damage surfaced, and
        // _save refuses to write over the original.
        s.storeUnreadable = true;
        s.emberEnDefaultApplied = true;
      }
      if (j == null && store.lastReadProblem != 'unreadable') {
        // No document: the pre-2095 read threw
        // FileSystemException here and the catch below
        // set the first-run state; the atomic store
        // reports absence as null instead, so the same
        // state is set explicitly (build 2095 fix — the
        // app_settings_test defaults/saves pins caught
        // the migration re-firing on a first save).
        s.firstRun = true;
        s.emberEnDefaultApplied = true;
      }
      if (j != null) {
        await s._decode(j.cast<String, Object?>());
        // Build 2116 (E-7): the sync token's migration to
        // the Keystore vault. The vault's value wins when
        // one exists; a plaintext token from a pre-2116
        // store is sealed into the vault, and only once it
        // is sealed (or already there) is the document
        // rewritten without the key — the plaintext is
        // never deleted before its replacement exists.
        final sealedToken = await SecretStore.load('sync_github_token');
        if (sealedToken != null) s.syncGithubToken = sealedToken;
        if (s._legacySyncTokenPresent) {
          var sealed = sealedToken != null;
          if (!sealed && s.syncGithubToken.isNotEmpty) {
            sealed = await SecretStore.store(
              'sync_github_token',
              s.syncGithubToken,
            );
          }
          if (sealed) await s._save();
        }
        if (!s.emberEnDefaultApplied) {
          // One-time 2006 migration: English is the default
          // language. Builds up to 2005 shipped 'fa' as the
          // baked-in default, so a stored 'fa' was the
          // default, not a choice; reset it once and persist,
          // after which the picker owns the value.
          s.language = 'en';
          s.emberEnDefaultApplied = true;
          await s._save();
        }
      }
    } on FileSystemException {
      // First run: defaults, and the welcome page.
      s.firstRun = true;
      s.emberEnDefaultApplied = true;
    }
    return s;
  }


  /// Build 2095 (V2Ray journey audit #15): the store
  /// decode, extracted verbatim from load() so a backup
  /// restore can apply an app-settings document to the
  /// LIVE settings object through the same tolerant
  /// reader. Fields a document does not carry keep the
  /// load-time defaulting rules (a real backup carries
  /// the full document toJson() writes).
  Future<void> _decode(Map<String, Object?> j) async {
      if (j['language'] case final String l
          when supportedLanguages.contains(l)) {
        language = l;
      }
      // Build 2096 (post-2095 audit L33): a PARTIAL
      // document (a hand-made restore, an older backup)
      // must not reset fields it does not carry to a
      // reader-side fallback — build 2095's decode sent
      // an absent 'theme' to ThemeMode.system (the app
      // default is dark) and an absent 'welcome_done'
      // re-armed the first run. Absent keys now keep the
      // field's current (default) value.
      if (j['theme'] case final String t) {
        // A PRESENT but unknown value keeps the legacy
        // tolerance (system — the value may come from a
        // newer build); only the ABSENT key changed
        // behaviour in 2096 (it keeps the dark default).
        themeMode =
            ThemeMode.values.asNameMap()[t] ?? ThemeMode.system;
      }
      closeAction =
          CloseAction.values.asNameMap()[j['close']] ?? CloseAction.ask;
      if (j.containsKey('welcome_done')) {
        firstRun = j['welcome_done'] != true;
      }
      showPublicIp = j['show_public_ip'] == true;
      if (j['dismissed_update'] case final String v) dismissedUpdate = v;
      if (j['update_version'] case final String v) updateVersion = v;
      if (j['update_url'] case final String v) updateUrl = v;
      updateCheckedAt = switch (j['update_checked_at']) {
        final String t => DateTime.tryParse(t),
        _ => null,
      };
      lowQuotaDismissedAt = switch (j['low_quota_dismissed_at']) {
        final String t => DateTime.tryParse(t),
        _ => null,
      };
      autostart = j['autostart'] != false;
      autoConnect = j['auto_connect'] == true;
      autoUpdate = j['auto_update'] != false;
      if (j['update_channel'] case final String v) {
        updateChannel = v == 'beta' ? 'beta' : 'stable';
      }
      if (j['session_budget_mb'] case final int v) {
        sessionBudgetMb = v < 0 ? 0 : v;
      }
      if (j['chains'] case final List v) {
        chains = [
          for (final e in v)
            if (ChainEntry.fromJson(e) case final c?) c,
        ];
      }
      // Build 2119 (audit F-10): an ABSENT key reads OFF.
      // Up to 2118 this read `!= false` — absent meant ON —
      // and only the 2114 reset block below neutralised
      // stored documents; a crafted partial document
      // carrying the reset flag but no key re-armed the
      // notice. A stored true (set by the owner after the
      // reset) is still honoured.
      udpNotice = j['udp_notice'] == true;
      if (j['hidden_connection_columns'] case final List<Object?> v) {
        hiddenConnectionColumns = {...v.whereType<String>()};
      }
      if (j['ember_mode'] case final int v) {
        // 2024: Lantern is back as mode 3 (its pre-2023 stored
        // values are valid again); WARP (4) stays gone. A stored
        // mode pointing outside the valid range falls back to
        // Mozilla, never a crash or a dead page. Build 2156:
        // URnetwork joins as mode 8. (The fallback chain below
        // stays 0..7 — the chain editor offers the classic
        // engines only.)
        emberMode = v >= 0 && v <= 8 ? v : 0;
      }
      if (j['mozilla_bootstrap'] case final String v
          when bootstrapChoices.contains(v)) {
        mozillaBootstrap = v;
      }
      ember2DefaultsApplied = j['ember2_defaults'] == true;
      transportPinned = j['transport_pinned'] == true;
      upstreamConnectionsPinned = j['upstream_connections_pinned'] == true;
      fallbackChainEnabled = j['fallback_chain_enabled'] == true;
      if (j['fallback_chain'] case final List<Object?> v) {
        final chain = v
            .whereType<int>()
            .where((m) => m >= 0 && m <= 7)
            .toList();
        if (chain.isNotEmpty) fallbackChain = chain;
      }
      emberAutoConnect = j['ember_auto_connect'] == true;
      if (j['ember_update_checked_ms'] case final int v) {
        lastEmberUpdateCheckMs = v;
      }
      if (j['app_lock_pin_hash'] case final String v) {
        appLockPinHash = v;
      }
      // Build 2077: a wrong-typed stored value reads false
      // (the same tolerance as every other bool here) — a
      // corrupt store can never enable biometrics by itself.
      // Build 2096 (post-2095 audit L31): the PIN guard
      // update() enforces applies here too — a RESTORED
      // document (whose PIN hash was stripped from the
      // backup, so the live hash above survives) must not
      // enable biometric unlock when no PIN exists to
      // fall back to.
      appLockBiometric =
          j['app_lock_biometric'] == true && appLockPinHash.isNotEmpty;
      if (j['app_lock_failed_attempts'] case final int v) {
        appLockFailedAttempts = v;
      }
      if (j['app_lock_cooldown_until_ms'] case final int v) {
        appLockCooldownUntilMs = v;
      }
      // Build 2116 (E-7): a pre-2116 document may still
      // carry the token in plaintext — load() migrates it
      // to the Keystore vault and purges the key.
      _legacySyncTokenPresent = j.containsKey('sync_github_token');
      if (j['sync_github_token'] case final String v) {
        syncGithubToken = v;
      }
      if (j['sync_gist_id'] case final String v) {
        syncGistId = v;
      }
      if (j['sync_last_ms'] case final int v) {
        syncLastMs = v;
      }
      autoConnectOnBoot = j['auto_connect_boot'] == true;
      autoConnectOnUntrustedWifi =
          j['auto_connect_untrusted_wifi'] == true;
      autoConnectOnNetworkChange =
          j['auto_connect_network_change'] == true;
      // Build 2116 (B9-2) defaults reset, the 2114 block's
      // pattern: the three triggers shipped default-ON and
      // are written on every save, so a stored ON cannot
      // be told apart from the shipped default — all three
      // move to OFF exactly once. A value set afterwards
      // is kept.
      defaultsReset2116 = j['defaults_reset_2116'] == true;
      if (!defaultsReset2116) {
        autoConnectOnBoot = false;
        autoConnectOnUntrustedWifi = false;
        autoConnectOnNetworkChange = false;
        defaultsReset2116 = true;
      }
      // Build 2119 (audit F-10): absent reads OFF, as
      // with udp_notice above.
      launcherShortcutsEnabled = j['launcher_shortcuts'] == true;
      // Build 2114 defaults reset (defaults audit 2026-11-19):
      // udp_notice and launcher_shortcuts shipped default-ON
      // and are written on every save, so a stored on is the
      // shipped default, not a discernible choice — both move
      // to OFF once, here, after both fields have been read
      // above. A value set afterwards is kept.
      defaultsReset2114 = j['defaults_reset_2114'] == true;
      if (!defaultsReset2114) {
        udpNotice = false;
        launcherShortcutsEnabled = false;
        defaultsReset2114 = true;
      }
      // Build 2105: absent keys keep the OFF defaults (a
      // pre-2105 store must not grow either feature by itself).
      signinBrowserFallbackOffer = j['signin_browser_fallback_offer'] == true;
      batteryReportEnabled = j['battery_report_enabled'] == true;
      if (j['trusted_ssids'] case final List<Object?> v) {
        trustedSsids = v.whereType<String>().toList();
      }
      if (j['ember_en_default'] == true) {
        emberEnDefaultApplied = true;
      }
  }

  /// Applies a restored app-settings document to this
  /// live object and persists it. The sync token and the
  /// lock PIN hash never ride a backup (the controller
  /// strips them), so those fields survive a restore
  /// untouched.
  Future<void> applyRestoredSettings(Map<String, Object?> j) async {
    // Build 2098 (post-2097 audit L11): never swap the
    // live settings when the store is UNREADABLE. The
    // in-memory object then holds defaults, not the user's
    // settings, so the overlay below would decode onto
    // defaults — and _save() refuses the write anyway
    // (M14), leaving the session running on
    // restored-over-defaults values while the real file
    // still holds the user's settings, with callers (the
    // gist pull) stamping a success that never landed.
    // Refuse up front, like importBackup refuses a
    // protected store; the pull's stamp is gated on this
    // call completing, so it stays honest too.
    if (storeUnreadable) {
      throw StateError(
        'The settings file could not be read, so the '
        'restore was not applied.',
      );
    }
    // Build 2097 (post-2096 audit C8): the decode no longer
    // runs bare against the live object. Two failure
    // shapes are closed:
    //  (1) a PARTIAL backup silently reset live settings —
    //      _decode's load-time rules assign fallbacks for
    //      keys a document does not carry (autostart back
    //      ON, the close action back to ask), and the
    //      result was persisted. The backup now decodes as
    //      an OVERLAY on the current document: keys the
    //      backup carries win, keys it lacks keep their
    //      live values. (The stripped PIN/token keys keep
    //      the live values the same way, as before.)
    //  (2) a decode that throws midway left a half-applied
    //      object for the save to persist. The live
    //      document is snapshotted first; a throw restores
    //      it and nothing is saved.
    final before = toJson();
    try {
      await _decode({...before, ...j});
    } catch (_) {
      await _decode(before);
      rethrow;
    }
    // Build 2096 (post-2095 audit M13): a restored
    // document's language is a CHOICE the user just made,
    // not a pre-2006 baked default — mark the migration
    // applied so the next launch's load() does not treat
    // the restored file as unmigrated and silently reset
    // the language to English.
    emberEnDefaultApplied = true;
    notifyListeners();
    await _save();
    // Build 2097 (post-2096 audit L-d): a successful
    // restore retires the damage surface — the settings
    // are whole again, and build 2096 left the "damaged"
    // panel up forever after exactly this recovery.
    if (saveError == null) storeDamaged = false;
  }
  Future<void> update({
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
    String? updateChannel,
    int? sessionBudgetMb,
    List<ChainEntry>? chains,
    bool? udpNotice,
    Set<String>? hiddenConnectionColumns,
    int? emberMode,
    String? mozillaBootstrap,
    bool? ember2DefaultsApplied,
    bool? emberEnDefaultApplied,
    bool? transportPinned,
    bool? upstreamConnectionsPinned,
    bool? fallbackChainEnabled,
    List<int>? fallbackChain,
    bool? emberAutoConnect,
    bool? autoConnectOnBoot,
    bool? autoConnectOnUntrustedWifi,
    bool? autoConnectOnNetworkChange,
    bool? launcherShortcutsEnabled,
    bool? signinBrowserFallbackOffer,
    bool? batteryReportEnabled,
    List<String>? trustedSsids,
    int? lastEmberUpdateCheckMs,
    String? appLockPinHash,
    bool? appLockBiometric,
    int? appLockFailedAttempts,
    int? appLockCooldownUntilMs,
    String? syncGithubToken,
    String? syncGistId,
    int? syncLastMs,
  }) async {
    this.fallbackChainEnabled =
        fallbackChainEnabled ?? this.fallbackChainEnabled;
    this.fallbackChain = fallbackChain ?? this.fallbackChain;
    this.emberAutoConnect = emberAutoConnect ?? this.emberAutoConnect;
    this.autoConnectOnBoot = autoConnectOnBoot ?? this.autoConnectOnBoot;
    this.autoConnectOnUntrustedWifi =
        autoConnectOnUntrustedWifi ?? this.autoConnectOnUntrustedWifi;
    this.autoConnectOnNetworkChange =
        autoConnectOnNetworkChange ?? this.autoConnectOnNetworkChange;
    this.launcherShortcutsEnabled =
        launcherShortcutsEnabled ?? this.launcherShortcutsEnabled;
    this.signinBrowserFallbackOffer =
        signinBrowserFallbackOffer ?? this.signinBrowserFallbackOffer;
    this.batteryReportEnabled =
        batteryReportEnabled ?? this.batteryReportEnabled;
    this.trustedSsids = trustedSsids ?? this.trustedSsids;
    this.lastEmberUpdateCheckMs =
        lastEmberUpdateCheckMs ?? this.lastEmberUpdateCheckMs;
    this.appLockPinHash = appLockPinHash ?? this.appLockPinHash;
    // Build 2077: biometrics only ever ride on a PIN — with
    // no PIN there is no lock, so a cleared PIN clears the
    // biometric preference in the same update, and a biometric
    // request against a PIN-less store stays off.
    this.appLockBiometric =
        (appLockBiometric ?? this.appLockBiometric) &&
        this.appLockPinHash.isNotEmpty;
    this.appLockFailedAttempts =
        appLockFailedAttempts ?? this.appLockFailedAttempts;
    this.appLockCooldownUntilMs =
        appLockCooldownUntilMs ?? this.appLockCooldownUntilMs;
    this.syncGithubToken = syncGithubToken ?? this.syncGithubToken;
    this.syncGistId = syncGistId ?? this.syncGistId;
    this.syncLastMs = syncLastMs ?? this.syncLastMs;
    this.mozillaBootstrap = mozillaBootstrap ?? this.mozillaBootstrap;
    this.emberMode = emberMode ?? this.emberMode;
    this.transportPinned = transportPinned ?? this.transportPinned;
    this.upstreamConnectionsPinned =
        upstreamConnectionsPinned ?? this.upstreamConnectionsPinned;
    this.emberEnDefaultApplied =
        emberEnDefaultApplied ?? this.emberEnDefaultApplied;
    this.ember2DefaultsApplied =
        ember2DefaultsApplied ?? this.ember2DefaultsApplied;
    this.hiddenConnectionColumns =
        hiddenConnectionColumns ?? this.hiddenConnectionColumns;
    this.udpNotice = udpNotice ?? this.udpNotice;
    this.autoUpdate = autoUpdate ?? this.autoUpdate;
    this.updateChannel = updateChannel ?? this.updateChannel;
    this.sessionBudgetMb = sessionBudgetMb ?? this.sessionBudgetMb;
    this.chains = chains ?? this.chains;
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
    // Build 2116 (E-7): a token change writes through to
    // the Keystore vault — the settings document no
    // longer carries it (see toJson), so this is the only
    // persistence the token has. Build 2119 (audit F-23):
    // the write is AWAITED — up to 2118 it was fire-and-
    // forget, so a process kill in the window lost the
    // token the settings change had just accepted.
    // update() is async for this alone: every field write,
    // the notify and _save() above still run synchronously
    // before the first await, so existing callers observe
    // no timing change.
    if (syncGithubToken != null) {
      if (this.syncGithubToken.isEmpty) {
        await SecretStore.delete('sync_github_token');
        if (syncTokenVaultWriteFailed) {
          syncTokenVaultWriteFailed = false;
          notifyListeners();
        }
      } else {
        // Build 2125 (audit A25-56 / P-60): the vault
        // write's result is no longer discarded — a failed
        // write persists the token NOWHERE (the document
        // dropped it in 2116), so the failure is recorded
        // for the Sync page to surface instead of the token
        // vanishing silently at the next launch.
        final stored = await SecretStore.store(
          'sync_github_token',
          this.syncGithubToken,
        );
        final failed = !stored;
        if (failed != syncTokenVaultWriteFailed) {
          syncTokenVaultWriteFailed = failed;
          notifyListeners();
        }
      }
    }
  }

  /// The settings document (build 2095, V2Ray journey
  /// audit #15): the exact map _save persists, exposed so a
  /// backup can carry the app settings. Callers embedding
  /// it in a backup must strip the secret keys first (the
  /// XrayController backup path does).
  Map<String, Object?> toJson() => {
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
        'update_channel': updateChannel,
        'session_budget_mb': sessionBudgetMb,
        'chains': [for (final c in chains) c.toJson()],
        'udp_notice': udpNotice,
        'hidden_connection_columns': hiddenConnectionColumns.toList(),
        'ember_mode': emberMode,
        'mozilla_bootstrap': mozillaBootstrap,
        'ember2_defaults': ember2DefaultsApplied,
        'ember_en_default': emberEnDefaultApplied,
        'transport_pinned': transportPinned,
        'upstream_connections_pinned': upstreamConnectionsPinned,
        'fallback_chain_enabled': fallbackChainEnabled,
        'fallback_chain': fallbackChain,
        'ember_auto_connect': emberAutoConnect,
        'ember_update_checked_ms': lastEmberUpdateCheckMs,
        'app_lock_pin_hash': appLockPinHash,
        'app_lock_biometric': appLockBiometric,
        'app_lock_failed_attempts': appLockFailedAttempts,
        'app_lock_cooldown_until_ms': appLockCooldownUntilMs,
        // Build 2116 (E-7): no 'sync_github_token' key —
        // the token lives in the Keystore vault, never in
        // this document (backups strip it too, as before).
        'sync_gist_id': syncGistId,
        'sync_last_ms': syncLastMs,
        'auto_connect_boot': autoConnectOnBoot,
        'auto_connect_untrusted_wifi': autoConnectOnUntrustedWifi,
        'auto_connect_network_change': autoConnectOnNetworkChange,
        'launcher_shortcuts': launcherShortcutsEnabled,
        'defaults_reset_2114': defaultsReset2114,
        'defaults_reset_2116': defaultsReset2116,
        'signin_browser_fallback_offer': signinBrowserFallbackOffer,
        'battery_report_enabled': batteryReportEnabled,
        'trusted_ssids': trustedSsids,
      };

  /// The shared atomic store for this file (build 2054, audit
  /// F-H8), created once so every write for this file goes
  /// through one serialization chain. Writes are fire-and-
  /// forget from update(), so serialization is what keeps two
  /// quick setting changes from interleaving bytes.
  AtomicJsonStore? _store;

  Future<void> _save() async {
    final f = file;
    if (f == null) return;
    // Build 2096 (post-2095 audit M14): never overwrite
    // an intact-but-unreadable settings file with the
    // in-memory defaults.
    if (storeUnreadable) {
      // Build 2097 (post-2096 audit L-c): one re-check
      // before refusing — if the unreadable file has since
      // DISAPPEARED (removed by the user or the system),
      // there is no original left to protect and saves may
      // resume. If it is still there — readable or not —
      // the refusal stands: a readable document this
      // session never decoded must not be overwritten by
      // the in-memory defaults either.
      if (!await f.exists()) {
        storeUnreadable = false;
      } else {
        saveError = 'settings file unreadable — saves are '
            'paused so the original is not overwritten';
        return;
      }
    }
    try {
      // Build 2054 (audit F-H8): tmp + flush + rename through
      // the shared store — the old direct writeAsString could
      // tear the file mid-save and silently reset every setting
      // on the next launch.
      _store ??= AtomicJsonStore(f);
      await _store!.write(toJson());
      // Build 2095 (audit 1.3): the write never throws —
      // its failure lives in lastWriteError; surface it.
      saveError = _store!.lastWriteError;
    } on FileSystemException {
      // Not fatal: the choice holds until the app quits.
    }
  }
}
