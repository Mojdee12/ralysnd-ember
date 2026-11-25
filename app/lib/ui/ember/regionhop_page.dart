/// The RegionHop page (build 2139, leg 1): the owner's
/// own Psiphon exits, served by the regionhop panel on
/// his server and reached through authenticated GOST
/// relays on the same box. Reached from Settings only
/// while the RegionHop switch is on — the feature is
/// DEFAULT OFF, and with it off this page is never
/// linked and the app never contacts the panel.
///
/// The page has two states. Setup: the panel URL (the
/// full address, path prefix included), the panel
/// password and the bridge credentials block the server
/// setup printed — saved into the settings store on a
/// successful login. List: one row per location with its
/// live status (polled every 5 s while the page is
/// visible), its exit after a Check, Start/Stop, and
/// Connect — which upserts an ordinary managed SOCKS
/// profile and rides the existing session machinery;
/// nothing about connecting is re-implemented here.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../regionhop/regionhop_client.dart';
import '../../regionhop/regionhop_defaults.dart';
import '../../xray/problem_report.dart';
import '../../xray/xray_controller.dart';
import '../../xray/xray_models.dart';
import 'ember_format.dart';
import 'ember_theme.dart';

Future<void> openRegionHop(BuildContext context, XrayController xray) =>
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => RegionHopPage(xray: xray)),
    );

class RegionHopPage extends StatefulWidget {
  const RegionHopPage({super.key, required this.xray});

  final XrayController xray;

  @override
  State<RegionHopPage> createState() => _RegionHopPageState();
}

/// A field's effective value (build 2141, leg 2): the
/// stored setting when one is stored, otherwise the
/// built-in default — so the form opens pre-filled and
/// the silent auto-login below connects with zero
/// typing, while any value the owner stored (or later
/// saves through Edit panel details) wins.
String _effectiveRegionHopValue(String stored, String fallback) =>
    stored.isNotEmpty ? stored : fallback;

/// The panel URL's effective value (build 2143): the
/// [RegionHopDefaults.panelUrl] fallback for an empty
/// field, as [_effectiveRegionHopValue] — plus one
/// migration. A device that stored the pre-2143 baked
/// default (the plain-HTTP address, with or without its
/// trailing slash) resolves to the NEW https default:
/// the carrier drops the old scheme's status exchange,
/// so honouring the stored copy verbatim would strand
/// the page on a dead address. Any other stored value —
/// a panel the owner runs elsewhere, a corrected
/// prefix — is respected verbatim.
String regionHopEffectivePanelUrl(String stored) {
  if (stored.isEmpty) return RegionHopDefaults.panelUrl;
  String bare(String value) {
    var v = value.trim();
    while (v.endsWith('/')) {
      v = v.substring(0, v.length - 1);
    }
    return v;
  }

  if (bare(stored) == bare(RegionHopDefaults.legacyPanelUrl)) {
    return RegionHopDefaults.panelUrl;
  }
  return stored;
}

class _RegionHopPageState extends State<RegionHopPage> {
  late final TextEditingController _url = TextEditingController(
    text: regionHopEffectivePanelUrl(
      widget.xray.settings.regionHopPanelUrl,
    ),
  );
  late final TextEditingController _password = TextEditingController(
    text: _effectiveRegionHopValue(
      widget.xray.settings.regionHopPanelPassword,
      RegionHopDefaults.panelPassword,
    ),
  );
  late final TextEditingController _relays = TextEditingController(
    text: _effectiveRegionHopValue(
      widget.xray.settings.regionHopRelays,
      RegionHopDefaults.bridgeCredentials,
    ),
  );

  RegionHopClient? _client;
  List<RegionHopLocation> _locations = const [];
  bool _inList = false;
  bool _loginBusy = false;
  bool _pollBusy = false;
  bool _stale = false;

  /// Build 2149 (audit A43-01): the poll stopped itself
  /// on a credential failure — the panel's password or
  /// its lockout is the problem, and polling on would
  /// only spend login attempts. The list stays visible
  /// with the error and a manual Reconnect; nothing
  /// resumes on its own.
  bool _authStopped = false;
  String? _pageError;
  String? _rowError;

  /// Build 2140 (leg B): what the Locations empty area may
  /// claim — a failed load must never render as an empty
  /// panel (see RegionHopListEmpty).
  RegionHopListState _listState = RegionHopListState.loading;
  String? _listLoadError;

  /// Build 2140 (leg B): the panel flow's journal writer —
  /// outcomes and error kinds only, never the panel URL,
  /// password, cookie or relay credentials (see
  /// RegionHopJournal).
  late final RegionHopJournal _journal = RegionHopJournal(
    (text, {ok}) => widget.xray.diagnostics.add('regionhop', text, ok: ok),
  );
  final Map<String, RegionHopProbe> _probes = {};
  final Set<String> _probing = {};
  final Set<String> _acting = {};
  bool _connectBusy = false;
  String? _previousSelection;
  Timer? _pollTimer;

