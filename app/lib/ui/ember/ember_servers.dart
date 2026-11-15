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
import '../../psiphon/psiphon_controller.dart';
import '../../xray/cf_scanner.dart';
import '../../xray/shared_link.dart';
import '../../xray/sub_fetcher.dart';
import '../../xray/xray_controller.dart';
import '../../xray/xray_models.dart';
import 'cf_scanner_page.dart';
import 'ember_format.dart';
import 'ember_theme.dart';
import 'map_widgets.dart';
import 'profile_country.dart';
import 'profile_editor.dart';
import 'qr_pages.dart';
import 'sandbox_test_sheet.dart';

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

  @override
  Widget build(BuildContext context) => v2ray
      ? _V2rayServers(
          xray: xray,
          onOpenAccounts: onOpenAccounts,
          onClose: onClose,
          psiphon: psiphon,
        )
      : _MozillaServers(core: core, onClose: onClose);
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
    } catch (_) {
      // The core answers the next poll with its own truth.
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
                              style: Ember.heading.copyWith(fontSize: 14.5),
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
    this.padding = const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
  });

  final Widget child;
  final bool selected;
  final VoidCallback? onTap;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            // Unselected rows wear the samples' crisp cool-slate
            // slot border (2023 polish, Gemini round-3 audit:
            // 0x5952759C over a 0x33142234 fill), not the old
            // near-invisible white hairline.
            color: selected
                ? Ember.orange.withValues(alpha: 0.08)
                : const Color(0x33142234),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected
                  ? Ember.orange.withValues(alpha: 0.65)
                  : const Color(0x5952759C),
              width: selected ? 1.2 : 1,
            ),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: Ember.orange.withValues(alpha: 0.16),
                      blurRadius: 16,
                      spreadRadius: -2,
                    ),
                  ]
                : null,
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
                style: Ember.heading.copyWith(fontSize: 14.5),
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
              fontSize: 13,
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
          const Divider(
            height: 1,
            thickness: 1,
            indent: 12,
            color: Color(0x2252759C),
          ),
      ],
    );
  }
}

// ------------------------------------------------------------------ V2Ray

class _V2rayServers extends StatefulWidget {
  const _V2rayServers({
    required this.xray,
    required this.onOpenAccounts,
    this.onClose,
    this.psiphon,
  });
  final XrayController xray;
  final VoidCallback onOpenAccounts;
  final VoidCallback? onClose;
  final PsiphonController? psiphon;

  @override
  State<_V2rayServers> createState() => _V2rayServersState();
}

