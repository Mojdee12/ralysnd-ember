/// Servers: Mozilla mode lists the core's countries like mockup 3
/// (smart-pick card, flag rows, colored pings); V2Ray mode lists the
/// configs grouped by subscription like the approved V2Ray mockup —
/// same glass cards, same chips, nothing of v2rayNG's look.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/core_controller.dart';
import '../../core/models.dart';
import '../../l10n/app_localizations.dart';
import '../../net/tcp_ping.dart';
import '../../psiphon/psiphon_controller.dart';
import '../../xray/cf_scanner.dart';
import '../../xray/shared_link.dart';
import '../../xray/smart_groups.dart';
import '../../xray/sub_fetcher.dart';
import '../../xray/xray_controller.dart';
import '../../xray/xray_models.dart';
import 'cf_scanner_page.dart';
import 'ember_accounts.dart';
import 'ember_dialogs.dart';
import 'ember_format.dart';
import 'ember_theme.dart';
import 'fastest_prune_sheet.dart';
import 'map_widgets.dart';
import 'profile_country.dart';
import 'profile_editor.dart';
import 'qr_pages.dart';
import 'recycle_bin_page.dart';
import 'sandbox_test_sheet.dart';
import 'service_check_sheet.dart';

class EmberServers extends StatelessWidget {
  const EmberServers({
    super.key,
    required this.core,
    required this.xray,
    required this.v2ray,
    required this.onOpenAccounts,
    this.onClose,
    this.psiphon,
  });

  final CoreController core;
  final XrayController xray;
  final bool v2ray;
  final VoidCallback onOpenAccounts;
  final VoidCallback? onClose;

  /// Build 2065 (item 3): lets the CF scanner offer its
  /// add-as-Psiphon-edge action.
  final PsiphonController? psiphon;

  // Build 2095 (owner-reported appearance fix): the V2Ray
  // config rows get the header panel's frosted-glass
  // backing via ONE container-level backdrop blur behind
  // the whole list (MapListFrost) — the rows rendered
  // almost directly on the dotted map and were hard to
  // read. The Mozilla locations branch is NOT wrapped:
  // its rows follow the approved sample-5 sheet design
  // and the shell deliberately keeps the actors layer
  // visible behind that tab.
  @override
  Widget build(BuildContext context) => v2ray
      ? MapListFrost(
          child: _V2rayServers(
            xray: xray,
            onOpenAccounts: onOpenAccounts,
            onClose: onClose,
            psiphon: psiphon,
          ),
        )
      : _MozillaServers(core: core, onClose: onClose);
}

/// Build 2133: the V2Ray tab as a dedicated full-screen
/// page — its own scaffold over the dotted-map backdrop;
/// the shell's map, header rail and tab bar are NOT
/// behind it. The body is the same servers surface
/// (build-2133 anatomy: status strip, subscription
/// cards, per-group ping); [EmberServers]' onClose pops
/// back to wherever the page was opened from.
class V2RayPage extends StatelessWidget {
  final XrayController xray;
  final PsiphonController? psiphon;
  final VoidCallback? onOpenAccounts;

  const V2RayPage({
    super.key,
    required this.xray,
    this.psiphon,
    this.onOpenAccounts,
  });

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: MapUi.baseBottom,
    body: Stack(
      children: [
        // Build 2145 (UI-review fix A3): the pushed V2Ray page
        // is a text surface — banded backdrop, like the shell's
        // non-home tabs.
        const Positioned.fill(child: MapBackdropVisual(banded: true)),
        SafeArea(
          // Fidelity rollout batch 3 (pro6-v2ray): the page
          // drops the MapListFrost blur — the sample's header
          // band is a READABLE dotted globe with its filament
          // arc, and the frost was the old glass language over
          // it (the live BackdropFilter is also the V-23 jank
          // class). The banded scrim alone carries row
          // legibility below the band, as on the other pushed
          // pages. The Servers TAB keeps its frost (batch 2's
          // accepted composition). The page also leads with
          // the sample's hero zone (pageLead).
          child: _V2rayServers(
            xray: xray,
            psiphon: psiphon,
            pageLead: true,
            onOpenAccounts: onOpenAccounts ?? () {},
            onClose: () {
              Navigator.of(context).maybePop();
            },
          ),
        ),
      ],
    ),
  );
}

// ---------------------------------------------------------------- Mozilla

class _MozillaServers extends StatefulWidget {
  const _MozillaServers({required this.core, this.onClose});
  final CoreController core;
  final VoidCallback? onClose;

  @override
  State<_MozillaServers> createState() => _MozillaServersState();
}

class _MozillaServersState extends State<_MozillaServers> {
  List<Location> _locations = [];
  bool _loading = true;
  bool _pinging = false;
  String _query = '';

  // Build 2074 (audit item 17): a failed load is its own
  // state (with Retry), not "no servers found"; a failed
  // Ping-all marks the numbers it left behind as stale.
  bool _loadFailed = false;
  bool _pingsStale = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    // Build 2074 (audit item 17): a retry re-enters the
    // loading state and clears the failure flag up front.
    if (mounted) {
      setState(() {
        _loading = true;
        _loadFailed = false;
      });
    }
    try {
      final list = await widget.core.call((api) => api.locations());
      if (mounted) {
        setState(() {
          _locations = list.locations;
          _loading = false;
          _loadFailed = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadFailed = true;
        });
      }
    }
  }

  Future<void> _pingAll() async {
    setState(() => _pinging = true);
    try {
      final list = await widget.core.call(
        (api) => api.pingLocations([for (final l in _locations) l.code]),
      );
      if (mounted) {
        setState(() {
          _locations = list.locations;
          _pingsStale = false;
        });
      }
    } catch (_) {
      // Build 2074 (audit item 17): the old numbers stay, but
      // they are marked stale — they no longer look fresh.
      if (mounted) setState(() => _pingsStale = true);
    } finally {
      if (mounted) setState(() => _pinging = false);
    }
  }

  Future<void> _pick(String code) async {
    try {
      await widget.core.call((api) => api.setLocation(code));
      await widget.core.refresh();
    } catch (e) {
      // Build 2095 (whole-app journey audit #14): a failed
      // pick is SAID — the tap used to look accepted while
      // the core kept the old location.
      if (mounted) {
        final text = e.toString();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'The location did not change: '
              '${text.length > 140 ? '${text.substring(0, 140)}\u2026' : text}',
            ),
            duration: const Duration(seconds: 5),
          ),
        );
      }
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final selection = widget.core.status?.selection ?? '';
    final shown = _locations.where((loc) {
      if (_query.isEmpty) return true;
      final q = _query.toLowerCase();
      return loc.name.toLowerCase().contains(q) ||
          loc.city.toLowerCase().contains(q) ||
          localizedCountryName(
            context,
            loc.code,
            loc.name,
          ).toLowerCase().contains(q);
    }).toList();

    return ListenableBuilder(
      listenable: widget.core,
      // Build 2055 (audit A-H4): slivers — the header panel
      // (title, search, smart pick) on its own, the location
      // rows lazily built below it. The old form put every
      // country row in one giant blurred MapGlass, all built
      // eagerly.
      builder: (context, _) => CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: MapGlass(
                blur: false,
                luminous: true,
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    MapPanelHeader(
                      title: 'Mozilla Locations',
                      onClose: widget.onClose,
                      actions: [
                        if (_pinging)
                          const SizedBox(
                            width: 19,
                            height: 19,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Ember.orange,
                            ),
                          )
                        else
                          MapGhostButton(
                            icon: Icons.bolt_rounded,
                            label: l.pingAll,
                            onTap: () => unawaited(_pingAll()),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      onChanged: (v) => setState(() => _query = v),
                      style: Ember.body,
                      decoration: emberField(
                        context,
                        l.searchCountry,
                        prefix: const Icon(
                          Icons.search_rounded,
                          color: Ember.faint,
                          size: 20,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    // The smart pick, collapsed to ONE compact row the
                    // height of a standard server row (sample 5's budget:
                    // five rows visible in the sheet).
                    _SubRow(
                      selected: selection == 'fastest',
                      onTap: () => _pick('fastest'),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 30,
                            height: 30,
                            decoration: const BoxDecoration(
                              gradient: Ember.gradient,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.bolt_rounded,
                              color: Color(0xFF1A1206),
                              size: 17,
                            ),
                          ),
                          const SizedBox(width: 11),
                          Expanded(
                            child: Text(
                              l.smartPick,
                              style: Ember.heading.copyWith(
                                fontSize: Ember.fontTitle,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          EmberChip(
                            label: l.optimalChip,
                            selected: selection == 'fastest',
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    // Build 2095 (audit #14): the Recommended
                    // row — the core's own pick (an empty
                    // selection). It existed in the core API
                    // and the legacy UI, but this list offered
                    // no way back to it once a country was
                    // picked.
                    _SubRow(
                      selected: selection == '',
                      onTap: () => _pick(''),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 30,
                            height: 30,
                            decoration: BoxDecoration(
                              color: Ember.orange.withValues(alpha: 0.16),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.recommend_rounded,
                              color: Ember.orange,
                              size: 17,
                            ),
                          ),
                          const SizedBox(width: 11),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  l.recommendedLocation,
                                  style: Ember.heading.copyWith(
                                    fontSize: Ember.fontTitle,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                                Text(
                                  l.useRecommendedLocation,
                                  style: Ember.caption,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                          if (selection == '')
                            const Icon(
                              Icons.check_rounded,
                              color: Ember.orange,
                              size: 18,
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 4),
                    if (_loading)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 40),
                        child: Center(
                          child: CircularProgressIndicator(color: Ember.orange),
                        ),
                      )
                    else if (_loadFailed)
                      // Build 2074 (audit item 17): load failure
                      // is distinct from an empty result, and
                      // carries its own Retry.
                      EmberEmpty(
                        icon: Icons.cloud_off_rounded,
                        text: 'Could not load locations.',
                        action: EmberButton(
                          label: l.retry,
                          icon: Icons.refresh_rounded,
                          onTap: () => unawaited(_load()),
                        ),
                      )
                    else if (shown.isEmpty)
                      EmberEmpty(
                        icon: Icons.public_off_rounded,
                        text: l.noServersFound,
                      ),
                  ],
                ),
              ),
            ),
          ),
          if (!_loading && shown.isNotEmpty)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, i) => _LocationRow(
                    location: shown[i],
                    selected:
                        selection == shown[i].code ||
                        (selection.isEmpty && shown[i].recommended),
                    onTap: () => _pick(shown[i].code),
                    divider: i < shown.length - 1,
                    stale: _pingsStale,
                  ),
                  childCount: shown.length,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// One inset sub-row inside a Map Control panel: a faint fill
/// and hairline normally; the warm orange selection of the
/// samples (tint, border, soft glow) when [selected].
class _SubRow extends StatelessWidget {
  const _SubRow({
    required this.child,
    this.selected = false,
    this.onTap,
    this.onLongPress,
    this.flat = false,
    this.padding = const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
  });

  final Widget child;
  final bool selected;
  final VoidCallback? onTap;

  /// Build 2136 (visual review V-13): the flat in-card form —
  /// no fill, no border; the row's own hairline (drawn by the
  /// caller-visible build below) replaces the box. Used for
  /// UNSELECTED profile rows inside subscription cards,
  /// where the card already supplies the container.
  final bool flat;

  /// Build 2095 (V2Ray journey audit #13): long-press enters
  /// multi-select on the profile rows.
  final VoidCallback? onLongPress;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    if (flat) {
      // Build 2136 (V-13): flat in-card row — content and a
      // hairline, nothing else.
      return Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(padding: padding, child: child),
              Container(height: 1, color: MapUi.line),
            ],
          ),
        ),
      );
    }
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            // Unselected rows wear a neutral charcoal fill
            // with a defined hairline rim (build 2144 reskin:
            // the old blue-tinted slate fill/border are
            // neutralised to the samples' grey ramp).
            // Build 2145 (UI-review fix A1): the selected row's
            // gradient wash and glow shadow are RETIRED — two
            // design generations no longer share the screen.
            // Selection is carried the way the rest of the
            // recomposed app carries it: the flat neutral fill
            // stays, the orange RIM (alpha 0.8, 1.2 wide) marks
            // the row, and the row's own ACTIVE label + left
            // tick say the rest.
            color: MapUi.cardSoft,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected
                  ? Ember.orange.withValues(alpha: 0.8)
                  : MapUi.lineStrong,
              width: selected ? 1.2 : 1,
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}

class _LocationRow extends StatelessWidget {
  const _LocationRow({
    required this.location,
    required this.selected,
    required this.onTap,
    this.divider = true,
    this.stale = false,
  });
  final Location location;
  final bool selected;
  final VoidCallback onTap;

  /// A hairline under an UNSELECTED row (unselected rows wear no
  /// box in sample 5 — dividers on the sheet instead).
  final bool divider;

  /// Build 2074 (audit item 17): the last Ping-all failed, so
  /// this row's ping is an old number — rendered dimmed and
  /// labelled stale instead of looking fresh.
  final bool stale;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final ms = location.pingMs;
    final name = localizedCountryName(context, location.code, location.name);
    final primary = location.city.isNotEmpty ? location.city : name;
    final row = Row(
      children: [
        FlagCircle(code: location.code, size: 34),
        const SizedBox(width: 11),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                primary,
                style: Ember.heading.copyWith(fontSize: Ember.fontTitle),
                overflow: TextOverflow.ellipsis,
              ),
              if (location.city.isNotEmpty)
                Text(
                  name,
                  style: Ember.caption,
                  overflow: TextOverflow.ellipsis,
                ),
            ],
          ),
        ),
        if (ms > 0) ...[
          Text(
            '${latDigits(ms)} ${l.msUnit}',
            style: TextStyle(
              fontSize: Ember.fontBody,
              fontWeight: FontWeight.w700,
              // Build 2074 (audit item 17): stale pings dim.
              color: stale ? MapUi.faint : mapPingColor(ms),
            ),
          ),
          if (stale) ...[
            const SizedBox(width: 5),
            Text('stale', style: Ember.caption.copyWith(color: MapUi.faint)),
          ],
        ],
        if (selected) ...[
          const SizedBox(width: 8),
          Container(
            width: 20,
            height: 20,
            decoration: const BoxDecoration(
              gradient: Ember.gradient,
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.check_rounded,
              color: Color(0xFF1A1206),
              size: 13,
            ),
          ),
        ],
      ],
    );
    if (selected) {
      return _SubRow(
        selected: true,
        onTap: onTap,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: row,
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: row,
            ),
          ),
        ),
        if (divider)
          const Divider(height: 1, thickness: 1, indent: 12, color: MapUi.line),
      ],
    );
  }
}

