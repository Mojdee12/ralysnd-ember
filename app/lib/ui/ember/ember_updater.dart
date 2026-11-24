/// Build 2075: Ember's own in-app updater (Android).
///
/// The feed is the app's public GitHub Releases page
/// (Mojdee12/ralysnd-ember) — the same place the owner now
/// publishes every build. This replaces the inherited upstream
/// checker (build 2071 disabled it on Android: it polled the
/// armanlife/firefox-vpn-client repo and could offer a foreign
/// "Firefox-VPN" update). The desktop entry keeps its own
/// Updates flow; this module is Android-only and is started
/// from runAndroid.
///
/// Behaviour: a silent auto-check once per 24 h (throttled by
/// AppSettings.lastEmberUpdateCheckMs), a manual "Check for
/// updates" row in Settings, and — when a newer build exists —
/// a download with progress into the app's own files dir,
/// then the system installer via AndroidCore.installApk.
/// Every failure surfaces as a plain sentence, never raw
/// exception text (the detail is the caller's to log).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../../app_info.dart';
import '../../app_settings.dart';
import '../../core/android_core.dart';
import '../../xray/sha256.dart';

/// The release feed: the latest release of the app's own repo.
const emberUpdateFeedUrl =
    'https://api.github.com/repos/Mojdee12/ralysnd-ember/releases/latest';

/// The asset every release ships.
const emberUpdateAssetName = 'RalysndEmber2.apk';

/// The build number a release tag names: 'v2075' → 2075.
/// Tolerates a bare '2075' and a 'v2.2.0+2075' shape; anything
/// else is not a build tag and returns null.
int? buildFromReleaseTag(String tag) {
  var t = tag.trim();
  if (t.startsWith('v') || t.startsWith('V')) t = t.substring(1);
  final plus = t.lastIndexOf('+');
  if (plus >= 0) t = t.substring(plus + 1);
  if (t.isEmpty || t.length > 9) return null;
  return int.tryParse(t);
}

/// The semantic version a release tag names, when it names
/// one: 'v2.3.0' → '2.3.0', 'v2.3.0-beta.1' → '2.3.0-beta.1'.
/// Returns null for build tags ('v2075', 'v2.2.0+2075' —
/// [buildFromReleaseTag]'s shapes) and for anything that is
/// not a plain major.minor.patch version with an optional
/// pre-release suffix. Build 2127 (audit A26-21): a release
/// published under a pure semver tag used to be invisible
/// to the updater — [buildFromReleaseTag] returned null and
/// the parse dropped the release entirely. A semver tag
/// still cannot be COMPARED with this app's build numbers,
/// so a release carrying one is offered as uncomparable
/// (see [EmberRelease.uncomparable]), never as newer.
String? semverFromReleaseTag(String tag) {
  var t = tag.trim();
  if (t.startsWith('v') || t.startsWith('V')) t = t.substring(1);
  if (t.contains('+')) return null; // a build-tag shape, not pure semver
  if (!RegExp(r'^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$').hasMatch(t)) {
    return null;
  }
  return t;
}

/// One parsed entry of the update feed.
class EmberRelease {
  const EmberRelease({
    required this.tag,
    required this.build,
    required this.name,
    required this.notes,
    required this.apkUrl,
    required this.apkSize,
    this.apkDigest = '',
  });

  final String tag;

  /// The build number the tag names, or NULL for a pure
  /// semver tag ('v2.3.0' — build 2127, audit A26-21): such
  /// a release is VISIBLE but uncomparable (see
  /// [uncomparable]); it is never newer than anything.
  final int? build;
  final String name;
  final String notes;
  final String apkUrl;
  final int apkSize;

  /// The feed's SHA-256 for the APK asset (the GitHub asset
  /// `digest`, `sha256:`-prefixed hex), normalized to bare
  /// lowercase hex; '' when the feed carries none (build
  /// 2116, AB-07 — until now the size was the only
  /// integrity check).
  final String apkDigest;

  /// True when the release's tag carries no build number
  /// (build 2127, A26-21): the offer is shown with words
  /// that say it cannot be compared, and only a deliberate
  /// tap installs it — no automatic path treats it as an
  /// update.
  bool get uncomparable => build == null;

  bool isNewerThan(int currentBuild) =>
      build != null && build! > currentBuild;
}

/// Parses the GitHub "latest release" JSON. Returns null when
/// the payload is not a usable release (a tag that is neither
/// a build tag nor a pure semver tag, or no
/// [emberUpdateAssetName] asset) — the caller treats that as
/// "no update information", never as an update. A pure semver
/// tag parses with a null [EmberRelease.build] (build 2127,
/// A26-21): visible, uncomparable, never newer.
EmberRelease? parseLatestRelease(Object? json) {
  if (json is! Map) return null;
  final tag = json['tag_name'];
  if (tag is! String) return null;
  final build = buildFromReleaseTag(tag);
  // Build 2127 (A26-21): a pure semver tag parses with a
  // null build (an uncomparable offer) instead of dropping
  // the release; a tag that is neither shape stays unusable.
  if (build == null && semverFromReleaseTag(tag) == null) return null;
  final assets = json['assets'];
  if (assets is! List) return null;
  String? apkUrl;
  var apkSize = 0;
  var apkDigest = '';
  for (final a in assets) {
    if (a is Map && a['name'] == emberUpdateAssetName) {
      final url = a['browser_download_url'];
      if (url is String && url.isNotEmpty) {
        apkUrl = url;
        final size = a['size'];
        if (size is int) apkSize = size;
        final digest = a['digest'];
        if (digest is String) {
          apkDigest = digest.toLowerCase().startsWith('sha256:')
              ? digest.substring(7).toLowerCase()
              : digest.toLowerCase();
        }
      }
    }
  }
  if (apkUrl == null) return null;
  final name = json['name'];
  final body = json['body'];
  return EmberRelease(
    tag: tag,
    build: build,
    name: name is String && name.isNotEmpty
        ? name
        : build != null
        ? 'Build $build'
        : 'Release $tag',
    notes: body is String ? body : '',
    apkUrl: apkUrl,
    apkSize: apkSize,
    apkDigest: apkDigest,
  );
}