  XraySettings get _settings => widget.xray.settings;

  @override
  void initState() {
    super.initState();
    // The effective credentials (stored, or the
    // built-in defaults — build 2141, leg 2) re-login
    // silently on open; the cookie itself is
    // memory-only and never persisted.
    if (_url.text.trim().isNotEmpty && _password.text.isNotEmpty) {
      unawaited(_connectToPanel(silent: true));
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _url.dispose();
    _password.dispose();
    _relays.dispose();
    super.dispose();
  }

  RegionHopRelayBlock get _relayBlock => parseRegionHopRelays(_relays.text);

  Future<void> _persistFields() async {
    _settings
      // Build 2149 (audit A43-26): the persisted URL is
      // the MIGRATED one — the legacy-address migration
      // applies at persist time, not only at field init,
      // so the store itself converges to the live address
      // instead of re-deriving it on every open.
      ..regionHopPanelUrl = regionHopEffectivePanelUrl(_url.text.trim())
      ..regionHopPanelPassword = _password.text
      ..regionHopRelays = _relays.text;
    await widget.xray.save();
  }

  Future<void> _connectToPanel({bool silent = false}) async {
    if (_loginBusy) return;
    setState(() {
      _loginBusy = true;
      if (!silent) _pageError = null;
    });
    final client = RegionHopClient(
      // Build 2149 (audit A43-26): connect uses the
      // migrated URL too, explicitly — not merely
      // whatever the field happened to be initialised
      // with.
      panelUrl: regionHopEffectivePanelUrl(_url.text),
      password: _password.text,
      // Build 2141: the fetch's single retry journals its
      // transition (sanitized failure tokens only).
      // Build 2142: each fetch's conclusion journals its
      // phase timings on failure / recovery transitions.
    )..onStatusRetry = _journal.fetchRetrying
      ..onStatusPhases = _journal.fetchPhases;
    try {
      await client.login();
      _journal.loginOk();
      _client = client;
      await _persistFields();
      if (!mounted) return;
      setState(() {
        _inList = true;
        _authStopped = false;
        _pageError = null;
        // A fresh list session: until its first fetch
        // lands, the empty area may only say it is loading
        // (build 2140, leg B).
        _listState = RegionHopListState.loading;
        _listLoadError = null;
      });
      _startPolling();
      await _refresh();
    } on RegionHopException catch (e) {
      _journal.loginFailed(e.kind);
      if (!mounted) return;
      setState(() => _pageError = e.message);
    } finally {
      if (mounted) setState(() => _loginBusy = false);
    }
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      // Only while this page is the visible route.
      if (ModalRoute.of(context)?.isCurrent ?? false) {
        unawaited(_refresh());
      }
    });
  }

  Future<void> _refresh() async {
    final client = _client;
    if (client == null || _pollBusy) return;
    _pollBusy = true;
    try {
      final locations = await client.fetchStatus();
      _journal.fetchOk(locations.length);
      if (!mounted) return;
      setState(() {
        _locations = locations;
        _stale = false;
        // The panel answered: if it said zero rows, the
        // panel is truly empty (build 2140, leg B).
        _listState = RegionHopListState.empty;
        _listLoadError = null;
      });
    } on RegionHopException catch (e) {
      _journal.fetchFailed(e.kind, e.transport);
      if (!mounted) return;
      // Build 2149 (audit A43-01): a credential failure
      // inside the poll STOPS the poll. The client is
      // blocked as well (it will not spend another login
      // POST), but the timer itself must not keep waking
      // the fetch up against a panel whose answer is the
      // password or the lockout — the owner reconnects
      // by hand when he has dealt with it.
      if (e.kind == RegionHopErrorKind.loginFailed ||
          e.kind == RegionHopErrorKind.lockout) {
        _pollTimer?.cancel();
        _pollTimer = null;
        _authStopped = true;
        // Build 2149 (expansion 4): a detected panel
        // lockout lands in the day's problem report.
        if (e.kind == RegionHopErrorKind.lockout) {
          widget.xray.recordProblem(
            type: ProblemTypes.regionHopLockout,
            engine: 'RegionHop',
            stage: 'panel login',
            reason: 'the panel reported too many login attempts',
          );
        }
      }
      setState(() {
        // Keep the last-known rows, greyed, behind the
        // unreachable state — never a blank page.
        _stale = true;
        _pageError = e.message;
        // With no rows to show, the empty area must own
        // this failure — never claim the panel is empty
        // (build 2140, leg B).
        _listState = RegionHopListState.loadFailed;
        _listLoadError = e.message;
      });
    } finally {
      _pollBusy = false;
    }
  }

  Future<void> _probe(RegionHopLocation location) async {
    final client = _client;
    if (client == null || _probing.contains(location.name)) return;
    setState(() => _probing.add(location.name));
    try {
      final probe = await client.probe(location.name);
      // The outcome only — the probe's exit IP and latency
      // are never journaled (build 2140, leg B).
      _journal.probeOutcome(location.name, probe.ok);
      if (!mounted) return;
      setState(() => _probes[location.name] = probe);
    } on RegionHopException catch (e) {
      _journal.probeFailed(location.name, e.kind);
      if (!mounted) return;
      setState(() => _rowError = e.message);
    } finally {
      if (mounted) setState(() => _probing.remove(location.name));
    }
  }

  Future<void> _act(RegionHopLocation location, bool start) async {
    final client = _client;
    if (client == null || _acting.contains(location.name)) return;
    setState(() {
      _acting.add(location.name);
      _rowError = null;
    });
    try {
      if (start) {
        await client.restart(location.name);
      } else {
        await client.stop(location.name);
      }
      _journal.actionOutcome(location.name, start);
      await _refresh();
    } on RegionHopException catch (e) {
      _journal.actionFailed(location.name, start, e.kind);
      if (!mounted) return;
      setState(() => _rowError = e.message);
    } finally {
      if (mounted) setState(() => _acting.remove(location.name));
    }
  }

  Future<void> _connect(RegionHopLocation location, RegionHopRelay relay) async {
    if (_connectBusy) return;
    setState(() => _connectBusy = true);
    try {
      final profile = regionHopManagedProfile(
        location: location,
        relay: relay,
        host: regionHopPanelHost(_url.text),
      );
      final xray = widget.xray;
      final exists = xray.profiles.any((p) => p.id == profile.id);
      if (exists) {
        await xray.updateProfile(profile);
      } else {
        await xray.addProfile(profile);
      }
      if (xray.selectedProfileId != profile.id) {
        _previousSelection = xray.selectedProfileId;
      }
      xray.selectedProfileId = profile.id;
      await xray.connect();
      // The exit-IP probe for the location being
      // connected runs once, here — never on the poll.
      unawaited(_probe(location));
    } finally {
      if (mounted) setState(() => _connectBusy = false);
    }
  }

  Future<void> _disconnect() async {
    if (_connectBusy) return;
    setState(() => _connectBusy = true);
    try {
      final xray = widget.xray;
      await xray.disconnect();
      final previous = _previousSelection;
      _previousSelection = null;
      if (previous != null &&
          previous.isNotEmpty &&
          xray.profiles.any((p) => p.id == previous)) {
        xray.selectedProfileId = previous;
        await xray.save();
      }
    } finally {
      if (mounted) setState(() => _connectBusy = false);
    }
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
      ),
      // Build 2147 (strict-audit F1): the banded ground.
      body: EmberBackground(
        banded: true,
        child: ListenableBuilder(
          listenable: widget.xray,
          builder: (context, _) => ListView(
            padding: EdgeInsets.fromLTRB(
              18,
              MediaQuery.of(context).padding.top + kToolbarHeight + 6,
              18,
              24,
            ),
            children: [
              // Build 2144 (reskin): the samples' huge light
              // page title (the AppBar keeps only the back
              // arrow).
              Text('RegionHop', style: Ember.hero),
              const SizedBox(height: 6),
              // Build 2145 (composition rebuild, pro6-regionhop
              // sample): the sample's subtitle line under the
              // hero title (the sample's own wording), then a
              // panel-state line built ONLY from this page's
              // real state — the connected location when a
              // session is live here, the stale flag when the
              // last fetch failed, otherwise the loaded row
              // count. Panel uptime and panel-level Stop /
              // Restart are GAPS: the client exposes neither
              // (actions stay per-location Start/Stop).
              const Text(
                'Self-hosted Psiphon panel',
                style: TextStyle(
                  fontSize: Ember.fontDisplay,
                  fontWeight: FontWeight.w300,
                  color: Ember.dim,
                ),
              ),
              const SizedBox(height: 12),
              _PanelStateLine(
                xray: widget.xray,
                inList: _inList,
                locations: _locations,
                stale: _stale,
                listState: _listState,
              ),
              const SizedBox(height: 18),
              if (!_inList)
                _SetupSection(
                  urlController: _url,
                  passwordController: _password,
                  relaysController: _relays,
                  relayErrors: _relayBlock.errors,
                  pageError: _pageError,
                  loginBusy: _loginBusy,
                  onRelaysChanged: () => setState(() {}),
                  onConnect: _loginBusy
                      ? null
                      : () => unawaited(_connectToPanel()),
                )
              else ...[
                if (_pageError != null) regionHopErrorLine(_pageError!),
                if (_rowError != null) regionHopErrorLine(_rowError!),
                _Section(
                  title: 'Locations',
                  children: [
                  if (_locations.isEmpty)
                    RegionHopListEmpty(
                      state: _listState,
                      error: _listLoadError,
                    )
                  else
                    for (final location in _locations)
                      _LocationRow(
                        location: location,
                        xray: widget.xray,
                        relay: _relayBlock.relays[location.name],
                        probe: _probes[location.name],
                        stale: _stale,
                        connectBusy: _connectBusy,
                        probing: _probing.contains(location.name),
                        acting: _acting.contains(location.name),
                        onCheck: () => unawaited(_probe(location)),
                        onStart: () => unawaited(_act(location, true)),
                        onStop: () => unawaited(_act(location, false)),
                        onConnect: _relayBlock.relays[location.name] == null
                            ? null
                            : () => unawaited(
                                _connect(
                                  location,
                                  _relayBlock.relays[location.name]!,
                                ),
                              ),
                        onDisconnect: () => unawaited(_disconnect()),
                      ),
                  ],
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    // Build 2149 (audit A43-01): after an
                    // auth-stopped poll, the way back is a
                    // deliberate tap — a fresh client, one
                    // login attempt, the owner's action.
                    if (_authStopped)
                      regionHopSmallButton('Reconnect', () {
                        setState(() => _authStopped = false);
                        unawaited(_connectToPanel());
                      }),
                    if (_authStopped) const SizedBox(width: 10),
                    regionHopSmallButton('Edit panel details', () {
                      _pollTimer?.cancel();
                      setState(() => _inList = false);
                    }),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// What the Locations section's empty area may claim
/// (build 2140, leg B). Until a status fetch completes,
/// the list is [loading]; a fetch that failed leaves it
/// [loadFailed]; only a fetch that SUCCEEDED with zero
/// rows earns [empty] — the one state whose wording says
/// the panel has no locations.
enum RegionHopListState { loading, loadFailed, empty }

/// The Locations section's empty area (build 2140,
/// leg B): three honest states. Before this build a
/// failed load with no rows rendered the [empty] wording
/// — 'No locations on this panel yet' — which sent the
/// owner to add locations that already existed; a failed
/// load now says so, with the error, in the empty area
/// itself.
class RegionHopListEmpty extends StatelessWidget {
  const RegionHopListEmpty({super.key, required this.state, this.error});

  final RegionHopListState state;

  /// The last fetch failure's message (loadFailed only).
  final String? error;

  @override
  Widget build(BuildContext context) {
    if (state == RegionHopListState.loadFailed) {
      return regionHopErrorLine(
        'Could not load the locations — ${error ?? 'unknown error'}',
      );
    }
    if (state == RegionHopListState.loading) {
      return Text('Loading locations…', style: Ember.dimStyle);
    }
    return Text(
      'No locations on this panel yet — add them '
      'in the web panel.',
      style: Ember.dimStyle,
    );
  }
}

/// The RegionHop panel flow's journal writer (build
/// 2140, leg B): login, status-fetch, probe and
/// start/stop outcomes land in the diagnostics journal
/// (and its on-disk mirror), so a diagnostics export
/// shows what the app actually received from the panel.
/// Lines carry outcomes, row counts and error KINDS
/// only — plus, since build 2141, a transport failure's
/// sanitized shape (class, exception type, OS error
/// code; never an address) — never the panel URL or its
/// path prefix, the password, the session cookie, a
/// probe's exit IP, or relay credentials.
///
/// The status poll runs every 5 s while the page is
/// visible, so fetch lines are written on outcome
/// TRANSITIONS only (the A34-02 journal-dedupe
/// precedent): a steady state journals once, every
/// change of state journals again. Login resets the
/// fetch signature — a new session's first fetch always
/// journals.
///
/// Build 2141: a transport failure's sanitized shape
/// (class, exception type, OS error code — never an
/// address) rides the fetch lines, and the status
/// fetch's single retry journals as its own transition
/// line under its own signature. A recovery (or a fresh
/// login) re-arms both signatures, so a later identical
/// failure episode journals once more.
///
/// Build 2142: a fetch's phase timings (open / headers
/// / body — milliseconds, failure classes, '-' for a
/// phase never reached) journal on the same transition
/// discipline: once per failure shape while fetches
/// fail, and once more for the first success after a
/// failure. An ordinary success journals no phase line.
class RegionHopJournal {
  RegionHopJournal(this._add);

  final void Function(String text, {bool? ok}) _add;

  String? _fetchSignature;
  String? _retrySignature;
  String? _phasesSignature;
  bool _phasesAfterFailure = false;

  void loginOk() {
    _fetchSignature = null;
    _retrySignature = null;
    _phasesSignature = null;
    _phasesAfterFailure = false;
    _add('panel login ok', ok: true);
  }

  void loginFailed(RegionHopErrorKind kind) {
    _add('panel login failed — ${kind.name}', ok: false);
  }

  void fetchOk(int rows) {
    final signature = 'ok:$rows';
    if (signature == _fetchSignature) return;
    _fetchSignature = signature;
    _retrySignature = null;
    _add(
      'status fetch ok — $rows location${rows == 1 ? '' : 's'}',
      ok: true,
    );
  }

  /// The status fetch's first attempt failed on the
  /// transport and the fetch is retrying (build 2141).
  void fetchRetrying(RegionHopTransportFailure failure) {
    final signature = 'retry:${failure.journalTokens}';
    if (signature == _retrySignature) return;
    _retrySignature = signature;
    _add(
      'status fetch attempt failed — unreachable '
      '(${failure.journalTokens}) — retrying',
      ok: false,
    );
  }

  void fetchFailed(
    RegionHopErrorKind kind, [
    RegionHopTransportFailure? transport,
  ]) {
    final detail = transport == null ? '' : ' (${transport.journalTokens})';
    final signature = 'err:${kind.name}$detail';
    if (signature == _fetchSignature) return;
    _fetchSignature = signature;
    _add('status fetch failed — ${kind.name}$detail', ok: false);
  }

  /// A status fetch's conclusion phases (build 2142):
  /// where the decisive attempt spent its time. A
  /// failure journals its phases once per outcome shape
  /// (the numbers differ every poll; the shape is the
  /// transition); the first success after a failure
  /// journals its phases once, closing the episode; an
  /// ordinary success journals nothing.
  void fetchPhases(RegionHopPhaseTimings phases, {required bool ok}) {
    if (!ok) {
      _phasesAfterFailure = true;
      final signature = phases.shape;
      if (signature == _phasesSignature) return;
      _phasesSignature = signature;
      _add('status fetch phases — ${phases.journalTokens}', ok: false);
    } else {
      if (!_phasesAfterFailure) return;
      _phasesAfterFailure = false;
      _phasesSignature = null;
      _add('status fetch phases — ${phases.journalTokens}', ok: true);
    }
  }

  void probeOutcome(String name, bool passed) {
    _add('probe $name ${passed ? 'passed' : 'did not pass'}', ok: passed);
  }

  void probeFailed(String name, RegionHopErrorKind kind) {
    _add('probe $name failed — ${kind.name}', ok: false);
  }

  void actionOutcome(String name, bool start) {
    _add('${start ? 'start' : 'stop'} $name ok', ok: true);
  }

  void actionFailed(String name, bool start, RegionHopErrorKind kind) {
    _add(
      '${start ? 'start' : 'stop'} $name failed — ${kind.name}',
      ok: false,
    );
  }
}

/// The page's error line (panel errors, parse problems,
/// the relay-down hint).
Widget regionHopErrorLine(String text) => Padding(
  padding: const EdgeInsets.only(top: 2, bottom: 6),
  child: Text(
    text,
    style: Ember.body.copyWith(
      color: Ember.orange,
      fontSize: Ember.fontSmall,
    ),
  ),
);

/// The page's small text button. Build 2144 (reskin): a
/// quiet outline pill (the samples' STOP / RESTART shape),
/// same label and tap.
Widget regionHopSmallButton(String label, VoidCallback? onPressed) =>
    TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        minimumSize: const Size(0, 32),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        side: const BorderSide(color: MapUi.lineStrong),
        shape: const StadiumBorder(),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: onPressed == null ? Ember.faint : Ember.text,
          fontSize: Ember.fontSmall,
        ),
      ),
    );

/// The tile's connect pill (build 2144, reskin): flat orange
/// for the connected row's Disconnect, a quiet outline for
/// Connect — the pro6-regionhop sample's pair. A null
/// [onTap] is the disabled state, drawn dimmed.
Widget regionHopConnectPill(
  String label,
  VoidCallback? onTap, {
  required bool filled,
}) => Material(
  color: Colors.transparent,
  child: InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(999),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
      decoration: BoxDecoration(
        color: filled
            ? (onTap == null ? Ember.cardSoft : Ember.orange)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(999),
        border: filled
            ? null
            : Border.all(
                color: onTap == null ? MapUi.line : MapUi.lineStrong,
              ),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: Ember.fontSmall,
          fontWeight: FontWeight.w700,
          color: filled
              ? (onTap == null ? Ember.faint : const Color(0xFF1A1206))
              : (onTap == null ? Ember.faint : Ember.text),
        ),
      ),
    ),
  ),
);

