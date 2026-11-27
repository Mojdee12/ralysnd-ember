/// The DNSTT underlay form (build 2072): the resolver, the
/// tunnel domain and the dnstt-server public key the client
/// is spawned with when DNSTT is the selected underlay (see
/// dnstt_args.dart for the command line these become).
///
/// The page states the deployment plainly: the client alone
/// does nothing — a dnstt-server with the matching domain and
/// key must run at the server end, forwarding to a SOCKS
/// proxy there.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../xray/dnstt_args.dart';
import '../../xray/dnstt_platform.dart';
import '../../xray/xray_controller.dart';
import 'ember_format.dart';
import 'ember_theme.dart';
import 'map_widgets.dart';

Future<void> openDnsttSettings(BuildContext context, XrayController xray) =>
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => DnsttSettingsPage(xray: xray)));

class DnsttSettingsPage extends StatefulWidget {
  const DnsttSettingsPage({super.key, required this.xray});
  final XrayController xray;

  @override
  State<DnsttSettingsPage> createState() => _DnsttSettingsPageState();
}

class _DnsttSettingsPageState extends State<DnsttSettingsPage> {
  final Map<String, TextEditingController> _fields = {};
  late String _resolverType = widget.xray.settings.dnsttResolverType;
  DnsttState _state = const DnsttState();

  /// Build 2074 (DNSTT audit c): a state refresh shows its
  /// loading state instead of silently swapping the line.
  bool _refreshing = false;

  /// Build 2092 (item 8): Save shows its busy state and
  /// cannot stack.
  bool _saving = false;

  /// Build 2074 (DNSTT audit d): the client log tail can be
  /// expanded past its 6-line clip.
  bool _logExpanded = false;

  @override
  void initState() {
    super.initState();
    final s = widget.xray.settings;
    _field('resolver', s.dnsttResolver);
    _field('domain', s.dnsttDomain);
    _field('pubkey', s.dnsttPubkey);
    unawaited(_refreshState());
  }

