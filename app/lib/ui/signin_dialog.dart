import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/core_api.dart';
import '../core/core_controller.dart';
import '../core/models.dart';
import '../l10n/app_localizations.dart';
import '../platform.dart';
import 'browser_signin_page.dart';
import 'ember/ember_theme.dart';
import 'format.dart';
import 'widgets.dart';

/// Adds an account, or signs one in again: the core runs the sign-in and
/// the dialog shows whatever Mozilla asks for (codes, CAPTCHA, a link).
Future<void> showSignInDialog(
  BuildContext context,
  CoreController core, {
  String email = '',
  SignInState? started,
}) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _SignInDialog(core: core, email: email, started: started),
);

class _SignInDialog extends StatefulWidget {
  const _SignInDialog({required this.core, required this.email, this.started});

  final CoreController core;
  final String email;
  final SignInState? started;

  @override
  State<_SignInDialog> createState() => _SignInDialogState();
}

class _SignInDialogState extends State<_SignInDialog> {
  late final _email = TextEditingController(text: widget.email);
  final _password = TextEditingController();
  final _answer = TextEditingController();
  final _form = GlobalKey<FormState>();
  final _emailFocus = FocusNode();
  final _passwordFocus = FocusNode();

  SignInState? _state;
  String? _error;

  /// A sign-in started from the form whose password Mozilla has not
  /// accepted yet: the form stays (with the button busy) until it does,
  /// so a password manager is asked to save only a password that works.
  SignInState? _checking;

  /// A failure the person fixes in the form ([_formProblems]): its code
  /// and the core's text.
  String _formProblem = '';
  String _formProblemText = '';
  bool _sending = false;
  bool _showPassword = false;
  Timer? _poll;

  /// The browser sign-in session whose WebView has been
  /// opened (build 2033), so the poll does not stack pages.
  String _browserOpenedId = '';

  CoreApi? get _api => widget.core.api;

  @override
  void initState() {
    super.initState();
    if (widget.started != null) _follow(widget.started!);
  }

