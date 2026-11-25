/// The DPI Strategy Lab page (build 2107; design:
/// ~/workspace/ember-app/dpi-lab-design.md).
///
/// A wizard over the shaping layer: pick one of your V2Ray
/// configs, run discovery, and the Lab tests each evasion
/// strategy with real requests through throwaway cores on
/// THIS network — the same requests the app's own delay test
/// makes — then confirms the first strategy that answers
/// with the endurance check (three requests over one
/// keep-alive connection) before calling it a winner. The
/// winner can be remembered per network; later connects on
/// that network dial it first.
///
/// Honesty rules the page keeps: a strategy that answers and
/// then freezes is labelled exactly that and is never offered
/// as a winner; every verdict shows its measured evidence;
/// discovery never touches a live session (throwaway cores
/// only); and configs the Lab cannot shape or grade —
/// WireGuard, Hysteria2, QUIC and sidecar-engine configs —
/// are not listed, with the reason stated.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../xray/dpi_lab.dart';
import '../../xray/xray_controller.dart';
import '../../xray/xray_models.dart';
import 'ember_format.dart';
import 'ember_theme.dart';
// Batch 5: the map_widgets import retired with the last
// MapGlass on this page — MapUi lives in ember_theme.dart.
import 'senpai_page.dart';

class DpiLabPage extends StatefulWidget {
  const DpiLabPage({super.key, required this.xray, this.initialProfileId});

  final XrayController xray;

  /// The config to preselect — set when the page is opened
  /// from the failed-connect offer on Home.
  final String? initialProfileId;

  @override
  State<DpiLabPage> createState() => _DpiLabPageState();
}

class _DpiLabPageState extends State<DpiLabPage> {
  String _profileId = '';
  bool _running = false;
  bool _stop = false;
  bool _stopping = false;

  /// The last run ended because the user stopped it — the
  /// no-winner card says so instead of presenting a partial
  /// run as a completed negative result.
  bool _stoppedRun = false;

  /// The fingerprint the current win was filed under (the
  /// Forget controls clear the winner card's caption when
  /// they remove exactly this win).
  String _filedFp = '';

  /// A Remember / Connect-now action is in flight: both
  /// buttons disable, so a double-tap cannot double-pop the
  /// navigator or race two connects (build 2107,
  /// verification iteration 1).
  bool _acting = false;

  /// The profile the current results were measured on,
  /// captured at Run time — the picker selection can be
  /// deleted mid-run, and the winner card must still act on
  /// the config that was actually tested.
  Profile? _runProfile;

  List<DpiLabResult> _results = [];
  bool _remembered = false;

  /// The candidate ids the current (or last) run tests, in
  /// probe order (build 2120): the full candidate list
  /// minus the owner's unticked set, captured at Run time —
  /// the rows derive "Testing…" / "Waiting" / "Not in this
  /// run" from it, and a stopped run is judged against its
  /// length, not the full list's.
  List<String> _runOrder = [];

  /// The candidate the owner filed BY HAND from the results
  /// list (build 2115) — '' when nothing was hand-picked.
  /// The picked row shows "Your pick"; its verdict label is
  /// never rewritten, and filing a different strategy (the
  /// winner card, or another row) replaces it.
  String _pickedId = '';

  /// The network label the win was actually filed under
  /// (returned by the controller), not the live fingerprint
  /// read at display time.
  String _filedLabel = '';

  /// A strategy-feed check is in flight (build 2114), and
  /// the user-ready line its last run produced.
  bool _updatingStrategies = false;
  String _strategyNote = '';

  XrayController get xray => widget.xray;

  List<Profile> get _eligible => [
    for (final p in xray.profiles)
      if (dpiLabEligible(p)) p,
  ];