/// Build 2095 (feature 13 — update channels): parses the
/// GitHub releases LIST (the Beta channel's feed) and
/// returns the newest entry that carries the APK asset.
/// Drafts are invisible to an unauthenticated reader, so
/// Beta sees published releases and pre-releases only.
EmberRelease? parseNewestRelease(Object? json) {
  if (json is! List) return null;
  EmberRelease? best;
  EmberRelease? firstUncomparable;
  for (final entry in json) {
    final r = parseLatestRelease(entry);
    if (r == null) continue;
    // Build 2127 (A26-21): an uncomparable (semver-tagged)
    // release never outranks a numbered one — it is kept
    // only as the fallback when the list carries no build
    // tag at all, in feed order (newest first).
    if (r.uncomparable) {
      firstUncomparable ??= r;
      continue;
    }
    if (best == null || r.build! > best.build!) best = r;
  }
  return best ?? firstUncomparable;
}

/// The feed URL for a channel (feature 13).
String emberUpdateFeedUrlFor(String channel) => channel == 'beta'
    ? 'https://api.github.com/repos/$githubRepo/releases?per_page=10'
    : emberUpdateFeedUrl;

/// Build 2125 (audit A25-49 / P-53): whether an update
/// URL may be followed at all. The asset URL is data from
/// the feed document — up to 2124 it was followed
/// anywhere, over any scheme, and the digest that "verified"
/// the download came from the SAME document, so a feed
/// answer that was not GitHub's (a captive portal, a
/// hijacked route) controlled both the bytes and their
/// expected hash. Downloads are now followed only over
/// HTTPS to GitHub's own hosts: github.com itself and the
/// release-asset hosts (*.githubusercontent.com, incl.
/// objects.githubusercontent.com, where asset downloads
/// redirect). The feed URL itself is a compile-time
/// constant on api.github.com and needs no check.
bool emberUpdateUrlAllowed(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.scheme != 'https') return false;
  final host = uri.host.toLowerCase();
  return host == 'github.com' ||
      host == 'objects.githubusercontent.com' ||
      host.endsWith('.githubusercontent.com');
}

/// Build 2129 (leg 6, delta §6(b)): the INITIAL download
/// URL must do more than sit on a GitHub host — on
/// github.com its path must be THIS repo's own
/// release-asset shape:
/// `/Mojdee12/ralysnd-ember/releases/download/<tag>/RalysndEmber2*.apk`
/// A feed answer pointing at another repo's asset, or at
/// any other github.com path, is refused before a byte is
/// fetched. The path rule applies ONLY here, to the
/// initial URL: redirect hops keep the host-only
/// [emberUpdateUrlAllowed], because GitHub's asset
/// redirects land on signed CDN URLs
/// (release-assets.githubusercontent.com/… with a
/// signature query) whose paths match no repo shape —
/// path-matching them would break every legitimate
/// download. The hops are still covered: host allowlist
/// per hop, the feed digest, and (build 2129) the
/// signing-cert check on the finished file.
bool emberUpdateInitialUrlAllowed(String url) {
  if (!emberUpdateUrlAllowed(url)) return false;
  final uri = Uri.tryParse(url);
  if (uri == null) return false;
  if (uri.host.toLowerCase() != 'github.com') return true;
  return RegExp(
    r'^/Mojdee12/ralysnd-ember/releases/download/[^/]+/RalysndEmber2[^/]*\.apk$',
  ).hasMatch(uri.path);
}

/// Build 2125 (audit A25-50 / P-54): the feed body cap.
/// The feed is a few KB of JSON; up to 2124 the body was
/// joined unbounded, so a hostile or broken endpoint
/// could grow the response until the process died. The
/// cap matches the sync reader's (16 MB) — far above any
/// real feed, far below a memory attack.
const emberUpdateFeedMaxBytes = 16 * 1024 * 1024;

/// Build 2126 (audit A26-25): the in-stream ceiling for
/// the APK body when the feed published no size (when it
/// did, the size itself is the ceiling). Up to 2125 the
/// over-long check ran only after the stream ENDED, so a
/// slow-drip endpoint could fill the storage before the
/// check ever fired. 512 MB is far above any real
/// release (the current APK is ~141 MB) and far below a
/// storage-fill attack.
const emberUpdateApkMaxBytes = 512 * 1024 * 1024;

enum EmberUpdateState {
  idle,
  checking,
  upToDate,
  available,
  downloading,
  downloaded,
  error,

  /// Build 2125 (audit A25-52 / P-56): the check completed
  /// but this app's own build number could not be read, so
  /// no comparison was possible. Distinct from upToDate —
  /// the old code reported an unresolvable build AS
  /// up-to-date, a false fact that also suppressed real
  /// updates behind it.
  unknownBuild,

  /// Build 2127 (audit A26-21): the feed's release is
  /// tagged with a pure semantic version, which cannot be
  /// compared with this app's build numbers. The release
  /// is VISIBLE — builds ≤2126 dropped it in the parse and
  /// reported no update information — with words that say
  /// it cannot be compared; installing it is a deliberate
  /// manual act, never an automatic offer.
  uncomparable,
}

/// The updater's observable state machine. One instance per
/// app run, created by [EmberUpdater.start] from runAndroid.
class EmberUpdater extends ChangeNotifier {
  EmberUpdater({
    required this.settings,
    required this.dataDir,
    HttpClient Function()? clientFactory,
    Future<String> Function(Uri url)? fetcher,
    this.stallTimeout = const Duration(seconds: 30),
    this.downloadStallTimeout = const Duration(seconds: 90),
  }) : _clientFactory = clientFactory ?? HttpClient.new,
       _fetcher = fetcher;

  final AppSettings settings;
  final String dataDir;
  final HttpClient Function() _clientFactory;
  final Future<String> Function(Uri url)? _fetcher;

  /// Test seam (the AetherController.dataProofBudget
  /// pattern): replaces the A25-49 download-URL policy for
  /// this instance, so the behavioural download tests can
  /// serve bytes from a local test server. Always null in
  /// production — the real policy is emberUpdateUrlAllowed.
  bool Function(String url)? urlPolicyOverride;

  /// Test seam (build 2129, leg 6 — the [urlPolicyOverride]
  /// pattern): replaces the platform signing-cert
  /// comparison for this instance, so the behavioural
  /// download tests can decide the verdict without an
  /// Android platform. Always null in production — the real
  /// check is [_signingCertMatches] over AndroidCore.
  Future<bool> Function(String apkPath)? certCheckOverride;