// ------------------------------------------------------------------ V2Ray

/// The filament globe arc of the pro6-v2ray sample's header
/// band: one thin gradient filament sweeping the band with
/// three glowing nodes — the Home filament's palette and
/// weights (batch 3). Pure decoration over the banded map.
class _GlobeArcPainter extends CustomPainter {
  const _GlobeArcPainter();

  static Offset _point(double t, double w, double h) {
    // The band's sweep: in low at the left edge, cresting
    // above the middle, out at the right — a quadratic
    // Bézier with its control point above the band.
    const p0 = Offset(-12, 0.88);
    final c = Offset(w * 0.38, -h * 0.62);
    final p1 = Offset(w + 12, h * 0.42);
    final a = Offset(p0.dx, p0.dy * h);
    final mt = 1 - t;
    return Offset(
      mt * mt * a.dx + 2 * mt * t * c.dx + t * t * p1.dx,
      mt * mt * a.dy + 2 * mt * t * c.dy + t * t * p1.dy,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final path = Path()
      ..moveTo(-12, h * 0.88)
      ..quadraticBezierTo(w * 0.38, -h * 0.62, w + 12, h * 0.42);
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4.5
        ..color = Ember.orange.withValues(alpha: 0.16),
    );
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.3
        ..shader = const LinearGradient(
          colors: [Color(0xFFFFC46B), Ember.orange],
        ).createShader(Offset.zero & size),
    );
    for (final t in const [0.28, 0.52, 0.76]) {
      final p = _point(t, w, h);
      canvas.drawCircle(
        p,
        5,
        Paint()..color = Ember.orange.withValues(alpha: 0.25),
      );
      canvas.drawCircle(p, 2.1, Paint()..color = const Color(0xFFFFC46B));
    }
  }

  @override
  bool shouldRepaint(covariant _GlobeArcPainter oldDelegate) => false;
}

/// Fidelity rollout batch 3 (pro6-v2ray): the full page's
/// hero lead — the shell header's own anatomy re-laid as the
/// sample composes it. Top line: the tracked EMBER wordmark
/// with its orange dot (the Home header's), the engine
/// status at the right, the page's Close. Second line: the
/// header's QR Scan / Add text actions, unchanged. Then the
/// globe-arc band over the page's map band, the selected
/// config as the hero (tracked label, hero name, tracked
/// meta, the hero ping numeral), and the config's
/// subscription as a hairline panel: its remaining traffic
/// in the sample's form over the 2 px line of what is left,
/// and the subscription's own scoped Ping as a tracked
/// action row — the same funnel run its card starts. Every
/// fact and callback is the list's own; nothing here
/// connects, selects or tests anything the list doesn't.
class _V2rayPageLead extends StatelessWidget {
  const _V2rayPageLead({
    required this.profile,
    required this.subscription,
    required this.pinging,
    required this.pingEnabled,
    required this.onPing,
    required this.onScan,
    required this.onAdd,
    this.onClose,
  });

