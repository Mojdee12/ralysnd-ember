/// The app lock (build 2075, feature item 11; biometric
/// half in build 2077, feature queue #7): a PIN gate shown
/// before the shell when the owner set a PIN in Settings,
/// with fingerprint / face unlock as an alternative when he
/// turns it on. The PIN always still works — a biometric
/// failure, cancel or lockout only falls back to the keypad,
/// so biometrics can never strand the owner out of the app.
///
/// The PIN is never stored: AppSettings holds its SHA-256
/// (the tree's pure-Dart sha256Hex over a namespaced
/// string). This is a privacy gate against casual access
/// to the app, not a cryptographic vault — the copy on the
/// settings row does not oversell it.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../app_settings.dart';
import '../../core/android_core.dart';
import '../../xray/sha256.dart';
import 'ember_theme.dart';
import 'map_widgets.dart';

/// The stored-hash form of a PIN.
String pinHashOf(String pin) => sha256Hex(utf8.encode('ember-lock-v1:$pin'));

/// True when [pin] matches the settings' stored hash.
bool pinMatches(AppSettings settings, String pin) =>
    settings.appLockPinHash.isNotEmpty &&
    settings.appLockPinHash == pinHashOf(pin);

/// A PIN is 4–6 digits, digits only.
bool isValidPin(String pin) =>
    pin.length >= 4 && pin.length <= 6 && int.tryParse(pin) != null;

/// Build 2095 (whole-app journey audit #45): the keypad
/// cooldown, in seconds, after [failedAttempts] consecutive
/// wrong PINs — none below 3 failures, then 15 s doubling
/// per further failure, capped at 300 s. Pure, so the test
/// suite pins the schedule. (Biometric unlock is a separate
/// factor with the system's own lockout and is not gated
/// by this.)
int lockCooldownSeconds(int failedAttempts) {
  if (failedAttempts < 3) return 0;
  final shift = failedAttempts - 3;
  if (shift >= 5) return 300;
  return 15 << shift;
}

/// The full-screen lock page. Calls [onUnlocked] when the
/// entered PIN matches — or when the biometric prompt
/// matches, when biometrics are turned on and available.
/// [biometricAvailable] / [biometricAuthenticate] are test
/// seams; they default to the [AndroidCore] channel calls.
class AppLockPage extends StatefulWidget {
  final AppSettings settings;
  final VoidCallback onUnlocked;
  final Future<bool> Function()? biometricAvailable;
  final Future<bool> Function()? biometricAuthenticate;

  const AppLockPage({
    super.key,
    required this.settings,
    required this.onUnlocked,
    this.biometricAvailable,
    this.biometricAuthenticate,
  });

  @override
  State<AppLockPage> createState() => _AppLockPageState();
}

class _AppLockPageState extends State<AppLockPage> {
  String _entered = '';
  bool _wrong = false;
  int _attempts = 0;

  /// Build 2095 (audit #45): the keypad cooldown window
  /// after repeated wrong PINs (see lockCooldownSeconds).
  DateTime? _cooldownEnd;
  Timer? _cooldownTimer;

  int get _cooldownLeft {
    final end = _cooldownEnd;
    if (end == null) return 0;
    final left = end.difference(DateTime.now()).inSeconds;
    return left > 0 ? left : 0;
  }

  bool get _inCooldown => _cooldownLeft > 0;

  /// Persists the attempt count and the cooldown
  /// deadline (build 2096, post-2095 audit M9): both used
  /// to live only in this page's State, so recreating the
  /// page reset them.
  void _persistLockCounters() {
    widget.settings.update(
      appLockFailedAttempts: _attempts,
      appLockCooldownUntilMs:
          _cooldownEnd?.millisecondsSinceEpoch ??
              widget.settings.appLockCooldownUntilMs,
    );
  }