  /// Build 2098 (post-2097 audit L30): the idle limit for
  /// the feed streams — a response that connects and then
  /// goes silent must fail inside this window instead of
  /// wedging the updater (see _fetchFeedOnce). The download
  /// body carries its own, longer bound below.
  final Duration stallTimeout;

  /// The download's own idle bound (build 2098 verification
  /// V-4): the feed is a few KB and a 30 s silence there is
  /// fatal at no cost, but a ~148 MB APK on the networks this
  /// app serves legitimately gaps longer than 30 s — Wi-Fi to
  /// cell handover, a tunnel reconnect — and the download has
  /// no resume, so the feed's bound made such updates
  /// undownloadable. 90 s still closes the L30 wedge (a
  /// stalled download cannot sit in 'downloading' forever)
  /// without discarding a nearly-complete transfer for one
  /// long gap.
  final Duration downloadStallTimeout;

  /// Build 2098 (post-2097 audit §7, item U-A): resolves
  /// the app's own local HTTP proxy endpoint ('host:port')
  /// while a tunnel session is up, or null when none is.
  /// Wired by the shell, which owns the Xray controller —
  /// the updater is created before any controller exists.
  ///
  /// Why: the feed fetch used to connect DIRECTLY, always.
  /// The launch auto-check fires seconds after start,
  /// before any tunnel is up, and on a network that filters
  /// GitHub every direct attempt fails silently into a
  /// Settings-only state line — the owner's "the updater
  /// does not update" on builds 2096 and 2097. While a
  /// session IS up, the core's local HTTP inbound is a
  /// working route to GitHub through the tunnel, so the
  /// feed and the APK download try it first and fall back
  /// to direct (and vice versa) instead of failing outright.
  String? Function()? localProxyResolver;

  /// Build 2098 (verification V-3): the credentials the
  /// session's HTTP inbound demands, when it demands any —
  /// the same selection the config builder makes (the LAN
  /// login when ready, else the local-proxy login). Without
  /// them, a session with proxy authentication answered
  /// every proxied updater attempt with 407 and the U-A
  /// route failed on exactly the setups that enable auth.
  /// Null when the inbound is noauth (the default).
  ({String user, String pass})? Function()? localProxyCredentialsResolver;

  static EmberUpdater? instance;

  /// How often the launch auto-check may run.
  static const autoCheckEvery = Duration(hours: 24);

  EmberUpdateState state = EmberUpdateState.idle;
  EmberRelease? release;

  /// Build 2096 (post-2095 audit L11): the channel the
  /// cached [release] was fetched from — a channel switch
  /// invalidates the cache (see [noteChannelChanged]).
  String? _feedChannel;
  double progress = 0;

  /// Build 2126 (audit A26-27): bytes of the offered
  /// release already sitting in its kept .part on DISK,
  /// resolved by check() — the settings page's "Resume
  /// download" label reads this, not the in-memory
  /// [progress], so a part left by a previous process (or
  /// an errored attempt) offers Resume on sight.
  int resumableBytes = 0;
  String? downloadedPath;

  /// Whether the file at [downloadedPath] passed the
  /// feed's SHA-256 check (build 2119, audit F-11). A
  /// feed carrying no digest used to skip verification
  /// silently; the Install offer now says "unverified"
  /// for such a download instead of implying a check ran.
  bool downloadedVerified = false;
  String errorText = '';

  /// Build 2098 (Item C): the installed package's own
  /// versionCode, resolved from the platform during the
  /// first check — [currentBuild] IS this number since
  /// build 2106 (see its doc): the APP_BUILD dart-define
  /// is no longer consulted for the comparison at all,
  /// because its compiled-in default still names build
  /// 2071. The package's own number is stamped by Gradle
  /// from the pubspec and cannot go missing.
  int? packageBuild;

  /// This build's number — the package's own, or NULL when
  /// it could not be resolved. Build 2106 (journey audit
  /// F-09): the APP_BUILD define is no longer a fallback.
  /// Its compiled-in default still names build 2071, so
  /// builds ≤2105 compared every release against 2071
  /// whenever the platform call returned null — the
  /// updater would permanently offer (and try to install)
  /// an "update", including the very build already
  /// installed. Unknown means unknown: [check] offers
  /// nothing rather than comparing against a stale number.
  /// (The define still feeds the brand panel's display
  /// line, where a stale number is cosmetic, not a
  /// decision.)
  int? get currentBuild => packageBuild;

  /// Resolves [packageBuild] once from the platform.
  /// Failures keep it null — unknown (tests, and any
  /// platform without the call).
  Future<void> resolvePackageBuild() async {
    if (packageBuild != null) return;
    packageBuild = await AndroidCore.appBuildNumber();
  }

  bool get busy =>
      state == EmberUpdateState.checking ||
      state == EmberUpdateState.downloading;

  /// Creates the singleton and schedules the throttled silent
  /// auto-check a few seconds after launch.
  static EmberUpdater start(AppSettings settings, String dataDir) {
    final u = EmberUpdater(settings: settings, dataDir: dataDir);
    instance = u;
    Timer(const Duration(seconds: 5), () => u.check(manual: false));
    return u;
  }

  /// Whether the 24 h auto-check throttle currently holds.
  bool autoCheckDue(DateTime now) {
    final last = settings.lastEmberUpdateCheckMs;
    if (last <= 0) return true;
    return now.millisecondsSinceEpoch - last >= autoCheckEvery.inMilliseconds;
  }

  /// Build 2096 (post-2095 audit L11): called by the
  /// Settings channel chips after a switch — a release
  /// fetched on the other channel (and any APK downloaded
  /// from it) must not stay on offer.
  void noteChannelChanged() {
    if (_feedChannel == null) {
      _feedChannel = settings.updateChannel;
      return;
    }
    if (_feedChannel == settings.updateChannel) return;
    _feedChannel = settings.updateChannel;
    release = null;
    downloadedPath = null;
    downloadedVerified = false;
    errorText = '';
    if (state == EmberUpdateState.available ||
        state == EmberUpdateState.downloaded ||
        state == EmberUpdateState.upToDate ||
        state == EmberUpdateState.unknownBuild ||
        state == EmberUpdateState.uncomparable ||
        state == EmberUpdateState.error) {
      _set(EmberUpdateState.idle);
    }
  }

