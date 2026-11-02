/// The dotted world map of the V2Ray home (layout E): land dots from
/// the generated raster in world_map_data.dart, one ember pin per
/// country the user's profiles actually claim, a pulsing pin on the
/// selected config's country while connected, and a glowing arc from
/// the home marker (Iran) to that pin. No pin is ever invented: a
/// country appears only when a profile's remark carries it or the
/// through-tunnel exit lookup reported it.

import 'package:flutter/material.dart';

import 'ember_theme.dart';
import 'world_map_data.dart';

/// Logical field the painter draws in (2:1); the panel keeps this
/// aspect, the motif strip cover-crops it.
const _field = Size(360, 180);

Offset _project(double lat, double lon) => Offset(
  (lon + 180) / 360 * _field.width,
  (worldMapLatTop - lat) / (worldMapLatTop - worldMapLatBottom) * _field.height,
);

/// The mini dark HUD badge behind a dark-map pin label: deep
/// navy at 80%, a hairline ember rim. [px] is one screen pixel
/// in field units.
void _labelBadge(
  Canvas canvas,
  double lx,
  double ly,
  double textW,
  double textH,
  double px,
) {
  final rect = RRect.fromRectAndRadius(
    Rect.fromLTWH(lx - 6 * px, ly - 3 * px, textW + 12 * px, textH + 6 * px),
    Radius.circular(4 * px),
  );
  canvas.drawRRect(
    rect,
    Paint()..color = const Color(0xFF0C1420).withValues(alpha: 0.8),
  );
  canvas.drawRRect(
    rect,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = px
      ..color = const Color(0xFFE65A1E).withValues(alpha: 0.6),
  );
}

/// Land cells as logical offsets, computed once. A deterministic few
/// carry an ember tint (the phone panel's sparse orange sparkle; the
/// desktop backdrop painter draws every dot monochrome instead).
final _dots = <(Offset, bool)>[
  for (var r = 0; r < worldMapRows.length; r++)
    for (var c = 0; c < worldMapCols; c++)
      if (worldMapRows[r][c] == '#')
        (
          Offset(
            (c + 0.5) * _field.width / worldMapCols,
            (r + 0.5) * _field.height / worldMapRows.length,
          ),
          ((r * worldMapCols + c) * 2654435761 % 97) < 5,
        ),
];

class WorldMapPainter extends CustomPainter {
  WorldMapPainter({
    required this.pins,
    required this.selected,
    required this.connected,
    required this.pulse,
    required this.homeLabel,
    this.faint = false,
    this.backdrop = false,
    this.darkMap = false,
    this.grid = false,
    this.selectedLabel = '',
    this.drawPulse = true,
    this.dots = true,
    this.pulseAnim,
    super.repaint,
  });

  /// Every country code to pin (the selected one is drawn apart).
  final Set<String> pins;
  final String? selected;
  final bool connected;
  final double pulse;
  final String homeLabel;
  final bool faint;

  /// The desktop shell's backdrop: the Fluent mockups draw the map
  /// BRIGHT — light blue-grey dots at a clearly readable alpha over
  /// the deep graphite-navy base — not the phone panel's faint tint.
  final bool backdrop;

  /// The Map Control backdrop/actors mode (2.1.0): the approved
  /// dark samples — pale blue-grey dots at moderate strength over
  /// the deep navy base, an orange-ringed home marker, and small
  /// caps labels under the home marker and the exit pin (their
  /// font size is in field units: at full-window cover it lands
  /// at the samples' ~13 px).
  final bool darkMap;

  /// Faint latitude/longitude grid lines under the dots' layer
  /// (drawn with the dots, so a faint backdrop keeps them too).
  final bool grid;

  /// The exit pin's caps label ("GERMANY • FRANKFURT"); empty
  /// draws none. Only the desktop actors layer passes one.
  final String selectedLabel;

  /// Whether the dot field is part of this painting. The desktop
  /// shell's actors layer turns it off — the backdrop layer owns
  /// the dots, and drawing them twice doubles their alpha.
  final bool dots;