  Profile? get _selectedProfile {
    for (final p in _eligible) {
      if (p.id == _profileId) return p;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    final initial = widget.initialProfileId ?? '';
    if (initial.isNotEmpty && _eligible.any((p) => p.id == initial)) {
      _profileId = initial;
    } else if (xray.selected != null && dpiLabEligible(xray.selected!)) {
      _profileId = xray.selected!.id;
    } else if (_eligible.isNotEmpty) {
      _profileId = _eligible.first.id;
    }
    // The network label (and any memory application) keys on
    // the fingerprint — make sure it is fresh for this page.
    xray.refreshNetworkFingerprint().then((_) {
      if (mounted) setState(() {});
    });
    // Persist any stale-win eviction the list below performs
    // in memory (verification iteration 2).
    unawaited(xray.pruneDpiLabMemory());
  }

  @override
  void dispose() {
    _stop = true;
    super.dispose();
  }

  Future<void> _pickProfile() async {
    // Build 2148 (FIX 7, class 6 — the owner's Mozilla
    // Locations defect class): this config picker was a
    // shrink-wrapped bottom sheet — a chooser opening at
    // half height over the page. It is a pushed FULL page
    // now, the same rows and the same result, with a BACK
    // header in the 2148 navigation model.
    final picked = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (pageContext) => Scaffold(
          backgroundColor: Ember.bg,
          body: EmberBackground(
            // Build 2149 (audit A48-02): the short band, as
            // the main Lab page below.
            bandShort: true,
            child: SafeArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 10, 16, 4),
                    child: Row(
                      children: [
                        IconButton(
                          icon: const Icon(
                            Icons.arrow_back_rounded,
                            color: Ember.orange,
                          ),
                          tooltip: 'Back',
                          onPressed: () => Navigator.of(pageContext).pop(),
                        ),
                        Text(
                          'Choose a config',
                          style: Ember.title.copyWith(color: Ember.text),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: ListView(
                      children: [
                        for (final p in _eligible)
                          ListTile(
                            leading: Icon(
                              p.id == _profileId
                                  ? Icons.radio_button_checked_rounded
                                  : Icons.radio_button_unchecked_rounded,
                              color: Ember.orange,
                              size: 19,
                            ),
                            title: Text(
                              p.displayName,
                              style: Ember.body.copyWith(color: Ember.text),
                            ),
                            subtitle: Text(
                              '${p.protocol.label} · ${p.address}:${p.port}',
                              style: Ember.caption,
                            ),
                            onTap: () =>
                                Navigator.of(pageContext).pop(p.id),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    if (picked != null && mounted) {
      setState(() {
        _profileId = picked;
        _results = [];
        _runOrder = [];
        _remembered = false;
        _pickedId = '';
        _runProfile = null;
        _filedLabel = '';
        _filedFp = '';
      });
    }
  }

  Future<void> _run() async {
    final p = _selectedProfile;
    if (p == null || _running) return;
    // Build 2120: the run tests the ticked subset only.
    // The Run button is disabled at zero ticked, so an
    // empty order here is only a race with an untick —
    // refuse quietly rather than starting a run that
    // tests nothing and reads as "did not start".
    final order = [
      for (final c in dpiLabCandidatesFor(p))
        if (!xray.dpiLabSweepExcluded.contains(c.id)) c.id,
    ];
    if (order.isEmpty) return;
    setState(() {
      _running = true;
      _stop = false;
      _stopping = false;
      _stoppedRun = false;
      _runProfile = p;
      _runOrder = order;
      _results = [];
      _remembered = false;
      _pickedId = '';
      _filedLabel = '';
      _filedFp = '';
    });
    try {
      final results = await xray.runDpiLab(
        p,
        onResult: (r) {
          if (mounted) setState(() => _results = [..._results, r]);
        },
        isCancelled: () => _stop,
      );
      if (mounted) {
        setState(() {
          _results = results;
          // "Stopped" means the stop actually truncated the
          // run — a stop pressed during the final candidate
          // leaves a complete result set (iteration 4).
          // Build 2120: completeness is judged against the
          // run's own ticked subset, not the full list.
          _stoppedRun = _stop && results.length < _runOrder.length;
        });
        // An empty result set means either the user stopped
        // before the first probe landed, or the controller
        // refused the run — the Lab is off, or a previous
        // page's run is still finishing (verification
        // iterations 3–4).
        if (results.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                _stop
                    ? 'The run was stopped before the first test.'
                    : 'The run did not start — the Lab may be '
                          'off, or another Lab run may still be '
                          'finishing.',
              ),
            ),
          );
        }
      }
    } catch (_) {
      // The run is the controller's to journal; the page must
      // never wedge in the running state on a throw
      // (verification iteration 2).
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('The Lab run could not finish.')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _running = false;
          _stopping = false;
        });
      }
    }
  }

  /// Remembers the winner; returns true only when a win was
  /// actually recorded, and says so when it was not — the
  /// page never announces a remember that silently no-oped.
  Future<bool> _remember() async {
    final p = _runProfile ?? _selectedProfile;
    final winner = dpiLabWinner(_results);
    if (p == null || winner == null || _acting) return false;
    setState(() => _acting = true);
    String fp;
    try {
      fp = await xray.rememberDpiLabWin(p, winner);
    } catch (_) {
      // A failed save must not wedge the page's buttons or
      // surface as an unhandled async error (verification
      // iteration 2).
      if (mounted) {
        setState(() => _acting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('The winner could not be saved.')),
        );
      }
      return false;
    }
    if (!mounted) return fp.isNotEmpty;
    setState(() => _acting = false);
    if (fp.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Nothing was remembered — the win could not be '
            'recorded for this network.',
          ),
        ),
      );
      return false;
    }
    setState(() {
      _remembered = true;
      _filedLabel = dpiLabNetworkLabel(fp);
      _filedFp = fp;
      // The filed strategy is now the winner: a hand pick of
      // a different strategy no longer names what is filed.
      if (_pickedId != winner.candidate.id) _pickedId = '';
    });
    return true;
  }

  /// Files [r] as this network's strategy at the owner's
  /// explicit pick (build 2115): any result that ANSWERED
  /// can be picked — not only the confirmed winner — during
  /// the run or after it. The controller's gate still
  /// refuses a blocked result (it never answered), and the
  /// row keeps its honest verdict label either way: a pick
  /// is the owner's decision, never a re-labelled win.
  Future<void> _pickManually(DpiLabResult r) async {
    final p = _runProfile ?? _selectedProfile;
    if (p == null || _acting) return;
    if (!dpiLabCanRemember(r, manual: true)) return;
    setState(() => _acting = true);
    String fp;
    try {
      fp = await xray.rememberDpiLabWin(p, r, manual: true);
    } catch (_) {
      if (mounted) {
        setState(() => _acting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('That pick could not be saved.')),
        );
      }
      return;
    }
    if (!mounted) return;
    setState(() => _acting = false);
    if (fp.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Nothing was filed — the pick could not be '
            'recorded for this network.',
          ),
        ),
      );
      return;
    }
    final winner = dpiLabWinner(_results);
    setState(() {
      _pickedId = r.candidate.id;
      _filedLabel = dpiLabNetworkLabel(fp);
      _filedFp = fp;
      // Picking the confirmed winner by hand files the same
      // win the winner card's Remember files.
      if (winner != null && winner.candidate.id == r.candidate.id) {
        _remembered = true;
      }
    });
  }

  Future<void> _connectNow() async {
    if (dpiLabWinner(_results) == null || _acting) return;
    // The connect target must be a config that still exists
    // in the list: the tested object can outlive its entry
    // (deleted mid-run), and connect() acts on the SELECTION
    // — dialing through a detached object would silently
    // connect whatever the selection falls back to
    // (verification iteration 2). Remembering a win for a
    // deleted config stays fine (a win is a property of the
    // network); connecting it does not.
    final p = _selectedProfile;
    if (p == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'That config is no longer in your list — pick '
            'another config to connect.',
          ),
        ),
      );
      return;
    }
    // An already-remembered win is not re-remembered: a
    // re-record would re-stamp the trust window with the tap
    // time and duplicate the journal line, for a win whose
    // evidence age runs from its measurement (verification
    // iteration 3).
    if (!_remembered && !await _remember()) return;
    if (!mounted) return;
    // A connect or switch already in flight owns the core —
    // never race a second one against it.
    if (xray.connecting || xray.switchingProfileId != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('A connection is already in progress.')),
      );
      return;
    }
    // A paused session is held, not ended: it is invisible
    // to the running checks below (and its engine flags are
    // derived from running), so it is named here rather than
    // misrouted into a fresh connect (iteration 3).
    if (xray.state.paused) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'A session is paused — resume or disconnect it '
            'first, then connect.',
          ),
        ),
      );
      return;
    }
    if (xray.state.running) {
      // "This config is the session" is judged by the
      // CONNECTED profile id, never by the selection fallback
      // chain, which can name the selected config for a
      // session that belongs to another engine entirely —
      // and never for a WARP/AWG session: sessionProfile
      // masks WARP outright, and an AWG session's connected
      // id can be refilled from the selection at adoption,
      // so the explicit engine guards below are load-bearing
      // (iteration 3, comment corrected iteration 4).
      final sp = xray.sessionProfile;
      if (!xray.warpSession &&
          !xray.awgSession &&
          sp != null &&
          sp.id == p.id &&
          xray.connectedProfileId == p.id) {
        // The winner IS the live session's config: bouncing
        // it would drop a working session to re-dial the
        // same server. The remembered strategy applies from
        // the next connect.
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Already connected to this config — the '
              'remembered strategy applies from the next '
              'connect.',
            ),
          ),
        );
        return;
      }
      // select() can only switch an Xray-core session. A WARP
      // session has no connected profile for it to switch
      // (it would silently change only the selection), and a
      // WireGuard / sidecar session falls back to an
      // unmonitored reconnect whose failure nobody would
      // report — so for those, the honest move is to say so
      // (verification iteration 2).
      final xrayCoreSession =
          !xray.warpSession &&
          !xray.awgSession &&
          sp != null &&
          sp.id == xray.connectedProfileId &&
          sp.protocol != Protocol.wireguard &&
          !xray.servedViaSidecar(sp);
      if (!xrayCoreSession) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Another engine session is live — disconnect '
              'it first, then connect.',
            ),
          ),
        );
        return;
      }
      // A different Xray config is live: select() runs the
      // controller's own switch path (seamless when the
      // session can rotate, a full reconnect otherwise).
      // Calling connect() as well would race that switch
      // with a second attempt (verification iteration 1).
      xray.select(p);
      Navigator.of(context).pop();
      return;
    }
    xray.select(p);
    setState(() => _acting = true);
    try {
      await xray.connect();
    } catch (_) {
      // The failure is the controller's to journal; the user
      // gets a visible word here instead of an unhandled
      // async error and a silent page (verification
      // iteration 1 — every sibling entry point reports).
      if (mounted) {
        setState(() => _acting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Connect failed: ${xray.lastError ?? 'see Diagnostics'}',
            ),
          ),
        );
      }
      return;
    }
    // A user-cancelled attempt returns from connect()
    // normally (the controller swallows the cancellation) —
    // the page must not pop as if it succeeded when no
    // session is actually up (verification iteration 3).
    if (mounted && !xray.state.running) {
      setState(() => _acting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('The connection was cancelled.')),
      );
      return;
    }
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _checkStrategyUpdates() async {
    setState(() {
      _updatingStrategies = true;
      _strategyNote = '';
    });
    final note = await xray.refreshDpiStrategies();
    if (!mounted) return;
    setState(() {
      _updatingStrategies = false;
      _strategyNote = note;
    });
  }

  @override
  // Build 2116 (B13-8, 2107-L5): the controller listening
  // follows the sibling pages' shared pattern — a
  // ListenableBuilder over the controller — instead of this
  // page's one manual addListener/setState pair.
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: xray,
      builder: (context, _) => _LabPageView(
        xray: xray,
        results: _results,
        selectedProfile: _selectedProfile,
        runProfile: _runProfile,
        eligible: _eligible,
        running: _running,
        acting: _acting,
        stopping: _stopping,
        stoppedRun: _stoppedRun,
        runOrder: _runOrder,
        pickedId: _pickedId,
        remembered: _remembered,
        filedLabel: _filedLabel,
        filedFp: _filedFp,
        updatingStrategies: _updatingStrategies,
        strategyNote: _strategyNote,
        ageLabel: _ageLabel,
        onStop: _requestStop,
        onPickProfile: _pickProfile,
        onRun: _run,
        onConnectNow: _connectNow,
        onRemember: _remember,
        onCheckStrategyUpdates: _checkStrategyUpdates,
        onPickManually: _pickManually,
        onForgetAll: _forgetAllWins,
        onForgetWin: _forgetWin,
      ),
    );
  }

  /// Build 2145 (UI-review fix A10): the page view's stop /
  /// forget actions — the exact bodies the inline closures
  /// ran when this composition lived in a state method.
  void _requestStop() => setState(() {
    _stop = true;
    _stopping = true;
  });

  void _forgetAllWins() {
    xray.clearDpiLabMemory();
    // The winner card must not keep claiming a remember that
    // no longer exists (verification iteration 3).
    setState(() {
      _remembered = false;
      _pickedId = '';
      _filedLabel = '';
      _filedFp = '';
    });
  }

  void _forgetWin(String key) {
    xray.forgetDpiLabWin(key);
    if (key == _filedFp) {
      setState(() {
        _remembered = false;
        _pickedId = '';
        _filedLabel = '';
        _filedFp = '';
      });
    }
  }

  String _ageLabel(int verifiedMs) {
    final age = DateTime.now().millisecondsSinceEpoch - verifiedMs;
    if (age < 60 * 1000) return 'just now';
    if (age < 3600 * 1000) return '${age ~/ (60 * 1000)} min ago';
    if (age < 24 * 3600 * 1000) return '${age ~/ (3600 * 1000)} h ago';
    return '${age ~/ (24 * 3600 * 1000)} d ago';
  }
}