/// One location's row on the RegionHop page: status
/// chip, exit line (country, and the probed IP + latency
/// once a Check has run), Check / Start / Stop, and
/// Connect / Disconnect with its block reason as a line
/// of its own. Stateless — the page owns the client, the
/// polling and the session; the tile only renders and
/// reports taps.
class RegionHopLocationTile extends StatelessWidget {
  const RegionHopLocationTile({
    super.key,
    required this.location,
    required this.relay,
    required this.probe,
    required this.sessionHere,
    required this.sessionVerified,
    required this.stale,
    required this.connectBusy,
    required this.probing,
    required this.acting,
    required this.onCheck,
    required this.onStart,
    required this.onStop,
    required this.onConnect,
    required this.onDisconnect,
  });

  final RegionHopLocation location;
  final RegionHopRelay? relay;
  final RegionHopProbe? probe;
  final bool sessionHere;
  final bool sessionVerified;
  final bool stale;
  final bool connectBusy;
  final bool probing;
  final bool acting;
  final VoidCallback onCheck;
  final VoidCallback onStart;
  final VoidCallback onStop;
  final VoidCallback? onConnect;
  final VoidCallback onDisconnect;

  @override
  Widget build(BuildContext context) {
    final r = relay;
    final block = regionHopConnectBlock(location, r);
    final portMismatch =
        r != null && r.port != regionHopRelayPortFor(location.socksPort);
    final p = probe;
    final exitLine = location.exitRegion.isNotEmpty
        ? 'Exit ${location.exitRegion}'
              '${p != null && p.ok && p.ip.isNotEmpty ? ' · ${p.ip}' : ''}'
              '${p != null && p.ok && p.latencyMs > 0 ? ' · ${latDigits(p.latencyMs)} ms' : ''}'
        : p != null && p.ok && p.ip.isNotEmpty
        ? 'Exit ${p.ip}'
              '${p.latencyMs > 0 ? ' · ${latDigits(p.latencyMs)} ms' : ''}'
        : 'No exit measured yet';
    // Build 2144 (reskin, pro6-regionhop sample): the row is
    // typographic — huge light country-code letters, the
    // region name and chip, the exit line in orange
    // monospace once a probe has measured it, the probe
    // latency as a big light numeral, and the connect pill.
    // Every string, action and gate below is the row's own.
    // Build 2145 (composition rebuild): the section is now
    // FULL-BLEED — no card fill or border anywhere; a
    // hairline divider alone separates sections. The
    // country letters sit at the numeral scale, the line
    // under them is country · city where the panel's region
    // label carries both ('DE - Germany' carries country
    // only — a city is a GAP, never invented), and the
    // connect pill sits under the latency numeral, as in
    // the sample. The region label's leading code is not
    // repeated in the line: the giant letters already are
    // that code.
    final regionLabel = location.region.isNotEmpty
        ? location.region
        : location.name;
    final regionDash = regionLabel.indexOf(' - ');
    final countryLine = regionDash > 0
        ? regionLabel.substring(regionDash + 3)
        : regionLabel;
    return Opacity(
      opacity: stale ? 0.55 : 1,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Build 2145 (UI-review fix A9): the giant
                // letters render at their true size — the
                // two-letter codes fit the slot at scale 1.0
                // with room; no FittedBox shrink against the
                // user's text scale.
                // Batch 5 (fidelity rollout — MEASURED
                // CORRECTION): at Ember.numeral's 100 px the
                // two-letter codes measure ≈133 dp wide —
                // they do NOT fit the 118 slot, and a
                // softWrap:false ellipsized line wider than
                // its box paints NOTHING (golden-verified:
                // the slot rendered empty). The letters now
                // carry their own 82 px size (≈109 dp for
                // the widest pair), still the numeral face
                // and weight; the slot is unchanged.
                SizedBox(
                  width: 118,
                  child: Text(
                    location.name.toUpperCase(),
                    style: Ember.numeral.copyWith(fontSize: Ember.fontCode),
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Build 2145 (UI-review fix A4): a Wrap,
                      // not a Row — at large text scales the
                      // middle column narrows until the status
                      // chip no longer fits beside the country
                      // name; the chip then wraps under it
                      // instead of overflowing the row. At
                      // scale 1.0 the composition is unchanged.
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            countryLine,
                            style: const TextStyle(
                              fontSize: Ember.fontHeadline,
                              fontWeight: FontWeight.w600,
                              color: Ember.text,
                            ),
                          ),
                          _TileChip(location: location),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        exitLine,
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: Ember.fontSmall,
                          color: p != null && p.ok
                              ? Ember.orange
                              : Ember.dim,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    if (p != null && p.ok && p.latencyMs > 0)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            latDigits(p.latencyMs),
                            style: TextStyle(
                              // Build 2148 (owner device verdict
                              // on 2147): a list row's probe
                              // latency wears the normal row
                              // size, not the hero scale — the
                              // same ruling as the config rows.
                              fontSize: Ember.fontTitle,
                              // Build 2147 (#22): health colour,
                              // not white.
                              color: mapPingColor(p.latencyMs),
                              height: 1.0,
                            ),
                          ),
                          Text('ms', style: Ember.caption),
                        ],
                      ),
                    const SizedBox(height: 8),
                    if (sessionHere)
                      regionHopConnectPill(
                        'Disconnect',
                        connectBusy ? null : onDisconnect,
                        filled: true,
                      )
                    else
                      regionHopConnectPill(
                        'Connect',
                        block != null || connectBusy ? null : onConnect,
                        filled: false,
                      ),
                  ],
                ),
              ],
            ),
            if (p != null && !p.ok && p.detail.isNotEmpty)
              regionHopErrorLine(p.detail),
            if (sessionHere && !sessionVerified)
              regionHopErrorLine(
                'The tunnel is up but the relay did not answer — '
                'check regionhop-relay@${location.name} on the '
                'server.',
              ),
            const SizedBox(height: 8),
            Row(
              children: [
                regionHopSmallButton(
                  probing ? 'Checking…' : 'Check',
                  probing ? null : onCheck,
                ),
                const SizedBox(width: 8),
                if (location.isActive)
                  regionHopSmallButton('Stop', acting ? null : onStop)
                else
                  regionHopSmallButton('Start', acting ? null : onStart),
              ],
            ),
            // The reason a row cannot connect is a line of
            // its own under the buttons — as a button label
            // it overflowed the row (build2139 test catch).
            // The port mismatch is an error state, so it
            // wears the error styling; the rest are dim.
            if (!sessionHere && block != null)
              portMismatch
                  ? regionHopErrorLine(block)
                  : Text(block, style: Ember.dimStyle),
            // The sample's bottom exit strip: the connected
            // row's measured exit, monospace on a card fill —
            // only when a probe actually measured it.
            if (sessionHere && p != null && p.ok && p.ip.isNotEmpty) ...[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  color: Ember.card,
                  borderRadius: BorderRadius.circular(Ember.radiusButton),
                ),
                child: Text(
                  exitLine,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: Ember.fontSmall,
                    color: Ember.dim,
                  ),
                ),
              ),
            ],
            // Build 2145: the hairline is the section's only
            // separator — no tile chrome above or below it.
            const Divider(color: Ember.line, height: 26),
          ],
        ),
      ),
    );
  }
}