  void _armCooldownTicker() {
    _cooldownTimer?.cancel();
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (_cooldownLeft <= 0) {
        _cooldownTimer?.cancel();
        _cooldownEnd = null;
      }
      setState(() {});
    });
  }

  /// Counts a wrong PIN and, from the third, starts the
  /// cooldown the keypad then enforces.
  void _registerFailure() {
    _attempts++;
    final secs = lockCooldownSeconds(_attempts);
    if (secs > 0) {
      _cooldownEnd = DateTime.now().add(Duration(seconds: secs));
      _armCooldownTicker();
    }
    _persistLockCounters();
  }

  /// Build 2096 (post-2095 audit L23): a failed
  /// VERIFICATION counts, including the intermediate
  /// length auto-submits — one typed entry tries up to
  /// three PIN lengths, and build 2095 counted the whole
  /// entry as a single failure.
  void _countFailedVerification() {
    _attempts++;
    _persistLockCounters();
  }

  /// A successful unlock clears the counters (build
  /// 2096, audit M9/L23): a legitimate long-PIN entry
  /// passes failing intermediate checks on its way to
  /// the full length, and must not accumulate toward a
  /// cooldown for succeeding.
  void _resetLockCounters() {
    _attempts = 0;
    _cooldownEnd = null;
    widget.settings.update(
      appLockFailedAttempts: 0,
      appLockCooldownUntilMs: 0,
    );
  }

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    super.dispose();
  }

  /// Build 2077: null while the platform answer is in
  /// flight; false when the device has nothing enrolled.
  bool? _bioAvailable;
  bool _bioFailed = false;

  /// The auto-prompt fires once per page appearance; a
  /// manual tap on the pill always prompts again.
  bool _bioPrompted = false;
  bool _bioBusy = false;

  @override
  void initState() {
    super.initState();
    // Build 2096 (post-2095 audit M9): the counters come
    // back from the persisted settings — a recreated page
    // resumes the count and any running cooldown.
    _attempts = widget.settings.appLockFailedAttempts;
    final untilMs = widget.settings.appLockCooldownUntilMs;
    if (untilMs > DateTime.now().millisecondsSinceEpoch) {
      _cooldownEnd = DateTime.fromMillisecondsSinceEpoch(untilMs);
      _armCooldownTicker();
    }
    if (widget.settings.appLockBiometric) {
      _checkBiometrics();
    }
  }

  Future<void> _checkBiometrics() async {
    final available =
        await (widget.biometricAvailable ?? AndroidCore.biometricsAvailable)();
    if (!mounted) return;
    setState(() => _bioAvailable = available);
    if (available) _promptBiometric(auto: true);
  }

  Future<void> _promptBiometric({bool auto = false}) async {
    if (_bioBusy) return;
    if (auto) {
      if (_bioPrompted) return;
      _bioPrompted = true;
    }
    _bioBusy = true;
    final ok =
        await (widget.biometricAuthenticate ??
            AndroidCore.authenticateBiometric)();
    if (!mounted) return;
    _bioBusy = false;
    if (ok) {
      _resetLockCounters();
      widget.onUnlocked();
      return;
    }
    setState(() => _bioFailed = true);
  }

  void _digit(String d) {
    // Build 2095 (audit #45): the keypad is dead during a
    // cooldown — mashing it cannot shorten the wait.
    if (_inCooldown) return;
    if (_entered.length >= 6) return;
    final next = _entered + d;
    setState(() {
      _entered = next;
      _wrong = false;
    });
    // A match at any offered length unlocks — the stored
    // hash does not record the PIN's length, so each length
    // from 4 up is tried as it is reached.
    if (next.length >= 4) {
      if (pinMatches(widget.settings, next)) {
        _resetLockCounters();
        widget.onUnlocked();
        return;
      }
      // Build 2096 (audit L23): the failed intermediate
      // verification counts too (the entry may still be
      // on its way to a longer PIN — the count is what
      // the cooldown schedule reads when it completes).
      if (next.length < 6) _countFailedVerification();
    }
    if (next.length == 6) {
      setState(() {
        _wrong = true;
        _entered = '';
      });
      _registerFailure();
    }
  }

  void _backspace() {
    if (_inCooldown) return;
    if (_entered.isEmpty) return;
    setState(() {
      _entered = _entered.substring(0, _entered.length - 1);
      _wrong = false;
    });
  }

  /// Build 2092 (UI audit 2026-11-16 item 1): the labelled
  /// confirm key — the finish path for a 4–5-digit PIN. A
  /// correct PIN already unlocks as its last digit lands
  /// (see _digit); this key exists so a mistyped short PIN
  /// gets its wrong-PIN feedback at its own length instead
  /// of only after six digits, and so the keypad's submit
  /// control carries a name.
  void _confirm() {
    if (_inCooldown) return;
    if (_entered.length < 4) return;
    if (pinMatches(widget.settings, _entered)) {
      _resetLockCounters();
      widget.onUnlocked();
      return;
    }
    setState(() {
      _wrong = true;
      _entered = '';
    });
    _registerFailure();
  }

  @override
  Widget build(BuildContext context) {
    // Build 2095 (audit #45): the lock page opts into the
    // overlay guard like the other sensitive surfaces
    // (hide-overlay-windows while the PIN pad is up).
    return OverlayGuard(
      child: Scaffold(
        backgroundColor: Ember.bg,
        // Build 2137 (visual review V-27): the lock page
        // joins the Map Control ground — the shared
        // EmberBackground (it hand-rolled the same backdrop
        // in a Stack over the flat bg). Build 2144 (reskin):
        // the pad floats bare on that ground, no panel. The
        // pad's behaviour (attempts, cooldown, biometrics)
        // is untouched.
        body: EmberBackground(
          child: SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) => SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 24,
                      ),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 400),
                        child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                      // Build 2144 (reskin, pro6-applock sample):
                      // the panel is gone — the pad sits bare on
                      // the ground, headed by the shield-flame
                      // mark in a thin orange ring.
                      Container(
                        // Batch 5 (fidelity rollout): the
                        // ring grows toward the sample's
                        // ~110 dp emblem (padding 22 + mark
                        // 52 inside the 1.5 px ring).
                        padding: const EdgeInsets.all(22),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: Ember.orange, width: 1.5),
                        ),
                        child: const EmberShieldMark(size: 52),
                      ),
                      const SizedBox(height: 20),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          'Ralysnd Ember is locked',
                          style: Ember.hero,
                          maxLines: 1,
                          softWrap: false,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        // Build 2095 (audit #45): during a
                        // cooldown the caption counts it down.
                        _inCooldown
                            ? 'Too many wrong PINs — wait $_cooldownLeft s'
                            : _wrong
                            ? 'Wrong PIN — try again'
                            // Build 2092 (item 1): the dot row
                            // cannot show the PIN's length (the
                            // hash does not record it), so the
                            // caption carries the 4–6 range.
                            : 'Enter your PIN (4–6 digits) to continue',
                        style: Ember.body.copyWith(
                          color: _inCooldown || _wrong
                              ? Ember.red
                              : Ember.dim,
                        ),
                      ),
                      const SizedBox(height: 24),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          for (var i = 0; i < 6; i++)
                            Container(
                              width: 14,
                              height: 14,
                              margin: const EdgeInsets.symmetric(horizontal: 6),
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: i < _entered.length
                                    ? Ember.orange
                                    : Colors.transparent,
                                // Build 2144 (reskin): filled dots
                                // stay orange; hollow dots are a
                                // neutral hairline ring.
                                // Batch 5 (pro6-applock sample):
                                // the sample's hollow dots are
                                // ember rings — the ring returns
                                // for both states.
                                border: Border.all(
                                  color: Ember.orange,
                                  width: 1.5,
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 32),
                      for (final row in const [
                        ['1', '2', '3'],
                        ['4', '5', '6'],
                        ['7', '8', '9'],
                        // Build 2092 (item 1): the bottom-left
                        // cell is the labelled confirm key ('='
                        // below), not an empty spacer; every key
                        // carries a semantics label.
                        ['=', '0', '<'],
                      ])
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            for (final key in row)
                              Padding(
                                padding: const EdgeInsets.all(6),
                                child: SizedBox(
                                  width: 68,
                                  height: 68,
                                  child: Semantics(
                                    button: true,
                                    label: key == '<'
                                        ? 'Backspace'
                                        : key == '='
                                        ? 'Confirm PIN'
                                        : 'Digit $key',
                                    child: TextButton(
                                      style: TextButton.styleFrom(
                                        // Build 2144 (reskin): bare
                                        // numerals — no key discs.
                                        backgroundColor: Colors.transparent,
                                        shape: const CircleBorder(),
                                      ),
                                      onPressed: _inCooldown
                                          ? null
                                          : () => key == '<'
                                          ? _backspace()
                                          : key == '='
                                          ? _confirm()
                                          : _digit(key),
                                      child: key == '<'
                                          ? const Icon(
                                              Icons.backspace_outlined,
                                              color: Ember.text,
                                            )
                                          : key == '='
                                          ? const Icon(
                                              Icons.check_rounded,
                                              color: Ember.orange,
                                            )
                                          : Text(
                                              key,
                                              // Build 2144 (reskin): the
                                              // samples' bare keypad
                                              // numerals are the hero
                                              // step, light.
                                              style: Ember.hero,
                                            ),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      // Build 2077: the biometric way in — only when
                      // the owner turned it on AND the device has one
                      // enrolled. A failed prompt leaves the PIN pad
                      // exactly where it was.
                      if (_bioAvailable == true) ...[
                        const SizedBox(height: 20),
                        MapActionPill(
                          icon: Icons.fingerprint_rounded,
                          label: 'Use fingerprint or face',
                          onTap: _bioBusy ? null : () => _promptBiometric(),
                          busy: _bioBusy,
                        ),
                        if (_bioFailed) ...[
                          const SizedBox(height: 12),
                          Text(
                            'Biometric didn\'t match — enter your PIN',
                            style: Ember.body.copyWith(color: Ember.dim),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ],
                      if (_attempts >= 3) ...[
                        const SizedBox(height: 16),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 40),
                          child: Text(
                            'If you forget the PIN, reinstalling the app '
                            'clears it — your configs live in the app data '
                            'and are removed with it.',
                            style: Ember.caption,
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ],
                    ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The Settings page for the app lock: set, change or
/// remove the PIN, and turn fingerprint / face unlock on
/// or off (build 2077). Reached from the Settings panel.
/// [biometricAvailable] is a test seam; it defaults to the
/// [AndroidCore] channel call.
class AppLockSettingsPage extends StatefulWidget {
  final AppSettings settings;
  final Future<bool> Function()? biometricAvailable;

  const AppLockSettingsPage({
    super.key,
    required this.settings,
    this.biometricAvailable,
  });

  @override
  State<AppLockSettingsPage> createState() => _AppLockSettingsPageState();
}

class _AppLockSettingsPageState extends State<AppLockSettingsPage> {
  final TextEditingController _current = TextEditingController();
  final TextEditingController _next = TextEditingController();
  String _status = '';

  /// Build 2097 (post-2096 audit C-L14): current-PIN
  /// verification here shares the lock page's attempt
  /// counters and cooldown — build 2096 verified with no
  /// limiting at all, so this page was an unbounded
  /// PIN-guessing oracle behind the very lock it guesses
  /// at, and a successful change left the lock page's
  /// accumulated counters standing.
  bool get _verifyCoolingDown =>
      widget.settings.appLockCooldownUntilMs >
      DateTime.now().millisecondsSinceEpoch;

  /// True when the typed current PIN matches; a miss is
  /// counted on the shared counters (with the shared
  /// cooldown schedule) before returning false.
  bool _verifyCurrentPin() {
    final settings = widget.settings;
    if (pinMatches(settings, _current.text)) return true;
    final attempts = settings.appLockFailedAttempts + 1;
    final secs = lockCooldownSeconds(attempts);
    settings.update(
      appLockFailedAttempts: attempts,
      appLockCooldownUntilMs: secs > 0
          ? DateTime.now().millisecondsSinceEpoch + secs * 1000
          : settings.appLockCooldownUntilMs,
    );
    return false;
  }

  String get _wrongPinStatus => _verifyCoolingDown
      ? 'The current PIN is wrong — too many attempts; '
          'wait for the lock cooldown to pass.'
      : 'The current PIN is wrong.';

  /// A successful change/remove clears the shared
  /// counters (build 2097, audit C-L14).
  void _clearLockCounters() {
    widget.settings.update(
      appLockFailedAttempts: 0,
      appLockCooldownUntilMs: 0,
    );
  }

  /// Build 2092 (UI audit item 49): the status line colours
  /// failure red and success dim — the two used to render in
  /// the identical style.
  bool _statusError = false;

  /// Build 2077: null while the platform answer is in
  /// flight; false when the device has nothing enrolled.
  bool? _bioAvailable;

  @override
  void initState() {
    super.initState();
    _loadBiometrics();
  }

  Future<void> _loadBiometrics() async {
    final available =
        await (widget.biometricAvailable ?? AndroidCore.biometricsAvailable)();
    if (!mounted) return;
    setState(() => _bioAvailable = available);
  }

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = widget.settings;
    final locked = settings.appLockEnabled;
    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Ember.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text('App lock', style: Ember.heading),
        foregroundColor: Ember.text,
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          const MapBackdropVisual(),
          ListView(
            // Build 2138 (visual review V-26): the body extends
            // behind the transparent bar — keep the first card
            // below it (the profile_editor formula).
            padding: EdgeInsets.fromLTRB(
              16,
              MediaQuery.of(context).padding.top + kToolbarHeight + 16,
              16,
              16,
            ),
            children: [
              Text(
                'A PIN asked when the app opens. It keeps casual '
                'hands out of the app — it is not a vault: anyone '
                'with the phone and enough time can clear the app\'s '
                'data and start over. Only the PIN\'s hash is stored, '
                'never the PIN. Fingerprint or face unlock is '
                'available below once a PIN is set — the PIN always '
                'still works if biometrics fail.',
                style: Ember.body.copyWith(color: Ember.dim),
              ),
              const SizedBox(height: 16),
              MapGlass(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (locked) ...[
                      Text('Current PIN', style: Ember.body),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _current,
                        obscureText: true,
                        keyboardType: TextInputType.number,
                        style: Ember.body,
                        // Build 2092 (item 49): the shared
                        // field style, not a stock decoration.
                        decoration: emberField(context, '••••'),
                      ),
                      const SizedBox(height: 16),
                    ],
                    Text(
                      locked ? 'New PIN (4–6 digits)' : 'PIN (4–6 digits)',
                      style: Ember.body,
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _next,
                      obscureText: true,
                      keyboardType: TextInputType.number,
                      style: Ember.body,
                      decoration: emberField(context, '••••'),
                    ),
                    const SizedBox(height: 20),
                    Row(
                      children: [
                        Expanded(
                          child: EmberButton(
                            label: locked ? 'Change PIN' : 'Set PIN',
                            onTap: () {
                              if (locked && _verifyCoolingDown) {
                                setState(() {
                                  _status =
                                      'Too many wrong PINs — wait '
                                      'for the lock cooldown to pass.';
                                  _statusError = true;
                                });
                                return;
                              }
                              if (locked && !_verifyCurrentPin()) {
                                setState(() {
                                  _status = _wrongPinStatus;
                                  _statusError = true;
                                });
                                return;
                              }
                              if (!isValidPin(_next.text)) {
                                setState(() {
                                  _status =
                                      'A PIN is 4 to 6 digits, digits only.';
                                  _statusError = true;
                                });
                                return;
                              }
                              settings.update(
                                appLockPinHash: pinHashOf(_next.text),
                              );
                              _clearLockCounters();
                              // Build 2095 (feature 5): the
                              // widget's lock marker follows.
                              unawaited(AndroidCore.setWidgetLock(true));
                              setState(() {
                                _status =
                                    'PIN set. It is asked when the '
                                    'app opens.';
                                _statusError = false;
                                _current.clear();
                                _next.clear();
                              });
                            },
                          ),
                        ),
                        if (locked) ...[
                          const SizedBox(width: 10),
                          Expanded(
                            child: EmberButton(
                              label: 'Remove PIN',
                              onTap: () {
                                if (_verifyCoolingDown) {
                                  setState(() {
                                    _status =
                                        'Too many wrong PINs — wait '
                                        'for the lock cooldown to pass.';
                                    _statusError = true;
                                  });
                                  return;
                                }
                                if (!_verifyCurrentPin()) {
                                  setState(() {
                                    _status = _wrongPinStatus;
                                    _statusError = true;
                                  });
                                  return;
                                }
                                settings.update(appLockPinHash: '');
                                _clearLockCounters();
                                unawaited(
                                  AndroidCore.setWidgetLock(false),
                                );
                                setState(() {
                                  _status = 'App lock removed.';
                                  _statusError = false;
                                  _current.clear();
                                  _next.clear();
                                });
                              },
                            ),
                          ),
                        ],
                      ],
                    ),
                    if (_status.isNotEmpty) ...[
                      const SizedBox(height: 14),
                      Text(
                        _status,
                        style: Ember.body.copyWith(
                          color: _statusError ? Ember.red : Ember.dim,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              // Build 2077: the biometric half of the lock —
              // only once a PIN is set (biometrics ride on the
              // PIN, never instead of it). The toggle appears
              // only when this device has a biometric enrolled;
              // otherwise the card says why, with no control
              // that cannot work.
              if (locked) ...[
                const SizedBox(height: 16),
                MapGlass(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text('Biometric unlock', style: Ember.body),
                          ),
                          if (_bioAvailable == true)
                            EmberToggle(
                              value: settings.appLockBiometric,
                              onChanged: (on) {
                                settings.update(appLockBiometric: on);
                                setState(() {});
                              },
                            ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _bioAvailable == null
                            ? 'Checking this device…'
                            : _bioAvailable == true
                            ? 'Fingerprint or face instead of the PIN '
                                  'when the app opens. The PIN always '
                                  'still works.'
                            : 'Biometrics aren\'t available on this '
                                  'device — set up a fingerprint or face '
                                  'in Android Settings first.',
                        style: Ember.body.copyWith(color: Ember.dim),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