  void _set(EmberUpdateState next) {
    state = next;
    notifyListeners();
  }

  /// Checks the feed. A non-manual check inside the throttle
  /// window returns at once and changes nothing (silent).
  Future<void> check({required bool manual}) async {
    if (busy) return;
    // Build 2095 (whole-app journey audit #29): the silent
    // auto-check honours the auto-update switch — it used to
    // run regardless, so turning auto-update off changed
    // nothing for this updater.
    if (!manual && !settings.autoUpdate) return;
    final now = DateTime.now();
    if (!manual && !autoCheckDue(now)) return;
    // Build 2097 (post-2096 audit L-l): the channel this
    // check belongs to, captured at entry — a mid-check
    // channel switch used to make the parse read the OLD
    // channel's feed with the NEW channel's shape (Beta's
    // list vs Stable's object), and a mid-download switch
    // let the old channel's APK be offered as ready under
    // the new channel (see download()).
    final startChannel = settings.updateChannel;
    _set(EmberUpdateState.checking);
    try {
      final text = _fetcher != null
          ? await _fetcher(
              Uri.parse(emberUpdateFeedUrlFor(startChannel)),
            )
          : await _fetchFeed(startChannel);
      if (settings.updateChannel != startChannel) {
        // The switch already invalidated the cache via
        // noteChannelChanged; this check's result belongs
        // to the old channel — discard it quietly.
        _set(EmberUpdateState.idle);
        return;
      }
      // Feature 13: the Beta feed is a list, Stable a single
      // release object.
      final decoded = jsonDecode(text);
      final parsed = startChannel == 'beta'
          ? parseNewestRelease(decoded)
          : parseLatestRelease(decoded);
      if (parsed == null) {
        release = null;
        // Build 2092 (item 58): no release, no downloaded
        // file to install.
        downloadedPath = null;
        downloadedVerified = false;
        // Build 2095 (whole-app journey audit, §9 minor),
        // narrowed by the build-2075 pin in the full
        // suite: GitHub's own "Not Found" answer means no
        // release exists yet — information, read as
        // up-to-date. Any OTHER unusable payload keeps
        // the 2075 contract: an error with a plain
        // sentence, because something IS wrong with the
        // feed.
        final notFound = decoded is Map && decoded['message'] == 'Not Found';
        if (notFound) {
          // Build 2098 (Item C): a genuine "no releases"
          // answer IS a completed look — it stamps the
          // throttle like a usable payload does below.
          settings.update(
            lastEmberUpdateCheckMs: now.millisecondsSinceEpoch,
          );
          errorText = '';
          _set(EmberUpdateState.upToDate);
        } else {
          // Build 2098 (Item C, post-2097 audit §7 U-B):
          // an UNUSABLE payload (a rate-limit answer, a
          // captive-portal page that happened to decode)
          // no longer stamps the 24 h throttle. Builds up
          // to 2097 stamped it "whatever it found", so one
          // bad launch check on a filtered network muted
          // every auto-check for a day — even after a
          // tunnel came up. The error still surfaces.
          errorText =
              'No update information came back from GitHub. '
              'Try again later.';
          _set(EmberUpdateState.error);
        }
        return;
      }
      // A completed look stamps the throttle. update() is
      // synchronous (it saves in the background), so there
      // is nothing to await here.
      settings.update(lastEmberUpdateCheckMs: now.millisecondsSinceEpoch);
      // Build 2092 (item 58): a different tag than the one
      // the downloaded file belongs to invalidates the path
      // — Install must never offer a stale APK.
      if (parsed.tag != release?.tag) {
        downloadedPath = null;
        downloadedVerified = false;
      }
      release = parsed;
      _feedChannel = settings.updateChannel;
      // Build 2125 (audit A25-53 / P-57 + A25-09 / P-20):
      // partial downloads are swept HERE, once the offered
      // release is known — the offered release's own .part
      // is a RESUME waiting to happen (build 2125 made
      // downloads resumable) and is kept; every other
      // .part, and any .part older than a week, is an
      // orphan and goes.
      await _sweepStaleParts(keepTag: parsed.tag);
      // Build 2126 (audit A26-27): resolve the kept
      // part's size for the Resume label (see
      // [resumableBytes]).
      resumableBytes = 0;
      try {
        final keptPart = File(
          '$dataDir${Platform.pathSeparator}updates'
          '${Platform.pathSeparator}RalysndEmber2-${parsed.tag}.apk.part',
        );
        if (await keptPart.exists()) {
          final len = await keptPart.length();
          if (len > 0 && (parsed.apkSize <= 0 || len < parsed.apkSize)) {
            resumableBytes = len;
          }
        }
      } catch (_) {
        // Label state only; never break a check.
      }
      // Build 2098 (Item C): compare against the package's
      // own build number, not only the define.
      await resolvePackageBuild();
      // Build 2106 (journey audit F-09): an unresolved
      // package build is UNKNOWN — no update is offered.
      // Build 2125 (audit A25-52 / P-56): the state no
      // longer READS as up-to-date in that case — it has
      // its own state (unknownBuild) whose line says the
      // comparison could not be made, instead of asserting
      // a false "latest build" fact.
      final current = currentBuild;
      if (current == null) {
        errorText =
            'This app\'s own build number could not be read, '
            'so the check cannot say whether an update exists.';
        _set(EmberUpdateState.unknownBuild);
      } else if (parsed.uncomparable) {
        // Build 2127 (A26-21): a semver-tagged release is
        // shown as what it is — published, but not
        // comparable with build numbers. It never reaches
        // the isNewerThan branch, so it can never be
        // offered (or auto-installed) as an update; the
        // stranded-APK reoffer below is likewise skipped,
        // since nothing says this release is newer.
        _set(EmberUpdateState.uncomparable);
      } else if (parsed.isNewerThan(current)) {
        // Build 2125 (audit A25-53 / P-57): a completed
        // download of THIS release may already sit in
        // updates/ — the app died after the download
        // finished but before the install, and up to 2124
        // the next check offered only a fresh ~141 MB
        // download (the post-download sweep kept the file
        // but nothing ever re-offered it). When the
        // stranded file's bytes verify against the feed's
        // digest it is re-offered as downloaded; a file
        // that does not verify is deleted inside the
        // helper — it is not the release's bytes.
        if (await _reofferStrandedApk(parsed)) {
          _set(EmberUpdateState.downloaded);
        } else {
          _set(EmberUpdateState.available);
        }
      } else {
        _set(EmberUpdateState.upToDate);
      }
    } on SocketException {
      errorText =
          'Could not reach GitHub. Check your connection '
          'and try again.';
      _set(EmberUpdateState.error);
    } on HttpException {
      errorText =
          'Could not reach GitHub. Check your connection '
          'and try again.';
      _set(EmberUpdateState.error);
    } on TimeoutException {
      errorText = 'GitHub took too long to answer. Try again.';
      _set(EmberUpdateState.error);
    } catch (_) {
      errorText = 'The update check failed. Try again.';
      _set(EmberUpdateState.error);
    }
  }

