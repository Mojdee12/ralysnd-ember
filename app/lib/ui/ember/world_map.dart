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
      (worldMapLatTop - lat) / (worldMapLatTop - worldMapLatBottom) *
          _field.height,
    );

/// Land cells as logical offsets, computed once. A deterministic few
/// carry an ember tint, as in the mockup's sparse orange sparkle.
final _dots = <(Offset, bool)>[
  for (var r = 0; r < worldMapRows.length; r++)
    for (var c = 0; c < worldMapCols; c++)
      if (worldMapRows[r][c] == '#')
        (
          Offset((c + 0.5) * _field.width / worldMapCols,
              (r + 0.5) * _field.height / worldMapRows.length),
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
    final home = homeLatLon == null ? null : _project(homeLatLon[0], homeLatLon[1]);
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
              fontSize: 8.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          textDirection: TextDirection.rtl,
        )..layout();
        final lx = (home.dx - tp.width / 2)
            .clamp(0.0, _field.width - tp.width);
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
      old.faint != faint;
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
          child: CustomPaint(
            painter: WorldMapPainter(
              pins: widget.pins,
              selected: widget.selected,
              connected: widget.connected,
              pulse: 0,
              homeLabel: widget.homeLabel,
              pulseAnim: _pulse,
              repaint: _pulse,
            ),
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