  /// Whether the expanding pulse ring is part of this painting.
  /// WorldMapPanel turns it off and lets [PulseRingPainter] draw
  /// the ring alone, so the animation no longer repaints the whole
  /// dot field at every tick.
  final bool drawPulse;

  /// When set, the live animation value replaces [pulse] at paint
  /// time (the painter instance itself is not rebuilt per tick).
  final Animation<double>? pulseAnim;

  @override
  void paint(Canvas canvas, Size size) {
    final pulse = pulseAnim?.value ?? this.pulse;
    final scaleX = size.width / _field.width;
    final scaleY = size.height / _field.height;
    final cover = scaleX > scaleY ? scaleX : scaleY;
    canvas.translate(
      (size.width - _field.width * cover) / 2,
      (size.height - _field.height * cover) / 2,
    );
    canvas.scale(cover);
    // One SCREEN pixel expressed in field units. The samples'
    // map furniture (dots, pins, the dashed arc) is sized in
    // screen pixels, so on the dark full-window map — where the
    // cover scale exceeds 4 — everything below divides by the
    // cover instead of ballooning with it.
    final px = 1 / cover;

    // Land dots. The desktop backdrop is MONOCHROME, as the mockups
    // draw it: every dot the same cool light blue-grey, the ember
    // sparkle suppressed — orange in a backdrop belongs to pins and
    // the arc only. (The phone panel keeps its tinted dots.)
    final dotPaint = Paint()..style = PaintingStyle.fill;
    for (final (pos, ember) in dots ? _dots : const <(Offset, bool)>[]) {
      // Two-tier luminance on the dark map, as the samples
      // render it: a deep blue-grey base with brighter dots
      // scattered through the land (~25%, hashed off the grid
      // cell so the phone's own sparkle tier is untouched).
      final cell =
          (pos.dy / (_field.height / worldMapRows.length) - 0.5).round() *
              worldMapCols +
          (pos.dx / (_field.width / worldMapCols) - 0.5).round();
      final highlight = (cell * 2654435761 % 89) < 22;
      dotPaint.color = darkMap
          ? highlight
                ? const Color(0xFF6E93BE).withValues(alpha: 0.50)
                : const Color(0xFF3A5478).withValues(alpha: 0.45)
          : backdrop
          ? const Color(0xFF8AA5C6).withValues(alpha: 0.66)
          : ember
          ? Ember.orange.withValues(alpha: faint ? 0.10 : 0.30)
          : const Color(0xFF41454F)
                .withValues(alpha: faint ? 0.35 : (connected ? 0.95 : 0.75));
      canvas.drawCircle(
        pos,
        darkMap ? 1.35 * px : (backdrop ? 0.72 : 0.62),
        dotPaint,
      );
    }

    // The faint lat/long grid of the dark samples, under
    // everything else the painter draws.
    if (grid) {
      final gridPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = px
        ..color = Colors.white.withValues(alpha: 0.022);
      for (var lon = -150; lon < 180; lon += 30) {
        final x = (lon + 180) / 360 * _field.width;
        canvas.drawLine(Offset(x, 0), Offset(x, _field.height), gridPaint);
      }
      for (var lat = 60; lat >= -30; lat -= 30) {
        final y =
            (worldMapLatTop - lat) /
            (worldMapLatTop - worldMapLatBottom) *
            _field.height;
        canvas.drawLine(Offset(0, y), Offset(_field.width, y), gridPaint);
      }
    }
    if (faint) return;

    final homeCode = 'IR';
    final homeLatLon = countryPinLatLon[homeCode];
    final home = homeLatLon == null
        ? null
        : _project(homeLatLon[0], homeLatLon[1]);
    final selLatLon = selected == null ? null : countryPinLatLon[selected];
    final sel = selLatLon == null ? null : _project(selLatLon[0], selLatLon[1]);

    // The arc lights up only while connected.
    if (connected && home != null && sel != null && selected != homeCode) {
      final mid = Offset(
        (home.dx + sel.dx) / 2,
        (home.dy + sel.dy) / 2 - (home - sel).distance * 0.26,
      );
      final arc = Path()
        ..moveTo(home.dx, home.dy)
        ..quadraticBezierTo(mid.dx, mid.dy, sel.dx, sel.dy);
      if (darkMap) {
        // The samples' soft energy underlay: two warm strokes
        // standing in for a blurred 5 px glow.
        canvas.drawPath(
          arc,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 9 * px
            ..color = const Color(0xFFE65A1E).withValues(alpha: 0.13),
        );
        canvas.drawPath(
          arc,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 5 * px
            ..color = const Color(0xFFE65A1E).withValues(alpha: 0.30),
        );
      } else {
        canvas.drawPath(
          arc,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 4.5
            ..color = Ember.orange.withValues(alpha: 0.16),
        );
      }
      if (darkMap) {
        // The dark samples' arc core is DASHED — a thin line in
        // screen pixels (4 on, 3 off), not field units, so the
        // dashes stay elegant at any window size.
        final corePaint = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.8 * px
          ..color = const Color(0xFFFFA04D).withValues(alpha: 0.95);
        for (final metric in arc.computeMetrics()) {
          var d = 0.0;
          while (d < metric.length) {
            final seg = 4 * px;
            final end = d + seg < metric.length ? d + seg : metric.length;
            canvas.drawPath(metric.extractPath(d, end), corePaint);
            d += 7 * px;
          }
        }
      } else {
        canvas.drawPath(
          arc,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..color = Ember.amber.withValues(alpha: 0.9),
        );
      }
    }

    // Ordinary pins.
    for (final code in pins) {
      if (code == selected) continue;
      final ll = countryPinLatLon[code];
      if (ll == null) continue;
      final pos = _project(ll[0], ll[1]);
      final a = connected ? 1.0 : 0.45;
      canvas.drawCircle(
        pos,
        darkMap ? 7 * px : 5.2,
        Paint()..color = Ember.orange.withValues(alpha: 0.20 * a),
      );
      canvas.drawCircle(
        pos,
        darkMap ? 3.2 * px : 2.6,
        Paint()..color = Ember.orange.withValues(alpha: 0.9 * a),
      );
      canvas.drawCircle(
        pos,
        darkMap ? 1.2 * px : 1.0,
        Paint()..color = Colors.white.withValues(alpha: 0.85 * a),
      );
    }

    // The home marker. On the dark map it is the samples' orange
    // ring with a soft halo; the phone panel keeps its grey ring.
    if (home != null) {
      if (darkMap) {
        canvas.drawCircle(
          home,
          18 * px,
          Paint()..color = Ember.orange.withValues(alpha: 0.10),
        );
        // The samples' radar ripples around the home node:
        // three soft concentric strokes (r 8 / 16 / 26 screen
        // px) fading outward — no hard bullseye ring.
        for (final (r, a) in [(8.0, 0.7), (16.0, 0.35), (26.0, 0.15)]) {
          canvas.drawCircle(
            home,
            r * px,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = px
              ..color = const Color(0xFFFF8C3B).withValues(alpha: a),
          );
        }
        canvas.drawCircle(home, 2.6 * px, Paint()..color = Ember.amber);
        canvas.drawCircle(home, 1.2 * px, Paint()..color = Colors.white);
      } else {
        canvas.drawCircle(
          home,
          4.6,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.1
            ..color = Ember.dim.withValues(alpha: 0.8),
        );
        canvas.drawCircle(
          home,
          2.0,
          Paint()..color = Ember.text.withValues(alpha: 0.9),
        );
      }
      if (homeLabel.isNotEmpty) {
        final tp = TextPainter(
          text: TextSpan(
            text: homeLabel,
            style: TextStyle(
              color: darkMap
                  ? const Color(0xFFFFC98A)
                  : Ember.dim.withValues(alpha: 0.9),
              fontSize: darkMap ? 8.5 * px : 8.5,
              fontWeight: FontWeight.w600,
              letterSpacing: darkMap ? 0.5 * px : 0,
            ),
          ),
          textDirection: TextDirection.rtl,
        )..layout();
        final lx = (home.dx - tp.width / 2).clamp(0.0, _field.width - tp.width);
        final ly = home.dy + (darkMap ? 15 * px : 6);
        if (darkMap) _labelBadge(canvas, lx, ly, tp.width, tp.height, px);
        tp.paint(canvas, Offset(lx, ly));
      }
    }

    // The selected pin, pulsing while connected.
    if (sel != null) {
      if (connected && darkMap) {
        // The destination's solar bloom, in the samples' two
        // stages: a wide radial flare (ember, gone by ~38 screen
        // px) under a tight bright corona (~14 px) — a single
        // soft disc read as a small dot-in-ring, so the corona
        // carries its own near-opaque heart.
        canvas.drawCircle(
          sel,
          38 * px,
          Paint()
            ..shader = RadialGradient(
              colors: [
                const Color(0xFFFF7A1A).withValues(alpha: 0.45),
                const Color(0xFFFF5500).withValues(alpha: 0),
              ],
            ).createShader(Rect.fromCircle(center: sel, radius: 38 * px)),
        );
        canvas.drawCircle(
          sel,
          14 * px,
          Paint()
            ..shader = RadialGradient(
              colors: [
                const Color(0xFFFFA347).withValues(alpha: 0.85),
                const Color(0xFFFFA347).withValues(alpha: 0.2),
              ],
            ).createShader(Rect.fromCircle(center: sel, radius: 14 * px)),
        );
      }
      if (connected) {
        if (drawPulse) {
          canvas.drawCircle(
            sel,
            6 + 11 * pulse,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.6
              ..color = Ember.orange.withValues(alpha: (1 - pulse) * 0.55),
          );
        }
        if (!darkMap) {
          canvas.drawCircle(
            sel,
            10,
            Paint()..color = Ember.orange.withValues(alpha: 0.22),
          );
        }
      }
      if (darkMap) {
        // A white-hot core with a thin ember rim.
        canvas.drawCircle(
          sel,
          4.5 * px,
          Paint()..color = Colors.white.withValues(alpha: connected ? 1 : 0.75),
        );
        canvas.drawCircle(
          sel,
          5.2 * px,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.2 * px
            ..color = Ember.orange.withValues(alpha: connected ? 0.95 : 0.6),
        );
      } else {
        canvas.drawCircle(
          sel,
          5.4,
          Paint()
            ..color = connected
                ? Ember.amber
                : Ember.orange.withValues(alpha: 0.55),
        );
        canvas.drawCircle(
          sel,
          2.2,
          Paint()..color = Colors.white.withValues(alpha: connected ? 1 : 0.7),
        );
      }
      // The exit pin's label (the dark samples' "GERMANY •
      // FRANKFURT"), in a mini dark HUD badge under the pin.
      if (selectedLabel.isNotEmpty) {
        final tp = TextPainter(
          text: TextSpan(
            text: selectedLabel,
            style: TextStyle(
              color: darkMap ? const Color(0xFFE0E8F0) : Ember.orange,
              fontSize: darkMap ? 8.5 * px : 8.5,
              fontWeight: FontWeight.w700,
              letterSpacing: darkMap ? 0.5 * px : 0,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        final lx = (sel.dx - tp.width / 2).clamp(0.0, _field.width - tp.width);
        final ly = sel.dy + (darkMap ? 24 * px : 8);
        if (darkMap) _labelBadge(canvas, lx, ly, tp.width, tp.height, px);
        tp.paint(canvas, Offset(lx, ly));
      }
    }
  }

  @override
  bool shouldRepaint(WorldMapPainter old) =>
      old.pins != pins ||
      old.selected != selected ||
      old.connected != connected ||
      old.faint != faint ||
      old.backdrop != backdrop ||
      old.darkMap != darkMap ||
      old.grid != grid ||
      old.selectedLabel != selectedLabel ||
      old.dots != dots ||
      old.drawPulse != drawPulse;
}

/// Just the selected pin's expanding pulse ring, in the same field
/// transform WorldMapPainter uses. Painted on its own layer above
/// the static map (see WorldMapPanel), so a tick repaints one ring
/// instead of the whole dot field.
class PulseRingPainter extends CustomPainter {
  PulseRingPainter({
    required this.selected,
    required this.anim,
    this.screenSpace = false,
    super.repaint,
  });

  final String? selected;
  final Animation<double> anim;

  /// On the full-window desktop map the ring is sized in screen
  /// pixels (20–46 px across), not field units.
  final bool screenSpace;

  @override
  void paint(Canvas canvas, Size size) {
    final latLon = selected == null ? null : countryPinLatLon[selected];
    if (latLon == null) return;
    final scaleX = size.width / _field.width;
    final scaleY = size.height / _field.height;
    final cover = scaleX > scaleY ? scaleX : scaleY;
    canvas.translate(
      (size.width - _field.width * cover) / 2,
      (size.height - _field.height * cover) / 2,
    );
    canvas.scale(cover);
    final sel = _project(latLon[0], latLon[1]);
    final pulse = anim.value;
    final px = 1 / cover;
    canvas.drawCircle(
      sel,
      screenSpace ? (10 + 13 * pulse) * px : 6 + 11 * pulse,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = screenSpace ? 1.6 * px : 1.6
        ..color = Ember.orange.withValues(alpha: (1 - pulse) * 0.55),
    );
  }

  @override
  bool shouldRepaint(PulseRingPainter old) => old.selected != selected;
}

/// The map panel of the V2Ray home.
class WorldMapPanel extends StatefulWidget {
  const WorldMapPanel({
    super.key,
    required this.pins,
    required this.selected,
    required this.connected,
    required this.homeLabel,
  });

  final Set<String> pins;
  final String? selected;
  final bool connected;
  final String homeLabel;

  @override
  State<WorldMapPanel> createState() => _WorldMapPanelState();
}

class _WorldMapPanelState extends State<WorldMapPanel>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1700),
  );