  /// Builds an HTTP client, optionally routed through the
  /// app's own local proxy (build 2098, U-A).
  HttpClient _client({String? proxy}) {
    final client = _clientFactory()
      ..connectionTimeout = const Duration(seconds: 25);
    if (proxy != null) {
      client.findProxy = (_) => 'PROXY $proxy';
      // Build 2098 (verification V-3): if the session's
      // inbound requires password auth, register the
      // credentials so the proxy's 407 challenge is answered
      // instead of failing the attempt.
      final credentials = localProxyCredentialsResolver?.call();
      if (credentials != null) {
        final cut = proxy.lastIndexOf(':');
        final host = cut > 0 ? proxy.substring(0, cut) : proxy;
        final port = cut > 0 ? int.tryParse(proxy.substring(cut + 1)) : null;
        if (port != null) {
          client.addProxyCredentials(
            host,
            port,
            '',
            HttpClientBasicCredentials(credentials.user, credentials.pass),
          );
        }
      }
    }
    return client;
  }

  Future<String> _fetchFeed(String channel) async {
    // Build 2098 (U-A): through the session's local proxy
    // first while one is up, direct as the fallback — and
    // direct first (only) when no session is up. The last
    // attempt's failure is what surfaces, so with no proxy
    // the behaviour is exactly the pre-2098 one.
    final proxy = localProxyResolver?.call();
    Object? lastError;
    for (final viaProxy in [if (proxy != null) proxy, null]) {
      try {
        return await _fetchFeedOnce(channel, proxy: viaProxy);
      } catch (e) {
        lastError = e;
      }
    }
    throw lastError ?? const HttpException('feed answered with an error');
  }

