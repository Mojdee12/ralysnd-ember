import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'ember/ember_theme.dart';

/// The result of a browser sign-in page: the authorization
/// code and state from the intercepted success redirect, or
/// the error FxA put in the redirect instead.
typedef BrowserSignInResult = ({String code, String state, String error});

/// Mozilla's own sign-in pages in a WebView (build 2033 —
/// the Kumiho contract): Firefox for Android's OAuth client
/// finishes on an ordinary HTTPS success page, so the app
/// watches navigations for it, reads code+state out of the
/// URL, and hands them to the core — the completion hand-off
/// the desktop client performs over Firefox's internal
/// WebChannel, which no WebView can receive, is never used.
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
  late final WebViewController _controller;
  bool _loading = true;
  bool _finished = false;

  /// Build 2074 (audit item 19): a failed main-frame load —
  /// the delegate used to have no error callbacks at all, so
  /// a failure was a blank page with no message or retry.
  bool _loadFailed = false;

  /// The registered success page of the Firefox for Android
  /// OAuth client (client-id suffixed, as registered); a
  /// main-frame navigation to it carries the outcome.
  static const _successPrefix =
      'https://accounts.firefox.com/oauth/success/a2270f727f45f648';

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) {
            if (mounted) {
              setState(() {
                _loading = true;
                _loadFailed = false;
              });
            }
          },
          onPageFinished: (_) {
            if (mounted) setState(() => _loading = false);
          },
          // Build 2074 (audit item 19): surface main-frame
          // load failures as an Ember error state with a
          // reload action (see build). Sub-resource failures
          // do not blank the page.
          onWebResourceError: (error) {
            if (error.isForMainFrame != false && mounted) {
              setState(() {
                _loading = false;
                _loadFailed = true;
              });
            }
          },
          onHttpError: (error) {
            // HttpResponseError carries no main-frame flag,
            // and sub-resources can 404 on a working page —
            // only an HTTP error while the page itself is
            // still loading counts as a failed load.
            final status = error.response?.statusCode ?? 0;
            if (status >= 400 && _loading && mounted) {
              setState(() {
                _loading = false;
                _loadFailed = true;
              });
            }
          },
          onNavigationRequest: (request) {
            final url = request.url;
            if (request.isMainFrame && url.startsWith(_successPrefix)) {
              _intercept(url);
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
        ),
      )
      ..loadRequest(Uri.parse(widget.authUrl));
  }

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
    // Build 2056: the page is Map Control now — the Ember
    // background and bar over Mozilla's own pages. The WebView
    // and the success-redirect interception are untouched: the
    // page itself still never sees the password.
    return Scaffold(
      backgroundColor: Ember.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Ember.text,
        title: Text('Sign in with Mozilla', style: Ember.heading),
        bottom: _loading
            ? const PreferredSize(
                preferredSize: Size.fromHeight(2),
                child: LinearProgressIndicator(
                  minHeight: 2,
                  color: Ember.orange,
                  backgroundColor: Ember.card,
                ),
              )
            : null,
      ),
      body: EmberBackground(
        child: _loadFailed
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.cloud_off_rounded,
                        size: 40,
                        color: Ember.faint,
                      ),
                      const SizedBox(height: 14),
                      Text(
                        'The sign-in page could not be loaded. '
                        'Check the connection and try again.',
                        style: Ember.dimStyle,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 18),
                      EmberButton(
                        label: 'Reload',
                        icon: Icons.refresh_rounded,
                        onTap: () {
                          setState(() {
                            _loadFailed = false;
                            _loading = true;
                          });
                          _controller.loadRequest(Uri.parse(widget.authUrl));
                        },
                      ),
                    ],
                  ),
                ),
              )
            : WebViewWidget(controller: _controller),
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
