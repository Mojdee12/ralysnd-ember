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

/// Land cells as logical offsets, computed once. A deterministic few
/// carry an ember tint, as in the mockup's sparse orange sparkle.
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

    // Land dots.
    final dotPaint = Paint()..style = PaintingStyle.fill;
    for (final (pos, ember) in _dots) {
      dotPaint.color = ember
          ? Ember.orange.withValues(alpha: faint ? 0.10 : 0.30)
          : const Color(0xFF41454F)
                .withValues(alpha: faint ? 0.35 : (connected ? 0.95 : 0.75));
      canvas.drawCircle(pos, 0.62, dotPaint);
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
        (home.dy + sel.dy) / 2 - (home - sel).distance * 0.22,
      );
      final arc = Path()
        ..moveTo(home.dx, home.dy)
        ..quadraticBezierTo(mid.dx, mid.dy, sel.dx, sel.dy);
      canvas.drawPath(
        arc,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4.5
          ..color = Ember.orange.withValues(alpha: 0.16),
      );
      canvas.drawPath(
        arc,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = Ember.amber.withValues(alpha: 0.9),
      );
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
        5.2,
        Paint()..color = Ember.orange.withValues(alpha: 0.20 * a),
      );
      canvas.drawCircle(
        pos,
        2.6,
        Paint()..color = Ember.orange.withValues(alpha: 0.9 * a),
      );
      canvas.drawCircle(
        pos,
        1.0,
        Paint()..color = Colors.white.withValues(alpha: 0.85 * a),
      );
    }

    // The home marker.
    if (home != null) {
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
      if (homeLabel.isNotEmpty) {
        final tp = TextPainter(
          text: TextSpan(
            text: homeLabel,
            style: TextStyle(
              color: Ember.dim.withValues(alpha: 0.9),
              // Build 2058 (audit §5 micro-type): 8.5 px floored
              // at 9.5 px.
              fontSize: 9.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          // Build 2057 (audit §6 appearance low): the label is an
          // English string — it was laid out right-to-left.
          textDirection: TextDirection.ltr,
        )..layout();
        final lx = (home.dx - tp.width / 2).clamp(0.0, _field.width - tp.width);
        tp.paint(canvas, Offset(lx, home.dy + 6));
      }
    }

    // The selected pin, pulsing while connected.
    if (sel != null) {
      if (connected) {
        canvas.drawCircle(
          sel,
          6 + 11 * pulse,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.6
            ..color = Ember.orange.withValues(alpha: (1 - pulse) * 0.55),
        );
        canvas.drawCircle(
          sel,
          10,
          Paint()..color = Ember.orange.withValues(alpha: 0.22),
        );
      }
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
  }

  @override
  bool shouldRepaint(WorldMapPainter old) =>
      old.pins != pins ||
      old.selected != selected ||
      old.connected != connected ||
      // Build 2057 (audit §6 appearance low): the home label was
      // ignored, so a renamed home kept painting the stale label.
      old.homeLabel != homeLabel ||
      old.faint != faint;
}

/// The Map Control view transform: the SAME equirectangular cover
/// projection the baked backdrop asset (assets/backdrop/map_backdrop.png)
/// is drawn with, so live actors land exactly on the baked dots.
/// The field is 360×180; [cover] scales it to cover [size]; the view
/// is centred on [centerLon] (portrait phones shift east so the home
/// marker and the usual European exits share the frame, as in the
/// approved mobile samples).
class MapViewTransform {
  const MapViewTransform({
    required this.cover,
    required this.offset,
    required this.centerLon,
  });

  final double cover;
  final Offset offset;
  final double centerLon;

  static MapViewTransform of(Size size, {double? centerLon}) {
    final c = centerLon ?? mapCenterLonFor(size);
    final cover = size.width / 360 > size.height / 180
        ? size.width / 360
        : size.height / 180;
    return MapViewTransform(
      cover: cover,
      centerLon: c,
      offset: Offset(
        (size.width - 360 * cover) / 2 - c * cover,
        (size.height - 180 * cover) / 2,
      ),
    );
  }

  /// A lat/lon in screen (logical) pixels.
  Offset project(double lat, double lon) => Offset(
    offset.dx + (lon + 180) * cover,
    offset.dy +
        (worldMapLatTop - lat) /
            (worldMapLatTop - worldMapLatBottom) *
            180 *
            cover,
  );

  /// A country code's pin position, or null when the table has none.
  Offset? pinFor(String code) {
    final ll = countryPinLatLon[code];
    return ll == null ? null : project(ll[0], ll[1]);
  }
}

/// The view-centre longitude for a surface: portrait shifts to
/// +18° (Europe ↔ Iran in one frame, as the mobile samples frame
/// it); landscape keeps the whole-world centre.
double mapCenterLonFor(Size size) => size.height > size.width ? 26 : 0;

/// The live actors of the Map Control screens — home marker with
/// radar rings, the exit pin with its bloom and badge, the glowing
/// dashed arc, and small dots for the other derivable countries —
/// painted over the baked backdrop through [MapViewTransform].
/// Nothing is invented: a pin exists only for a country the caller
/// derived from real data (a chosen location, a profile remark, or
/// a through-tunnel exit lookup).
class MapActorsPainter extends CustomPainter {
  MapActorsPainter({
    required this.pins,
    required this.selected,
    required this.connected,
    required this.homeLabel,
    this.exitBadge,
    this.pulseAnim,
    super.repaint,
  });

  /// Other countries to dot (the selected one is drawn apart).
  final Set<String> pins;

  /// The exit country code (the pin), when one is derivable.
  final String? selected;
  final bool connected;
  final String homeLabel;

  /// The badge under the exit pin ("GERMANY • FRANKFURT"); null
  /// hides it.
  final String? exitBadge;
  final Animation<double>? pulseAnim;

  @override
  void paint(Canvas canvas, Size size) {
    // Everything is drawn in screen space: positions come from the
    // shared transform, sizes are plain logical pixels.
    final t = MapViewTransform.of(size);
    double px(double v) => v;
    final home = t.pinFor('IR');
    final sel = selected == null ? null : t.pinFor(selected!);
    final pulse = pulseAnim?.value ?? 0.0;

    // The arc, only while connected: a wide soft glow under a
    // dashed amber core, dissolving toward the exit pin.
    if (connected && home != null && sel != null && selected != 'IR') {
      final mid = Offset(
        (home.dx + sel.dx) / 2,
        (home.dy + sel.dy) / 2 - (home - sel).distance * 0.22,
      );
      final arc = Path()
        ..moveTo(home.dx, home.dy)
        ..quadraticBezierTo(mid.dx, mid.dy, sel.dx, sel.dy);
      canvas.drawPath(
        arc,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = px(5)
          ..color = const Color(0xFFE65116).withValues(alpha: 0.35),
      );
      final core = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = px(1.8)
        ..color = const Color(0xFFFFA24D).withValues(alpha: 0.95);
      for (final metric in arc.computeMetrics()) {
        var d = 0.0;
        while (d < metric.length) {
          final end = d + px(4);
          canvas.drawPath(
            metric.extractPath(d, end > metric.length ? metric.length : end),
            core,
          );
          d += px(7);
        }
      }
    }

    // Ordinary pins: small ember dots.
    for (final code in pins) {
      if (code == selected) continue;
      final pos = t.pinFor(code);
      if (pos == null) continue;
      final a = connected ? 1.0 : 0.5;
      canvas.drawCircle(
        pos,
        px(9),
        Paint()..color = Ember.orange.withValues(alpha: 0.20 * a),
      );
      canvas.drawCircle(
        pos,
        px(4.5),
        Paint()..color = Ember.orange.withValues(alpha: 0.9 * a),
      );
      canvas.drawCircle(
        pos,
        px(1.8),
        Paint()..color = Colors.white.withValues(alpha: 0.85 * a),
      );
    }

    // The home marker: a hot core with radar rings; the rings
    // breathe outward while connected.
    if (home != null) {
      // The origin's solar core (2023 polish, Gemini round-3
      // audit): a hot additive bloom under the radar rings —
      // 0x99FF7A1A at the centre, 0x4DFF6200 mid-way, gone at
      // the outer ring (r40), screen-blended over the dot field
      // so the inner rings sit IN the glow, not on top of it.
      canvas.drawCircle(
        home,
        px(40),
        Paint()
          ..blendMode = BlendMode.screen
          ..shader = RadialGradient(
            colors: const [
              Color(0x99FF7A1A),
              Color(0x4DFF6200),
              Color(0x00FF5000),
            ],
            stops: const [0, 0.45, 1],
          ).createShader(Rect.fromCircle(center: home, radius: px(40))),
      );
      for (final (r, alpha) in [
        (11.0, 0.68),
        (20.0, 0.50),
        (30.0, 0.36),
        (40.0, 0.24),
      ]) {
        canvas.drawCircle(
          home,
          px(r),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = px(1.0)
            ..color = const Color(0xFFFFA04A).withValues(alpha: alpha),
        );
      }
      if (connected) {
        canvas.drawCircle(
          home,
          px(10 + 18 * pulse),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = px(1.1)
            ..color = const Color(0xFFFFA04A)
                .withValues(alpha: (1 - pulse) * 0.5),
        );
      }
      canvas.drawCircle(home, px(5), Paint()..color = const Color(0xFFFFC46B));
      canvas.drawCircle(home, px(2.5), Paint()..color = Colors.white);
      if (homeLabel.isNotEmpty) {
        _badge(
          canvas,
          home + Offset(0, px(51)),
          homeLabel,
          px,
          screenWidth: size.width,
        );
      }
    }

    // The exit pin: a soft 28 px halo behind it (2024, Gemini
    // audit v4 exact values: 0x55FF8533 fading to transparent),
    // a teardrop with a white core, and its badge.
    if (sel != null) {
      canvas.drawCircle(
        sel,
        px(28),
        Paint()
          ..shader = RadialGradient(
            colors: const [Color(0x55FF8533), Color(0x00FF8533)],
          ).createShader(Rect.fromCircle(center: sel, radius: px(28))),
      );
      if (connected) {
        canvas.drawCircle(
          sel,
          px(12),
          Paint()..color = const Color(0xFFFFA347).withValues(alpha: 0.55),
        );
        canvas.drawCircle(
          sel,
          px(12 + 14 * pulse),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = px(1.2)
            ..color = const Color(0xFFFFA04A)
                .withValues(alpha: (1 - pulse) * 0.55),
        );
      }
      final h = px(30);
      final w = px(21);
      final pin = Path()
        ..moveTo(sel.dx, sel.dy)
        ..cubicTo(
          sel.dx - w / 2,
          sel.dy - h * 0.38,
          sel.dx - w * 0.42,
          sel.dy - h,
          sel.dx,
          sel.dy - h,
        )
        ..cubicTo(
          sel.dx + w * 0.42,
          sel.dy - h,
          sel.dx + w / 2,
          sel.dy - h * 0.38,
          sel.dx,
          sel.dy,
        )
        ..close();
      canvas.drawPath(
        pin,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: connected
                ? const [Color(0xFFFFB347), Color(0xFFFF6A1A)]
                : const [Color(0xFF93A2B8), Color(0xFF5B6B82)],
          ).createShader(Rect.fromLTWH(sel.dx - w / 2, sel.dy - h, w, h)),
      );
      canvas.drawCircle(
        sel + Offset(0, -h * 0.68),
        px(4.6),
        Paint()..color = const Color(0xFF3A1C07),
      );
      canvas.drawCircle(
        sel + Offset(0, -h * 0.68),
        px(3.4),
        Paint()..color = Colors.white,
      );
      if (connected && exitBadge != null && exitBadge!.isNotEmpty) {
        _badge(
          canvas,
          sel + Offset(0, px(10)),
          exitBadge!,
          px,
          screenWidth: size.width,
        );
      }
    }
  }

  /// A bare micro-label centred at [center] (2023 polish,
  /// Gemini round-3 audit + sample 1): NO box, no border — caps
  /// text in warm amber with a soft black shadow for legibility
  /// against the dot field.
  void _badge(
    Canvas canvas,
    Offset center,
    String text,
    double Function(double) px, {
    required double screenWidth,
  }) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          // Build 2058 (audit §5 micro-type): px(8.5) floored
          // at px(9.5).
          fontSize: px(9.5),
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
          color: const Color(0xFFFFA85C),
          shadows: const [Shadow(color: Colors.black, blurRadius: 6)],
        ),
      ),
      textDirection: TextDirection.ltr,
      // Build 2074 (audit item 26): the layout width is capped
      // at the canvas, so a long badge wraps/clips inside the
      // screen instead of painting past its edge.
    )..layout(maxWidth: screenWidth);
    final half = tp.width / 2;
    final cx = half + 4 >= screenWidth - half - 4
        ? screenWidth / 2
        : center.dx.clamp(half + 4, screenWidth - half - 4);
    tp.paint(
      canvas,
      Offset(cx, center.dy) - Offset(tp.width / 2, tp.height / 2),
    );
  }

  @override
  bool shouldRepaint(MapActorsPainter old) =>
      old.pins != pins ||
      old.selected != selected ||
      old.connected != connected ||
      old.exitBadge != exitBadge ||
      old.homeLabel != homeLabel;
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
