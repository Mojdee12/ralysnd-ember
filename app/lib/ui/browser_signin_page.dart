import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// The result of a browser sign-in page: the authorization
/// code and state from the intercepted success redirect, or
/// the error FxA put in the redirect instead.
typedef BrowserSignInResult = ({String code, String state, String error});

/// Mozilla's own sign-in pages in a WebView2 view (Windows
/// port of the Android build-2033 page — the Kumiho
/// contract): Firefox for Android's OAuth client finishes on
/// an ordinary HTTPS success page, so the app watches
/// navigations for it, reads code+state out of the URL, and
/// hands them to the core — the completion hand-off the
/// desktop client performs over Firefox's internal
/// WebChannel, which no web view can receive, is never used.
///
/// The platform split: Android uses webview_flutter (no
/// Windows implementation exists); on Windows this page uses
/// flutter_inappwebview's WebView2 host. The contract — the
/// authorize URL from the core, the intercepted success
/// prefix, the (code, state, error) hand-back — is identical,
/// and the core's OAuth grant (Fenix client, PKCE S256) is
/// the same code on both platforms.
///
/// The page itself never sees the password: Mozilla's pages
/// handle it, exactly as in Firefox.
class BrowserSignInPage extends StatefulWidget {
  const BrowserSignInPage({super.key, required this.authUrl});

  final String authUrl;

  @override
  State<BrowserSignInPage> createState() => _BrowserSignInPageState();
}

class _BrowserSignInPageState extends State<BrowserSignInPage> {
  bool _loading = true;
  bool _finished = false;

  /// The registered success page of the Firefox for Android
  /// OAuth client (client-id suffixed, as registered); a
  /// main-frame navigation to it carries the outcome.
  static const _successPrefix =
      'https://accounts.firefox.com/oauth/success/a2270f727f45f648';

  void _intercept(String url) {
    if (_finished) return;
    _finished = true;
    final q = Uri.parse(url).queryParameters;
    final result = (
      code: q['code'] ?? '',
      state: q['state'] ?? '',
      error: q['error'] ?? '',
    );
    Navigator.of(context).pop(result);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sign in with Mozilla'),
        bottom: _loading
            ? const PreferredSize(
                preferredSize: Size.fromHeight(2),
                child: LinearProgressIndicator(minHeight: 2),
              )
            : null,
      ),
      body: InAppWebView(
        initialUrlRequest: URLRequest(url: WebUri(widget.authUrl)),
        initialSettings: InAppWebViewSettings(
          javaScriptEnabled: true,
          domStorageEnabled: true,
          thirdPartyCookiesEnabled: true,
        ),
        onLoadStart: (_, __) {
          if (mounted) setState(() => _loading = true);
        },
        onLoadStop: (_, __) {
          if (mounted) setState(() => _loading = false);
        },
        shouldOverrideUrlLoading: (_, action) async {
          final url = action.request.url?.toString() ?? '';
          if (action.isForMainFrame && url.startsWith(_successPrefix)) {
            _intercept(url);
            return NavigationActionPolicy.CANCEL;
          }
          return NavigationActionPolicy.ALLOW;
        },
      ),
    );
  }
}

/// Opens the browser sign-in page and returns what it
/// intercepted; null when the person backed out.
Future<BrowserSignInResult?> openBrowserSignIn(
  BuildContext context,
  String authUrl,
) => Navigator.of(context).push<BrowserSignInResult>(
  MaterialPageRoute(builder: (_) => BrowserSignInPage(authUrl: authUrl)),
);