  @override
  void dispose() {
    _poll?.cancel();
    _email.dispose();
    _password.dispose();
    _answer.dispose();
    _emailFocus.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  /// Failures of what was typed (a mistyped password or email): the form
  /// comes back with the fields as they were, to fix and send again.
  static const _formProblems = {
    SignInError.wrongPassword,
    SignInError.noAccount,
  };

  void _follow(SignInState s) {
    _poll?.cancel();
    final fromForm = _checking != null;
    _checking = null;
    if (s.step == SignInStep.failed && _formProblems.contains(s.errorCode)) {
      _state = null;
      _formProblem = s.errorCode;
      _formProblemText = s.error;
      final wrongPassword = s.errorCode == SignInError.wrongPassword;
      final field = wrongPassword ? _password : _email;
      final focus = wrongPassword ? _passwordFocus : _emailFocus;
      field.selection = TextSelection.collapsed(offset: field.text.length);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) focus.requestFocus();
      });
      return;
    }
    if (fromForm) {
      if (s.passwordAccepted) {
        // The fields are still there: the phone's password manager (Android
        // autofill) may now offer to save them, or update a saved password.
        TextInput.finishAutofillContext();
      } else if (s.step == SignInStep.working) {
        _checking = s;
        _poll = Timer.periodic(const Duration(seconds: 1), (_) => _read());
        return;
      }
      // Otherwise Mozilla asks for something first (a CAPTCHA, an unblock
      // code) or the sign-in failed: nothing is offered for saving.
    }
    _state = s;
    if (s.finished) {
      if (s.step == SignInStep.done) {
        _password.clear();
        widget.core.refresh(accountsToo: true);
      }
      return;
    }
    if (s.step == SignInStep.needBrowser &&
        s.authUrl.isNotEmpty &&
        _browserOpenedId != s.id) {
      _browserOpenedId = s.id;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_openBrowser(s));
      });
    }
    _poll = Timer.periodic(const Duration(seconds: 1), (_) => _read());
  }

  /// Opens the WebView on Mozilla's pages and hands the
  /// intercepted code back to the core (build 2033).
  Future<void> _openBrowser(SignInState s) async {
    final result = await openBrowserSignIn(context, s.authUrl);
    if (!mounted || result == null) return;
    _send(
      (api) => api.answerBrowserSignIn(
        s.id,
        result.code,
        result.state,
        error: result.error,
      ),
    );
  }

  void _startBrowser() {
    _formProblem = '';
    _send((api) => api.startBrowserSignIn());
  }

  Future<void> _read() async {
    final id = (_state ?? _checking)?.id;
    final api = _api;
    if (id == null || api == null) return;
    try {
      final next = await api.signInState(id);
      if (!mounted) return;
      // Keep a typed answer while the step stays the same.
      if (next.step != _state?.step) _answer.clear();
      setState(() => _follow(next));
    } on Exception {
      // The next tick retries; the core may be busy.
    }
  }

  Future<void> _send(Future<SignInState> Function(CoreApi api) call) async {
    final api = _api;
    if (api == null) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final next = await call(api);
      if (!mounted) return;
      setState(() => _follow(next));
    } on CoreApiException catch (e) {
      // Build 2074 (audit item 19): a generic plain sentence —
      // the core's raw text (e.message) goes to diagnostics
      // only, never into the dialog.
      debugPrint('Ember sign-in failed: ${e.message}');
      if (mounted) {
        setState(() => _error = AppLocalizations.of(context).signInFailed);
      }
    } on CoreUnavailable catch (e) {
      if (mounted) {
        setState(
          () => _error = describeProblem(AppLocalizations.of(context), e),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _start() {
    if (!_form.currentState!.validate()) return;
    final email = _email.text.trim();
    final password = _password.text;
    _formProblem = '';
    _send((api) async {
      final started = await api.startSignIn(email, password);
      // Marks the sign-in as the form's, for _follow.
      _checking = started;
      return started;
    });
  }

  void _submitAnswer() {
    final value = _answer.text.trim();
    final id = _state?.id;
    if (value.isEmpty || id == null) return;
    _send((api) => api.answerSignIn(id, value));
  }

  Future<void> _close() async {
    final s = _state ?? _checking;
    if (s != null && !s.finished) {
      try {
        await _api?.cancelSignIn(s.id);
      } on Exception {
        // The core ends abandoned sign-ins itself.
      }
    }
    if (mounted) Navigator.of(context).pop();
  }

  void _restart() => setState(() {
    _poll?.cancel();
    _state = null;
    _checking = null;
    _error = null;
    _formProblem = '';
    _answer.clear();
  });

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final s = _state;
    final done = s?.step == SignInStep.done;
    final failed =
        s?.step == SignInStep.failed || s?.step == SignInStep.cancelled;
    // An account without a password (Google or Apple sign-in) cannot sign
    // in again as it is: the button opens Mozilla's page to set one.
    final noPassword = failed && s?.errorCode == SignInError.noPassword;
    // Build 2056: the dialog is Map Control now — Ember glass
    // instead of stock Material, the width is capped at the
    // screen (the old fixed 400 px was wider than a 360 px
    // phone's dialog), and the title is the raw email with an
    // ellipsis. The submit stays a FilledButton, Ember-styled:
    // the widget tests tap find.byType(FilledButton) for it.
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: GlassCard(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  s == null
                      ? l.addAccount
                      : (s.email.isEmpty ? l.signInTitle : ltr(s.email)),
                  style: Ember.heading,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textDirection: TextDirection.ltr,
                ),
                const SizedBox(height: 14),
                AnimatedSize(
                  duration: const Duration(milliseconds: 200),
                  alignment: Alignment.topCenter,
                  child: s == null ? _credentials() : _progress(s),
                ),
                const SizedBox(height: 18),
                if (done)
                  _EmberFilledButton(label: l.done, onPressed: _close)
                else ...[
                  if (noPassword)
                    _EmberFilledButton(
                      label: l.setPasswordButton,
                      icon: Icons.open_in_new_rounded,
                      onPressed: () => openUrl(firefoxAccountSetPasswordUrl),
                    )
                  else if (failed)
                    _EmberFilledButton(label: l.tryAgain, onPressed: _restart)
                  else if (s == null)
                    _EmberFilledButton(
                      label: l.signIn,
                      busy: _sending || _checking != null,
                      onPressed: _sending || _checking != null ? null : _start,
                    )
                  else if (s.needsAnswer)
                    _EmberFilledButton(
                      label: l.continueLabel,
                      onPressed: _sending ? null : _submitAnswer,
                    ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: _close,
                    style: TextButton.styleFrom(foregroundColor: Ember.dim),
                    child: Text(failed ? l.close : l.cancel),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _credentials() {
    final l = AppLocalizations.of(context);
    // The fields are a sign-in form for password managers: they can fill
    // it, and offer to save it when the user signs in (_start); leaving the
    // form otherwise saves nothing.
    return Form(
      key: _form,
      child: AutofillGroup(
        onDisposeAction: AutofillContextAction.cancel,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // The primary route (build 2033): Mozilla's own
            // pages in a WebView — the sign-in that survives
            // Mozilla's 2026 bot rules. The password form
            // below stays as the fallback. (An outlined button,
            // deliberately: the dialog's filled button is the
            // password form's, as the widget tests have it.)
            OutlinedButton.icon(
              onPressed: _sending ? null : _startBrowser,
              icon: const Icon(Icons.open_in_browser_rounded, size: 19),
              label: const Text('Sign in with browser'),
              style: OutlinedButton.styleFrom(
                foregroundColor: Ember.orange,
                side: BorderSide(color: Ember.orange.withValues(alpha: 0.7)),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
                textStyle: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Mozilla’s page asks for everything, including '
              'any security code — nothing is typed here.',
              style: Ember.dimStyle,
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                const Expanded(child: Divider(color: Ember.line)),
                // Build 2056: the label flexes and ellipsises —
                // at a large system text scale (and in the test
                // font) it measured wider than the dialog and
                // overflowed the row by 20 px on a 360 px phone.
                Flexible(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Text(
                      'or with your password',
                      style: Ember.dimStyle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                const Expanded(child: Divider(color: Ember.line)),
              ],
            ),
            const SizedBox(height: 16),
            Text(l.signInIntro, style: Ember.body),
            const SizedBox(height: 16),
            TextFormField(
              controller: _email,
              focusNode: _emailFocus,
              autofocus: widget.email.isEmpty,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [
                AutofillHints.email,
                AutofillHints.username,
              ],
              textDirection: TextDirection.ltr,
              style: Ember.body,
              decoration: emberField(context, l.email).copyWith(
                labelText: l.email,
                labelStyle: const TextStyle(color: Ember.faint, fontSize: 13),
                floatingLabelStyle: const TextStyle(color: Ember.orange),
              ),
              validator: (v) => (v ?? '').contains('@') ? null : l.emailInvalid,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _password,
              focusNode: _passwordFocus,
              autofocus: widget.email.isNotEmpty,
              obscureText: !_showPassword,
              enableSuggestions: false,
              autocorrect: false,
              autofillHints: const [AutofillHints.password],
              // Passwords are typed left to right, also in Persian.
              textDirection: TextDirection.ltr,
              style: Ember.body,
              decoration: emberField(context, l.password).copyWith(
                labelText: l.password,
                labelStyle: const TextStyle(color: Ember.faint, fontSize: 13),
                floatingLabelStyle: const TextStyle(color: Ember.orange),
                suffixIcon: IconButton(
                  tooltip: _showPassword ? l.hide : l.show,
                  icon: Icon(
                    _showPassword ? Icons.visibility_off : Icons.visibility,
                    color: Ember.dim,
                  ),
                  onPressed: () =>
                      setState(() => _showPassword = !_showPassword),
                ),
              ),
              validator: (v) => (v ?? '').isEmpty ? l.passwordEmpty : null,
              onFieldSubmitted: (_) => _start(),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              _ErrorBox(_error!),
            ] else if (_formProblem.isNotEmpty) ...[
              const SizedBox(height: 12),
              _ErrorBox(_problem(l, _formProblem, _formProblemText)),
            ],
            // No Firefox Account has this email: how to make one.
            if (_formProblem == SignInError.noAccount) ...[
              const SizedBox(height: 12),
              Text(l.signInNoAccountHint, style: Ember.body),
              const SizedBox(height: 8),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: OutlinedButton.icon(
                  onPressed: () => openUrl(firefoxAccountSignUpUrl),
                  icon: const Icon(Icons.open_in_new_rounded, size: 18),
                  label: Text(l.createAccountButton),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Ember.orange,
                    side: BorderSide(
                      color: Ember.orange.withValues(alpha: 0.7),
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// The instruction for a step in the app's language; the core's own
  /// message for steps the app does not know.
  String _instruction(AppLocalizations l, SignInState s) => switch (s.step) {
    SignInStep.needBrowser =>
      'Finish the sign-in on Mozilla’s page in the browser window.',
    SignInStep.needEmailCode => l.stepEmailCode(s.email),
    SignInStep.needTotp => l.stepTotp,
    SignInStep.needUnblockCode => l.stepUnblockCode(s.email),
    SignInStep.needCaptcha => l.stepCaptcha,
    SignInStep.needEmailLink => l.stepEmailLink(s.email),
    SignInStep.working => l.signingIn,
    SignInStep.failed => l.signInFailed,
    SignInStep.cancelled => l.signInCancelled,
    _ => s.message,
  };

  /// What went wrong, in the app's language. Build 2074
  /// (audit item 19): an unknown problem shows the generic
  /// failure sentence — the core's own text ([text]) used to
  /// fall through verbatim; it stays in diagnostics only.
  String _problem(AppLocalizations l, String code, String text) =>
      switch (code) {
        SignInError.noAccount => l.signInNoAccount,
        SignInError.wrongPassword => l.signInWrongPassword,
        SignInError.noPassword => l.signInNoPassword,
        SignInError.tooManyAttempts => l.signInTooManyAttempts,
        SignInError.unblockCodeRejected => l.signInUnblockRejected,
        SignInError.wrongCode => l.signInWrongCode,
        SignInError.wrongTotp => l.signInWrongTotp,
        SignInError.tooManyCodes => l.signInTooManyCodes,
        SignInError.timedOut => l.signInTimedOut,
        SignInError.network => l.signInNetwork,
        _ => l.signInFailed,
      };

  Widget _progress(SignInState s) {
    final l = AppLocalizations.of(context);
    final instruction = _instruction(l, s);
    final error =
        _error ?? (s.error.isEmpty ? null : _problem(l, s.errorCode, s.error));
    final numericCode =
        s.step == SignInStep.needEmailCode || s.step == SignInStep.needTotp;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (s.step == SignInStep.done)
          // Build 2074 (audit item 15): a plain Ember row, not
          // a stock ListTile; the check wears Ember.green.
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                Icons.check_circle_rounded,
                color: Ember.green,
                size: 32,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(l.accountReady, style: Ember.body),
                    const SizedBox(height: 2),
                    Text(l.accountReadyHint, style: Ember.dimStyle),
                  ],
                ),
              ),
            ],
          )
        else if (s.step == SignInStep.working ||
            s.step == SignInStep.needEmailLink)
          Row(
            children: [
              const SizedBox.square(
                dimension: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: Ember.orange,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(child: Text(instruction, style: Ember.body)),
            ],
          )
        else if (instruction.isNotEmpty)
          Text(instruction, style: Ember.body),
        if (s.step == SignInStep.needBrowser) ...[
          const SizedBox(height: 16),
          _EmberFilledButton(
            label: 'Open the sign-in page',
            icon: Icons.open_in_browser_rounded,
            onPressed: () => unawaited(_openBrowser(s)),
          ),
        ],
        if (s.step == SignInStep.needCaptcha && s.captcha.isNotEmpty) ...[
          const SizedBox(height: 12),
          _Captcha(dataUrl: s.captcha),
        ],
        if (s.needsAnswer) ...[
          const SizedBox(height: 16),
          TextField(
            // A new field for each step, so its keyboard is the step's.
            key: ValueKey(s.step),
            controller: _answer,
            autofocus: true,
            // A code from an email or an authenticator app, which the
            // phone may offer to fill; not the CAPTCHA's text.
            autofillHints: s.step == SignInStep.needCaptcha
                ? null
                : const [AutofillHints.oneTimeCode],
            // The emailed and the authenticator codes are digits: the
            // number keyboard, and nothing else is taken. (The unblock
            // code has letters too.)
            keyboardType: numericCode ? TextInputType.number : null,
            inputFormatters: numericCode ? const [_CodeDigits()] : null,
            textDirection: s.step == SignInStep.needCaptcha
                ? null
                : TextDirection.ltr,
            textAlign: numericCode ? TextAlign.center : TextAlign.start,
            style: numericCode
                // Build 2074 (audit item 15): an explicit Ember
                // style, not the theme's titleLarge.
                ? const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 6,
                    color: Ember.text,
                  )
                : Ember.body,
            decoration:
                emberField(
                  context,
                  s.step == SignInStep.needCaptcha
                      ? l.captchaLabel
                      : l.codeLabel,
                ).copyWith(
                  labelText: s.step == SignInStep.needCaptcha
                      ? l.captchaLabel
                      : l.codeLabel,
                  labelStyle: const TextStyle(color: Ember.faint, fontSize: 13),
                  floatingLabelStyle: const TextStyle(color: Ember.orange),
                ),
            onSubmitted: (_) => _submitAnswer(),
          ),
        ],
        if (error != null && s.step != SignInStep.done) ...[
          const SizedBox(height: 12),
          _ErrorBox(error),
        ],
      ],
    );
  }
}

/// Keeps the digits of a typed or pasted code and drops everything else
/// (spaces, dashes, letters); Persian and Arabic-Indic digits, which a
/// Persian or Arabic keyboard types, become 0-9.
class _CodeDigits extends TextInputFormatter {
  const _CodeDigits();

  static String? _digit(int rune) {
    if (rune >= 0x30 && rune <= 0x39) return String.fromCharCode(rune);
    if (rune >= 0x6F0 && rune <= 0x6F9) return '${rune - 0x6F0}';
    if (rune >= 0x660 && rune <= 0x669) return '${rune - 0x660}';
    return null;
  }

  static String _digits(String text) =>
      text.runes.map(_digit).whereType<String>().join();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final text = _digits(newValue.text);
    if (text == newValue.text) return newValue;
    // The cursor stays after the same digits it followed.
    final end = newValue.selection.end.clamp(0, newValue.text.length);
    final cursor = _digits(newValue.text.substring(0, end)).length;
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: cursor),
    );
  }
}

class _Captcha extends StatelessWidget {
  const _Captcha({required this.dataUrl});

  final String dataUrl;

  @override
  Widget build(BuildContext context) {
    final comma = dataUrl.indexOf(',');
    try {
      final bytes = base64Decode(dataUrl.substring(comma + 1));
      return ClipRRect(
        // Build 2074 (audit item 15): the dialog's control
        // radius (18), not the old stock 8 dp box.
        borderRadius: BorderRadius.circular(18),
        child: Image.memory(bytes, height: 120, fit: BoxFit.contain),
      );
    } on FormatException {
      return _ErrorBox(AppLocalizations.of(context).captchaBroken);
    }
  }
}

class _ErrorBox extends StatelessWidget {
  const _ErrorBox(this.message);

  final String message;

  @override
  // Build 2074 (audit item 15): Ember radius (18) and palette
  // (Ember.red, Ember text styles) — not the stock 8 dp box
  // in StatusColors / theme type.
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: Ember.red.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(18),
    ),
    child: Text(message, style: Ember.body.copyWith(color: Ember.red)),
  );
}

/// A FilledButton in the Ember language (build 2056): the
/// ember-orange fill with dark text. It stays a FilledButton —
/// not an EmberButton — because the widget tests tap
/// find.byType(FilledButton) for the sign-in submit, and the
/// dialog's own contract says the filled button is the
/// password form's.
class _EmberFilledButton extends StatelessWidget {
  const _EmberFilledButton({
    required this.label,
    required this.onPressed,
    this.icon,
    this.busy = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final style = FilledButton.styleFrom(
      backgroundColor: Ember.orange,
      foregroundColor: const Color(0xFF1A1206),
      disabledBackgroundColor: Ember.cardSoft,
      disabledForegroundColor: Ember.dim,
      padding: const EdgeInsets.symmetric(vertical: 14),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
    );
    final child = busy
        ? const SizedBox.square(
            dimension: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Color(0xFF1A1206),
            ),
          )
        : Text(label);
    if (icon == null) {
      return FilledButton(onPressed: onPressed, style: style, child: child);
    }
    return FilledButton.icon(
      onPressed: onPressed,
      style: style,
      icon: Icon(icon, size: 18),
      label: Text(label),
    );
  }
}