/// Build 2145 (UI-review fix A10): the page's former
/// Widget-returning helper methods are widget CLASSES now
/// (widget-composition rule 1) — same trees, same state flow:
/// the page state passes its values and callbacks down.

/// A hairline section under a tracked orange label (the 2144
/// reskin's section form — no glass panels).
class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title.toUpperCase(), style: Ember.microLabelOrange),
        const SizedBox(height: 13),
        ...children,
      ],
    ),
  );
}

/// One setup form field (the shared emberField decoration
/// with the page's label treatment).
class _SetupField extends StatelessWidget {
  const _SetupField({
    required this.controller,
    required this.label,
    this.obscure = false,
    this.maxLines = 1,
    this.hint,
    this.onChanged,
  });

  final TextEditingController controller;
  final String label;
  final bool obscure;
  final int maxLines;
  final String? hint;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 11),
    child: TextField(
      controller: controller,
      obscureText: obscure,
      maxLines: maxLines,
      style: Ember.body,
      textDirection: TextDirection.ltr,
      onChanged: onChanged,
      decoration: emberField(context, hint ?? label).copyWith(
        labelText: label,
        labelStyle: const TextStyle(
          color: Ember.faint,
          fontSize: Ember.fontBody,
        ),
        floatingLabelStyle: const TextStyle(color: Ember.orange),
      ),
    ),
  );
}