  final Profile profile;
  final Subscription? subscription;
  final bool pinging;
  final bool pingEnabled;
  final VoidCallback? onPing;
  final VoidCallback onScan;
  final VoidCallback onAdd;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final sub = subscription;
    final delay = profile.delayMs;
    final meta = [
      profile.protocol.label,
      if (profile.security.isNotEmpty) profile.security,
      if (profile.network.isNotEmpty) profile.network,
      '${profile.port}',
    ].join(' · ').toUpperCase();
    final remaining = sub == null
        ? 0
        : (sub.totalBytes - sub.usedBytes).clamp(0, sub.totalBytes);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text(
              'EMBER',
              style: TextStyle(
                fontSize: Ember.fontDisplay,
                fontWeight: FontWeight.w300,
                letterSpacing: 6,
                color: Ember.text,
              ),
            ),
            const SizedBox(width: 5),
            Container(
              width: 6,
              height: 6,
              decoration: const BoxDecoration(
                color: Ember.orange,
                shape: BoxShape.circle,
              ),
            ),
            const Spacer(),
            Container(
              width: 7,
              height: 7,
              decoration: const BoxDecoration(
                color: Color(0xFF3DDC84),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 6),
            Text('V2RAY ENGINE', style: Ember.microLabel),
            if (onClose != null)
              IconButton(
                tooltip: 'Close',
                onPressed: onClose,
                icon: const Icon(Icons.close_rounded, size: 19),
                color: MapUi.dim,
                constraints: const BoxConstraints(
                  minWidth: 48,
                  minHeight: 48,
                ),
              ),
          ],
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: onScan,
              child: const Text('QR Scan', style: _V2rayServersState._headerActionStyle),
            ),
            TextButton(
              onPressed: onAdd,
              child: const Text('Add', style: _V2rayServersState._headerActionStyle),
            ),
          ],
        ),
        const SizedBox(
          height: 118,
          child: CustomPaint(painter: _GlobeArcPainter(), size: Size.infinite),
        ),
        Text('V2RAY · SELECTED CONFIG', style: Ember.microLabelOrange),
        const SizedBox(height: 6),
        // The hero name takes the full width on its own line
        // (batch 3, iteration 2): beside the numeral it
        // ellipsised at the owner's width — the name is the
        // hero, the numeral anchors the meta row under it,
        // right-aligned as the sample's is. Its size steps
        // down by length (iteration 3): the sample's name is
        // short and wears the full hero; real config names
        // run long, and a stepped size keeps them whole on
        // one line instead of clipped.
        Text(
          profile.name,
          style: Ember.hero.copyWith(
            fontSize: profile.name.length <= 13
                ? 54
                : profile.name.length <= 20
                ? 38
                : 30,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 2),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(
                  meta,
                  style: const TextStyle(
                    fontSize: Ember.fontSmall,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.6,
                    color: MapUi.dim,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            if (delay > 0)
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        latDigits(delay),
                        style: Ember.numeral.copyWith(
                          fontSize: Ember.fontHeroPing,
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text('ms', style: Ember.caption),
                      ),
                    ],
                  ),
                  Text('PING', style: Ember.microLabel),
                ],
              ),
          ],
        ),
        if (sub != null && sub.totalBytes > 0) ...[
          const SizedBox(height: 14),
          Container(
            decoration: BoxDecoration(
              color: MapUi.card,
              border: Border.all(color: MapUi.line),
              borderRadius: MapUi.panelBorder,
            ),
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'SUBSCRIPTION · ${sub.name}',
                        // Tightened tracking (batch 3, iteration
                        // 2): the microLabel's 2.2 spacing
                        // ellipsised the name beside the
                        // remaining figure at the owner's width.
                        style: Ember.microLabel.copyWith(
                          letterSpacing: 1.0,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      '${fmtGigabytes(remaining)} / '
                      '${fmtGigabytes(sub.totalBytes)} GB LEFT',
                      style: _V2rayServersState._headerActionStyle.copyWith(
                        fontSize: Ember.fontSmall,
                        letterSpacing: 0.6,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: Container(
                    height: 2,
                    color: MapUi.line,
                    child: Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: FractionallySizedBox(
                        widthFactor: (remaining / sub.totalBytes).clamp(
                          0.0,
                          1.0,
                        ),
                        child: Container(color: Ember.orange),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                InkWell(
                  onTap: pingEnabled ? onPing : null,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Row(
                      children: [
                        Text('Ping this subscription', style: Ember.body),
                        const Spacer(),
                        Text(
                          pinging ? 'STOP' : 'RUN',
                          style: Ember.microLabelOrange,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _V2rayServers extends StatefulWidget {
  const _V2rayServers({
    required this.xray,
    required this.onOpenAccounts,
    this.onClose,
    this.psiphon,
    this.pageLead = false,
  });
  final XrayController xray;
  final VoidCallback onOpenAccounts;
  final VoidCallback? onClose;
  final PsiphonController? psiphon;

  /// Fidelity rollout batch 3: only the full-screen
  /// [V2RayPage] sets this — the page leads with the
  /// pro6-v2ray hero zone (wordmark + engine status, the
  /// globe-arc band, the selected config as hero, its
  /// subscription's hairline panel) in place of the list's
  /// title row. The Servers tab keeps the batch-2 header.
  final bool pageLead;

  @override
  State<_V2rayServers> createState() => _V2rayServersState();
}

class _V2rayServersState extends State<_V2rayServers> {
  String _query = '';
  Protocol? _filter;

  /// Build 2095 (V2Ray journey audit #13): long-press
  /// multi-select — the batch bar acts on this set.
  final Set<String> _multiSel = {};

  bool get _selecting => _multiSel.isNotEmpty;

  List<Profile> get _multiProfiles =>
      widget.xray.profiles.where((p) => _multiSel.contains(p.id)).toList();

  Future<void> _multiDelete() async {
    final targets = _multiProfiles;
    if (targets.isEmpty) return;
    final ok = await showEmberConfirm(
      context,
      title: 'Delete ${targets.length} configs?',
      message:
          'The selected configs are removed. A config that is '
          'connected is disconnected first.',
      confirmLabel: 'Delete',
    );
    if (!ok || !mounted) return;
    for (final p in targets) {
      await widget.xray.deleteProfile(p);
    }
    if (mounted) setState(_multiSel.clear);
  }

  Future<void> _multiTest() async {
    for (final p in _multiProfiles) {
      await widget.xray.testDelay(p);
    }
  }

  Future<void> _multiStar() async {
    for (final p in _multiProfiles) {
      if (!p.starred) await widget.xray.toggleStarred(p);
    }
  }

  // Build 2074 (audit item 17): the search field gets a
  // controller so the no-matches empty state's Clear-search
  // action can actually clear the field, not just the state.
  final TextEditingController _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// Group-by-country view (build 2032, the v2go fold-in):
  /// groups by the exit country a delay test OBSERVED, else
  /// the country the remark claims, else "Unknown" — plus a
  /// Cloudflare-endpoints group for profiles whose address is
  /// a Cloudflare IP.
  bool _groupByCountry = false;

  XrayController get xray => widget.xray;

  bool _isCfEndpoint(Profile p) {
    final a = p.address;
    if (!RegExp(r'^\d+\.\d+\.\d+\.\d+$').hasMatch(a)) return false;
    for (final cidr in [...cfWideRanges, ...cfRegionalRanges]) {
      if (ipInCidr(a, cidr)) return true;
    }
    return false;
  }

  /// The grouped rendering for [_groupByCountry]: Cloudflare
  /// first (it is a property of the endpoint, not a country),
  /// then countries A–Z, Unknown last.
  /// Build 2116 (AP-15): the group record carries the
  /// country code beside the title, so the header renders
  /// the shared FlagCircle instead of a flag emoji (whose
  /// rendering is device-font-dependent).
  List<(String, String?, List<Profile>)> _countryGroups(List<Profile> all) {
    final cf = <Profile>[];
    final byCountry = <String, List<Profile>>{};
    final unknown = <Profile>[];
    for (final p in all) {
      if (_isCfEndpoint(p)) {
        cf.add(p);
        continue;
      }
      final code = p.exitCountryCode.isNotEmpty
          ? p.exitCountryCode.toUpperCase()
          : profileCountryCode(p);
      if (code == null || code.isEmpty) {
        unknown.add(p);
      } else {
        byCountry.putIfAbsent(code, () => []).add(p);
      }
    }
    final codes = byCountry.keys.toList()..sort();
    return [
      if (cf.isNotEmpty) ('Cloudflare endpoints', null, cf),
      for (final c in codes) (countryDisplayName(c), c, byCountry[c]!),
      if (unknown.isNotEmpty) ('Unknown exit', null, unknown),
    ];
  }

  /// The flat item list the sliver list builds lazily (build
  /// 2055, audit A-H4): group headers + one profile per item,
  /// in the same order the old eager Column had them —
  /// favorites first, then loose, then one group per
  /// subscription; By-country groups when that view is on.
  /// A starred profile still appears in its own group below,
  /// so nothing ever hides by starring (build 2044).
  List<_ServersItem> _serversItems(List<Profile> loose, String looseTitle) {
    final items = <_ServersItem>[];
    // Build 2116 (AB-12): subscriptions whose automatic
    // refresh is failing say so, once, at the head of the
    // list — the sweep no longer fails in silence.
    final failing = xray.subAutoRefreshFailing;
    if (failing > 0) {
      items.add(
        _ServersNoticeItem(
          failing == 1
              ? '1 subscription could not refresh automatically — '
                    'its list may be out of date.'
              : '$failing subscriptions could not refresh '
                    'automatically — their lists may be out of date.',
        ),
      );
    }
    // Build 2129 (recycle bin): the Recently deleted
    // entry rides at the head of the list while the bin
    // holds anything — in both views, and even when every
    // profile is gone (the case where it matters most).
    if (xray.deletedProfileCount > 0) {
      items.add(_ServersRecycleBinItem(xray.deletedProfileCount));
    }
    if (_groupByCountry) {
      for (final g in _countryGroups(_shown(xray.profiles))) {
        items.add(
          _ServersGroupHeaderItem(
            title: g.$1,
            flagCode: g.$2,
            count: g.$3.length,
          ),
        );
        for (final p in g.$3) {
          items.add(_ServersProfileItem(p));
        }
      }
      return items;
    }
    final shown = _shown(xray.profiles);
    if (shown.any((p) => p.starred)) {
      final favs = shown.where((p) => p.starred).toList();
      items.add(
        _ServersGroupHeaderItem(title: 'Favorites', count: favs.length),
      );
      for (final p in favs) {
        items.add(_ServersProfileItem(p));
      }
    }
    // Build 2105: smart groups — rule-made sections on the
    // same second-home doctrine as Favorites (a member still
    // appears in its own group below; nothing hides). Only in
    // the default view — By-country is its own grouping — and
    // only while the feature is on; off, this adds nothing and
    // the list is exactly the pre-2105 one.
    if (xray.settings.smartGroupsEnabled) {
      for (final rule in xray.settings.smartGroupRules) {
        final members = smartGroupMembers(
          rule,
          shown,
          subscriptionNameOf: (p) => xray.subscriptionOf(p)?.name ?? '',
        );
        if (members.isEmpty) continue;
        items.add(
          _ServersGroupHeaderItem(title: rule.label, count: members.length),
        );
        for (final p in members) {
          items.add(_ServersProfileItem(p));
        }
      }
    }
    if (loose.isNotEmpty) {
      items.add(
        _ServersGroupHeaderItem(title: looseTitle, count: loose.length),
      );
      for (final p in loose) {
        items.add(_ServersProfileItem(p));
      }
    }
    // Build 2137 (#9): the fallback card leads the
    // subscription sections in this view too — the header
    // it used to live in is shared by both views.
    final selForFallback = xray.selected;
    if (selForFallback != null &&
        xray.fallbackGroupMembers(selForFallback).length >= 2) {
      items.add(const _ServersFallbackItem());
    }
    for (final sub in xray.subscriptions) {
      final storeMembers = xray.profilesOf(sub);
      final members = _shown(storeMembers);
      // Build 2137 (#10): as in the grouped view — a fully
      // hidden subscription keeps its header, subtitled
      // "No configs match" (its count stays the store's);
      // only a store-empty subscription is skipped.
      if (members.isEmpty && storeMembers.isEmpty) continue;
      items.add(
        _ServersGroupHeaderItem(
          title: sub.name,
          count: members.isEmpty ? storeMembers.length : members.length,
          onRefresh: () => unawaited(_refreshSub(sub.id)),
          refreshing: _refreshingSubs.contains(sub.id),
          onPrune: () => unawaited(_pruneSub(sub.id, sub.name)),
          subtitle: members.isEmpty
              ? 'No configs match'
              : _updatedAgo(sub.lastUpdatedMs),
        ),
      );
      for (final p in members) {
        items.add(_ServersProfileItem(p));
      }
    }
    return items;
  }

  /// The Import sheet behind the action bar's first cell:
  /// every add path the pill row used to carry, in one place.
  Future<void> _importMenu() async {
    final l = AppLocalizations.of(context);
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Ember.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(
                Icons.content_paste_rounded,
                color: Ember.orange,
              ),
              title: Text(l.addByPaste, style: Ember.body),
              onTap: () => Navigator.of(sheetContext).pop('paste'),
            ),
            // Build 2094: a subscription entry where users
            // look for one — the full add-subscription sheet
            // used to be reachable only from the Accounts tab,
            // so the V2Ray section read as having no way to
            // add a subscription at all. Same sheet, reused.
            ListTile(
              leading: const Icon(
                Icons.subscriptions_rounded,
                color: Ember.orange,
              ),
              title: Text(l.addSubscription, style: Ember.body),
              onTap: () => Navigator.of(sheetContext).pop('sub'),
            ),
            ListTile(
              leading: const Icon(Icons.add_rounded, color: Ember.orange),
              title: Text(l.addManual, style: Ember.body),
              onTap: () => Navigator.of(sheetContext).pop('manual'),
            ),
            ListTile(
              leading: const Icon(
                Icons.cloud_done_rounded,
                color: Ember.orange,
              ),
              title: Text('CF clean IP', style: Ember.body),
              onTap: () => Navigator.of(sheetContext).pop('cf'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    if (choice == 'paste') showPasteSheet(context, xray);
    if (choice == 'sub') showAddSubscriptionSheet(context, xray);
    if (choice == 'manual') unawaited(openProfileEditor(context, xray));
    if (choice == 'cf') {
      unawaited(openCfScanner(context, xray, psiphon: widget.psiphon));
    }
  }

  Future<void> _keepOnlyWorking() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Keep only working?', style: Ember.heading),
        content: Text(
          'Every config whose last delay test failed will be '
          'removed. Configs that were never tested stay.',
          style: Ember.body,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove failed'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final removed = await xray.keepOnlyWorking();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            // Build 2074 (audit item 27): the count routes
            // through latDigits.
            removed > 0
                ? 'Removed ${latDigits(removed)} failed config${removed == 1 ? '' : 's'}'
                : 'Nothing to remove',
          ),
        ),
      );
    }
  }

  /// "Keep only the fastest N" over the servers list's visible
  /// configs (build 2076, feature queue #6): the scope is the
  /// same visible list Test All just covered — the current
  /// search + protocol filter — so a filtered view prunes what
  /// the user sees, never the whole store behind it. The
  /// sheet states the exact counts first; Cancel deletes
  /// nothing.
  Future<void> _keepFastestFlow() async {
    final scope = _shown(xray.profiles);
    final removed = await showFastestPruneSheet(
      context,
      xray: xray,
      scope: scope,
      scopeName: _query.isEmpty && _filter == null
          ? 'All configs'
          : 'Shown configs',
      // Build 2095 (V2Ray journey audit, batch 8): the same
      // restore note the per-subscription prune shows.
      restoreNote:
          'Configs from a subscription can come back on its '
          'next refresh; hand-added configs are gone for good.',
      // Build 2133: no Test All run is offered from this
      // tab any more (the owner's per-subscription ping
      // doctrine) — the sheet ranks the stored results;
      // its in-sheet test shortcut is not passed here.
      onRunTestAll: null,
    );
    if (removed != null && removed > 0 && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            // Build 2074 (audit item 27): latDigits.
            'Removed ${latDigits(removed)} slower config${removed == 1 ? '' : 's'}',
          ),
        ),
      );
    }
  }

  /// Build 2133 (V2Ray full tab): which group cards are
  /// expanded, keyed 'sub:(id)' / 'manual'. Null until the
  /// first build seeds it from the store (see
  /// [_seedExpandedGroups]).
  Set<String>? _expandedGroups;

  /// The group whose scoped ping is running (build 2133).
  /// The delay funnel is a single global run, so at most
  /// one group pings at a time; that group's card shows
  /// the funnel's progress and its Ping button is Stop.
  String? _pingGroupKey;

  static const String _manualGroupKey = 'manual';

  /// Build 2144 (reskin): the header's SCAN / ADD actions
  /// are bare orange text in the pro6 sample, not chips.
  static const TextStyle _headerActionStyle = TextStyle(
    fontSize: Ember.fontSmall,
    fontWeight: FontWeight.w700,
    letterSpacing: 1.2,
    color: Ember.orange,
  );

  String _subGroupKey(Subscription sub) => 'sub:${sub.id}';

  /// The first-build expansion (build 2133): the group
  /// holding the selected profile, else the first
  /// subscription that has configs, else Manual configs
  /// when it alone has any — the approved sample's shape
  /// (first subscription open, the rest closed).
  Set<String> _seedExpandedGroups() {
    final selected = xray.selected;
    if (selected != null) {
      final sub = xray.subscriptionOf(selected);
      if (sub != null) return {_subGroupKey(sub)};
      if (xray.looseProfiles.any((p) => p.id == selected.id)) {
        return {_manualGroupKey};
      }
    }
    for (final sub in xray.subscriptions) {
      if (xray.profilesOf(sub).isNotEmpty) return {_subGroupKey(sub)};
    }
    if (xray.looseProfiles.isNotEmpty) return {_manualGroupKey};
    return {};
  }

  void _toggleGroup(String key) {
    final expanded = _expandedGroups ??= _seedExpandedGroups();
    setState(() {
      if (!expanded.remove(key)) expanded.add(key);
    });
  }

  /// "just now" / "12 min ago" / "2 h ago" / "3 d ago" for
  /// the Last-ping caption (build 2133) — [_updatedAgo]
  /// without its "Updated" word.
  String _agoText(int epochMs) {
    final d = DateTime.now().millisecondsSinceEpoch - epochMs;
    if (d < 60 * 1000) return 'just now';
    if (d < 3600 * 1000) return '${latDigits(d ~/ 60000)} min ago';
    if (d < 86400 * 1000) return '${latDigits(d ~/ 3600000)} h ago';
    return '${latDigits(d ~/ 86400000)} d ago';
  }

  /// One group's scoped ping (build 2133): the existing
  /// delay funnel over ONLY this group's shown profiles —
  /// build 2033's funnel-respects-the-view rule, now per
  /// group instead of the whole visible store. On a
  /// completed (not cancelled) run, [record] writes the
  /// group's Best/Last-ping summary and the store is
  /// saved; a cancelled run keeps the previous summary.
  /// No store-wide sort follows (the old Test All sorted
  /// every profile; a group ping reorders nothing).
  Future<void> _pingGroup({
    required String key,
    required List<Profile> members,
    required void Function(String bestName, int bestMs) record,
  }) async {
    if (xray.scanRunning) {
      if (_pingGroupKey == key) xray.stopTestAll();
      return;
    }
    if (members.isEmpty) return;
    setState(() => _pingGroupKey = key);
    try {
      final cancelled = await xray.testAllDelays(only: members);
      if (!cancelled) {
        Profile? best;
        for (final p in members) {
          if (p.delayMs >= 0 && (best == null || p.delayMs < best.delayMs)) {
            best = p;
          }
        }
        record(best?.displayName ?? '', best?.delayMs ?? -1);
        await xray.save();
      }
    } finally {
      if (mounted) setState(() => _pingGroupKey = null);
    }
  }

  /// The subscription card's subtitle (build 2133):
  /// "24 servers · Updated 2 h ago", plus the traffic the
  /// panel reported and the days left — each ONLY when
  /// the stored subscription metadata actually carries
  /// it (never fabricated).
  String _subCardSubtitle(Subscription sub, int count) {
    final parts = <String>['${latDigits(count)} servers'];
    final ago = _updatedAgo(sub.lastUpdatedMs);
    if (ago.isNotEmpty) parts.add(ago);
    if (sub.totalBytes > 0) {
      parts.add('${fmtBytes(sub.usedBytes)} of ${fmtBytes(sub.totalBytes)}');
    }
    if (sub.expireEpochSec > 0) {
      final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      if (sub.expireEpochSec <= nowSec) {
        parts.add('Expired');
      } else if (sub.remainingDays > 0) {
        parts.add('${latDigits(sub.remainingDays)} days left');
      } else {
        parts.add('Expires today');
      }
    }
    return parts.join(' · ');
  }

  /// The grouped view's sliver items (build 2133): the
  /// auto-refresh notice and the recycle-bin row at the
  /// head (the same items the flat list carries), then
  /// Favorites and smart groups as flat sections (as
  /// before), then the SUBSCRIPTIONS label and one card
  /// per subscription — head slice, its server rows and
  /// a foot cap when expanded — then the Manual configs
  /// card. Cards are ITEMS, not widgets, so an expanded
  /// card's rows stay lazy sliver rows (build 2055's
  /// A-H4 guarantee).
  List<_ServersItem> _defaultItems(
    List<Profile> loose,
    Set<String> expanded,
    AppLocalizations l,
  ) {
    final items = <_ServersItem>[];
    final failing = xray.subAutoRefreshFailing;
    if (failing > 0) {
      items.add(
        _ServersNoticeItem(
          failing == 1
              ? '1 subscription could not refresh automatically — '
                    'its list may be out of date.'
              : '$failing subscriptions could not refresh '
                    'automatically — their lists may be out of date.',
        ),
      );
    }
    if (xray.deletedProfileCount > 0) {
      items.add(_ServersRecycleBinItem(xray.deletedProfileCount));
    }
    final shown = _shown(xray.profiles);
    if (shown.any((p) => p.starred)) {
      final favs = shown.where((p) => p.starred).toList();
      items.add(
        _ServersGroupHeaderItem(title: 'Favorites', count: favs.length),
      );
      for (final p in favs) {
        items.add(_ServersProfileItem(p));
      }
    }
    if (xray.settings.smartGroupsEnabled) {
      for (final rule in xray.settings.smartGroupRules) {
        final members = smartGroupMembers(
          rule,
          shown,
          subscriptionNameOf: (p) => xray.subscriptionOf(p)?.name ?? '',
        );
        if (members.isEmpty) continue;
        items.add(
          _ServersGroupHeaderItem(title: rule.label, count: members.length),
        );
        for (final p in members) {
          items.add(_ServersProfileItem(p));
        }
      }
    }
    // Build 2137 (visual review #9): the fallback group is
    // the list's first card — it lived in the header panel
    // through 2136. Same visibility rule the card applies
    // itself: a selected profile whose group has 2+ members.
    final selForFallback = xray.selected;
    if (selForFallback != null &&
        xray.fallbackGroupMembers(selForFallback).length >= 2) {
      items.add(const _ServersFallbackItem());
    }
    var anyCard = false;
    for (final sub in xray.subscriptions) {
      final storeMembers = xray.profilesOf(sub);
      final members = _shown(storeMembers);
      // Build 2137 (visual review #10): a subscription the
      // view fully hides (search / protocol filter) keeps
      // its card head, subtitled "No configs match", instead
      // of vanishing; only a subscription with no configs in
      // the store at all is skipped, as before.
      if (members.isEmpty && storeMembers.isEmpty) continue;
      if (!anyCard) {
        items.add(
          _ServersGroupHeaderItem(
            title: l.subscriptionsTitle,
            count: xray.subscriptions.length,
          ),
        );
        anyCard = true;
      }
      final key = _subGroupKey(sub);
      // An empty-view card renders closed whatever the
      // stored expansion says (its head draws the closed
      // anatomy; the toggle still flips the stored state).
      final isOpen = expanded.contains(key) && members.isNotEmpty;
      items.add(
        _ServersCardHeadItem(
          title: sub.name,
          subtitle: members.isEmpty
              ? 'No configs match'
              : _subCardSubtitle(sub, members.length),
          lastPingMs: sub.lastPingMs,
          bestName: sub.bestPingName,
          bestMs: sub.bestPingMs,
          expanded: isOpen,
          onToggleExpand: () => _toggleGroup(key),
          pingLabel: _pingGroupKey == key ? 'Stop' : l.pingLabel,
          pinging: _pingGroupKey == key,
          // Build 2137 (#10): an empty-view card's Ping is
          // disabled — there is nothing shown to test.
          pingEnabled: members.isNotEmpty && !xray.scanRunning,
          onPing: () => unawaited(
            _pingGroup(
              key: key,
              members: members,
              record: (name, ms) {
                sub.lastPingMs = DateTime.now().millisecondsSinceEpoch;
                sub.bestPingName = name;
                sub.bestPingMs = ms;
              },
            ),
          ),
          onRefresh: () => unawaited(_refreshSub(sub.id)),
          refreshing: _refreshingSubs.contains(sub.id),
          onPrune: () => unawaited(_pruneSub(sub.id, sub.name)),
          trafficUsedBytes: sub.usedBytes,
          trafficTotalBytes: sub.totalBytes,
          // Build 2145: the head's expires micro line —
          // the same real expiry facts the subtitle
          // composes, in the existing days-left wording.
          trafficExpiresLine: sub.expireEpochSec > 0
              ? (sub.expireEpochSec <=
                        DateTime.now().millisecondsSinceEpoch ~/ 1000
                    ? 'Expired'
                    : sub.remainingDays > 0
                    ? l.daysLeft(latDigits(sub.remainingDays))
                    : 'Expires today')
              : '',
          trafficRemainingBytes: sub.totalBytes > 0
              ? (sub.totalBytes - sub.usedBytes).clamp(0, sub.totalBytes)
              : -1,
          trafficFraction: sub.totalBytes > 0
              ? ((sub.totalBytes - sub.usedBytes) / sub.totalBytes).clamp(
                  0.0,
                  1.0,
                )
              : 0,
        ),
      );
      if (isOpen) {
        for (var i = 0; i < members.length; i++) {
          items.add(_ServersCardProfileItem(members[i], first: i == 0));
        }
        items.add(const _ServersCardFootItem());
      }
    }
    if (loose.isNotEmpty) {
      final settings = xray.settings;
      final isOpen = expanded.contains(_manualGroupKey);
      items.add(
        _ServersCardHeadItem(
          title: l.manualConfigsGroup,
          subtitle: '${latDigits(loose.length)} servers · added by hand',
          lastPingMs: settings.looseLastPingMs,
          bestName: settings.looseBestPingName,
          bestMs: settings.looseBestPingMs,
          expanded: isOpen,
          onToggleExpand: () => _toggleGroup(_manualGroupKey),
          pingLabel: _pingGroupKey == _manualGroupKey ? 'Stop' : l.pingLabel,
          pinging: _pingGroupKey == _manualGroupKey,
          pingEnabled: !xray.scanRunning,
          onPing: () => unawaited(
            _pingGroup(
              key: _manualGroupKey,
              members: loose,
              record: (name, ms) {
                settings.looseLastPingMs =
                    DateTime.now().millisecondsSinceEpoch;
                settings.looseBestPingName = name;
                settings.looseBestPingMs = ms;
              },
            ),
          ),
        ),
      );
      if (isOpen) {
        for (var i = 0; i < loose.length; i++) {
          items.add(_ServersCardProfileItem(loose[i], first: i == 0));
        }
        items.add(const _ServersCardFootItem());
      }
    }
    return items;
  }

  /// "Updated 12 min ago" for a subscription group header
  /// (build 2050, sample A); '' when it never refreshed.
  String _updatedAgo(int lastUpdatedMs) {
    if (lastUpdatedMs <= 0) return '';
    final d = DateTime.now().millisecondsSinceEpoch - lastUpdatedMs;
    if (d < 60 * 1000) return 'Updated just now';
    if (d < 3600 * 1000) {
      return 'Updated ${latDigits(d ~/ 60000)} min ago';
    }
    if (d < 86400 * 1000) {
      return 'Updated ${latDigits(d ~/ 3600000)} h ago';
    }
    return 'Updated ${latDigits(d ~/ 86400000)} d ago';
  }

  /// The funnel's honest progress line (build 2026): which
  /// stage is running, how far it got, and — in the real-test
  /// stage — how many profiles have answered so far.
  String _scanProgressText() {
    final phase = switch (xray.scanPhase) {
      'tcp' => 'Probing endpoints',
      'tls' => 'Checking TLS handshakes',
      'real' => 'Testing tunnels',
      _ => 'Testing',
    };
    final base =
        '$phase · ${latDigits(xray.scanDone)}/${latDigits(xray.scanTotal)}';
    return xray.scanPhase == 'real'
        ? '$base · ${latDigits(xray.scanAlive)} working'
        : base;
  }

  List<Profile> _shown(Iterable<Profile> all) => all.where((p) {
    if (_filter != null && p.protocol != _filter) return false;
    if (_query.isEmpty) return true;
    final q = _query.toLowerCase();
    // Build 2045: search matches the name the user sees AND the
    // server name, so a renamed config is still found by the
    // name the provider gave it.
    return p.displayName.toLowerCase().contains(q) ||
        p.name.toLowerCase().contains(q) ||
        p.address.toLowerCase().contains(q);
  }).toList();

  /// One servers-list item, rendered (build 2133: the
  /// By-country list and the grouped card list share this
  /// builder — the card slices are items of the same one
  /// lazy list).
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: xray,
      builder: (context, _) {
        final loose = _shown(xray.looseProfiles);
        final expanded = _expandedGroups ??= _seedExpandedGroups();
        // The flat item list survives for the By-country
        // view only (build 2133): the grouped view renders
        // subscription cards instead.
        final items = _groupByCountry
            ? _serversItems(loose, l.looseGroup)
            : const <_ServersItem>[];
        final defaultItems = _groupByCountry
            ? const <_ServersItem>[]
            : _defaultItems(loose, expanded, l);
        // Fidelity rollout batch 3 (pro6-v2ray): the full
        // page's hero lead — the selected profile, its
        // subscription, and the SAME scoped ping the
        // subscription's card runs (same members, same
        // record writes), computed once for the lead widget.
        final leadProfile = widget.pageLead ? xray.selected : null;
        final leadSub = leadProfile == null
            ? null
            : xray.subscriptionOf(leadProfile);
        final leadKey = leadSub == null ? null : _subGroupKey(leadSub);
        final leadMembers = leadSub == null
            ? const <Profile>[]
            : _shown(xray.profilesOf(leadSub));
        final leadPinging = leadKey != null && _pingGroupKey == leadKey;
        VoidCallback? leadOnPing;
        if (leadSub != null && leadKey != null) {
          final sub = leadSub;
          final key = leadKey;
          leadOnPing = () => unawaited(
            _pingGroup(
              key: key,
              members: leadMembers,
              record: (name, ms) {
                sub.lastPingMs = DateTime.now().millisecondsSinceEpoch;
                sub.bestPingName = name;
                sub.bestPingMs = ms;
              },
            ),
          );
        }
        return CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                // Build 2144 (reskin): the header is no longer
                // a glass panel — the pro6 sample's header is
                // open typography over the page ground.
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Build 2133 (V2Ray full tab): the
                      // header panel is the approved
                      // sample's — the page title, the slim
                      // Connected strip, the summary
                      // caption, and one buttons row
                      // (Import / QR Scan / + Add / the
                      // overflow menu that carries the old
                      // Sort menu). The action bar's Test
                      // All cell is GONE: each subscription
                      // card pings only itself now.
                      // Build 2144 (reskin): the pro6 header —
                      // the page title as a huge light hero
                      // word, the scan/add actions as bare
                      // orange text at the right, then the
                      // same close control MapPanelHeader
                      // carried. Title text unchanged.
                      // Fidelity rollout batch 3: on the full
                      // page (pageLead) with a config selected,
                      // the sample's hero lead takes this slot
                      // instead — wordmark + engine status, the
                      // globe-arc band, the config hero, its
                      // subscription's panel; QR Scan / Add /
                      // Close ride the lead's own top lines
                      // with the same callbacks.
                      if (widget.pageLead && leadProfile != null)
                        _V2rayPageLead(
                          profile: leadProfile,
                          subscription: leadSub,
                          pinging: leadPinging,
                          pingEnabled:
                              leadMembers.isNotEmpty &&
                              (!xray.scanRunning || leadPinging),
                          onPing: leadOnPing,
                          onScan: () =>
                              unawaited(scanAndImport(context, xray)),
                          onAdd: () =>
                              showAddSubscriptionSheet(context, xray),
                          onClose: widget.onClose,
                        )
                      else
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Expanded(
                              child: Text(
                                'V2Ray',
                                style: Ember.hero,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          TextButton(
                            onPressed: () =>
                                unawaited(scanAndImport(context, xray)),
                            child: const Text(
                              'QR Scan',
                              style: _headerActionStyle,
                            ),
                          ),
                          TextButton(
                            onPressed: () =>
                                showAddSubscriptionSheet(context, xray),
                            child: const Text('Add', style: _headerActionStyle),
                          ),
                          if (widget.onClose != null)
                            IconButton(
                              tooltip: 'Close',
                              onPressed: widget.onClose,
                              icon: const Icon(Icons.close_rounded, size: 19),
                              color: MapUi.dim,
                              constraints: const BoxConstraints(
                                minWidth: 48,
                                minHeight: 48,
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      _StatusStrip(xray: xray),
                      const SizedBox(height: 8),
                      Text(
                        l.tabSummary(
                          xray.subscriptions.length,
                          xray.profiles.length,
                        ),
                        style: const TextStyle(
                          fontSize: Ember.fontMicro,
                          color: MapUi.faint,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          MapGhostButton(
                            icon: Icons.download_rounded,
                            label: 'Import',
                            primary: false,
                            onTap: () => unawaited(_importMenu()),
                          ),
                          // Build 2144 (reskin): QR Scan and
                          // Add moved up into the header as
                          // orange text actions (same labels,
                          // same callbacks) — Import and the
                          // Sort overflow stay in this row.
                          const Spacer(),
                          // The old action bar's Sort menu,
                          // verbatim, behind the overflow
                          // button (build 2133).
                          PopupMenuButton<String>(
                            tooltip: 'Sort',
                            color: Ember.card,
                            padding: EdgeInsets.zero,
                            enabled: xray.profiles.isNotEmpty,
                            onSelected: (v) {
                              if (v == 'delay') xray.sortProfilesByDelay();
                              if (v == 'name') xray.sortProfilesByName();
                              if (v == 'country') {
                                setState(
                                  () => _groupByCountry = !_groupByCountry,
                                );
                              }
                              if (v == 'keepWorking') {
                                unawaited(_keepOnlyWorking());
                              }
                              if (v == 'keepFastest') {
                                unawaited(_keepFastestFlow());
                              }
                            },
                            itemBuilder: (_) => [
                              PopupMenuItem(
                                value: 'delay',
                                child: Text(l.sortByDelay),
                              ),
                              PopupMenuItem(
                                value: 'name',
                                child: Text(l.sortByName),
                              ),
                              PopupMenuItem(
                                value: 'country',
                                child: Row(
                                  children: [
                                    const Expanded(child: Text('By country')),
                                    if (_groupByCountry)
                                      const Icon(
                                        Icons.check_rounded,
                                        size: 17,
                                        color: Ember.orange,
                                      ),
                                  ],
                                ),
                              ),
                              if (xray.profiles.any((p) => p.delayFailed))
                                const PopupMenuItem(
                                  value: 'keepWorking',
                                  child: Text('Keep working only'),
                                ),
                              const PopupMenuItem(
                                value: 'keepFastest',
                                child: Text('Keep fastest N…'),
                              ),
                            ],
                            child: const Padding(
                              padding: EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 8,
                              ),
                              child: Icon(
                                Icons.more_vert_rounded,
                                color: MapUi.dim,
                                size: 21,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _searchController,
                        onChanged: (v) => setState(() => _query = v),
                        style: Ember.body,
                        // Build 2144 (reskin): the search is
                        // the sample's single hairline
                        // underline row — no box, no fill;
                        // hint text and icon unchanged.
                        decoration: InputDecoration(
                          hintText: l.searchConfig,
                          hintStyle: const TextStyle(
                            color: MapUi.dim,
                            fontSize: Ember.fontBody,
                          ),
                          prefixIcon: const Icon(
                            Icons.search_rounded,
                            color: Ember.faint,
                            size: 20,
                          ),
                          filled: false,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 13,
                          ),
                          border: const UnderlineInputBorder(
                            borderSide: BorderSide(color: MapUi.line),
                          ),
                          enabledBorder: const UnderlineInputBorder(
                            borderSide: BorderSide(color: MapUi.line),
                          ),
                          focusedBorder: const UnderlineInputBorder(
                            borderSide: BorderSide(
                              color: Ember.orange,
                              width: 1.4,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      // The protocol chips, slimmed to one compact row so
                      // the config cards get the panel's height.
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            EmberChip(
                              label: l.filterAll,
                              selected: _filter == null,
                              compact: true,
                              onTap: () => setState(() => _filter = null),
                            ),
                            const SizedBox(width: 6),
                            for (final proto in Protocol.values) ...[
                              EmberChip(
                                label: proto.label,
                                selected: _filter == proto,
                                compact: true,
                                onTap: () => setState(() => _filter = proto),
                              ),
                              const SizedBox(width: 6),
                            ],
                            // Build 2095 (V2Ray journey audit,
                            // batch 8): group-by-country as a
                            // visible toggle — it used to hide
                            // inside the Sort menu, where a
                            // toggle does not belong.
                            EmberChip(
                              label: 'By country',
                              selected: _groupByCountry,
                              compact: true,
                              onTap: () => setState(
                                () => _groupByCountry = !_groupByCountry,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                      // Fallback group (build 2035): the selected
                      // config's group in failover order, so the user
                      // sees what the engine will move to — and can
                      // tap a member to make it the selected one.
                      // Build 2137 (visual review #9): the card no
                      // longer lives in this header — it is the
                      // list's own first card now (see
                      // _ServersFallbackItem), so the header drops
                      // ~90 dp when the card is collapsed and the
                      // first subscription card rises above the
                      // fold.
                      if (xray.profiles.isEmpty)
                        EmberEmpty(
                          icon: Icons.dns_outlined,
                          text: l.noProfilesYet,
                          action: EmberButton(
                            label: l.addByPaste,
                            icon: Icons.content_paste_rounded,
                            onTap: () => showPasteSheet(context, xray),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            // A query that matches nothing gets an honest
            // empty state instead of blank space (build
            // 2074, audit item 17 — the EmberEmpty
            // treatment, with a Clear-search action that
            // clears both the field and the protocol
            // filter).
            if (xray.profiles.isNotEmpty &&
                (_groupByCountry
                    ? items.isEmpty
                    : _shown(xray.profiles).isEmpty))
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: EmberEmpty(
                    icon: Icons.search_off_rounded,
                    text: 'No configs match the search.',
                    action: EmberButton(
                      label: 'Clear search',
                      icon: Icons.clear_rounded,
                      onTap: () {
                        _searchController.clear();
                        setState(() {
                          _query = '';
                          _filter = null;
                        });
                      },
                    ),
                  ),
                ),
              ),
            // Build 2095 (V2Ray journey audit #13): the
            // multi-select batch bar. Build 2133: while a
            // funnel run is live (a card ping or the batch
            // Test), the bar also carries its progress —
            // the header panel's old global progress block
            // is gone with Test All.
            if (_selecting)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                  // Build 2144 (reskin): the batch bar is a
                  // flat charcoal block with a hairline rim,
                  // not glass.
                  child: Container(
                    decoration: BoxDecoration(
                      color: MapUi.card,
                      border: Border.all(color: MapUi.line),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Text(
                              '${latDigits(_multiSel.length)} selected',
                              style: const TextStyle(
                                fontSize: Ember.fontBody,
                                fontWeight: FontWeight.w800,
                                color: MapUi.text,
                              ),
                            ),
                            const Spacer(),
                            TextButton(
                              onPressed: () => unawaited(_multiTest()),
                              child: const Text('Test'),
                            ),
                            TextButton(
                              onPressed: () => unawaited(_multiStar()),
                              child: const Text('Star'),
                            ),
                            TextButton(
                              onPressed: () => unawaited(_multiDelete()),
                              child: const Text(
                                'Delete',
                                style: TextStyle(color: Ember.red),
                              ),
                            ),
                            IconButton(
                              tooltip: 'Clear selection',
                              icon: const Icon(
                                Icons.close_rounded,
                                size: 18,
                                color: MapUi.dim,
                              ),
                              onPressed: () => setState(_multiSel.clear),
                            ),
                          ],
                        ),
                        if (xray.scanRunning) ...[
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              const Icon(
                                Icons.radar_rounded,
                                size: 13,
                                color: Ember.orange,
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  _scanProgressText(),
                                  style: const TextStyle(
                                    fontSize: Ember.fontMicro,
                                    color: MapUi.dim,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          LinearProgressIndicator(
                            value: xray.scanTotal > 0
                                ? xray.scanDone / xray.scanTotal
                                : null,
                            minHeight: 3,
                            backgroundColor: MapUi.line,
                            color: Ember.orange,
                          ),
                          const SizedBox(height: 4),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            // Build 2133: the grouped view is subscription
            // cards (Favorites and smart groups stay flat
            // sections); the By-country view keeps the
            // flat item list it always had.
            if (_groupByCountry)
              if (items.isNotEmpty)
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  sliver: SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (context, i) => _ServersItemWidget(
                        item: items[i],
                        index: i,
                        xray: xray,
                        agoText: _agoText,
                        scanProgressText: _scanProgressText,
                        multiSelect: _selecting,
                        multiSelected: _multiSel,
                        onToggleMulti: (p) => setState(() {
                          if (!_multiSel.remove(p.id)) _multiSel.add(p.id);
                        }),
                        onEnterMulti: (p) =>
                            setState(() => _multiSel.add(p.id)),
                      ),
                      childCount: items.length,
                    ),
                  ),
                )
              else
                const SliverToBoxAdapter(child: SizedBox.shrink())
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                sliver: SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, i) => _ServersItemWidget(
                        item: defaultItems[i],
                        index: i,
                        xray: xray,
                        agoText: _agoText,
                        scanProgressText: _scanProgressText,
                        multiSelect: _selecting,
                        multiSelected: _multiSel,
                        onToggleMulti: (p) => setState(() {
                          if (!_multiSel.remove(p.id)) _multiSel.add(p.id);
                        }),
                        onEnterMulti: (p) =>
                            setState(() => _multiSel.add(p.id)),
                      ),
                    childCount: defaultItems.length,
                  ),
                ),
              ),
            // Build 2144 (reskin): the pro6 sample's bottom
            // action row — a long flat-orange scan pill and
            // an outline add pill, carrying the existing
            // QR Scan / Add actions and labels verbatim.
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                child: Row(
                  children: [
                    Expanded(
                      child: EmberButton(
                        label: 'QR Scan',
                        icon: Icons.qr_code_scanner_rounded,
                        onTap: () => unawaited(scanAndImport(context, xray)),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: () => showAddSubscriptionSheet(context, xray),
                        borderRadius: BorderRadius.circular(999),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            vertical: 14,
                            horizontal: 20,
                          ),
                          decoration: BoxDecoration(
                            border: Border.all(color: MapUi.lineStrong),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.add_rounded,
                                size: 19,
                                color: Ember.orange,
                              ),
                              SizedBox(width: 8),
                              Text(
                                'Add',
                                style: TextStyle(
                                  fontSize: Ember.fontTitle,
                                  fontWeight: FontWeight.w800,
                                  color: MapUi.text,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// Keep only the fastest N of one subscription (build 2065,
  /// item 12): an N picker, then a confirmation that names what
  /// will go — the ranking itself lives in the controller.
  /// "Keep only the fastest N" for one subscription group
  /// (build 2076, feature queue #6): the 2033 bare-dialog flow
  /// is replaced by the shared Map Control sheet — same plan,
  /// same counts, same Confirm/Cancel. A refresh of the
  /// subscription brings removed configs back.
  Future<void> _pruneSub(String id, String name) async {
    final sub = xray.subscriptions.where((s) => s.id == id).firstOrNull;
    if (sub == null) return;
    final removed = await showFastestPruneSheet(
      context,
      xray: xray,
      scope: xray.profilesOf(sub),
      scopeName: name,
      restoreNote:
          'A refresh of this subscription can bring removed configs back.',
      onRunTestAll: () async {
        final cancelled = await xray.testAllDelays(only: xray.profilesOf(sub));
        if (!cancelled) xray.sortProfilesByDelay();
      },
    );
    if (removed != null && removed > 0 && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            // Build 2074 (audit item 27): latDigits.
            'Removed ${latDigits(removed)} slower config${removed == 1 ? '' : 's'} from $name',
          ),
        ),
      );
    }
  }

  /// Build 2092 (item 28): subscription ids with a refresh
  /// in flight — their header buttons spin and disable, and
  /// a success is confirmed, not silent.
  final Set<String> _refreshingSubs = {};

  Future<void> _refreshSub(String id) async {
    final sub = xray.subscriptions.where((s) => s.id == id).firstOrNull;
    if (sub == null || _refreshingSubs.contains(id)) return;
    setState(() => _refreshingSubs.add(id));
    try {
      await xray.updateSubscription(sub);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Updated ${sub.name}')));
      }
    } catch (e) {
      if (mounted) {
        // Build 2050 (audit C-2): the fetcher's specific words.
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              subFetchErrorText(
                e,
                fallback: AppLocalizations.of(context).subUpdateFailed,
              ),
            ),
            duration: const Duration(seconds: 6),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _refreshingSubs.remove(id));
    }
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

/// Build 2137 (visual review #9): the fallback group's
/// standalone card chrome — the group-card head slice's
/// anatomy closed on all sides (the gradient fill, the
/// line border, the 20 dp radius and the specular top
/// line build 2136's V-12 pass gave the cards) around the
/// unchanged _FallbackGroupCard content.
class _FallbackCardShell extends StatelessWidget {
  const _FallbackCardShell({required this.xray});
  final XrayController xray;

  @override
  // Build 2144 (reskin): the fallback block wears the
  // group blocks' flat form — no fill, border box or
  // specular line; one hairline closes it.
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(
      border: Border(bottom: BorderSide(color: MapUi.line)),
    ),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
      child: _FallbackGroupCard(xray: xray),
    ),
  );
}

/// The selected config's fallback group (build 2035), in the
/// page's own section anatomy — caps micro-header, then rows.
/// Shows the group in failover order with each member's state
/// (active / tested delay / untested / cooling down) and the
/// on/off toggle; tapping a member selects it. Hidden when the
/// group has a single member: there is nothing to fall back to.
class _FallbackGroupCard extends StatefulWidget {
  const _FallbackGroupCard({required this.xray});
  final XrayController xray;

  @override
  State<_FallbackGroupCard> createState() => _FallbackGroupCardState();
}

class _FallbackGroupCardState extends State<_FallbackGroupCard> {
  /// Collapsed by default (owner's order, build 2050; audit
  /// A-H1): the card used to render its whole member list
  /// unconditionally above the configs, pushing them down.
  /// The header stays; a tap expands the members.
  bool _open = false;

  XrayController get xray => widget.xray;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final sel = xray.selected;
    if (sel == null) return const SizedBox.shrink();
    final members = xray.fallbackGroupMembers(sel);
    if (members.length < 2) return const SizedBox.shrink();
    final groupName = xray.subscriptionOf(sel)?.name ?? l.looseGroup;
    final on = xray.settings.adaptiveFailover;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: InkWell(
                onTap: () => setState(() => _open = !_open),
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  // Build 2092 (item 57): the expand header
                  // was a ~27 dp target; 15 dp vertical
                  // padding brings it to the 48 dp floor.
                  padding: const EdgeInsets.symmetric(vertical: 15),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.alt_route_rounded,
                        size: 14,
                        color: Ember.orange,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'FALLBACK GROUP \u2014 ${groupName.toUpperCase()}',
                          style: const TextStyle(
                            fontSize: Ember.fontMicro,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1.6,
                            color: MapUi.dim,
                          ),
                          // Build 2145 (UI-review fix A8): the
                          // title YIELDS — it wraps to a second
                          // line at a word boundary instead of
                          // truncating mid-word when the count
                          // and the toggle crowd the row; the
                          // ellipsis remains only as the backstop
                          // for names too long for two lines.
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        '${latDigits(members.length)} nodes',
                        style: Ember.caption,
                      ),
                      const SizedBox(width: 4),
                      Icon(
                        _open
                            ? Icons.expand_less_rounded
                            : Icons.expand_more_rounded,
                        size: 18,
                        color: MapUi.dim,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            // The failover toggle stays OUTSIDE the expand tap
            // target (audit A-H1): tapping it never opens or
            // closes the card.
            MapToggle(
              value: on,
              onChanged: (v) async {
                xray.settings.adaptiveFailover = v;
                await xray.save();
                // Build 2098 (post-2097 audit L22): every
                // other settings toggle also notifies — this
                // one saved silently, so listeners (and the
                // walk's own readers) never saw the change
                // and the knob looked dead.
                xray.notifySettingsChanged();
              },
            ),
          ],
        ),
        if (_open) ...[
          const SizedBox(height: 2),
          Text(
            on ? 'If a config dies, the next member takes over automatically' : 'Off \u2014 turn on to switch to the next member automatically',
            style: const TextStyle(fontSize: Ember.fontMicro, color: MapUi.dim),
          ),
          const SizedBox(height: 8),
          for (final p in members) ...[
            _FallbackMemberRow(
              xray: xray,
              profile: p,
              active: p.id == xray.selectedProfileId,
            ),
            const SizedBox(height: 6),
          ],
          const SizedBox(height: 8),
        ],
      ],
    );
  }
}

class _FallbackMemberRow extends StatelessWidget {
  const _FallbackMemberRow({
    required this.xray,
    required this.profile,
    required this.active,
  });
  final XrayController xray;
  final Profile profile;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final coolingDown = xray.isCoolingDown(profile.id);
    final switching = xray.switchingProfileId == profile.id;
    final status = switching
        ? 'Switching…'
        : coolingDown
        ? 'Cooling down'
        : profile.delayMs >= 0
        ? '${latDigits(profile.delayMs)}ms'
        // Build 2101 (D3): the sidecar-busy outcome, as on
        // the main server rows — not a failure.
        : profile.delayStage == 'sidecar-busy'
        ? 'Sidecar busy'
        : profile.delayFailed
        ? 'Failed'
        : 'Untested';
    final statusColor = switching
        ? Ember.orange
        : profile.delayStage == 'sidecar-busy'
        ? Ember.orange
        : coolingDown || profile.delayFailed
        ? Ember.red
        : profile.delayMs >= 0
        ? mapPingColor(profile.delayMs)
        : MapUi.dim;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => xray.select(profile),
        borderRadius: BorderRadius.circular(8),
        // Build 2058 (audit §5 Servers): the member rows were
        // borderless with no affordance — they did not look
        // tappable — and ~25 px tall. Now a bordered slot with
        // a chevron, 44 dp tall, so the row reads as a control
        // and a finger lands it.
        child: Container(
          // Build 2092 (item 57): the row floor is 48 dp.
          constraints: const BoxConstraints(minHeight: 48),
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.03),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: MapUi.line),
          ),
          child: Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: active
                      ? Ember.orange
                      : coolingDown
                      ? Ember.red
                      : MapUi.faint,
                ),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  // Build 2045: the name the user sees.
                  profile.displayName,
                  style: TextStyle(
                    fontSize: Ember.fontBody,
                    fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                    color: active ? Ember.orange : MapUi.text,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (active)
                const Padding(
                  padding: EdgeInsets.only(right: 8),
                  child: Text(
                    'ACTIVE',
                    style: TextStyle(
                      // Build 2116 (AP-13): the ACTIVE badge
                      // at the chip's 11sp floor — this member
                      // label rendered at 9sp, below the app's
                      // micro-text floor for this badge.
                      fontSize: Ember.fontMicro,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.8,
                      color: Ember.orange,
                    ),
                  ),
                ),
              Text(
                status,
                style: TextStyle(
                  fontSize: Ember.fontSmall,
                  fontWeight: FontWeight.w700,
                  color: statusColor,
                ),
              ),
              const SizedBox(width: 6),
              const Icon(
                Icons.chevron_right_rounded,
                size: 16,
                color: MapUi.dim,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One item of the servers sliver list (build 2055, audit
/// A-H4): a group header or one profile card. The list is
/// flat so SliverList.builder can build rows lazily.
sealed class _ServersItem {
  const _ServersItem();
}

class _ServersGroupHeaderItem extends _ServersItem {
  const _ServersGroupHeaderItem({
    required this.title,
    required this.count,
    this.subtitle = '',
    this.flagCode,
    this.onRefresh,
    this.onPrune,
    this.refreshing = false,
  });
  final String title;

  /// Build 2116 (AP-15): the by-country group's code, when
  /// this header is one — rendered as a FlagCircle.
  final String? flagCode;
  final int count;
  final String subtitle;
  final VoidCallback? onRefresh;

  /// Build 2092 (item 28): a refresh for this group is in
  /// flight — the header spins and disables its button.
  final bool refreshing;

  /// Build 2065 (item 12): keep-only-fastest-N for this
  /// subscription group; null on non-subscription groups.
  final VoidCallback? onPrune;
}

class _ServersProfileItem extends _ServersItem {
  const _ServersProfileItem(this.profile);
  final Profile profile;
}

/// Build 2116 (AB-12): a one-line notice at the head of
/// the list — today it carries the auto-refresh failure
/// count, which used to be completely silent.
class _ServersNoticeItem extends _ServersItem {
  const _ServersNoticeItem(this.text);
  final String text;
}

/// Build 2129 (recycle bin): the tappable head-of-list
/// row into the Recently deleted page, present only
/// while the bin is non-empty.
class _ServersRecycleBinItem extends _ServersItem {
  const _ServersRecycleBinItem(this.count);
  final int count;
}

/// Build 2133: a group card's head slice as a sliver
/// item — the card's data and actions; the widget is
/// built by the list's item builder so the summary line
/// can use the live context. The card's rows and foot
/// are their own items ([_ServersCardProfileItem],
/// [_ServersCardFootItem]) so they stay lazy.
class _ServersCardHeadItem extends _ServersItem {
  const _ServersCardHeadItem({
    required this.title,
    required this.subtitle,
    required this.lastPingMs,
    required this.bestName,
    required this.bestMs,
    required this.expanded,
    required this.onToggleExpand,
    required this.pingLabel,
    required this.pinging,
    required this.pingEnabled,
    required this.onPing,
    this.onRefresh,
    this.refreshing = false,
    this.onPrune,
    this.trafficRemainingBytes = -1,
    this.trafficFraction = 0,
    this.trafficUsedBytes = 0,
    this.trafficTotalBytes = 0,
    this.trafficExpiresLine = '',
  });
  final String title;
  final String subtitle;

  /// Build 2144 (reskin): the subscription's stored
  /// remaining traffic, rendered as the card's hero
  /// numeral with a thin orange progress line (the
  /// remaining fraction). -1 when the subscription
  /// carries no stored traffic metadata — the hero is
  /// then not drawn at all (never fabricated).
  /// Build 2145 (composition rebuild): the figure moves
  /// to the numeral scale, split into value + unit, with
  /// the used-of line under it — so the head also carries
  /// the used/total pair and the expiry line.
  final int trafficRemainingBytes;
  final double trafficFraction;
  final int trafficUsedBytes;
  final int trafficTotalBytes;
  final String trafficExpiresLine;
  final int lastPingMs;
  final String bestName;
  final int bestMs;
  final bool expanded;
  final VoidCallback onToggleExpand;
  final String pingLabel;
  final bool pinging;
  final bool pingEnabled;
  final VoidCallback onPing;
  final VoidCallback? onRefresh;
  final bool refreshing;
  final VoidCallback? onPrune;
}

/// Build 2133: one server row inside an expanded group
/// card — rendered in the card's slice chrome.
class _ServersCardProfileItem extends _ServersItem {
  const _ServersCardProfileItem(this.profile, {this.first = false});
  final Profile profile;

  /// The card's first row — it carries the gap under
  /// the card head.
  final bool first;
}

/// Build 2133: an expanded group card's foot cap.
class _ServersCardFootItem extends _ServersItem {
  const _ServersCardFootItem();
}

/// Build 2137 (visual review #9): the fallback group as a
/// list item — through 2136 it was rendered inside the
/// header panel. The item builders add it only when the
/// card itself would show (a selected profile whose group
/// has 2+ members); it renders as a standalone card in the
/// group cards' anatomy (see _FallbackCardShell).
class _ServersFallbackItem extends _ServersItem {
  const _ServersFallbackItem();
}

/// The header slice of one group card of the V2Ray tab
/// (build 2133): a subscription — or the Manual configs
/// group. Header: name + subtitle, the group's own
/// prune/refresh icon buttons (the same 48 dp actions
/// the flat list's group headers carried), a Ping button
/// that tests ONLY this group, and the expand chevron.
/// Below: the persisted Best/Last-ping summary; while
/// this card's ping runs, the funnel's progress line and
/// bar. The card is drawn as SLIVER SLICES (this head,
/// one slice per server row, a foot cap) so an expanded
/// card's rows stay lazy — build 2055's A-H4 guarantee;
/// the slices share MapGlass's gradient fill and line
/// border, split across the items.
class _GroupCardHead extends StatelessWidget {
  final String title;
  final String subtitle;
  final Widget summary;
  final bool expanded;
  final VoidCallback onToggleExpand;
  final String pingLabel;
  final bool pinging;
  final bool pingEnabled;
  final VoidCallback onPing;
  final String? progressText;
  final double? progressValue;
  final VoidCallback? onRefresh;
  final bool refreshing;
  final VoidCallback? onPrune;

  /// Build 2144 (reskin): see [_ServersCardHeadItem] — the
  /// stored remaining traffic as hero numeral + progress.
  /// Build 2145: plus the used/total pair and expiry line
  /// the numeral composition carries under the progress
  /// line.
  final int trafficRemainingBytes;
  final double trafficFraction;
  final int trafficUsedBytes;
  final int trafficTotalBytes;
  final String trafficExpiresLine;

  const _GroupCardHead({
    required this.title,
    required this.subtitle,
    required this.summary,
    required this.expanded,
    required this.onToggleExpand,
    required this.pingLabel,
    required this.pinging,
    required this.pingEnabled,
    required this.onPing,
    this.progressText,
    this.progressValue,
    this.onRefresh,
    this.refreshing = false,
    this.onPrune,
    this.trafficRemainingBytes = -1,
    this.trafficFraction = 0,
    this.trafficUsedBytes = 0,
    this.trafficTotalBytes = 0,
    this.trafficExpiresLine = '',
  });

  @override
  // Build 2144 (reskin): the card chrome is retired — no
  // gradient fill, no side/top borders, no specular line.
  // The group is a typographic block over the page ground,
  // closed by one hairline; its rows carry their own
  // hairlines (the flat _SubRow form).
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(
      border: Border(bottom: BorderSide(color: MapUi.line)),
    ),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Ember.title,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        fontSize: Ember.fontMicro,
                        color: MapUi.dim,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              // Build 2136 (visual review V-14): Prune moves
              // into a head overflow menu — the title column
              // gains its 48dp back; Refresh, Ping and the
              // chevron stay visible.
              if (onPrune != null)
                PopupMenuButton<String>(
                  tooltip: 'More actions',
                  icon: const Icon(
                    Icons.more_vert_rounded,
                    color: Ember.dim,
                    size: 20,
                  ),
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                  onSelected: (v) {
                    if (v == 'prune') onPrune!();
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: 'prune',
                      child: Text('Keep only fastest'),
                    ),
                  ],
                ),
              if (onRefresh != null)
                IconButton(
                  tooltip: 'Refresh subscriptions',
                  onPressed: refreshing ? null : onRefresh,
                  icon: refreshing
                      ? const SizedBox(
                          width: 19,
                          height: 19,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Ember.orange,
                          ),
                        )
                      : const Icon(
                          Icons.refresh_rounded,
                          color: Ember.dim,
                          size: 19,
                        ),
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                ),
              MapGhostButton(
                icon: Icons.bolt_rounded,
                label: pingLabel,
                onTap: (pingEnabled || pinging) ? onPing : null,
              ),
              IconButton(
                tooltip: expanded ? 'Collapse' : 'Expand',
                onPressed: onToggleExpand,
                icon: Icon(
                  expanded
                      ? Icons.keyboard_arrow_up_rounded
                      : Icons.keyboard_arrow_down_rounded,
                  color: Ember.dim,
                  size: 20,
                ),
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              ),
            ],
          ),
          if (trafficRemainingBytes >= 0) ...[
            const SizedBox(height: 10),
            // Build 2145 (composition rebuild, pro6-servers):
            // the remaining traffic at the numeral scale —
            // the value huge and light, its unit small
            // beside it (both halves of the same fmtBytes
            // string), over the 2 px orange progress line
            // of what is left. No honest 'left' wording
            // exists in the strings for a bare figure, so
            // the used-of line the subtitle already
            // composes goes under the progress line, and
            // the expiry fact follows as its own micro
            // line — the sample's EXPIRES slot.
            Builder(
              builder: (context) {
                final parts = fmtBytes(trafficRemainingBytes).split(' ');
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    // Build 2145 (UI-review fix A9): true-size
                    // numeral, no FittedBox (see the home
                    // delay numeral) — ellipsis is the backstop
                    // at extreme scale/width pairs only.
                    Flexible(
                      child: Text(
                        parts.first,
                        style: Ember.numeral,
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (parts.length > 1) ...[
                      const SizedBox(width: 8),
                      Text(
                        parts.sublist(1).join(' '),
                        style: const TextStyle(
                          fontSize: Ember.fontDisplay,
                          fontWeight: FontWeight.w300,
                          color: MapUi.text,
                        ),
                      ),
                    ],
                  ],
                );
              },
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: trafficFraction,
              minHeight: 2,
              color: Ember.orange,
              backgroundColor: MapUi.line,
            ),
            if (trafficTotalBytes > 0) ...[
              const SizedBox(height: 8),
              Text(
                '${fmtBytes(trafficUsedBytes)} of '
                '${fmtBytes(trafficTotalBytes)}',
                style: Ember.microLabel,
              ),
            ],
            if (trafficExpiresLine.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(trafficExpiresLine, style: Ember.microLabel),
            ],
          ],
          const SizedBox(height: 4),
          summary,
          if (progressText != null) ...[
            const SizedBox(height: 8),
            Text(progressText!, style: Ember.body),
            const SizedBox(height: 6),
            LinearProgressIndicator(
              value: progressValue,
              minHeight: 3,
              color: Ember.orange,
              backgroundColor: Colors.white.withValues(alpha: 0.08),
            ),
          ],
        ],
      ),
    ),
  );
}

/// One server-row slice of an expanded group card
/// (build 2133): the card's side borders and fill around
/// the ordinary profile row, so the row stays a lazy
/// sliver item of the page's one list.
class _CardRowSlice extends StatelessWidget {
  final bool first;
  final Widget child;

  const _CardRowSlice({required this.first, required this.child});

  @override
  // Build 2144 (reskin): no card fill or side borders —
  // the slice is just the row's inset inside the
  // typographic block; the row's own hairline separates.
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(14, first ? 10 : 0, 8, 0),
    child: child,
  );
}

/// The foot cap of an expanded group card (build 2133):
/// the card's bottom border and rounding, closing the
/// slices the head opened.
class _GroupCardFoot extends StatelessWidget {
  const _GroupCardFoot();

  @override
  // Build 2144 (reskin): the foot cap's borders and fill
  // are retired with the card chrome — it is now just
  // the block's closing gap.
  Widget build(BuildContext context) =>
      const SizedBox(height: 12, width: double.infinity);
}

/// A group header, extracted from the old _Group (build 2055):
/// caps micro-header + count + optional refresh, the same
/// anatomy — now a sliver-list item instead of the head of an
/// eager Column.
class _GroupHeader extends StatelessWidget {
  const _GroupHeader({
    required this.title,
    required this.count,
    this.subtitle = '',
    this.flagCode,
    this.onRefresh,
    this.onPrune,
    this.refreshing = false,
  });

  /// Build 2092 (item 28): see _ServersGroupHeaderItem.
  final bool refreshing;
  final String title;

  /// Build 2116 (AP-15): see _ServersGroupHeaderItem.
  final String? flagCode;
  final int count;

  /// A caption under the title (build 2050, sample A: a
  /// subscription group header carries its refresh age —
  /// "Updated 12 min ago").
  final String subtitle;
  final VoidCallback? onRefresh;
  final VoidCallback? onPrune;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      if (flagCode != null) ...[
        FlagCircle(code: flagCode!, size: 26),
        const SizedBox(width: 8),
      ],
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title.toUpperCase(),
              style: const TextStyle(
                // Build 2136 (visual review V-30): the 11sp
                // floor applies to group titles too.
                fontSize: Ember.fontMicro,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.6,
                color: MapUi.dim,
              ),
              overflow: TextOverflow.ellipsis,
            ),
            if (subtitle.isNotEmpty)
              Text(
                subtitle,
                // Build 2136 (visual review V-30): 11sp floor
                // + dim — this header pair sat at 10.5sp in
                // faint (3.52:1).
                style: const TextStyle(
                  fontSize: Ember.fontMicro,
                  color: MapUi.dim,
                ),
                overflow: TextOverflow.ellipsis,
              ),
          ],
        ),
      ),
      Text(latDigits(count), style: Ember.caption),
      // Build 2074 (audit item 4): prune / refresh get the
      // full 48 dp hit area — icons unchanged, the compact
      // density that shrank them is gone.
      if (onPrune != null)
        IconButton(
          onPressed: onPrune,
          tooltip: 'Keep only fastest',
          icon: const Icon(
            Icons.content_cut_rounded,
            color: Ember.dim,
            size: 18,
          ),
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
        ),
      if (onRefresh != null)
        // Build 2092 (item 28): while the refresh runs the
        // button is a disabled spinner, not a live button
        // stacking concurrent fetches.
        IconButton(
          tooltip: 'Refresh subscriptions',
          onPressed: refreshing ? null : onRefresh,
          icon: refreshing
              ? const SizedBox(
                  width: 19,
                  height: 19,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Ember.orange,
                  ),
                )
              : const Icon(Icons.refresh_rounded, color: Ember.dim, size: 19),
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
        ),
    ],
  );
}