  @override
  void dispose() {
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController _field(String key, String initial) =>
      _fields.putIfAbsent(key, () => TextEditingController(text: initial));

  String _v(String key) => _fields[key]?.text.trim() ?? '';

  Future<void> _refreshState() async {
    if (mounted) setState(() => _refreshing = true);
    final st = await DnsttPlatform.state();
    if (mounted) {
      setState(() {
        _state = st;
        _refreshing = false;
      });
    }
  }

  Future<void> _save() async {
    // Build 2074 (DNSTT audit c): the pop is gated on validity
    // — the page used to exit as if saved with an invalid or
    // incomplete public key while the underlay refused to
    // start. Invalid stays, with a plain message.
    final complete =
        _v('resolver').isNotEmpty &&
        _v('domain').isNotEmpty &&
        isDnsttPubkey(_v('pubkey'));
    if (!complete) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Fill in the resolver, the tunnel domain and a valid '
            'server public key (64 hex digits) first.',
          ),
        ),
      );
      return;
    }
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await widget.xray.saveDnsttSettings(
        resolverType: _resolverType,
        resolver: _v('resolver'),
        domain: _v('domain'),
        pubkey: _v('pubkey'),
      );
      if (mounted) Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _text(String key, String label, {String? hint}) => Padding(
    padding: const EdgeInsets.only(bottom: 11),
    child: TextField(
      controller: _fields[key],
      style: Ember.body,
      textDirection: TextDirection.ltr,
      onChanged: (_) => setState(() {}),
      decoration: emberField(context, hint ?? label).copyWith(
        labelText: label,
        labelStyle: const TextStyle(color: Ember.faint, fontSize: Ember.fontBody),
        floatingLabelStyle: const TextStyle(color: Ember.orange),
      ),
    ),
  );

  Widget _dropdown(
    String label,
    String value,
    List<(String, String)> options,
    ValueChanged<String> onChanged,
  ) => Padding(
    padding: const EdgeInsets.only(bottom: 11),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      decoration: BoxDecoration(
        color: Ember.field,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Ember.line),
      ),
      child: Row(
        children: [
          Text(label, style: Ember.dimStyle),
          const SizedBox(width: 12),
          // Build 2092 (item 21): the dropdown flexes with
          // the row instead of overflowing it at 320 dp or
          // large font scales.
          Expanded(
            child: DropdownButton<String>(
              value: value,
              isExpanded: true,
              dropdownColor: Ember.card,
              underline: const SizedBox.shrink(),
              style: Ember.body,
              items: [
                for (final (v, name) in options)
                  DropdownMenuItem(value: v, child: Text(name)),
              ],
              onChanged: (v) {
                if (v != null) onChanged(v);
              },
            ),
          ),
        ],
      ),
    ),
  );

  // Build 2074 (DNSTT audit e): sections are MapGlass, like
  // the sibling settings surfaces — not the legacy GlassCard.
  // The padding is the old GlassCard default, spelled out.
  Widget _section(String title, List<Widget> children) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: MapGlass(
        blur: false,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Ember.heading.copyWith(fontSize: Ember.fontTitle)),
          const SizedBox(height: 13),
          ...children,
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final pubkeyOk = isDnsttPubkey(_v('pubkey'));
    final complete =
        _v('resolver').isNotEmpty && _v('domain').isNotEmpty && pubkeyOk;
    final resolverHint = switch (_resolverType) {
      'dot' => 'e.g. dns.example.com:853 or 1.1.1.1:853',
      'udp' => 'e.g. 8.8.8.8:53',
      _ => 'e.g. https://dns.google/dns-query',
    };
    // Build 2074 (DNSTT audit a+b): the port routes through
    // latDigits(), and a stopped client reads as a plain
    // sentence — the raw platform error stays in the client
    // log below, not in the state line.
    final stateLine = !_state.available
        ? 'The DNSTT client is not available in this build.'
        : _state.ready
        ? 'Client running — listening on '
              '127.0.0.1:${latDigits(dnsttListenPort)}.'
        : _state.running
        ? 'Client is starting…'
        : _state.stage == 'error'
        ? 'Client stopped unexpectedly.'
        : 'Client is not running. It starts with the next '
              'V2Ray session while DNSTT is the underlay.';
    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Ember.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Ember.text,
        title: Text('DNSTT settings', style: Ember.heading),
        actions: [
          IconButton(
            onPressed: _saving ? null : () => unawaited(_save()),
            icon: _saving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Ember.orange,
                    ),
                  )
                : const Icon(Icons.check_rounded, color: Ember.orange),
            tooltip: 'Save',
          ),
        ],
      ),
      body: EmberBackground(
        // Build 2092 (item 21): the page listens to the
        // controller while visible (the warp settings
        // pattern) — a settings change made elsewhere no
        // longer leaves this page showing stale values.
        child: ListenableBuilder(
          listenable: widget.xray,
          builder: (context, _) => ListView(
            padding: EdgeInsets.fromLTRB(18, MediaQuery.of(context).padding.top + kToolbarHeight + 6, 18, 24),
            children: [
              _section('How DNSTT works', [
                Text(
                  'DNSTT tunnels through DNS queries to your own '
                  'server. A dnstt-server must run there with the '
                  'same tunnel domain and key, forwarding to a '
                  'SOCKS proxy on that server — the client alone '
                  'does nothing. Ember runs the client on '
                  '127.0.0.1:${latDigits(dnsttListenPort)} and dials '
                  'the V2Ray session through it.',
                  style: Ember.caption,
                ),
              ]),
              _section('Server', [
                _dropdown('Resolver transport', _resolverType, const [
                  ('doh', 'DNS over HTTPS'),
                  ('dot', 'DNS over TLS'),
                  ('udp', 'Plain UDP DNS'),
                ], (v) => setState(() => _resolverType = v)),
                _text('resolver', 'Resolver', hint: resolverHint),
                _text(
                  'domain',
                  'Tunnel domain',
                  hint: 'e.g. t.example.com (delegated to your server)',
                ),
                _text(
                  'pubkey',
                  'Server public key',
                  hint: '64 hex digits, from dnstt-server -gen-key',
                ),
                Text(
                  _v('pubkey').isEmpty
                      ? 'The public key is required — the client '
                            'refuses to start without it.'
                      : pubkeyOk
                      ? 'Public key looks valid.'
                      : 'Not a valid key yet: it must be exactly '
                            '64 hex digits.',
                  style: Ember.caption.copyWith(
                    color: _v('pubkey').isNotEmpty && !pubkeyOk
                        ? Ember.orange
                        : null,
                  ),
                ),
              ]),
              _section('Client', [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: Text(stateLine, style: Ember.caption)),
                    // Build 2074 (DNSTT audit c): the refresh shows
                    // its loading state while the state is read.
                    if (_refreshing)
                      const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Ember.orange,
                          ),
                        ),
                      )
                    else
                      IconButton(
                        onPressed: () => unawaited(_refreshState()),
                        icon: const Icon(
                          Icons.refresh_rounded,
                          size: 18,
                          color: MapUi.dim,
                        ),
                        tooltip: 'Refresh',
                      ),
                  ],
                ),
                if (_state.logTail.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  // Build 2074 (DNSTT audit d): the log tail is
                  // no longer hard-clipped to 6 lines with the
                  // end hidden — it expands, and it can be copied,
                  // like the app's other log surfaces.
                  Text(
                    _state.logTail,
                    style: Ember.caption,
                    maxLines: _logExpanded ? null : 6,
                    overflow: _logExpanded
                        ? TextOverflow.visible
                        : TextOverflow.ellipsis,
                  ),
                  Row(
                    children: [
                      TextButton.icon(
                        // Build 2092 (item 51): 48 dp floor.
                        style: TextButton.styleFrom(
                          minimumSize: const Size(0, 48),
                        ),
                        onPressed: () async {
                          await Clipboard.setData(
                            ClipboardData(text: _state.logTail),
                          );
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Client log copied'),
                              ),
                            );
                          }
                        },
                        icon: const Icon(
                          Icons.copy_rounded,
                          size: 16,
                          color: Ember.dim,
                        ),
                        label: Text('Copy', style: Ember.caption),
                      ),
                      TextButton.icon(
                        // Build 2092 (item 51): 48 dp floor.
                        style: TextButton.styleFrom(
                          minimumSize: const Size(0, 48),
                        ),
                        onPressed: () =>
                            setState(() => _logExpanded = !_logExpanded),
                        icon: Icon(
                          _logExpanded
                              ? Icons.expand_less_rounded
                              : Icons.expand_more_rounded,
                          size: 16,
                          color: Ember.dim,
                        ),
                        label: Text(
                          _logExpanded ? 'Show less' : 'Show more',
                          style: Ember.caption,
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 4),
                Text(
                  complete
                      ? 'Ready: the next V2Ray session with the '
                            'DNSTT underlay will start this client.'
                      : 'Fill in all three server fields to use '
                            'the DNSTT underlay.',
                  style: Ember.caption,
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}