/// The Panel setup section: the three form fields, the relay
/// block's errors, the page error, the connect action and the
/// explainer line — values and callbacks from the page state.
class _SetupSection extends StatelessWidget {
  const _SetupSection({
    required this.urlController,
    required this.passwordController,
    required this.relaysController,
    required this.relayErrors,
    required this.pageError,
    required this.loginBusy,
    required this.onRelaysChanged,
    required this.onConnect,
  });

  final TextEditingController urlController;
  final TextEditingController passwordController;
  final TextEditingController relaysController;
  final List<String> relayErrors;
  final String? pageError;
  final bool loginBusy;
  final VoidCallback onRelaysChanged;
  final VoidCallback? onConnect;

  @override
  Widget build(BuildContext context) => _Section(
    title: 'Panel',
    children: [
      _SetupField(
        controller: urlController,
        label: 'Panel URL',
        hint: 'The full panel address, including its path',
      ),
      _SetupField(
        controller: passwordController,
        label: 'Panel password',
        obscure: true,
      ),
      _SetupField(
        controller: relaysController,
        label: 'Bridge credentials',
        maxLines: 4,
        hint: 'One line per location: name port user password',
        onChanged: (_) => onRelaysChanged(),
      ),
      for (final error in relayErrors) regionHopErrorLine(error),
      if (pageError != null) regionHopErrorLine(pageError!),
      Align(
        alignment: Alignment.centerRight,
        child: TextButton(
          onPressed: onConnect,
          child: loginBusy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Ember.orange,
                  ),
                )
              : const Text(
                  'Connect to panel',
                  style: TextStyle(color: Ember.orange),
                ),
        ),
      ),
      Text(
        'RegionHop is your own server’s Psiphon exits: each '
        'location is a tunnel on the server, reached through '
        'an authenticated relay on the same box. Nothing '
        'here contacts the panel until you tap Connect.',
        style: Ember.dimStyle,
      ),
    ],
  );
}