/// The ping result (build 2050's bordered pill; build 2118
/// renders it as bare coloured text, sample 5's own form):
/// the value in its frozen health colour — green under
/// 150 ms, amber to 400, red beyond (and for failures).
class _PingPill extends StatelessWidget {
  const _PingPill({required this.text, required this.color});
  final String text;
  final Color color;

  @override
  // Build 2118 (appearance fix round): sample 5 shows latency
  // as BARE coloured text ("38ms", "210ms") — no pill, no
  // border. The bordered pill also ate ~18 dp of the row's
  // width, starving the name column into ellipses. The hues
  // are unchanged: the owner's frozen ping pair, which is
  // sample 5's own palette.
  Widget build(BuildContext context) => Text(
    text,
    style: TextStyle(
      fontSize: Ember.fontSmall,
      fontWeight: FontWeight.w800,
      color: color,
    ),
  );
}

class _ProfileRow extends StatelessWidget {
  const _ProfileRow({
    required this.xray,
    required this.profile,
    this.multiSelect = false,
    this.checked = false,
    this.onToggleMulti,
    this.onEnterMulti,
  });
  final XrayController xray;
  final Profile profile;

  // Build 2136 (V-13) carried an inCard flag for the flat
  // in-card form; batch 2 made EVERY row flat (see the
  // _SubRow call below), so the flag is retired.