class _V2rayServersState extends State<_V2rayServers> {
  String _query = '';
  Protocol? _filter;

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
  List<(String, List<Profile>)> _countryGroups(List<Profile> all) {
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
      if (cf.isNotEmpty) ('Cloudflare endpoints', cf),
      for (final c in codes)
        ('${countryFlagEmoji(c)} ${countryDisplayName(c)}', byCountry[c]!),
      if (unknown.isNotEmpty) ('Unknown exit', unknown),
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
    if (_groupByCountry) {
      for (final g in _countryGroups(_shown(xray.profiles))) {
        items.add(_ServersGroupHeaderItem(title: g.$1, count: g.$2.length));
        for (final p in g.$2) {
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
    if (loose.isNotEmpty) {
      items.add(
        _ServersGroupHeaderItem(title: looseTitle, count: loose.length),
      );
      for (final p in loose) {
        items.add(_ServersProfileItem(p));
      }
    }
    for (final sub in xray.subscriptions) {
      final members = _shown(xray.profilesOf(sub));
      if (members.isEmpty) continue;
      items.add(
        _ServersGroupHeaderItem(
          title: sub.name,
          count: members.length,
          onRefresh: () => unawaited(_refreshSub(sub.id)),
          onPrune: () => unawaited(_pruneSub(sub.id, sub.name)),
          subtitle: _updatedAgo(sub.lastUpdatedMs),
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

  Future<void> _testAll() async {
    // Build 2033: the batch test runs over what the current
    // search/filter shows — the funnel respects the view
    // (OneXray's rule) instead of silently testing the whole
    // store — and a cancelled run keeps its partial results
    // but does NOT re-sort the list on the strength of them.
    final cancelled = await xray.testAllDelays(
      only: _shown(xray.profiles).toList(),
    );
    if (cancelled) return;
    // Frozen rule: after a test-all the list stands fastest-first.
    xray.sortProfilesByDelay();
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

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: xray,
      builder: (context, _) {
        final loose = _shown(xray.looseProfiles);
        // Build 2055 (audit A-H4): the list is slivers — the
        // header panel on its own, the config rows lazily built
        // below it. The old form put the whole list in one giant
        // blurred MapGlass with a Column of EVERY row built
        // eagerly; with a 55-config subscription (or hundreds)
        // that was one enormous blur plus all rows up front.
        // Rows are already individual cards (_SubRow), so they
        // read the same on the backdrop.
        final items = _serversItems(loose, l.looseGroup);
        return CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: MapGlass(
                  luminous: true,
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      MapPanelHeader(
                        title: 'V2Ray CONFIGURATIONS',
                        onClose: widget.onClose,
                      ),
                      const SizedBox(height: 10),
                      // The action bar (build 2050, approved design
                      // samples A/B): one segmented glass bar —
                      // Import / QR Scan / Test All / Sort. Every
                      // 2049 control stays reachable: Import opens
                      // a sheet (Paste, Add manually, CF clean IP),
                      // and Sort's menu also carries the By-country
                      // view toggle and Keep-working-only.
                      Container(
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.04),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: MapUi.line),
                        ),
                        child: Row(
                          children: [
                            _ActionCell(
                              icon: Icons.download_rounded,
                              label: 'Import',
                              onTap: () => unawaited(_importMenu()),
                            ),
                            const _ActionDivider(),
                            _ActionCell(
                              icon: Icons.qr_code_scanner_rounded,
                              label: 'QR Scan',
                              onTap: () =>
                                  unawaited(scanAndImport(context, xray)),
                            ),
                            const _ActionDivider(),
                            _ActionCell(
                              icon: xray.scanRunning
                                  ? Icons.stop_rounded
                                  : Icons.speed_rounded,
                              label: xray.scanRunning ? 'Stop' : 'Test All',
                              primary: xray.scanRunning,
                              onTap: xray.profiles.isEmpty
                                  ? null
                                  : xray.scanRunning
                                  ? () => xray.stopTestAll()
                                  : () => unawaited(_testAll()),
                            ),
                            const _ActionDivider(),
                            // Build 2074 (audit item 26): the Sort
                            // cell fills its Expanded slot like its
                            // three siblings — no menu-button
                            // padding, and the content stretches
                            // the full cell width so the tap area
                            // and alignment match the other cells.
                            Expanded(
                              child: PopupMenuButton<String>(
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
                                        const Expanded(
                                          child: Text('By country'),
                                        ),
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
                                ],
                                child: SizedBox(
                                  width: double.infinity,
                                  child: _ActionCellContent(
                                    icon: Icons.sort_rounded,
                                    label: 'Sort',
                                    enabled: xray.profiles.isNotEmpty,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (xray.scanRunning) ...[
                        const SizedBox(height: 10),
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
                                  fontSize: 11,
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
                      ],
                      const SizedBox(height: 10),
                      TextField(
                        controller: _searchController,
                        onChanged: (v) => setState(() => _query = v),
                        style: Ember.body,
                        decoration: emberField(
                          context,
                          l.searchConfig,
                          prefix: const Icon(
                            Icons.search_rounded,
                            color: Ember.faint,
                            size: 20,
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
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                      // Fallback group (build 2035): the selected
                      // config's group in failover order, so the user
                      // sees what the engine will move to — and can
                      // tap a member to make it the selected one.
                      if (xray.profiles.length > 1)
                        _FallbackGroupCard(xray: xray),
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
            // The rows, lazily built: group headers + one card
            // per config, in the same order the old eager list
            // had them (favorites first, then loose, then one
            // group per subscription; By-country groups when
            // that view is on). A query that matches nothing
            // gets an honest empty state instead of blank space.
            // Build 2074 (audit item 17): the EmberEmpty
            // treatment, with a Clear-search action that clears
            // both the field and the protocol filter.
            if (xray.profiles.isNotEmpty && items.isEmpty)
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
              )
            else if (items.isNotEmpty)
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                sliver: SliverList(
                  delegate: SliverChildBuilderDelegate((context, i) {
                    final item = items[i];
                    if (item is _ServersGroupHeaderItem) {
                      return Padding(
                        padding: EdgeInsets.only(
                          top: i == 0 ? 0 : 14,
                          bottom: 8,
                        ),
                        child: _GroupHeader(
                          title: item.title,
                          subtitle: item.subtitle,
                          onRefresh: item.onRefresh,
                          onPrune: item.onPrune,
                          count: item.count,
                        ),
                      );
                    }
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 9),
                      child: _ProfileRow(
                        xray: xray,
                        profile: (item as _ServersProfileItem).profile,
                      ),
                    );
                  }, childCount: items.length),
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
  Future<void> _pruneSub(String id, String name) async {
    var keep = 5;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: Text('Keep only fastest?', style: Ember.heading),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Keep the fastest configs of "$name" by their last '
                'real delay test and remove the rest from this '
                'subscription. The selected config is always kept. '
                'A refresh of the subscription brings removed '
                'configs back.',
                style: Ember.body,
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 6,
                children: [
                  for (final n in const [3, 5, 10, 20])
                    EmberChip(
                      // Build 2074 (audit item 27): latDigits.
                      label: latDigits(n),
                      compact: true,
                      selected: keep == n,
                      onTap: () => setLocal(() => keep = n),
                    ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Keep fastest'),
            ),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    final sub = xray.subscriptions.where((s) => s.id == id).firstOrNull;
    if (sub == null) return;
    final removed = await xray.keepFastestInSubscription(sub, keep);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            // Build 2074 (audit item 27): latDigits.
            removed > 0
                ? 'Removed ${latDigits(removed)} slower config${removed == 1 ? '' : 's'} from $name'
                : 'Nothing to remove — $name already fits',
          ),
        ),
      );
    }
  }

  Future<void> _refreshSub(String id) async {
    final sub = xray.subscriptions.where((s) => s.id == id).firstOrNull;
    if (sub == null) return;
    try {
      await xray.updateSubscription(sub);
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
    }
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

/// One cell of the servers action bar (build 2050): an icon
/// over a short label, in the segmented glass bar the approved
/// samples draw. [primary] tints it ember (Test All while a
/// scan runs); a null [onTap] renders it dimmed.
class _ActionCell extends StatelessWidget {
  const _ActionCell({
    required this.icon,
    required this.label,
    required this.onTap,
    this.primary = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) => Expanded(
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: _ActionCellContent(
        icon: icon,
        label: label,
        primary: primary,
        enabled: onTap != null,
      ),
    ),
  );
}

/// The action-bar cell's content, shared with the Sort popup
/// (whose button wraps the same content).
class _ActionCellContent extends StatelessWidget {
  const _ActionCellContent({
    required this.icon,
    required this.label,
    this.primary = false,
    this.enabled = true,
  });

  final IconData icon;
  final String label;
  final bool primary;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final color = !enabled
        ? MapUi.faint
        : primary
        ? Ember.orange
        : MapUi.text;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 19, color: color),
          const SizedBox(height: 3),
          Text(
            label,
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionDivider extends StatelessWidget {
  const _ActionDivider();

  @override
  Widget build(BuildContext context) =>
      Container(width: 1, height: 34, color: MapUi.line);
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
                  padding: const EdgeInsets.symmetric(vertical: 6),
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
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1.6,
                            color: MapUi.dim,
                          ),
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
              },
            ),
          ],
        ),
        if (_open) ...[
          const SizedBox(height: 2),
          Text(
            on ? 'If a config dies, the next member takes over automatically' : 'Off \u2014 turn on to switch to the next member automatically',
            style: const TextStyle(fontSize: 11, color: MapUi.dim),
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
        : profile.delayFailed
        ? 'Failed'
        : 'Untested';
    final statusColor = switching
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
          constraints: const BoxConstraints(minHeight: 44),
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
                    fontSize: 13,
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
                      fontSize: 9,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.8,
                      color: Ember.orange,
                    ),
                  ),
                ),
              Text(
                status,
                style: TextStyle(
                  fontSize: 12,
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
    this.onRefresh,
    this.onPrune,
  });
  final String title;
  final int count;
  final String subtitle;
  final VoidCallback? onRefresh;

  /// Build 2065 (item 12): keep-only-fastest-N for this
  /// subscription group; null on non-subscription groups.
  final VoidCallback? onPrune;
}

class _ServersProfileItem extends _ServersItem {
  const _ServersProfileItem(this.profile);
  final Profile profile;
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
    this.onRefresh,
    this.onPrune,
  });
  final String title;
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
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title.toUpperCase(),
              style: const TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.6,
                color: MapUi.dim,
              ),
              overflow: TextOverflow.ellipsis,
            ),
            if (subtitle.isNotEmpty)
              Text(
                subtitle,
                style: const TextStyle(fontSize: 10.5, color: MapUi.faint),
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
        IconButton(
          onPressed: onRefresh,
          icon: const Icon(Icons.refresh_rounded, color: Ember.dim, size: 19),
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
        ),
    ],
  );
}

/// The ping result as a tinted pill (build 2050, samples
/// A/B): the value in its frozen health colour on a matching
/// wash — green under 150 ms, amber to 400, red beyond (and
/// for failures).
class _PingPill extends StatelessWidget {
  const _PingPill({required this.text, required this.color});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(999),
      border: Border.all(color: color.withValues(alpha: 0.45)),
    ),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 11.5,
        fontWeight: FontWeight.w700,
        color: color,
      ),
    ),
  );
}