/// Batch 5: the flat hairline panel — the batch-4 recipe
/// (WireGuard's session table): the quiet card fill, a
/// 1 px hairline frame, the panel radius. The Lab's one
/// framed surface (the winner call to action).
class _HairlinePanel extends StatelessWidget {
  const _HairlinePanel({required this.child, required this.padding});

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: MapUi.card,
        borderRadius: MapUi.panelBorder,
        border: Border.all(color: MapUi.line),
      ),
      child: child,
    );
  }
}

/// Build 2118 (appearance fix round): the Lab's action
/// button — a glowing glass pill (orange outline, translucent
/// ember fill, orange text) instead of the app-wide solid
/// gradient EmberButton. The samples reserve solid orange
/// fills for small status pills (ON, ACTIVE) and give page
/// actions this outlined-glass shape (the ghost pills of the
/// panel headers). Same contract as EmberButton: a null
/// [onTap] is the disabled state, drawn dimmed.
class _LabAction extends StatelessWidget {
  const _LabAction({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onTap;

  @override
Widget build(BuildContext context) {
  final enabled = onTap != null;
  final color = enabled ? Ember.orange : MapUi.faint;
  return Material(
    color: Colors.transparent,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        height: 46,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          // A mostly-opaque cool-slate fill: the first
          // builds used a translucent orange/white wash and
          // the pill's own orange glow shadow showed
          // THROUGH it, tinting the whole pill brown. The
          // ember lives in the edge, the text and the
          // (now subtler) glow — the samples' ghost pill.
          // Build 2144 (reskin): the fill is the neutral
          // charcoal panel token (was a blue-tinted slate).
          // Batch 5 (fidelity rollout): the glow and the
          // orange edge retire — the pill is the slim-bar
          // form (the Home R2 bar, the RegionHop connect
          // pill): the quiet card fill, a hairline frame,
          // the tracked word; the orange lives in the
          // glyph and the word alone.
          color: enabled ? MapUi.card : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: enabled ? MapUi.lineStrong : MapUi.line,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 8),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                label,
                style: TextStyle(
                  fontSize: Ember.fontBody,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2,
                  color: enabled ? MapUi.text : MapUi.faint,
                ),
                maxLines: 1,
                softWrap: false,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
}

/// The Lab page's whole body, as a widget class
/// (build 2145, UI-review fix A10 — formerly the state's
/// _buildPage method). The state passes its values and
/// callbacks down; every derivation the method computed at
/// its head is computed here from those same inputs.
class _LabPageView extends StatelessWidget {
  const _LabPageView({
    required this.xray,
    required this.results,
    required this.selectedProfile,
    required this.runProfile,
    required this.eligible,
    required this.running,
    required this.acting,
    required this.stopping,
    required this.stoppedRun,
    required this.runOrder,
    required this.pickedId,
    required this.remembered,
    required this.filedLabel,
    required this.filedFp,
    required this.updatingStrategies,
    required this.strategyNote,
    required this.ageLabel,
    required this.onStop,
    required this.onPickProfile,
    required this.onRun,
    required this.onConnectNow,
    required this.onRemember,
    required this.onCheckStrategyUpdates,
    required this.onPickManually,
    required this.onForgetAll,
    required this.onForgetWin,
  });

  final XrayController xray;
  final List<DpiLabResult> results;
  final Profile? selectedProfile;
  final Profile? runProfile;
  final List<Profile> eligible;
  final bool running;
  final bool acting;
  final bool stopping;
  final bool stoppedRun;
  final List<String> runOrder;
  final String pickedId;
  final bool remembered;
  final String filedLabel;
  final String filedFp;
  final bool updatingStrategies;
  final String strategyNote;
  final String Function(int verifiedMs) ageLabel;
  final VoidCallback onStop;
  final VoidCallback onPickProfile;
  final VoidCallback onRun;
  final VoidCallback onConnectNow;
  final VoidCallback onRemember;
  final VoidCallback onCheckStrategyUpdates;
  final void Function(DpiLabResult result) onPickManually;
  final VoidCallback onForgetAll;
  final void Function(String key) onForgetWin;

  @override
Widget build(BuildContext context) {
  final profile = selectedProfile;
  final winner = dpiLabWinner(results);
  final excluded = xray.profiles.length - eligible.length;
  // Stale wins are not displayed as remembered: lookup
  // applies the trust window (and evicts) before the list
  // renders.
  final wins = <String, DpiLabWin>{
    for (final e in xray.dpiLabMemory.wins.entries)
      if (xray.dpiLabMemory.lookup(e.key) != null) e.key: e.value,
  };
  // Build 2120: the candidate list for the profile the
  // card describes (the measured one once results exist,
  // else the selected one) and how many of them are
  // ticked for a run — the Run button's count, the rows'
  // tick states and the "Testing…" derivation all read
  // these, so they can never disagree.
  final labProfile = (running || results.isNotEmpty)
      ? (runProfile ?? profile)
      : (profile ?? runProfile);
  final labCandidates = labProfile == null
      ? const <DpiLabCandidate>[]
      : dpiLabCandidatesFor(labProfile);
  final labTicked = labCandidates
      .where((c) => !xray.dpiLabSweepExcluded.contains(c.id))
      .length;
  return Scaffold(
    extendBodyBehindAppBar: true,
    backgroundColor: Ember.bg,
    appBar: AppBar(
      backgroundColor: Colors.transparent,
      elevation: 0,
      foregroundColor: Ember.text,
    ),
    // Build 2147 (strict-audit F1): the banded ground.
    // Build 2149 (audit A48-02): the SHORT band — the
    // pro6-dpilab sample's band is short and faint (dots
    // in the top band only); the tall banded scrim kept
    // prose sitting on dots to ≈55% of the viewport.
    body: EmberBackground(bandShort: true, child: ListView(
      padding: EdgeInsets.fromLTRB(16, MediaQuery.of(context).padding.top + kToolbarHeight + 8, 16, 24),
      children: [
        // Build 2145 (composition rebuild, pro6-dpilab
        // sample): the header completes the sample's stack —
        // the tracked micro-label, the huge light title (the
        // page's own title string, two-line wrap allowed),
        // the sample's subtitle, and the target as a
        // monospace TARGET line — the same address the
        // config picker shows.
        // Build 2150 (engine appearance audit E49-06): the
        // head was still the heaviest in the app — the
        // two-line 54 pt title stack plus its gaps pushed
        // the first result to ≈57% of the first screen.
        // The title steps to the stat tier (44) and fits
        // ONE line at phone widths; the gaps tighten to
        // the sample's rhythm. The Lab's identity — label,
        // title string, subtitle, TARGET line, explainer —
        // is untouched; the first result lands ≈50%.
        Text('‹ STRATEGY LAB', style: Ember.microLabelOrange),
        const SizedBox(height: 10),
        Text(
          'DPI Strategy Lab',
          style: Ember.hero.copyWith(fontSize: Ember.fontStat),
          maxLines: 1,
        ),
        const SizedBox(height: 8),
        Text('Test results for the selected config', style: Ember.dimStyle),
        if (profile != null) ...[
          const SizedBox(height: 10),
          Text(
            'TARGET · ${profile.protocol.label} · '
            '${profile.address}:${latDigits(profile.port)}',
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: Ember.fontSmall,
              color: Ember.dim,
            ),
          ),
        ],
        const SizedBox(height: 12),
        // Batch 5 (fidelity rollout): the Lab's glass cards
        // retire — every section sits on the ground in the
        // samples' open composition (tracked labels, hairline
        // separators), the batch-4 hairline-panel precedent
        // carried to its end. Contents and callbacks are
        // untouched; only the containers change.
        Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Build 2147 (strict-audit F8): the intro
              // collapses to two lines; the full text rides
              // the info affordance beside it.
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      'On a filtered network, the TLS handshake '
                      'shape decides whether a config connects. '
                      'The Lab tests your ticked strategies with '
                      'real requests.',
                      style: Ember.body,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    tooltip: 'About the Lab',
                    icon: const Icon(
                      Icons.info_outline_rounded,
                      size: 19,
                      color: Ember.dim,
                    ),
                    constraints: const BoxConstraints(
                      minWidth: 48,
                      minHeight: 48,
                    ),
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('About the Lab'),
                        content: const Text(
                          'On a filtered network, a config\'s TLS '
                          'handshake shape can decide whether it '
                          'connects. The Lab tests the strategies '
                          'you tick with real requests on this '
                          'network — none of the ticked ones '
                          'skipped, even after one works — and any '
                          'that answered can be remembered for this '
                          'network. Without TLS, only Stock, TCP '
                          'noise and the Zapret engine\'s byte-level '
                          'modes apply.',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () =>
                                Navigator.of(context).pop(),
                            child: const Text('CLOSE'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  const Icon(
                    Icons.wifi_rounded,
                    size: 15,
                    color: Ember.orange,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Network: ${dpiLabNetworkLabel(xray.networkFp)}',
                    style: Ember.caption,
                  ),
                ],
              ),
              if (xray.state.running) ...[
                const SizedBox(height: 6),
                Text(
                  'A session is live — discovery uses throwaway '
                  'test cores and never touches it.',
                  style: Ember.caption,
                ),
              ],
              if (xray.scanRunning) ...[
                const SizedBox(height: 6),
                Text(
                  'A bulk delay test is running — Lab tests '
                  'queue behind it and may take longer.',
                  style: Ember.caption,
                ),
              ],
            ],
          ),
        const SizedBox(height: 14),
        const Divider(color: Ember.line, height: 1, thickness: 1),
        const SizedBox(height: 14),
        Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Config to test', style: Ember.microLabelOrange),
              const SizedBox(height: 8),
              if (profile == null && eligible.isEmpty) ...[
                Text(
                  'No config the Lab can test. Its strategies '
                  'shape the Xray core\'s TLS layer: WireGuard, '
                  'Hysteria2 and QUIC configs build their own '
                  'connection layer (QUIC is removed from the '
                  'core), and sidecar-engine configs are '
                  'dialed by their own engines — none of those '
                  'can be shaped or graded honestly here.',
                  style: Ember.body,
                ),
                // A run whose config was deleted mid-flight
                // still needs its Stop control.
                if (running) ...[
                  const SizedBox(height: 14),
                  _LabAction(
                    label: stopping ? 'Stopping…' : 'Stop',
                    icon: Icons.stop_rounded,
                    onTap: stopping ? null : onStop,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Tests run one at a time — Stop takes '
                    'effect after the current test finishes '
                    '(up to ~15 s).',
                    style: Ember.caption,
                  ),
                ],
              ] else ...[
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  // Gated on acting too (iteration 4): a
                  // picker sheet opened during Connect-now
                  // would be the route the success pop()
                  // closes, wedging the page in acting.
                  onTap: (running || acting) ? null : onPickProfile,
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              profile?.displayName ?? 'Choose a config',
                              style: Ember.body.copyWith(color: Ember.text),
                            ),
                            Text(
                              profile != null
                                  ? '${profile.protocol.label} · '
                                        '${profile.address}:${profile.port}'
                                  : 'The previous config is no '
                                        'longer available — pick '
                                        'another.',
                              style: Ember.caption,
                            ),
                          ],
                        ),
                      ),
                      const Icon(
                        Icons.unfold_more_rounded,
                        size: 18,
                        color: Ember.orange,
                      ),
                    ],
                  ),
                ),
                if (excluded > 0) ...[
                  const SizedBox(height: 8),
                  Text(
                    '$excluded config${excluded == 1 ? '' : 's'} '
                    'not listed: WireGuard, Hysteria2, QUIC '
                    'and sidecar-engine configs, which the Lab '
                    'cannot shape.',
                    style: Ember.caption,
                  ),
                ],
                const SizedBox(height: 14),
                if (running) ...[
                  _LabAction(
                    label: stopping ? 'Stopping…' : 'Stop',
                    icon: Icons.stop_rounded,
                    onTap: stopping ? null : onStop,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Tests run one at a time — Stop takes '
                    'effect after the current test finishes '
                    '(up to ~15 s).',
                    style: Ember.caption,
                  ),
                ] else if (profile != null) ...[
                  // Build 2120: the run tests the ticked
                  // subset; at zero ticked there is nothing
                  // to run and the button says so by being
                  // disabled, with the caption naming why.
                  _LabAction(
                    label: 'Run discovery',
                    icon: Icons.science_rounded,
                    onTap: labTicked == 0 ? null : onRun,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    labTicked == 0
                        ? 'Tick at least one strategy below '
                              'to run.'
                        : labTicked == labCandidates.length
                        ? 'Tests all ${labCandidates.length} '
                              'strategies below.'
                        : 'Tests $labTicked of '
                              '${labCandidates.length} '
                              'strategies — unticked ones keep '
                              'their saved results.',
                    style: Ember.caption,
                  ),
                ],
              ],
            ],
          ),
        // Build 2120: the strategies card is shown whenever
        // a profile is in view — before any run it carries
        // the tick boxes and the SAVED results, so opening
        // the Lab no longer starts from an empty list.
        // Batch 5: an open section on the ground now.
        if (labProfile != null) ...[
          const SizedBox(height: 14),
          const Divider(color: Ember.line, height: 1, thickness: 1),
          const SizedBox(height: 14),
          Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Strategies on this network',
                  style: Ember.microLabelOrange,
                ),
                // Build 2149 (audit A48-03): the two
                // explainer paragraphs move BELOW the
                // result rows — between the section head
                // and the first row they pushed the first
                // result to ≈72% of the first screen; the
                // pro6-dpilab sample puts its rows directly
                // under the head. The copy is unchanged.
                const SizedBox(height: 10),
                for (final candidate in labCandidates)
                  _ResultRow(
                      candidate: candidate,
                      xray: xray,
                      results: results,
                      runProfile: runProfile,
                      selectedProfile: selectedProfile,
                      running: running,
                      runOrder: runOrder,
                      acting: acting,
                      pickedId: pickedId,
                      ageLabel: ageLabel,
                      onPickManually: onPickManually,
                    ),
                const SizedBox(height: 10),
                Text(
                  'Tick the strategies a run tests. A '
                  'result stays saved for this config '
                  'until its strategy is re-tested.',
                  style: Ember.caption,
                ),
                const SizedBox(height: 6),
                // Build 2127 (H1): the honest boundary of
                // the Zapret engine rows — the userspace
                // half of zapret is real and included; the
                // packet-forging half is root-bound on
                // Android and is not claimed anywhere.
                Text(
                  'The “Zapret engine” rows run the real '
                  'Zapret desync engine (ciadpi) as a local '
                  'proxy. Its packet-forging techniques — '
                  'bad-checksum fakes, sequence overlap, '
                  'RST injection, IP fragmentation and QUIC '
                  'splitting — need root on Android and are '
                  'not included.',
                  style: Ember.caption,
                ),
              ],
            ),
        ],
        if (!running && results.isNotEmpty) ...[
          const SizedBox(height: 14),
          if (winner != null)
            // Batch 5: the winner keeps a frame (it is the
            // page's one call to action) but the frame is
            // the flat hairline panel, glow retired.
            _HairlinePanel(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    winner.candidate.id == 's0'
                        ? 'No evasion needed here'
                        : 'What works here: ${winner.candidate.label}',
                    style: Ember.heading,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${winner.candidate.detail} Confirmed with '
                    'real requests: the quick round answered '
                    'in ${winner.ms} ms'
                    '${winner.exitCountry.isEmpty ? '' : ' with exit ${winner.exitCountry}'}, '
                    'and a confirmation session held — probes '
                    'at 0 / +2.5 / +5.4 s answered '
                    '${winner.p0} / ${winner.p1} / '
                    '${winner.p2} ms.',
                    style: Ember.body,
                  ),
                  const SizedBox(height: 14),
                  if (remembered) ...[
                    Text(
                      'Remembered for $filedLabel — '
                      'connects on this network dial it first.',
                      style: Ember.caption,
                    ),
                    const SizedBox(height: 10),
                    // Remembering must not remove Connect-now
                    // (verification iteration 2): the two
                    // actions are independent, and a Connect
                    // that was deferred once must stay
                    // retryable from this card.
                    _LabAction(
                      label: acting ? 'Working…' : 'Connect now',
                      icon: Icons.bolt_rounded,
                      onTap: acting ? null : onConnectNow,
                    ),
                  ] else
                    Row(
                      children: [
                        Expanded(
                          child: _LabAction(
                            label: 'Remember',
                            icon: Icons.bookmark_rounded,
                            onTap: acting ? null : onRemember,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _LabAction(
                            label: acting ? 'Working…' : 'Connect now',
                            icon: Icons.bolt_rounded,
                            onTap: acting ? null : onConnectNow,
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            )
          else
            Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    stoppedRun
                        ? 'Run stopped'
                        : 'No strategy carried traffic',
                    style: Ember.heading,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    stoppedRun
                        ? 'The run was stopped before every '
                              'strategy was tested, so this is '
                              'not a verdict on the untested '
                              'ones. Nothing tested before the '
                              'stop both answered and held a '
                              'session.'
                        : 'Nothing tested here both answered and held '
                              'a session on this network. A strategy that '
                              'answers and then freezes is listed above '
                              'as exactly that — it is not remembered as '
                              'a winner. The server may be down, or this '
                              'network may block the server\'s address '
                              'itself, which no handshake shape can fix. '
                              'A strategy above that answered can still '
                              'be filed from its row as your own pick — '
                              'recorded as a pick, not as a win.',
                    style: Ember.body,
                  ),
                ],
              ),
        ],
        if (wins.isNotEmpty) ...[
          const SizedBox(height: 14),
          const Divider(color: Ember.line, height: 1, thickness: 1),
          const SizedBox(height: 14),
          Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Remembered networks',
                        style: Ember.microLabelOrange,
                      ),
                    ),
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      // Not while a remember is in flight —
                      // the two would race (iteration 4).
                      onTap: acting ? null : onForgetAll,
                      child: Text(
                        'Forget all',
                        style: Ember.caption.copyWith(color: Ember.orange),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                for (final e in wins.entries)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                dpiLabNetworkLabel(e.key),
                                style: Ember.body.copyWith(color: Ember.text),
                              ),
                              Text(
                                '${dpiLabCandidateById(e.value.candidateId)?.label ?? e.value.candidateId}'
                                ' · ${e.value.ms} ms · through '
                                '${e.value.profileName} · '
                                '${ageLabel(e.value.verifiedMs)}',
                                style: Ember.caption,
                              ),
                            ],
                          ),
                        ),
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: acting ? null : () => onForgetWin(e.key),
                          child: const Icon(
                            Icons.delete_outline_rounded,
                            size: 18,
                            color: Ember.dim,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
        ],
        const SizedBox(height: 14),
        const Divider(color: Ember.line, height: 1, thickness: 1),
        const SizedBox(height: 14),
        Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Strategy updates', style: Ember.microLabelOrange),
              const SizedBox(height: 6),
              Text(
                // Build 2119 (audit F-17): the empty state
                // trimmed from 196 chars; the installed
                // branch keeps its count + age and drops
                // the repeated Lab-on qualification to one
                // short clause.
                xray.dpiRemoteStrategies.isEmpty
                    ? 'No community strategies installed yet. '
                          'New strategies can arrive from the '
                          'community feed — no app update '
                          'needed — and join the list above.'
                    : '${xray.dpiRemoteStrategies.length} community '
                          'strateg'
                          '${xray.dpiRemoteStrategies.length == 1 ? 'y' : 'ies'} '
                          'installed'
                          '${xray.dpiRemoteUpdatedMs > 0 ? ' · updated ${ageLabel(xray.dpiRemoteUpdatedMs)}' : ''}. '
                          'Listed above; used only while the '
                          'Lab is on.',
                style: Ember.body,
              ),
              for (final s in xray.dpiRemoteStrategies) ...[
                const SizedBox(height: 8),
                Text(
                  s.candidate.label,
                  style: Ember.body.copyWith(color: Ember.text),
                ),
                if (s.candidate.detail.isNotEmpty)
                  Text(s.candidate.detail, style: Ember.caption),
              ],
              const SizedBox(height: 12),
              _LabAction(
                label: updatingStrategies
                    ? 'Checking…'
                    : 'Check for updates',
                icon: Icons.cloud_download_rounded,
                onTap: updatingStrategies
                    ? null
                    : onCheckStrategyUpdates,
              ),
              if (strategyNote.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(strategyNote, style: Ember.caption),
              ],
            ],
          ),
        const SizedBox(height: 14),
        // Build 2129 (Leg 3): the Senpai scanner — a
        // discovery tool in the Lab family, behind its
        // own default-OFF toggle (the page itself carries
        // the switch; Settings → DPI Strategy Lab does
        // too). The Lab's opt-in gates reaching this page
        // at all.
        // Batch 5: an open section on the ground, like the
        // rest of the page.
        Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Senpai scanner', style: Ember.microLabelOrange),
              const SizedBox(height: 6),
              Text(
                'Find working endpoints on this network '
                'with the SenPaiScanner engine (its own '
                'Xray core, anti-DPI probes, neighbour '
                'scan). Top results import as ordinary '
                'profiles through a template you pick, '
                'and are re-tested with Ember\u2019s own '
                'delay test before they are shown as '
                'working.',
                style: Ember.body,
              ),
              const SizedBox(height: 12),
              _LabAction(
                label: 'Open the Senpai scanner',
                icon: Icons.radar_rounded,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => SenpaiPage(xray: xray),
                  ),
                ),
              ),
            ],
          ),
      ],
    )),
  );
}
}