  /// Build 2095 (V2Ray journey audit #13): multi-select
  /// state, driven by _V2rayServersState.
  final bool multiSelect;
  final bool checked;
  final VoidCallback? onToggleMulti;
  final VoidCallback? onEnterMulti;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final selected = xray.selectedProfileId == profile.id;
    // Build 2095 (V2Ray journey audit #12/#25): this row IS
    // the live session's config — the row itself must offer
    // the disconnect (and, when selected but stopped, the
    // connect) instead of sending the user to the home bar.
    final liveHere = selected && xray.state.running;
    // Build 2098 (post-2097 audit M15): the ACTIVE badge
    // belongs to the RUNNING session's profile, not to the
    // selection — a merely-selected profile used to wear it
    // next to its own Connect button while nothing was
    // running at all.
    final activeHere =
        xray.state.running && xray.sessionProfile?.id == profile.id;
    final testing = xray.isTesting(profile.id);
    final switching = xray.switchingProfileId == profile.id;
    // Sample anatomy (build 2050, approved samples A/B): a
    // flag circle at the left; the name, then protocol ·
    // endpoint, then the per-config totals on their own line
    // when the config has carried traffic (build 2074); at
    // the right a ping pill in the frozen colours, a tappable
    // star, and the ⋮ menu with every per-config action it
    // always had.
    // Build 2118 (appearance fix round): the row's status
    // element (spinner / latency / busy / failed / block),
    // computed once — on the selected row it stacks UNDER the
    // Connect button instead of beside it, returning ~45 dp
    // to the name column.
    Widget? statusTrailing() {
      if (testing || switching) {
        return const SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2, color: Ember.orange),
        );
      }
      if (profile.delayMs >= 0) {
        // Build 2144 (reskin): the pro6 row's ping is a big
        // light numeral with a small unit, not coloured
        // pill text — the value is the same stored delay.
        // Build 2145 (composition rebuild): the numeral
        // moves to the sample's hero scale (fontHero).
        return Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              latDigits(profile.delayMs),
              style: const TextStyle(
                fontSize: Ember.fontHero,
                fontWeight: FontWeight.w300,
                color: MapUi.text,
              ),
            ),
            const SizedBox(width: 3),
            Text('ms', style: Ember.caption),
          ],
        );
      }
      // Build 2101 (D3): a sidecar-busy test outcome is
      // its own state — the test never ran, so the row
      // must not claim the profile failed.
      if (profile.delayStage == 'sidecar-busy') {
        return const _PingPill(text: 'Sidecar busy', color: Ember.orange);
      }
      if (profile.delayFailed) {
        return const _PingPill(text: 'Failed', color: Ember.red);
      }
      // Build 2075: the block icon means NO engine serves
      // the protocol — sidecar-served protocols (TUIC,
      // Snell, Naive, Tailscale, OpenConnect, Mieru)
      // connect now and never show it.
      if (!profile.protocol.connectable) {
        return const Icon(Icons.block_rounded, size: 17, color: Ember.red);
      }
      return null;
    }

    final status = statusTrailing();
        // Batch 2 (fidelity rollout, owner order 2026-11-23):
    // the selected row's anatomy splits in two. In one row
    // the Connect button stacked over the hero ping beside
    // the star and the menu left the name ~124 dp — it
    // ellipsised even at the owner's 411 dp width. Now the
    // name row carries flag, name, star and menu at full
    // width, and the Connect action and the hero ping take
    // their own line beneath it, indented to the name
    // column — the pro6-servers row rhythm. Same widgets,
    // same handlers, same facts; testing/switching states
    // keep the status in the name row as before.
    final selectedIdle = selected && !testing && !switching && !multiSelect;
    final rowA = Row(
        children: [
          FlagCircle(code: profileDisplayCountryCode(profile) ?? '', size: 34),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  // Build 2045: the name the user sees.
                  // Build 2144 (reskin): the pro6 row's name
                  // is big and light, not small and bold.
                  // Build 2145: the sample's light weight
                  // (w300, the display tier's own weight).
                  profile.displayName,
                  style: const TextStyle(
                    fontSize: Ember.fontDisplay,
                    fontWeight: FontWeight.w300,
                    color: MapUi.text,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                // Build 2144 (reskin): the protocol line is
                // the sample's one grey monospace micro-line
                // (protocol · endpoint) — the rust tag box
                // is retired; the same two facts, one line.
                // Build 2145: the sample's full composition —
                // protocol · security · port in the one mono
                // micro-line, all real profile fields; the
                // endpoint host the row has always shown
                // stays with its port (the sample's rows are
                // named by city and carry no host).
                Text(
                  '${profile.protocol.label} · '
                  '${profile.security.isEmpty ? '' : '${profile.security} · '}'
                  '${maskHost(profile.address)}:'
                  '${latDigits(profile.port)}',
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: Ember.fontMicro,
                    letterSpacing: 0.4,
                    color: MapUi.dim,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                // Build 2074 (audit item 16): the per-config
                // totals are their own line, never folded into
                // the ellipsis above — on a narrow screen the
                // protocol · endpoint line truncates, the
                // totals always survive in full.
                // Build 2137 (visual review #7 / V-19): the
                // meta block is capped at this ONE further
                // line — rows used to stack totals, last-speed
                // and TCP lines to five text lines and break
                // the list's rhythm (and misalign the ping
                // pills). The totals keep the line when the
                // profile has them (the 2074 rule stands);
                // otherwise the TCP fact (build 2075 item 14:
                // raw endpoint reachability, labelled as what
                // it is, never folded into the real delay) and
                // the last speed test (build 2095 batch 8)
                // combine on the one line. The full detail
                // stays in the editor.
                if (profileHasTotals(profile)) ...[
                  const SizedBox(height: 2),
                  Directionality(
                    textDirection: TextDirection.ltr,
                    child: Text(
                      fmtProfileTotals(profile),
                      style: const TextStyle(
                        fontSize: Ember.fontMicro,
                        color: MapUi.dim,
                      ),
                    ),
                  ),
                ] else if (profile.lastSpeedBps >= 0 ||
                    profile.tcpPingMs >= 0 ||
                    profile.tcpPingFailed) ...[
                  const SizedBox(height: 2),
                  Text(
                    [
                      if (profile.tcpPingMs >= 0)
                        'TCP connect ${latDigits(profile.tcpPingMs)} ms'
                      else if (profile.tcpPingFailed)
                        'TCP connect failed',
                      if (profile.lastSpeedBps >= 0)
                        'Last speed test ${fmtRate(profile.lastSpeedBps)}',
                    ].join(' · '),
                    style: TextStyle(
                      fontSize: Ember.fontMicro,
                      // The failed-TCP red survives only when
                      // it is the line's whole content (as
                      // before); combined lines read dim.
                      color:
                          profile.tcpPingFailed &&
                              profile.tcpPingMs < 0 &&
                              profile.lastSpeedBps < 0
                          ? Ember.red
                          : MapUi.dim,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          // Build 2095 (audit #12/#25): the selected row
          // carries its own connect/disconnect pill.
          if (multiSelect) ...[
            Icon(
              checked
                  ? Icons.check_circle_rounded
                  : Icons.radio_button_unchecked_rounded,
              size: 22,
              color: checked ? Ember.orange : MapUi.faint,
            ),
            ?status,
          ] else if (!selectedIdle)
            ?status,
          // Build 2074 (audit item 4): the star and the ⋮ menu
          // get the full 48 dp hit area — icons unchanged.
          if (!multiSelect)
            SizedBox(
              width: 48,
              height: 48,
              child: IconButton(
                padding: EdgeInsets.zero,
                tooltip: profile.starred
                    ? 'Remove from favorites'
                    : 'Add to favorites',
                icon: Icon(
                  profile.starred
                      ? Icons.star_rounded
                      : Icons.star_border_rounded,
                  size: 19,
                  color: profile.starred ? Ember.orange : Ember.faint,
                ),
                onPressed: () => unawaited(xray.toggleStarred(profile)),
              ),
            ),
          if (!multiSelect)
            SizedBox(
              width: 48,
              height: 48,
              child: PopupMenuButton<String>(
                padding: EdgeInsets.zero,
                icon: const Icon(
                  Icons.more_vert_rounded,
                  color: Ember.faint,
                  size: 20,
                ),
                color: Ember.card,
                onSelected: (v) => unawaited(_act(context, v)),
                itemBuilder: (_) => [
                  if (liveHere)
                    const PopupMenuItem(
                      value: 'disconnect',
                      child: Text(
                        'Disconnect',
                        style: TextStyle(color: Ember.red),
                      ),
                    ),
                  const PopupMenuItem(
                    value: 'sandbox',
                    child: Text('Sandbox test'),
                  ),
                  const PopupMenuItem(
                    value: 'services',
                    child: Text('Check services'),
                  ),
                  PopupMenuItem(value: 'delay', child: Text(l.delayTest)),
                  const PopupMenuItem(
                    value: 'tcpping',
                    child: Text('TCP ping'),
                  ),
                  PopupMenuItem(value: 'speed', child: Text(l.speedTest)),
                  // Build 2095 (feature 14): quick rename
                  // without opening the full editor.
                  const PopupMenuItem(
                    value: 'rename',
                    child: Text('Rename\u2026'),
                  ),
                  PopupMenuItem(value: 'edit', child: Text(l.editProfile)),
                  PopupMenuItem(
                    value: 'star',
                    child: Text(
                      profile.starred
                          ? 'Remove from favorites'
                          : 'Add to favorites',
                    ),
                  ),
                  PopupMenuItem(value: 'duplicate', child: Text(l.duplicate)),
                  PopupMenuItem(value: 'resetStats', child: Text(l.resetStats)),
                  PopupMenuItem(value: 'qr', child: Text(l.shareQr)),
                  PopupMenuItem(value: 'copy', child: Text(l.copyLink)),
                  const PopupMenuItem(
                    value: 'protected',
                    child: Text('Copy protected link\u2026'),
                  ),
                  PopupMenuItem(
                    value: 'delete',
                    child: Text(
                      l.deleteProfile,
                      style: const TextStyle(color: Ember.red),
                    ),
                  ),
                ],
              ),
            ),
        ],
      );
    final connectButton = TextButton(
                  onPressed: () => unawaited(
                    liveHere ? xray.disconnect() : _connectFromTest(context),
                  ),
                  style: TextButton.styleFrom(
                    foregroundColor: liveHere ? Ember.red : Ember.orange,
                    // Build 2136 (visual review V-18): the row's
                    // most consequential tap gets a 40dp target.
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    minimumSize: const Size(0, 40),
                  ),
                  child: Text(
                    liveHere ? 'Disconnect' : 'Connect',
                    style: const TextStyle(
                      fontSize: Ember.fontSmall,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                );
    final rowChild = selectedIdle
        ? Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              rowA,
              const SizedBox(height: 2),
              Padding(
                padding: const EdgeInsets.only(left: 45),
                child: Row(
                  children: [
                    connectButton,
                    const Spacer(),
                    ?status,
                  ],
                ),
              ),
            ],
          )
        : rowA;
    final card = _SubRow(
      selected: selected || (multiSelect && checked),
      // Build 2136 (V-13): in-card and unselected → flat.
      // Build 2144: the live row is flat in-card too.
      // Batch 2 (fidelity rollout, owner order 2026-11-23):
      // EVERY profile row now wears the flat hairline form —
      // the pro6-servers sample's rows carry no fill and no
      // rim, inside a group block or standing alone. The
      // selection is drawn over the row below (the orange
      // left tick; the ACTIVE label stays reserved for the
      // running session's row, build 2098 M15).
      flat: true,
      onTap: multiSelect ? onToggleMulti : () => xray.select(profile),
      onLongPress: multiSelect ? null : onEnterMulti,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
      child: rowChild,
    );
    if (!selected && !activeHere) return card;
    // Build 2144 (reskin): the pro6 treatment — a 2 px
    // orange tick at the row's left edge and the ACTIVE
    // micro-label in orange text at the top right,
    // replacing the gradient badge pill. The label is
    // reached ONLY for the running session's profile, so
    // it marks the one actually-active row (build 2098
    // M15). Batch 2: the tick now also marks the merely
    // selected row — with the rim box retired, the tick is
    // how selection reads in the sample's hairline list.
    // (Build 2074's placement rule stands: both marks sit
    // inside the row, never overlapping the row above.)
    return Stack(
      children: [
        card,
        Positioned(
          left: 0,
          top: 10,
          bottom: 10,
          child: Container(width: 2, color: Ember.orange),
        ),
        if (activeHere)
          Positioned(
            top: 6,
            right: 12,
            child: Text('ACTIVE', style: Ember.microLabelOrange),
          ),
      ],
    );
  }

  Future<void> _act(BuildContext context, String action) async {
    final l = AppLocalizations.of(context);
    switch (action) {
      case 'disconnect':
        // Build 2095 (V2Ray journey audit #12): disconnect
        // from the row's own menu.
        await xray.disconnect();
      case 'rename':
        // Build 2095 (feature 14): inline rename through
        // the editor's own name field (localName) — the
        // same dialog shape as the OpenVPN rename.
        if (context.mounted) {
          // Build 2103 (verification iteration 1, M1): seed
          // from the stored editable name, never displayName —
          // its render-time address fallback would be stored
          // as the label by an untouched save (renameProfile
          // writes any value ≠ the provider name to localName).
          final field = TextEditingController(
            text: profile.localName.isNotEmpty
                ? profile.localName
                : profile.name,
          );
          final name = await showEmberFormDialog<String>(
            context,
            title: 'Rename config',
            content: TextField(
              controller: field,
              autofocus: true,
              style: Ember.body,
              decoration: emberField(context, 'Config name'),
              onSubmitted: (v) => Navigator.of(context).pop(v),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(field.text),
                child: const Text('Rename'),
              ),
            ],
          );
          field.dispose();
          if (name != null) {
            await xray.renameProfile(profile, name);
          }
        }
      case 'sandbox':
        // Build 2061 (feature queue #1): the full sandbox test —
        // one isolated core proves delay + hold + exit, without
        // touching the live tunnel — shown as a verdict sheet.
        final r = await xray.sandboxTest(profile);
        if (context.mounted) {
          await showSandboxTestSheet(
            context,
            profile: profile,
            result: r,
            onConnect: () => _connectFromTest(context),
          );
        }
      case 'services':
        // Build 2091: the service reachability check — one
        // isolated core asks the six key services for a real
        // HTTPS HEAD through this config, without touching the
        // live tunnel — shown as a verdict sheet.
        final sr = await xray.serviceCheck(profile);
        if (context.mounted) {
          await showServiceCheckSheet(
            context,
            profile: profile,
            result: sr,
            onConnect: () => _connectFromTest(context),
          );
        }
      case 'delay':
        final ms = await xray.testDelay(profile);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                ms >= 0
                    ? '${l.delayTest}: ${latDigits(ms)} ${l.msUnit}'
                    : l.testFailed,
              ),
            ),
          );
        }
      case 'tcpping':
        // Build 2075 (feature item 14): the raw TCP connect
        // time to the endpoint — reachability only, stored
        // on the profile and shown under its name.
        final ms = await probeProfileTcp(profile);
        profile.tcpPingMs = ms;
        profile.tcpPingFailed = ms < 0;
        await xray.save();
        xray.notifySettingsChanged();
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                ms >= 0
                    ? 'TCP connect: ${latDigits(ms)} ms'
                    : 'TCP connect failed — the endpoint did not answer.',
              ),
            ),
          );
        }
      case 'speed':
        final bps = await xray.testSpeed(profile);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                bps >= 0 ? '${l.speedTest}: ${fmtRate(bps)}' : l.testFailed,
              ),
            ),
          );
        }
      case 'edit':
        await openProfileEditor(context, xray, existing: profile);
      case 'star':
        await xray.toggleStarred(profile);
      case 'duplicate':
        await xray.duplicateProfile(profile);
      case 'resetStats':
        await xray.resetProfileStats(profile);
      case 'qr':
        await showProfileQr(context, profile);
      case 'copy':
        // Build 2095 (audit 5-4): secret copies self-clear.
        await copySensitive(profileLinkOf(profile));
        if (context.mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(l.linkCopied)));
        }
      case 'protected':
        await _shareProtected(context, profile);
      case 'delete':
        // Build 2092 (UI audit item 6): deleting a profile
        // confirms first, naming it — the WireGuard profiles
        // and subscriptions in this app already did; this
        // menu fired on one tap.
        if (!context.mounted) return;
        final confirmed = await showEmberConfirm(
          context,
          title: 'Delete profile?',
          // Build 2098 (post-2097 audit L17): the
          // disconnect-first disclosure the multi-delete
          // confirmation already carries — a single delete
          // of the connected profile disconnects it too,
          // and the user should read that before confirming.
          message:
              'Delete "${profile.displayName}"? This cannot be '
              'undone. If it is connected, it is disconnected first.',
          confirmLabel: 'Delete',
        );
        if (confirmed) await xray.deleteProfile(profile);
    }
  }

  /// Connects this profile from the sandbox sheet: select,
  /// then the profile's own engine path — the editor's status
  /// card pattern, with the same plain-words failure.
  Future<void> _connectFromTest(BuildContext context) async {
    try {
      await connectProfileFromTest(xray, profile);
    } on StateError catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              // Build 2092 (item 19): only the known code
              // gets its sentence; any other StateError
              // message is raw internals (the wireguard_pages
              // pattern).
              e.message == 'wg-all-peers-failed'
                  ? 'No peer of this config carried traffic'
                  : 'The tunnel did not start — check the core logs',
            ),
          ),
        );
      }
    }
  }
}