  @override
  void initState() {
    super.initState();
    _syncPulse();
  }

  @override
  void didUpdateWidget(WorldMapPanel old) {
    super.didUpdateWidget(old);
    _syncPulse();
  }

  void _syncPulse() {
    if (widget.connected && widget.selected != null) {
      if (!_pulse.isAnimating) _pulse.repeat();
    } else {
      _pulse.stop();
      _pulse.value = 0;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: Ember.surface.withValues(alpha: 0.65),
      borderRadius: Ember.radius,
      border: Border.all(color: Ember.line),
    ),
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
    child: AspectRatio(
      aspectRatio: 2,
      child: Stack(
        children: [
          // The static map (dots, arc, pins, markers) on its
          // own repaint boundary: painted once per state
          // change, then composited.
          Positioned.fill(
            child: RepaintBoundary(
              child: CustomPaint(
                painter: WorldMapPainter(
                  pins: widget.pins,
                  selected: widget.selected,
                  connected: widget.connected,
                  pulse: 0,
                  homeLabel: widget.homeLabel,
                  drawPulse: false,
                ),
              ),
            ),
          ),
          // The pulse ring alone animates.
          if (widget.connected && widget.selected != null)
            Positioned.fill(
              child: CustomPaint(
                painter: PulseRingPainter(
                  selected: widget.selected,
                  anim: _pulse,
                  repaint: _pulse,
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

/// A slim dotted-map band used as a decorative header on the V2Ray
/// servers / subscriptions screens, keeping them in the map family.
class MapMotifStrip extends StatelessWidget {
  const MapMotifStrip({super.key});

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(16),
    child: SizedBox(
      height: 42,
      width: double.infinity,
      child: CustomPaint(
        painter: WorldMapPainter(
          pins: const {},
          selected: null,
          connected: false,
          pulse: 0,
          homeLabel: '',
          faint: true,
        ),
      ),
    ),
  );
}