  Future<String> _fetchFeedOnce(String channel, {String? proxy}) async {
    final client = _client(proxy: proxy);
    try {
      final request = await client.getUrl(
        Uri.parse(emberUpdateFeedUrlFor(channel)),
      );
      request.headers.set(
        HttpHeaders.acceptHeader,
        'application/vnd.github+json',
      );
      request.headers.set(
        HttpHeaders.userAgentHeader,
        'RalysndEmber/$appVersion',
      );
      // Build 2098 (post-2097 audit L30): the header wait
      // and the body read both carry the stall timeout.
      // connectionTimeout alone covers only the connect —
      // a response that connected and then went silent used
      // to wedge check() in 'checking' forever: busy stayed
      // true and every later (manual) check silently
      // returned at the busy guard.
      final response = await request.close().timeout(stallTimeout);
      if (response.statusCode != 200) {
        throw const HttpException('feed answered with an error');
      }
      // Build 2125 (audit A25-50 / P-54): accumulate under
      // the byte cap instead of joining unbounded.
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(stallTimeout)) {
        builder.add(chunk);
        if (builder.length > emberUpdateFeedMaxBytes) {
          throw const HttpException('feed response too large');
        }
      }
      return utf8.decode(builder.takeBytes());
    } finally {
      client.close(force: true);
    }
  }

  /// Build 2125 (audit A25-53 / P-57): deletes leftover
  /// `.part` files in updates/ — the residue of downloads
  /// the process died in the middle of. The offered
  /// release's own part ([keepTag]) survives: since build
  /// 2125 (A25-09) a download resumes from it. A part
  /// older than a week is an orphan even when its tag
  /// matches.
  Future<void> _sweepStaleParts({String? keepTag}) async {
    try {
      final dir = Directory('$dataDir${Platform.pathSeparator}updates');
      if (!await dir.exists()) return;
      final keepName = keepTag == null
          ? null
          : 'RalysndEmber2-$keepTag.apk.part';
      final staleBefore = DateTime.now().subtract(
        const Duration(days: 7),
      );
      await for (final e in dir.list()) {
        if (e is File && e.path.endsWith('.part')) {
          var keep = keepName != null &&
              e.uri.pathSegments.last == keepName;
          if (keep) {
            try {
              if ((await e.lastModified()).isBefore(staleBefore)) {
                keep = false;
              }
            } catch (_) {
              keep = false;
            }
          }
          if (!keep) {
            try {
              await e.delete();
            } catch (_) {}
          }
        }
      }
    } catch (_) {
      // Housekeeping never breaks a check.
    }
  }

  /// Build 2126 (audit A26-19): opens [url] with GET and
  /// follows redirects MANUALLY — dart:io's automatic
  /// following re-validates nothing, so a redirect from
  /// an allowed host could land the APK download on any
  /// host or scheme (the 2125 allowlist checked only the
  /// initial URL). Every hop's target must pass the same
  /// policy as the initial URL (the test seam's override
  /// included). [rangeFrom] > 0 sends the resume Range
  /// header on EVERY hop, so it survives the asset
  /// hosts' redirect to the signed URL. The header wait
  /// carries the stall timeout (build 2098, L30).
  Future<HttpClientResponse> _openGetChecked(
    HttpClient client,
    String url, {
    required int rangeFrom,
  }) async {
    var current = url;
    for (var hop = 0; hop <= 5; hop++) {
      final allowed =
          urlPolicyOverride?.call(current) ??
          emberUpdateUrlAllowed(current);
      if (!allowed) {
        throw const HttpException(
          'the download address was refused',
        );
      }
      final request = await client.getUrl(Uri.parse(current));
      request.followRedirects = false;
      request.headers.set(
        HttpHeaders.userAgentHeader,
        'RalysndEmber/$appVersion',
      );
      if (rangeFrom > 0) {
        request.headers.set(
          HttpHeaders.rangeHeader,
          'bytes=$rangeFrom-',
        );
      }
      final resp = await request.close().timeout(stallTimeout);
      final status = resp.statusCode;
      if (status == 301 ||
          status == 302 ||
          status == 303 ||
          status == 307 ||
          status == 308) {
        final location = resp.headers.value(
          HttpHeaders.locationHeader,
        );
        try {
          await resp.drain<void>();
        } catch (_) {}
        if (location == null || hop == 5) {
          throw const HttpException(
            'download answered with an error',
          );
        }
        current = Uri.parse(current).resolve(location).toString();
        continue;
      }
      return resp;
    }
    throw const HttpException('download answered with an error');
  }

  /// Build 2126 (audit A26-24): true when [resp]'s
  /// Content-Range header starts exactly at [from] —
  /// the only 206 that is really the requested remainder.
  bool _contentRangeStartsAt(HttpClientResponse resp, int from) {
    final v = resp.headers.value(HttpHeaders.contentRangeHeader);
    if (v == null) return false;
    final m = RegExp(r'^bytes (\d+)-').firstMatch(v.trim());
    if (m == null) return false;
    return int.tryParse(m.group(1)!) == from;
  }

  /// The in-flight download's client and cancel flag
  /// (build 2125, audit A25-09): cancelDownload() closes
  /// the client, which ends the stream; download() sees
  /// the flag and lands as a resumable stop, not an error.
  HttpClient? _downloadClient;
  bool _downloadCancelled = false;

  /// Cancels the in-flight download. The fetched part is
  /// KEPT — the next Download resumes from it.
  void cancelDownload() {
    if (state != EmberUpdateState.downloading) return;
    _downloadCancelled = true;
    _downloadClient?.close(force: true);
  }

  /// Build 2125 (audit A25-53 / P-57): re-offers a
  /// completed download of [r] already sitting in
  /// updates/, when its bytes verify against the feed's
  /// digest. Returns true when the offer was made. A file
  /// whose size or hash does not match is deleted (it is
  /// not the release's bytes) and false is returned; with
  /// no digest published there is nothing to verify
  /// against, so nothing is re-offered.
  Future<bool> _reofferStrandedApk(EmberRelease r) async {
    if (r.apkDigest.isEmpty) return false;
    try {
      final dir = Directory('$dataDir${Platform.pathSeparator}updates');
      final file = File(
        '${dir.path}${Platform.pathSeparator}RalysndEmber2-${r.tag}.apk',
      );
      if (!await file.exists()) return false;
      if (r.apkSize > 0 && await file.length() != r.apkSize) {
        await file.delete();
        return false;
      }
      final hasher = Sha256();
      await for (final chunk in file.openRead()) {
        hasher.add(chunk);
      }
      if (hasher.hex() != r.apkDigest) {
        await file.delete();
        return false;
      }
      // Build 2129 (leg 6): a stranded file is re-offered
      // only when it also passes the signing-cert check —
      // the same gate a fresh download passes (above). A
      // file signed by anyone else is not this release,
      // whatever its bytes hash to: it goes, and the
      // release stays available for a fresh download.
      if (!await _signingCertMatches(file.path)) {
        await file.delete();
        return false;
      }
      downloadedPath = file.path;
      downloadedVerified = true;
      progress = 1;
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Build 2129 (leg 6, delta §6(b)): whether the finished
  /// APK at [apkPath] is signed by the SAME certificate as
  /// the running app. The feed digest (build 2116) proves
  /// the bytes match the feed document — but the feed
  /// supplies both the URL and the digest, so a compromised
  /// or spoofed feed answer controls both. It cannot forge
  /// the release signing key: a differently-signed APK is
  /// not this app's update, whatever the feed says. An
  /// unreadable cert on either side is NOT a match — the
  /// caller discards the download and says so in plain
  /// words, and Install is never offered.
  Future<bool> _signingCertMatches(String apkPath) async {
    final override = certCheckOverride;
    if (override != null) {
      try {
        return await override(apkPath);
      } catch (_) {
        return false;
      }
    }
    final own = await AndroidCore.ownSigningCertSha256();
    if (own == null || own.isEmpty) return false;
    final apk = await AndroidCore.apkSigningCertSha256(apkPath);
    if (apk == null || apk.isEmpty) return false;
    return apk.toLowerCase() == own.toLowerCase();
  }

  /// Downloads the available release's APK with progress, into
  /// `dataDir/updates/` (files/core/updates/ on Android — the
  /// folder ember_file_paths.xml exposes to the installer).
  /// A size mismatch against the feed's own figure is an
  /// incomplete download, never an installable one.
  Future<void> download() async {
    final r = release;
    if (r == null || busy) return;
    // Build 2125 (audit A25-49 / P-53): the asset URL is
    // feed data — it is followed only to GitHub's own
    // hosts over HTTPS (see emberUpdateUrlAllowed).
    // Build 2129 (leg 6): the INITIAL URL additionally
    // has to match this repo's own release-asset path
    // shape (see emberUpdateInitialUrlAllowed — the
    // path rule deliberately does not apply to redirect
    // hops, whose signed CDN paths match no repo shape).
    final urlAllowed =
        urlPolicyOverride?.call(r.apkUrl) ??
        emberUpdateInitialUrlAllowed(r.apkUrl);
    if (!urlAllowed) {
      errorText =
          'The update\'s download address was not a GitHub '
          'address, so it was refused.';
      _set(EmberUpdateState.error);
      return;
    }
    // Build 2097 (post-2096 audit L-l): the channel this
    // download belongs to — checked again before the file
    // is offered as ready.
    final startChannel = settings.updateChannel;
    _downloadCancelled = false;
    progress = 0;
    _set(EmberUpdateState.downloading);
    final dir = Directory('$dataDir${Platform.pathSeparator}updates');
    // Build 2125 (audit A25-09 / P-20): the part file is
    // named for THIS release, so a kept part can only ever
    // resume its own download (check()'s sweep keeps
    // exactly this name and deletes the rest).
    final part = File(
      '${dir.path}${Platform.pathSeparator}RalysndEmber2-${r.tag}.apk.part',
    );
    final target = File(
      '${dir.path}${Platform.pathSeparator}RalysndEmber2-${r.tag}.apk',
    );
    // Resume state, resolved once the directory exists:
    // how many bytes of this release already sit in the
    // part (0 = a fresh download).
    var resumeFrom = 0;
    // Build 2098 (U-A): the download opens through the
    // session's local proxy first while one is up, direct
    // as the fallback (the feed's route, mirrored). Only
    // the OPEN is retried — once a response is streaming,
    // its own outcome decides, and the size check below
    // already refuses a short file.
    HttpClient? activeClient;
    try {
      await dir.create(recursive: true);
      // Build 2125 (A25-09): resolve the resume offset. A
      // part longer than the release is not this release's
      // prefix — it goes. A part exactly the release's
      // size is a finished download whose rename never
      // happened: it is hashed and, when it verifies (or
      // the feed published no digest to verify against),
      // finalised below without any network at all.
      var partComplete = false;
      if (await part.exists()) {
        final len = await part.length();
        if (r.apkSize > 0 && len == r.apkSize) {
          partComplete = true;
        } else if (r.apkSize > 0 && len > 0 && len < r.apkSize) {
          resumeFrom = len;
        } else if (len > 0) {
          await part.delete().catchError((_) => part);
        }
      }
      final proxy = localProxyResolver?.call();
      HttpClientResponse? opened;
      Object? openError;
      if (!partComplete) {
        for (final viaProxy in [if (proxy != null) proxy, null]) {
          final candidate = _client(proxy: viaProxy);
          try {
            // Build 2126 (audit A26-19 + A26-24): the
            // open follows redirects MANUALLY, every hop
            // re-validated against the URL policy
            // (dart:io's automatic following re-checks
            // nothing — a 302 from an allowed host could
            // land the download on any host or scheme),
            // and a 206 is accepted only when its
            // Content-Range starts exactly at the
            // requested offset: a wrong-offset append
            // would corrupt the part, caught only by the
            // final digest and only when one is
            // published. A bad range drops the part and
            // restarts whole on a fresh request inside
            // the same attempt.
            Future<HttpClientResponse> openAttempt() async {
              var resp = await _openGetChecked(
                candidate,
                r.apkUrl,
                rangeFrom: resumeFrom,
              );
              if (resp.statusCode == 200) {
                // A 200 to a Range request means the
                // server ignored it: the part is
                // truncated and the body streams whole.
                if (resumeFrom > 0) {
                  resumeFrom = 0;
                  await part.delete().catchError((_) => part);
                }
                return resp;
              }
              if (resp.statusCode == 206 && resumeFrom > 0) {
                if (_contentRangeStartsAt(resp, resumeFrom)) {
                  // The remainder, as asked.
                  return resp;
                }
                try {
                  await resp.drain<void>();
                } catch (_) {}
                await part.delete().catchError((_) => part);
                resumeFrom = 0;
                resp = await _openGetChecked(
                  candidate,
                  r.apkUrl,
                  rangeFrom: 0,
                );
                if (resp.statusCode == 200) return resp;
              }
              throw const HttpException(
                'download answered with an error',
              );
            }

            final resp = await openAttempt();
            activeClient = candidate;
            _downloadClient = candidate;
            opened = resp;
            break;
          } catch (e) {
            openError = e;
            candidate.close(force: true);
          }
        }
        if (opened == null) {
          throw openError ??
              const HttpException('download answered with an error');
        }
      }
      final response = opened;
      final expected = r.apkSize > 0
          ? r.apkSize
          : (response?.contentLength ?? 0) + resumeFrom;
      var received = partComplete ? r.apkSize : resumeFrom;
      if (expected > 0 && resumeFrom > 0) {
        progress = resumeFrom / expected;
        notifyListeners();
      }
      // Build 2116 (AB-07): the body is hashed as it
      // streams — the feed's digest is verified below
      // before the file is ever offered for install.
      // Build 2125 (A25-09): on a resume the hasher is
      // first fed the part's existing bytes, so the final
      // digest still covers the whole file.
      final hasher = Sha256();
      if (resumeFrom > 0 || partComplete) {
        await for (final chunk in part.openRead()) {
          hasher.add(chunk);
        }
      }
      // Build 2126 (audit A26-25): the in-stream ceiling —
      // the release's own size when the feed published
      // one, the absolute cap otherwise.
      final ceiling = expected > 0 ? expected : emberUpdateApkMaxBytes;
      var overLimit = false;
      if (!partComplete) {
        final sink = part.openWrite(
          mode: resumeFrom > 0 ? FileMode.append : FileMode.write,
        );
        try {
          // Build 2098 (L30): an idle timeout on the body —
          // a download that connects and then stalls used to
          // sit in 'downloading' forever. The bound is the
          // download's own (verification V-4), not the feed's.
          await for (final chunk in response!.timeout(downloadStallTimeout)) {
            if (_downloadCancelled) break;
            sink.add(chunk);
            hasher.add(chunk);
            received += chunk.length;
            // Build 2126 (A26-25): enforced IN the
            // stream — up to 2125 an over-long body was
            // refused only after it had fully arrived,
            // so a slow-drip endpoint could fill the
            // storage before the check ever fired.
            if (received > ceiling) {
              overLimit = true;
              break;
            }
            if (expected > 0) {
              progress = received / expected;
              notifyListeners();
            }
          }
        } finally {
          await sink.close();
        }
      }
      if (overLimit) {
        // An over-long stream is not a prefix of the
        // release: the part goes (the same disposition
        // the post-stream size check gives it).
        await part.delete().catchError((_) => part);
        errorText =
            'The download grew past the release\'s size and '
            'was discarded.';
        _set(EmberUpdateState.error);
        return;
      }
      if (_downloadCancelled) {
        // Build 2125 (A25-09): a cancel is a resumable
        // stop, not a failure — the part stays, and the
        // offer returns with its progress intact (the
        // button reads Resume).
        _set(EmberUpdateState.available);
        return;
      }
      if (expected > 0 && received != expected) {
        // Build 2125 (A25-09): a short stream is a resumable
        // stop now — the part is KEPT (up to 2124 it was
        // deleted here and in the finally, so every
        // interruption restarted a ~141 MB download from
        // zero). An over-long stream is not a prefix of
        // anything: that part goes.
        if (received > expected) {
          await part.delete().catchError((_) => part);
        }
        errorText =
            'The download was incomplete — the part already '
            'fetched is kept, and Download will resume it.';
        _set(EmberUpdateState.error);
        return;
      }
      // Build 2116 (AB-07): a size match alone never proved
      // the bytes are the release's — the feed's SHA-256
      // does. A mismatch discards the file and says why.
      if (r.apkDigest.isNotEmpty && hasher.hex() != r.apkDigest) {
        await part.delete().catchError((_) => part);
        errorText =
            'The downloaded update did not match the '
            'checksum the feed published for it, so it was '
            'discarded. Try again.';
        _set(EmberUpdateState.error);
        return;
      }
      // Build 2129 (leg 6, delta §6(b)): the signing-cert
      // check — AFTER the digest, BEFORE the file is
      // renamed into place and Install is offered. The
      // digest alone cannot close the feed-compromise gap
      // (the feed supplies the digest too); the cert can.
      // It runs whether or not the feed published a
      // digest. Mismatch OR unreadable = the download is
      // discarded, never offered.
      if (!await _signingCertMatches(part.path)) {
        await part.delete().catchError((_) => part);
        errorText =
            'The downloaded update was not signed with '
            'this app\'s release key, so it was discarded. '
            'It did not come from this app\'s releases.';
        _set(EmberUpdateState.error);
        return;
      }
      // Build 2097 (post-2096 audit L-l): the channel
      // switched mid-download — this file belongs to the
      // old channel's feed and must not be offered as the
      // new channel's update. Discard it quietly.
      if (settings.updateChannel != startChannel) {
        await part.delete().catchError((_) => part);
        _set(EmberUpdateState.idle);
        return;
      }
      if (await target.exists()) await target.delete();
      await part.rename(target.path);
      downloadedPath = target.path;
      // Build 2119 (audit F-11): reaching this line with a
      // feed digest means the hash matched (a mismatch
      // discards the file above); with none, nothing was
      // verified and the offer must say so.
      downloadedVerified = r.apkDigest.isNotEmpty;
      progress = 1;
      // Build 2126 (A26-27): the part was just renamed
      // into the target — nothing remains to resume.
      resumableBytes = 0;
      _set(EmberUpdateState.downloaded);
      // Build 2116 (AB-07): older builds' APKs (~150 MB
      // each) used to accumulate in updates/ forever.
      // Build 2125 (audit A25-08 / P-19): the sweep now
      // keeps ONE previous build's APK beside the new one
      // — up to 2124 it deleted every older file, so a bad
      // update left nothing on the device to roll back
      // to. The newest other APK (by modification time)
      // stays; anything older goes.
      try {
        final others = <File>[];
        await for (final e in dir.list()) {
          if (e is File &&
              e.path != target.path &&
              e.uri.pathSegments.last.startsWith('RalysndEmber2-') &&
              e.path.endsWith('.apk')) {
            others.add(e);
          }
        }
        if (others.length > 1) {
          final modified = <String, DateTime>{};
          for (final f in others) {
            modified[f.path] = await f.lastModified();
          }
          others.sort(
            (a, b) => modified[b.path]!.compareTo(modified[a.path]!),
          );
          for (final f in others.sublist(1)) {
            await f.delete();
          }
        }
      } catch (_) {}
    } on SocketException {
      // Build 2125 (A25-09): if the cancel flag ended this
      // download, it is a resumable stop, not an error.
      if (_downloadCancelled) {
        _set(EmberUpdateState.available);
        return;
      }
      errorText =
          'The download was interrupted. Check your '
          'connection and try again — the part already '
          'fetched is kept, and Download will resume it.';
      _set(EmberUpdateState.error);
    } on TimeoutException {
      if (_downloadCancelled) {
        _set(EmberUpdateState.available);
        return;
      }
      // Build 2098 (L30): a stalled download is a named
      // failure, not an endless 'downloading'.
      errorText =
          'The download stalled and was stopped. The part '
          'already fetched is kept, and Download will '
          'resume it.';
      _set(EmberUpdateState.error);
    } catch (_) {
      if (_downloadCancelled) {
        _set(EmberUpdateState.available);
        return;
      }
      if (state == EmberUpdateState.downloading) {
        errorText =
            'The download failed. The part already fetched '
            'is kept, and Download will resume it.';
        _set(EmberUpdateState.error);
      }
    } finally {
      activeClient?.close(force: true);
      _downloadClient = null;
      // Build 2125 (A25-09): the AB-15 finally-delete is
      // gone — a leftover .part is resume state now, and
      // its orphan control is check()'s tag-scoped,
      // age-capped sweep (_sweepStaleParts). The paths
      // whose bytes are WRONG (digest mismatch, over-long
      // stream, channel switch) still delete their part
      // at the decision point above.
    }
  }

  /// Hands the downloaded APK to the system installer.
  Future<void> install() async {
    final path = downloadedPath;
    if (path == null) return;
    // Build 2125 (audit A25-58 / P-62): the file is
    // re-verified against the feed's digest at INSTALL
    // time. The download-time check (build 2116) proved
    // the bytes THEN; the file has sat in storage since —
    // a truncated copy, a restore from a backup, or plain
    // tampering would otherwise be handed to the installer
    // under a "checksum verified" label that no longer
    // described it. A mismatch discards the file and says
    // so honestly; the release stays available for a fresh
    // download. (A feed with no digest has nothing to
    // re-verify against — the offer already reads
    // UNVERIFIED for those.)
    final r = release;
    if (r != null && r.apkDigest.isNotEmpty) {
      var matches = false;
      try {
        final hasher = Sha256();
        await for (final chunk in File(path).openRead()) {
          hasher.add(chunk);
        }
        matches = hasher.hex() == r.apkDigest;
      } catch (_) {
        matches = false;
      }
      if (!matches) {
        try {
          await File(path).delete();
        } catch (_) {}
        downloadedPath = null;
        downloadedVerified = false;
        errorText =
            'The downloaded file no longer matches the '
            'checksum the feed published for it, so it was '
            'discarded instead of installed. Download it '
            'again.';
        _set(EmberUpdateState.available);
        return;
      }
    }
    try {
      // installApk answers false when the platform channel had
      // nothing to hand back (no installer was opened): that is
      // a failed install, not a silent success.
      final opened = await AndroidCore.installApk(path);
      if (!opened) {
        errorText =
            'Android could not open the installer. The '
            'downloaded file is kept — try again.';
        _set(EmberUpdateState.error);
      }
    } catch (_) {
      errorText =
          'Android could not open the installer. The '
          'downloaded file is kept — try again.';
      _set(EmberUpdateState.error);
    }
  }
}