/// The header's panel-state line — a dot and a tracked micro
/// label, derived from the values the page state passes in.
class _PanelStateLine extends StatelessWidget {
  const _PanelStateLine({
    required this.xray,
    required this.inList,
    required this.locations,
    required this.stale,
    required this.listState,
  });

  final XrayController xray;
  final bool inList;
  final List<RegionHopLocation> locations;
  final bool stale;
  final RegionHopListState listState;

  @override
  Widget build(BuildContext context) {
    String connectedRegion = '';
    if (inList && xray.state.running) {
      for (final location in locations) {
        if (xray.sessionProfile?.id == 'regionhop-${location.name}') {
          connectedRegion = location.region.isNotEmpty
              ? location.region
              : location.name;
        }
      }
    }
    final (dotColor, label) = !inList
        ? (Ember.faint, 'PANEL · NOT CONNECTED')
        : connectedRegion.isNotEmpty
        ? (Ember.green, 'CONNECTED · ${connectedRegion.toUpperCase()}')
        : stale
        ? (Ember.orange, 'PANEL UNREACHABLE')
        : listState == RegionHopListState.loading
        ? (Ember.faint, 'LOADING LOCATIONS')
        : (
            Ember.green,
            'PANEL · ${latDigits(locations.length)} '
                '${locations.length == 1 ? 'LOCATION' : 'LOCATIONS'}',
          );
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(shape: BoxShape.circle, color: dotColor),
        ),
        const SizedBox(width: 8),
        Expanded(child: Text(label, style: Ember.microLabel)),
      ],
    );
  }
}

