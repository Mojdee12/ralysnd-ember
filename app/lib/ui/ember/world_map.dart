/// The dotted world map of the V2Ray home (layout E): land dots from
/// the generated raster in world_map_data.dart, one ember pin per
/// country the user's profiles actually claim, a pulsing pin on the
/// selected config's country while connected, and a glowing arc from
/// the home marker (Iran) to that pin. No pin is ever invented: a
/// country appears only when a profile's remark carries it or the
/// through-tunnel exit lookup reported it.
///
/// Build 2137 (visual review V-22): the original
/// WorldMapPainter is deleted — it was never instantiated
/// anywhere; MapActorsPainter below is the map's only
/// painter, and its helpers (_samePins, MapViewTransform)
/// stay.

import 'package:flutter/material.dart';

import 'ember_theme.dart';
import 'world_map_data.dart';

/// Build 2092 (UI audit 2026-11-16 items 33, 60): pin sets
/// compare by VALUE in shouldRepaint — the old `!=` on a Set
/// is identity, and the shell builds a fresh set per run, so
/// the painters repainted on every unrelated tick.
bool _samePins(Set<String> a, Set<String> b) =>
    a.length == b.length && a.containsAll(b);


/// The Map Control view transform: the SAME equirectangular cover
/// projection the baked backdrop asset (assets/backdrop/map_backdrop.webp)
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
    this.filament = false,
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

  /// Home fidelity round R1 (owner order 2026-11-23): the
  /// approved pro3 home composition — a THIN SOLID luminous
  /// filament arc with two glowing nodes instead of the thick
  /// dashed beam, a minimal hollow-ring home marker instead
  /// of the radar bloom, and smaller, quieter country dots.
  /// Only the shell's Home tab passes this; every other
  /// surface keeps the legacy actors byte-for-byte.
  final bool filament;

  /// Build 2092 (item 33): laid-out badge painters cached by
  /// (text, screen width) — the bucketed pulse repaint laid
  /// out two fresh TextPainters on every tick.
  final Map<String, TextPainter> _badgeCache = {};

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
      if (filament) {
        // R1 (pro3): one thin luminous filament — a soft
        // under-glow, a solid hairline core with a warm
        // gradient along its length, and two small glowing
        // nodes riding it, like the sample's arc lights.
        canvas.drawPath(
          arc,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = px(3.5)
            ..color = const Color(0xFFFF7A29).withValues(alpha: 0.16),
        );
        canvas.drawPath(
          arc,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = px(1.2)
            ..shader = LinearGradient(
              colors: const [Color(0xFFFFC46B), Color(0xFFFF7A29)],
            ).createShader(Rect.fromPoints(home, sel)),
        );
        for (final metric in arc.computeMetrics()) {
          for (final f in const [0.38, 0.68]) {
            final pos = metric.getTangentForOffset(metric.length * f)?.position;
            if (pos == null) continue;
            canvas.drawCircle(
              pos,
              px(5),
              Paint()
                ..color = const Color(0xFFFFA24D).withValues(alpha: 0.30),
            );
            canvas.drawCircle(
              pos,
              px(2.1),
              Paint()..color = const Color(0xFFFFD9A0),
            );
          }
        }
      } else {
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
    }

    // Ordinary pins: small ember dots.
    for (final code in pins) {
      if (code == selected) continue;
      // R1 (pro5-off): the sample's disconnected field is
      // bare — no satellite dots until a session is up.
      if (filament && !connected) continue;
      final pos = t.pinFor(code);
      if (pos == null) continue;
      final a = connected ? 1.0 : 0.5;
      if (filament) {
        // R1 (pro3): the sample's field carries no chunky
        // satellite blobs — a faint halo and a small core.
        canvas.drawCircle(
          pos,
          px(5),
          Paint()..color = Ember.orange.withValues(alpha: 0.14 * a),
        );
        canvas.drawCircle(
          pos,
          px(2.6),
          Paint()..color = Ember.orange.withValues(alpha: 0.75 * a),
        );
        continue;
      }
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
    if (home != null && filament) {
      // R1 (pro3): the sample's origin is a single hollow
      // orange ring with a small lit core and its city label
      // directly underneath — no bloom, no radar rings. One
      // soft pulse ring still breathes while connected.
      if (connected) {
        canvas.drawCircle(
          home,
          px(10 + 7 * pulse),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = px(1.0)
            ..color = const Color(0xFFFFA04A)
                .withValues(alpha: (1 - pulse) * 0.35),
        );
      }
      canvas.drawCircle(
        home,
        px(9),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = px(2.0)
          ..color = Ember.orange,
      );
      canvas.drawCircle(home, px(2.4), Paint()..color = const Color(0xFFFFD9A0));
      if (homeLabel.isNotEmpty) {
        _badge(
          canvas,
          home + Offset(0, px(24)),
          homeLabel,
          px,
          screenWidth: size.width,
        );
      }
    } else if (home != null) {
      // The origin's solar core (2023 polish, Gemini round-3
      // audit): a hot additive bloom under the radar rings —
      // 0x99FF7A29 at the centre, 0x4DFF6200 mid-way, gone at
      // the outer ring (r40), screen-blended over the dot field
      // so the inner rings sit IN the glow, not on top of it.
      canvas.drawCircle(
        home,
        px(40),
        Paint()
          ..blendMode = BlendMode.screen
          ..shader = RadialGradient(
            colors: const [
              Color(0x99FF7A29),
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
    // R1 (pro5-off): in the filament composition the pin joins
    // only once connected — the off state's map stays bare.
    if (sel != null && !(filament && !connected)) {
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
                : const [Color(0xFF9A9AA0), Color(0xFF5A5A5E)],
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
    // Build 2092 (item 33): reuse the laid-out painter when
    // the same badge is painted again (every pulse tick).
    final cached = _badgeCache['$text|${screenWidth.round()}'];
    if (cached != null) {
      final half = cached.width / 2;
      final cx = half + 4 >= screenWidth - half - 4
          ? screenWidth / 2
          : center.dx.clamp(half + 4, screenWidth - half - 4);
      cached.paint(
        canvas,
        Offset(cx, center.dy) - Offset(cached.width / 2, cached.height / 2),
      );
      return;
    }
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          // R1: the family is named so capture harnesses (which
          // load Roboto explicitly) render the badge as the
          // device does — Android's system sans is Roboto, so
          // the device pixels are unchanged.
          fontFamily: 'Roboto',
          // Build 2058 (audit §5 micro-type): px(8.5) floored
          // at px(9.5).
          // Build 2092 (item 52): the floor is px(11).
          fontSize: px(11),
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
    if (_badgeCache.length > 8) _badgeCache.clear();
    _badgeCache['$text|${screenWidth.round()}'] = tp;
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
      // Build 2092 (item 33): pins by value, not identity.
      !_samePins(old.pins, pins) ||
      old.selected != selected ||
      old.connected != connected ||
      old.exitBadge != exitBadge ||
      old.filament != filament ||
      old.homeLabel != homeLabel;
}