class _ProfileRow extends StatelessWidget {
  const _ProfileRow({required this.xray, required this.profile});
  final XrayController xray;
  final Profile profile;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final selected = xray.selectedProfileId == profile.id;
    final testing = xray.isTesting(profile.id);
    final switching = xray.switchingProfileId == profile.id;
    // Sample anatomy (build 2050, approved samples A/B): a
    // flag circle at the left; the name, then protocol ·
    // endpoint, then the per-config totals on their own line
    // when the config has carried traffic (build 2074); at
    // the right a ping pill in the frozen colours, a tappable
    // star, and the ⋮ menu with every per-config action it
    // always had.
    final card = _SubRow(
      selected: selected,
      onTap: () => xray.select(profile),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      child: Row(
        children: [
          FlagCircle(code: profileCountryCode(profile) ?? '', size: 36),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  // Build 2045: the name the user sees.
                  profile.displayName,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: MapUi.text,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  '${profile.protocol.label} \u00b7 '
                  '${maskHost(profile.address)}:${latDigits(profile.port)}',
                  style: const TextStyle(fontSize: 11, color: MapUi.dim),
                  overflow: TextOverflow.ellipsis,
                ),
                // Build 2074 (audit item 16): the per-config
                // totals are their own line, never folded into
                // the ellipsis above — on a narrow screen the
                // protocol · endpoint line truncates, the
                // totals always survive in full.
                if (profileHasTotals(profile)) ...[
                  const SizedBox(height: 2),
                  Directionality(
                    textDirection: TextDirection.ltr,
                    child: Text(
                      fmtProfileTotals(profile),
                      style: const TextStyle(fontSize: 11, color: MapUi.dim),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (testing || switching)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Ember.orange,
              ),
            )
          else if (profile.delayMs >= 0)
            _PingPill(
              text: '${latDigits(profile.delayMs)} ms',
              color: mapPingColor(profile.delayMs),
            )
          else if (profile.delayFailed)
            const _PingPill(text: 'Failed', color: Ember.red)
          else if (!profile.protocol.supportedByCore)
            const Icon(Icons.block_rounded, size: 17, color: Ember.red),
          // Build 2074 (audit item 4): the star and the ⋮ menu
          // get the full 48 dp hit area — icons unchanged.
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
                const PopupMenuItem(
                  value: 'sandbox',
                  child: Text('Sandbox test'),
                ),
                PopupMenuItem(value: 'delay', child: Text(l.delayTest)),
                PopupMenuItem(value: 'speed', child: Text(l.speedTest)),
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
      ),
    );
    if (!selected) return card;
    // Build 2074 (audit item 26): the ACTIVE badge sits INSIDE
    // the card (top: 6, no Clip.none stack) — at top: -7 it
    // overlapped the row above and clipped at scroll edges.
    return Stack(
      children: [
        card,
        Positioned(
          top: 6,
          right: 12,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(
              gradient: Ember.gradient,
              borderRadius: BorderRadius.circular(6),
              boxShadow: [
                BoxShadow(
                  color: Ember.orange.withValues(alpha: 0.35),
                  blurRadius: 8,
                ),
              ],
            ),
            child: const Text(
              'ACTIVE',
              style: TextStyle(
                // Build 2058 (audit §5 micro-type): 8.5 px
                // floored at 9.5 px.
                fontSize: 9.5,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.8,
                color: Color(0xFF1A1206),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _act(BuildContext context, String action) async {
    final l = AppLocalizations.of(context);
    switch (action) {
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
        await Clipboard.setData(ClipboardData(text: profileLinkOf(profile)));
        if (context.mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(l.linkCopied)));
        }
      case 'protected':
        await _shareProtected(context, profile);
      case 'delete':
        await xray.deleteProfile(profile);
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
              e.message == 'wg-all-peers-failed'
                  ? 'No peer of this config carried traffic'
                  : e.message,
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
  if (made == null) return;
  await Clipboard.setData(ClipboardData(text: made));
  if (context.mounted) {
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Protected link copied.')));
  }
}

/// host••• masking for config rows, as the mockup shows: the address is
/// not hidden, only shortened visually when long.
String maskHost(String address) {
  if (address.length <= 24) return address;
  return '${address.substring(0, 12)}…${address.substring(address.length - 6)}';
}