/// One location's row slot: resolves the per-location state
/// into the tile's props (the tile itself is unchanged).
class _LocationRow extends StatelessWidget {
  const _LocationRow({
    required this.location,
    required this.xray,
    required this.relay,
    required this.probe,
    required this.stale,
    required this.connectBusy,
    required this.probing,
    required this.acting,
    required this.onCheck,
    required this.onStart,
    required this.onStop,
    required this.onConnect,
    required this.onDisconnect,
  });

  final RegionHopLocation location;
  final XrayController xray;
  final RegionHopRelay? relay;
  final RegionHopProbe? probe;
  final bool stale;
  final bool connectBusy;
  final bool probing;
  final bool acting;
  final VoidCallback onCheck;
  final VoidCallback onStart;
  final VoidCallback onStop;
  final VoidCallback? onConnect;
  final VoidCallback onDisconnect;

  @override
  Widget build(BuildContext context) => RegionHopLocationTile(
    location: location,
    relay: relay,
    probe: probe,
    sessionHere:
        xray.state.running &&
        xray.sessionProfile?.id == 'regionhop-${location.name}',
    sessionVerified: xray.state.verified,
    stale: stale,
    connectBusy: connectBusy,
    probing: probing,
    acting: acting,
    onCheck: onCheck,
    onStart: onStart,
    onStop: onStop,
    onConnect: onConnect,
    onDisconnect: onDisconnect,
  );
}

/// The location tile's status chip (Active / Connecting /
/// other), coloured by state.
class _TileChip extends StatelessWidget {
  const _TileChip({required this.location});

  final RegionHopLocation location;

  @override
  Widget build(BuildContext context) {
    final active = location.chipLabel == 'Tunnel up';
    final connecting = location.chipLabel == 'Connecting';
    final color = active
        ? Ember.orange
        : connecting
        ? Ember.text
        : Ember.faint;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color),
      ),
      child: Text(
        location.chipLabel,
        style: TextStyle(color: color, fontSize: Ember.fontSmall),
      ),
    );
  }
}