/// One candidate's result row.
/// Build 2145 (UI-review fix A10): a widget class now, not a
/// Widget-returning method on the Lab state — the state
/// passes its values and callbacks down.
class _ResultRow extends StatelessWidget {
  const _ResultRow({
    required this.candidate,
    required this.xray,
    required this.results,
    required this.runProfile,
    required this.selectedProfile,
    required this.running,
    required this.runOrder,
    required this.acting,
    required this.pickedId,
    required this.ageLabel,
    required this.onPickManually,
  });

  final DpiLabCandidate candidate;
  final XrayController xray;
  final List<DpiLabResult> results;
  final Profile? runProfile;
  final Profile? selectedProfile;
  final bool running;
  final List<String> runOrder;
  final bool acting;
  final String pickedId;
  final String Function(int verifiedMs) ageLabel;
  final void Function(DpiLabResult result) onPickManually;

  @override
Widget build(BuildContext context) {
  DpiLabResult? result;
  for (final r in results) {
    if (r.candidate.id == candidate.id) result = r;
  }
  // Build 2120: the saved evidence for this row, shown
  // when the current run has not (re-)tested the
  // strategy — the row keeps its last measured verdict
  // with its age and network, never a blank "Not tested"
  // for a strategy that was measured before.
  final rowProfile = runProfile ?? selectedProfile;
  final saved = (result == null && rowProfile != null)
      ? xray.dpiLabSavedFor(rowProfile.id)[candidate.id]
      : null;
  final shown = result ?? saved?.toResult();
  // Build 2144 (reskin): the confirmed winner's row wears
  // the orange tag (its verdict's own word).
  final isWinner =
      result != null &&
      dpiLabWinner(results)?.candidate.id == candidate.id;
  final excluded = xray.dpiLabSweepExcluded.contains(candidate.id);
  // The candidate being probed right now: the first of
  // the run's order with no fresh result yet (results
  // land in probe order).
  var testingId = '';
  if (running) {
    for (final id in runOrder) {
      if (!results.any((r) => r.candidate.id == id)) {
        testingId = id;
        break;
      }
    }
  }
  final testing = running && result == null && testingId == candidate.id;
  final waiting =
      running &&
      result == null &&
      !testing &&
      runOrder.contains(candidate.id);
  final notInRun = running && result == null && !testing && !waiting;
  final (icon, color, verdict) = switch (shown?.verdict) {
    DpiLabVerdict.works => (
      Icons.check_circle_rounded,
      Ember.green,
      'Works · ${shown!.ms} ms'
          '${shown.exitCountry.isEmpty ? '' : ' · exit ${shown.exitCountry}'}',
    ),
    DpiLabVerdict.freezes => (
      Icons.pause_circle_rounded,
      Ember.warn,
      'Answers, then freezes · ${shown!.ms} ms',
    ),
    DpiLabVerdict.unconfirmed => (
      Icons.help_rounded,
      Ember.warn,
      'Answered ${shown!.ms} ms — confirmation could not run',
    ),
    DpiLabVerdict.blocked => (
      Icons.cancel_rounded,
      Ember.red,
      'Blocked — no answer',
    ),
    null => (
      testing ? Icons.hourglass_top_rounded : Icons.circle_outlined,
      testing ? Ember.orange : Ember.faint,
      testing
          ? 'Testing…'
          : waiting
          ? 'Waiting'
          : notInRun
          ? 'Not in this run'
          : 'Not tested',
    ),
  };
  // Build 2145 (composition rebuild, pro6-dpilab sample):
  // blocked and untested rows render dimmed, with no
  // numeral and no bar. The bar under a measured row is
  // RELATIVE DELAY only: the best (smallest) measured ms
  // of the shown rows divided by this row's measured ms —
  // the fastest row's bar is full. There is no score.
  // Batch 5: the shown rows include the SAVED evidence —
  // a saved row's bar now tracks its real measured delay
  // exactly as a fresh row's does (up to here the bar was
  // fresh-run only, so a saved row showed its numeral
  // with no bar under it).
  final dimmed =
      shown == null || shown.verdict == DpiLabVerdict.blocked;
  int? bestMs;
  for (final r in results) {
    if (r.ms > 0 && (bestMs == null || r.ms < bestMs)) bestMs = r.ms;
  }
  if (rowProfile != null) {
    for (final s in xray.dpiLabSavedFor(rowProfile.id).values) {
      if (s.ms > 0 && (bestMs == null || s.ms < bestMs)) bestMs = s.ms;
    }
  }
  final barFraction = (shown != null && shown.ms > 0 && bestMs != null)
      ? (bestMs / shown.ms).clamp(0.0, 1.0)
      : null;
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Opacity(
      opacity: dimmed ? 0.55 : 1,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Build 2120: the sweep tick — a run tests only
        // ticked strategies, and the tick persists. Locked
        // while a run or an action is in flight: a run's
        // subset is fixed at its start.
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: (running || acting)
              ? null
              : () => unawaited(
                  xray.setDpiLabCandidateExcluded(candidate.id, !excluded),
                ),
          child: Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(
              excluded
                  ? Icons.check_box_outline_blank_rounded
                  : Icons.check_box_rounded,
              size: 20,
              color: excluded ? Ember.faint : Ember.orange,
            ),
          ),
        ),
        const SizedBox(width: 7),
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 9),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      candidate.label,
                      // Build 2145: the sample's row name
                      // step (fontTitle); dimmed rows take
                      // the faint colour as well as the
                      // row opacity above.
                      style: TextStyle(
                        fontSize: Ember.fontTitle,
                        fontWeight: FontWeight.w500,
                        color: dimmed ? Ember.faint : Ember.text,
                      ),
                    ),
                  ),
                  if (isWinner) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: Ember.orange,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: const Text(
                        // Build 2149 (owner expansion
                        // 2026-11-25, un-holding the Lab badge
                        // decision): the approved pro6-dpilab
                        // sample's winner pill reads 'BEST' —
                        // the pill takes the sample's word.
                        // The verdict LINE below the row name
                        // keeps its prose ('Works · 640 ms'):
                        // it describes the measurement, it is
                        // not the badge.
                        'BEST',
                        style: TextStyle(
                          fontSize: Ember.fontMicro,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF1A1206),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              Text(verdict, style: Ember.caption.copyWith(color: color)),
              if (saved != null)
                Text(
                  'Saved ${ageLabel(saved.measuredMs)}'
                  '${saved.networkFp.isEmpty ? '' : ' · ${dpiLabNetworkLabel(saved.networkFp)}'}',
                  style: Ember.caption,
                ),
            ],
          ),
        ),
        // Build 2144 (reskin): the measured delay as the
        // sample's big light numeral. Build 2148: the
        // numeral comes down to the normal row size (owner
        // device verdict on 2147 — hero numerals belong to
        // page heroes, not list rows). Build 2145 (honesty
        // comment, updated): the numeral is the measured
        // delay in ms, shown as delay and nothing else;
        // the bar under the row (above) is relative delay
        // within the shown run — best ms ÷ this row's ms;
        // the app computes verdicts and delays, never a
        // 0–100 score, and no score exists on this page.
        if (shown != null && shown.ms > 0) ...[
          const SizedBox(width: 10),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                latDigits(shown.ms),
                style: TextStyle(
                  // Build 2148 (owner device verdict on
                  // 2147): a candidate ROW's delay wears the
                  // normal row size, not the hero scale —
                  // the same ruling as the config rows.
                  fontSize: Ember.fontTitle,
                  // Build 2147 (#22): health colour, not white.
                  color: mapPingColor(shown.ms),
                  height: 1.0,
                ),
              ),
              Text('ms', style: Ember.caption),
            ],
          ),
        ],
        // Build 2115: any strategy that ANSWERED can be
        // filed by hand from its row — during the run or
        // after it. A blocked row offers nothing (it never
        // answered). The verdict text above is never
        // rewritten by a pick. Build 2120: a SAVED answered
        // row offers the same pick — the evidence is the
        // owner's to file, with its age shown above.
        if (shown != null &&
            shown.verdict != DpiLabVerdict.blocked) ...[
          const SizedBox(width: 8),
          if (pickedId == candidate.id)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.bookmark_rounded,
                    size: 13,
                    color: Ember.orange,
                  ),
                  const SizedBox(width: 3),
                  Text(
                    'Your pick',
                    style: Ember.caption.copyWith(color: Ember.orange),
                  ),
                ],
              ),
            )
          else
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: acting ? null : () => onPickManually(shown),
              child: Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text(
                  'Use this',
                  style: Ember.caption.copyWith(
                    color: acting ? Ember.faint : Ember.orange,
                  ),
                ),
              ),
            ),
        ],
        ],
          ),
          if (barFraction != null) ...[
            const SizedBox(height: 6),
            SizedBox(
              height: 4,
              child: Stack(
                children: [
                  Container(
                    decoration: BoxDecoration(
                      color: MapUi.line,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  FractionallySizedBox(
                    widthFactor: barFraction,
                    child: Container(
                      decoration: BoxDecoration(
                        color: Ember.orange,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    ),
  );
}
}