/// The protected share dialog (build 2030): a password and
/// an expiry, then the AES-256-GCM wrapped link goes to the
/// clipboard. Self-contained — the receiver needs nothing
/// but Ember and the password.
Future<void> _shareProtected(BuildContext context, Profile profile) async {
  final passwordController = TextEditingController();
  var hours = 24;
  final made = await showDialog<String>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setDialogState) => AlertDialog(
        title: Text('Protected link', style: Ember.heading),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'The link is encrypted with this password and '
              'carries an expiry. Share the password separately.',
              style: Ember.dimStyle,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: passwordController,
              obscureText: true,
              autofocus: true,
              style: Ember.body,
              decoration: emberField(context, 'Password'),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Text('Expires in', style: Ember.dimStyle),
                const Spacer(),
                DropdownButton<int>(
                  value: hours,
                  dropdownColor: Ember.card,
                  underline: const SizedBox.shrink(),
                  style: Ember.body,
                  items: const [
                    DropdownMenuItem(value: 1, child: Text('1 hour')),
                    DropdownMenuItem(value: 24, child: Text('1 day')),
                    DropdownMenuItem(value: 168, child: Text('1 week')),
                    DropdownMenuItem(value: 720, child: Text('30 days')),
                  ],
                  onChanged: (v) {
                    if (v != null) setDialogState(() => hours = v);
                  },
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              final pw = passwordController.text;
              if (pw.isEmpty) return;
              Navigator.of(dialogContext).pop(
                createProtectedShareLink(
                  profileLinkOf(profile),
                  pw,
                  ttl: Duration(hours: hours),
                ),
              );
            },
            child: const Text('Copy link'),
          ),
        ],
      ),
    ),
  );
  // Build 2092 (item 61): the dialog is closed — its
  // controller is disposed here instead of leaking per open.
  passwordController.dispose();
  if (made == null) return;
  await copySensitive(made);
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Protected link copied — it clears itself in a minute.'),
      ),
    );
  }
}

