/// Build 2095, batch 5 — Mozilla account (whole-app
/// journey audit #7, #24, #52, #53, #54).
///
/// - #7: the "Sign-in needed" state has a way through it —
///   the legacy startSignInAgain flow (with the 409
///   pre-filled-dialog fallback) is reachable from the
///   Ember account card, by tap and by button.
/// - #24: refresh/remove surface their errors; removal
///   clears the FxA WebView cookies with the account.
/// - #53: disabled accounts are listed (not filtered
///   away), named "Turned off", and can be turned back on
///   from their own card.
/// - #54: the card states used/total and the reset date,
///   and says "Quota not read yet" when it has not been.
/// - #52: the bootstrap card carries a real Prepare now
///   button, and the home card names it truthfully.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  group('Mozilla account batch (audit #7, #24, #52, #53, #54)', () {
    final accounts = _read('lib/ui/ember/ember_accounts.dart');

    test('re-sign-in is reachable from the Ember card', () {
      expect(accounts, contains('startSignInAgain(account.id)'));
      expect(accounts, contains('e.statusCode == 409'));
      // PIN UPDATED by build 2145: the same re-sign-in
      // call (the 409 path), re-wrapped multi-line by the
      // account card's recomposition format pass.
      expect(
        accounts,
        contains(
          'await showSignInDialog(\n'
          '        context,\n'
          '        core,\n'
          '        email: account.email,',
        ),
      );
      expect(accounts, contains('account.needsSignIn'));
      expect(accounts, contains('l.signInAgain'));
    });

    test('disabled accounts are shown and can be re-enabled', () {
      expect(accounts, isNot(contains('.where((a) => a.enabled)')));
      expect(accounts, contains("'Turned off'"));
      expect(accounts, contains('core.setEnabled(account, true)'));
      expect(accounts, contains('core.setEnabled(account, false)'));
    });

    test('refresh/remove surface errors; removal clears FxA cookies', () {
      expect(accounts, contains('_runAccountAction'));
      expect(accounts, contains('core.refreshQuota(account)'));
      expect(accounts, contains('WebViewCookieManager().clearCookies()'));
    });

    test('the card states quota facts or that quota is unread', () {
      expect(accounts, contains('Quota not read yet'));
      expect(accounts, contains('usage.resetAt'));
      expect(accounts, contains('of '));
    });

    test('Prepare now exists and the home wording names it', () {
      final bootstrap = _read('lib/ui/ember/mozilla_bootstrap.dart');
      expect(bootstrap, contains("'Prepare now'"));
      expect(bootstrap, contains('await _b.prepareIfNeeded()'));
      final home = _read('lib/ui/ember/ember_home.dart');
      expect(home, contains('tap Prepare now in Account'));
    });
  });
}
