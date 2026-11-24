/// Traffic history (build 2105): the chart surface for the
/// per-profile traffic accounting Ember has always kept. The
/// totals on the profile list say HOW MUCH a config has moved;
/// this page says WHEN — hourly buckets (traffic_history.dart)
/// drawn as bars over the last day, week, or month, per
/// profile.
///
/// Recording is gated by XraySettings.trafficHistoryEnabled
/// (default OFF): while off, nothing is recorded, and this
/// page — reachable only while the toggle is on — says so
/// plainly if it is opened with no history behind it.

import 'package:flutter/material.dart';

import '../../xray/traffic_history.dart';
import '../../xray/xray_controller.dart';
import '../../xray/xray_models.dart';
import '../format.dart';
import 'ember_theme.dart';

class TrafficHistoryPage extends StatefulWidget {
  const TrafficHistoryPage({super.key, required this.xray});

  final XrayController xray;

  @override
  State<TrafficHistoryPage> createState() => _TrafficHistoryPageState();
}

enum _Range {
  day('24 hours', Duration(hours: 1), 24),
  week('7 days', Duration(hours: 6), 28),
  month('30 days', Duration(days: 1), 30);

  const _Range(this.label, this.window, this.bars);

  final String label;
  final Duration window;
  final int bars;
}

class _TrafficHistoryPageState extends State<TrafficHistoryPage> {
  TrafficHistoryStore? _store;
  String? _profileId;
  _Range _range = _Range.day;

  @override
  void initState() {
    super.initState();
    // The controller's own store instance, loaded on demand:
    // a page loading its own copy would never see this
    // session's recordings and would diverge from disk.
    _store = widget.xray.trafficHistory;
    if (_store == null) {
      widget.xray.loadTrafficHistory().then((store) {
        if (!mounted) return;
        if (store != null) {
          setState(() => _store = store);
          return;
        }
        // One retry: the controller does not cache a failed
        // load, and in the no-traffic case nothing else loads
        // the store while this page is open — without the
        // retry a transient failure wedges the page on
        // Loading even though there is simply nothing
        // recorded yet.
        Future.delayed(const Duration(seconds: 2), () {
          if (!mounted) return;
          widget.xray.loadTrafficHistory().then((s) {
            if (mounted) setState(() => _store = s);
          });
        });
      });
    }
    // The chart follows a live session: the controller
    // notifies as polls land, and the shared store's buckets
    // are read fresh on every build.
    widget.xray.addListener(_onXrayChanged);
  }

  void _onXrayChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.xray.removeListener(_onXrayChanged);
    super.dispose();
  }

  Profile? _profile(String id) {
    for (final p in widget.xray.profiles) {
      if (p.id == id) return p;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    // The controller's store wins over the page's snapshot of
    // it: when the page's own load came back empty (a transient
    // failure the controller deliberately does not cache), the
    // next poll's successful load reaches this page through
    // the listener instead of wedging it on Loading.
    final store = _store ?? widget.xray.trafficHistory;
    final ids = store?.profileIds ?? const <String>[];
    final selected = _profileId ?? (ids.isNotEmpty ? ids.first : null);
    final buckets = selected == null
        ? const <TrafficBucket>[]
        : store!.bucketsFor(selected);
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final bars = trafficBars(
      buckets,
      nowMs: nowMs,
      windowMs: _range.window.inMilliseconds,
      count: _range.bars,
    );
    final sinceMs = nowMs - _range.window.inMilliseconds * _range.bars;
    final totals = selected == null
        ? (up: 0, down: 0)
        : store!.totalsFor(selected, sinceMs);
    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Ember.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Ember.text,
        title: Text('Traffic history', style: Ember.heading),
      ),
      body: EmberBackground(child: ListView(
        padding: EdgeInsets.fromLTRB(16, MediaQuery.of(context).padding.top + kToolbarHeight + 8, 16, 24),
        children: [
          if (store == null)
            // Build 2116 (AP-17): the shared loading
            // treatment — orange spinner + caption. These
            // were the only two pages with a bare text.
            Padding(
              padding: const EdgeInsets.only(top: 24),
              child: Center(
                child: Column(
                  children: [
                    const CircularProgressIndicator(color: Ember.orange),
                    const SizedBox(height: 12),
                    Text('Loading…', style: Ember.caption),
                  ],
                ),
              ),
            )
          else if (ids.isEmpty)
            GlassCard(
              child: Text(
                'Nothing recorded yet. Traffic is recorded while '
                'the Traffic history switch is on and a session '
                'moves data; older sessions were never recorded.',
                style: Ember.body,
              ),
            )
          else ...[
            Wrap(
              spacing: 7,
              runSpacing: 7,
              children: [
                for (final id in ids)
                  EmberChip(
                    label: _profile(id)?.name ?? 'Deleted config',
                    selected: id == selected,
                    onTap: () => setState(() => _profileId = id),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 7,
              children: [
                for (final r in _Range.values)
                  EmberChip(
                    label: r.label,
                    selected: r == _range,
                    onTap: () => setState(() => _range = r),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            GlassCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${formatBytes(totals.up + totals.down)} in the '
                    'last ${_range.label}',
                    style: Ember.heading.copyWith(fontSize: Ember.fontTitle),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Up ${formatBytes(totals.up)} · '
                    'Down ${formatBytes(totals.down)}',
                    style: Ember.body,
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    height: 140,
                    child: CustomPaint(
                      painter: _TrafficBarsPainter(bars),
                      size: Size.infinite,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      _legend(Ember.orange, 'Download'),
                      const SizedBox(width: 16),
                      _legend(Ember.amber, 'Upload'),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ],
      )),
    );
  }

  Widget _legend(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
        const SizedBox(width: 6),
        Text(label, style: Ember.caption),
      ],
    );
  }
}

/// Stacked bars: download below in ember orange, upload above
/// in amber, scaled to the largest bar. An all-zero range draws
/// the baseline only.
class _TrafficBarsPainter extends CustomPainter {
  _TrafficBarsPainter(this.bars);

  final List<TrafficBar> bars;

  @override
  void paint(Canvas canvas, Size size) {
    final baseline = Paint()
      ..color = Ember.line
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(0, size.height - 0.5),
      Offset(size.width, size.height - 0.5),
      baseline,
    );
    var max = 0;
    for (final b in bars) {
      if (b.total > max) max = b.total;
    }
    if (max <= 0 || bars.isEmpty) return;
    final slot = size.width / bars.length;
    final barWidth = (slot * 0.62).clamp(1.0, 18.0);
    final downPaint = Paint()..color = Ember.orange;
    final upPaint = Paint()..color = Ember.amber;
    for (var i = 0; i < bars.length; i++) {
      final b = bars[i];
      if (b.total <= 0) continue;
      final x = slot * i + (slot - barWidth) / 2;
      final downH = size.height * b.down / max;
      final upH = size.height * b.up / max;
      if (downH > 0) {
        canvas.drawRRect(
          RRect.fromRectAndCorners(
            Rect.fromLTWH(x, size.height - downH, barWidth, downH),
            topLeft: const Radius.circular(2),
            topRight: const Radius.circular(2),
          ),
          downPaint,
        );
      }
      if (upH > 0) {
        canvas.drawRect(
          Rect.fromLTWH(x, size.height - downH - upH, barWidth, upH),
          upPaint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_TrafficBarsPainter old) => old.bars != bars;
}