/// host••• masking for config rows, as the mockup shows: the address is
/// not hidden, only shortened visually when long.
String maskHost(String address) {
  if (address.length <= 24) return address;
  return '${address.substring(0, 12)}…${address.substring(address.length - 6)}';
}

/// The per-card Best / Last-ping summary line.
/// Build 2145 (UI-review fix A10): a widget class now, not a
/// Widget-returning method on the servers state.
class _PingSummaryLine extends StatelessWidget {
  const _PingSummaryLine({
    required this.lastPingMs,
    required this.bestName,
    required this.bestMs,
    required this.agoText,
  });

  final int lastPingMs;
  final String bestName;
  final int bestMs;
  final String Function(int epochMs) agoText;

  @override
Widget build(BuildContext context) {
  final l = AppLocalizations.of(context);
  // Build 2136 (visual review V-15): the per-card summary
  // line is the tab's most repeated text — dim, not faint.
  const style = TextStyle(fontSize: Ember.fontMicro, color: MapUi.dim);
  if (lastPingMs <= 0) return Text(l.notTestedYet, style: style);
  final parts = <String>[
    if (bestName.isNotEmpty && bestMs >= 0)
      l.bestPingResult(bestName, bestMs),
    l.lastPingLabel(agoText(lastPingMs)),
  ];
  return Text(
    parts.join(' · '),
    style: style,
    overflow: TextOverflow.ellipsis,
  );
}
}

/// The slim Connected strip under the page title
/// (build 2133, the approved sample): the shell bottom
/// bar's V2Ray verdict in one line — state word, the
/// session's config, its last tested delay.
/// Build 2145 (UI-review fix A10): a widget class now, not a
/// Widget-returning method on the servers state.
class _StatusStrip extends StatelessWidget {
  const _StatusStrip({required this.xray});

  final XrayController xray;

  @override
Widget build(BuildContext context) {
  final on = xray.state.running && !xray.warpSession;
  final p = xray.sessionProfile ?? xray.selected;
  final proven = xray.state.verified || p?.protocol == Protocol.wireguard;
  final word = on
      ? (proven
            ? 'Connected'
            : xray.connecting
            ? 'Connecting…'
            : 'Connected — not answering')
      : xray.connecting
      ? 'Connecting…'
      : 'Not connected';
  final dot = on
      // Build 2136 (visual review V-17): the strip dot uses
      // the system's one green, not a one-off #4ADE80.
      ? Ember.green
      : xray.connecting
      ? Ember.orange
      : MapUi.faint;
  final detail = StringBuffer(word);
  if (on && p != null) {
    detail.write(' · ${p.displayName}');
    if (p.delayMs >= 0) detail.write(' · ${latDigits(p.delayMs)} ms');
  }
  // Build 2144 (reskin): the strip is a flat typographic
  // row over a single hairline — the box fill, rim and
  // selected-gradient wash are retired in the pro6
  // editorial language; the state word, dot and detail
  // text are unchanged.
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: const BoxDecoration(
      border: Border(bottom: BorderSide(color: MapUi.line)),
    ),
    child: Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            detail.toString(),
            style: const TextStyle(
              fontSize: Ember.fontSmall,
              fontWeight: FontWeight.w600,
              color: MapUi.text,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    ),
  );
}
}

/// One profile row with the multi-select plumbing
/// (extracted from the flat list's builder, build 2133).
/// Build 2145 (UI-review fix A10): a widget class now, not a
/// Widget-returning method on the servers state.
class _RowFor extends StatelessWidget {
  const _RowFor({
    required this.xray,
    required this.profile,
    required this.multiSelect,
    required this.checked,
    required this.onToggleMulti,
    required this.onEnterMulti,
  });

  final XrayController xray;
  final Profile profile;
  final bool multiSelect;
  final bool checked;
  final VoidCallback onToggleMulti;
  final VoidCallback onEnterMulti;

  @override
  // Batch 2: the boxed rows' 9 dp bottom gap is retired
  // with the boxes — hairline rows run contiguous, their
  // own padding carrying the rhythm (the pro6 sample's
  // ruled list).
  Widget build(BuildContext context) => _ProfileRow(
    xray: xray,
    profile: profile,
    multiSelect: multiSelect,
    checked: checked,
    onToggleMulti: onToggleMulti,
    onEnterMulti: onEnterMulti,
  );
}

/// The grouped view's sliver item dispatch (build 2133):
/// builds the widget for one _ServersItem at [index].
/// Build 2145 (UI-review fix A10): a widget class now, not a
/// Widget-returning method on the servers state — the state
/// passes its values and callbacks down.
class _ServersItemWidget extends StatelessWidget {
  const _ServersItemWidget({
    required this.item,
    required this.index,
    required this.xray,
    required this.agoText,
    required this.scanProgressText,
    required this.multiSelect,
    required this.multiSelected,
    required this.onToggleMulti,
    required this.onEnterMulti,
  });

  final _ServersItem item;
  final int index;
  final XrayController xray;
  final String Function(int epochMs) agoText;
  final String Function() scanProgressText;
  final bool multiSelect;
  final Set<String> multiSelected;
  final void Function(Profile profile) onToggleMulti;
  final void Function(Profile profile) onEnterMulti;

  @override
Widget build(BuildContext context) {
  final item = this.item;
  if (item is _ServersNoticeItem) {
    return Padding(
      padding: EdgeInsets.only(top: index == 0 ? 0 : 14, bottom: 10),
      child: Row(
        children: [
          const Icon(Icons.cloud_off_rounded, size: 15, color: Ember.orange),
          const SizedBox(width: 7),
          Expanded(child: Text(item.text, style: Ember.body)),
        ],
      ),
    );
  }
  if (item is _ServersRecycleBinItem) {
    // Build 2129 (recycle bin): a plain
    // tappable row — restore lives on its
    // own page, not inline in this list.
    return Padding(
      padding: EdgeInsets.only(top: index == 0 ? 0 : 14, bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => RecycleBinPage(xray: xray))),
        child: Row(
          children: [
            const Icon(
              Icons.delete_sweep_rounded,
              size: 15,
              color: Ember.orange,
            ),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                'Recently deleted '
                '(${latDigits(item.count)})',
                style: Ember.body,
              ),
            ),
            const Icon(
              Icons.chevron_right_rounded,
              size: 17,
              color: MapUi.dim,
            ),
          ],
        ),
      ),
    );
  }
  if (item is _ServersGroupHeaderItem) {
    return Padding(
      padding: EdgeInsets.only(top: index == 0 ? 0 : 14, bottom: 8),
      child: _GroupHeader(
        title: item.title,
        flagCode: item.flagCode,
        subtitle: item.subtitle,
        onRefresh: item.onRefresh,
        refreshing: item.refreshing,
        onPrune: item.onPrune,
        count: item.count,
      ),
    );
  }
  if (item is _ServersFallbackItem) {
    // Build 2137 (#9): the fallback group as
    // a standalone card in the group cards'
    // anatomy.
    return Padding(
      padding: EdgeInsets.only(top: index == 0 ? 0 : 14, bottom: 12),
      child: _FallbackCardShell(xray: xray),
    );
  }
  if (item is _ServersCardHeadItem) {
    return Padding(
      padding: EdgeInsets.only(bottom: item.expanded ? 0 : 12),
      child: _GroupCardHead(
        title: item.title,
        subtitle: item.subtitle,
        summary: _PingSummaryLine(
          lastPingMs: item.lastPingMs,
          bestName: item.bestName,
          bestMs: item.bestMs,
          agoText: agoText,
        ),
        expanded: item.expanded,
        onToggleExpand: item.onToggleExpand,
        pingLabel: item.pingLabel,
        pinging: item.pinging,
        pingEnabled: item.pingEnabled,
        onPing: item.onPing,
        progressText: item.pinging ? scanProgressText() : null,
        progressValue: item.pinging && xray.scanTotal > 0
            ? xray.scanDone / xray.scanTotal
            : null,
        onRefresh: item.onRefresh,
        refreshing: item.refreshing,
        onPrune: item.onPrune,
        trafficRemainingBytes: item.trafficRemainingBytes,
        trafficFraction: item.trafficFraction,
        trafficUsedBytes: item.trafficUsedBytes,
        trafficTotalBytes: item.trafficTotalBytes,
        trafficExpiresLine: item.trafficExpiresLine,
      ),
    );
  }
  if (item is _ServersCardProfileItem) {
    return _CardRowSlice(
      first: item.first,
      child: _RowFor(
          xray: xray,
          profile: item.profile,
          multiSelect: multiSelect,
          checked: multiSelected.contains(item.profile.id),
          onToggleMulti: () => onToggleMulti(item.profile),
          onEnterMulti: () => onEnterMulti(item.profile),
        ),
    );
  }
  if (item is _ServersCardFootItem) {
    return const Padding(
      padding: EdgeInsets.only(bottom: 12),
      child: _GroupCardFoot(),
    );
  }
  final prof = (item as _ServersProfileItem).profile;
  return _RowFor(
      xray: xray,
      profile: prof,
      multiSelect: multiSelect,
      checked: multiSelected.contains(prof.id),
      onToggleMulti: () => onToggleMulti(prof),
      onEnterMulti: () => onEnterMulti(prof),
    );
}
}
