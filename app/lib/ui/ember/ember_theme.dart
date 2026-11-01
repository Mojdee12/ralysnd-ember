/// The Ember design system, built from the approved mockups: graphite
/// surfaces, glass cards, the ember-orange gradient, one radius and
/// spacing scale everywhere — Mozilla screens and V2Ray screens alike.

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../features.dart';
import '../country_names.dart';
import '../local_country_names.dart';

abstract final class Ember {
  static const bg = Color(0xFF0B0B0E);
  static const surface = Color(0xFF17181C);
  static const card = Color(0xFF1C1D23);
  static const cardSoft = Color(0xFF23242B);
  static const field = Color(0xFF121317);
  static const line = Color(0x1FFFFFFF);
  static const text = Color(0xFFF4F1EA);
  static const dim = Color(0xFFA5A2AC);
  static const faint = Color(0xFF6E6C78);
  static const orange = Color(0xFFFF7A18);
  static const amber = Color(0xFFFFB347);
  static const green = Color(0xFF41D97E);
  static const warn = Color(0xFFFFB020);
  static const red = Color(0xFFFF5A5A);
  static const gradient = LinearGradient(
    colors: [orange, amber],
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
  );
  static const gradientVertical = LinearGradient(
    colors: [amber, orange],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
  );
  static const cardRadius = 24.0;
  static const radius = BorderRadius.all(Radius.circular(cardRadius));

  static TextStyle get title =>
      const TextStyle(fontSize: 21, fontWeight: FontWeight.w800, color: text);
  static TextStyle get heading =>
      const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: text);
  static TextStyle get body =>
      const TextStyle(fontSize: 14, color: text, height: 1.35);
  static TextStyle get dimStyle =>
      const TextStyle(fontSize: 13, color: dim, height: 1.35);
  static TextStyle get caption =>
      const TextStyle(fontSize: 11.5, color: faint, height: 1.3);
}

/// The app background: near-black with a faint ember glow at the top.
class EmberBackground extends StatelessWidget {
  final Widget child;
  const EmberBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(0, -1.15),
            radius: 1.15,
            colors: [Color(0x2EFF7A18), Ember.bg, Ember.bg],
            stops: [0, 0.45, 1],
          ),
        ),
        child: child,
      );
}

/// A mockup glass card: soft graphite fill, hairline border, big radius.
///
/// On the desktop shell (Windows) the same widget renders the Fluent
/// mockups' LIGHT glass instead: a COOL NEUTRAL pale translucent fill
/// over a real backdrop blur — the dotted map shows through the card
/// in blue-grey — with a luminous edge and a thin orange rim line
/// along the top edge (brighter on the [glow] cards, the primary
/// connection cards). No warm tint washes the fill: orange lives
/// only in that rim line. The phone rendering below is untouched.
class GlassCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final bool glow;
  final VoidCallback? onTap;
  const GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.glow = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    if (Features.desktopShell) return _buildDesktopGlass();
    final card = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: Ember.card.withValues(alpha: 0.82),
        borderRadius: Ember.radius,
        border: Border.all(
          color: glow ? Ember.orange.withValues(alpha: 0.55) : Ember.line,
          width: glow ? 1.4 : 1,
        ),
        boxShadow: glow
            ? [
                BoxShadow(
                  color: Ember.orange.withValues(alpha: 0.22),
                  blurRadius: 24,
                  spreadRadius: 1,
                )
              ]
            : const [],
      ),
      child: child,
    );
    if (onTap == null) return card;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: Ember.radius,
        child: card,
      ),
    );
  }

  /// The desktop light-glass surface (see the class doc).
  Widget _buildDesktopGlass() {
    // A RepaintBoundary around the glass: the card's backdrop blur
    // becomes its own composited layer, so a repaint anywhere else
    // on the page (a ticking value, a sibling card) reuses the
    // cached blur instead of re-running the filter for this card.
    final surface = RepaintBoundary(
      child: Container(
      decoration: BoxDecoration(
        borderRadius: Ember.radius,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.38),
            blurRadius: 22,
            offset: const Offset(0, 10),
          ),
          // NO orange halo shadow, deliberately: the card's
          // backdrop blur samples everything painted beneath it,
          // so any filled orange shadow behind the glass bleeds
          // through the blur and tints the interior sepia (a short
          // selected row showed exactly that band). The mockups'
          // warm edge is the bright rim LINE painted on top of the
          // glass below — stronger on [glow] cards — and that is
          // the only orange a card carries.
        ],
      ),
      child: ClipRRect(
        borderRadius: Ember.radius,
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Stack(
            children: [
              // The pale translucent fill, lighter at the top — a
              // cool blue-grey white, so the glass reads neutral
              // grey like the mockups, never sepia.
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        const Color(0xFFDDE7F5).withValues(alpha: 0.13),
                        const Color(0xFFDDE7F5).withValues(alpha: 0.06),
                      ],
                    ),
                  ),
                ),
              ),
              Container(
                padding: padding,
                decoration: BoxDecoration(
                  borderRadius: Ember.radius,
                  border:
                      Border.all(color: Colors.white.withValues(alpha: 0.20)),
                ),
                child: child,
              ),
              // The bright rim line along the top edge, fading at the
              // corners as in the mockups.
              Positioned(
                top: 0,
                left: 26,
                right: 26,
                child: Container(
                  height: 1.4,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        Ember.orange.withValues(alpha: 0.05),
                        Ember.orange.withValues(alpha: glow ? 0.85 : 0.6),
                        Ember.orange.withValues(alpha: glow ? 0.85 : 0.6),
                        Ember.orange.withValues(alpha: 0.05),
                      ],
                      stops: const [0, 0.25, 0.75, 1],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      ),
    );
    if (onTap == null) return surface;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: Ember.radius,
        child: surface,
      ),
    );
  }
}

/// The dashed outline button of the mockups («افزودن حساب» / اشتراک).
class DashedAddButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  const DashedAddButton({
    super.key,
    required this.label,
    this.icon = Icons.add,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: Ember.radius,
          child: CustomPaint(
            painter: _DashedBorderPainter(),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 18),
              alignment: Alignment.center,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, color: Ember.orange, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    label,
                    style: const TextStyle(
                      color: Ember.orange,
                      fontSize: 14.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
}

class _DashedBorderPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Ember.orange.withValues(alpha: 0.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.3;
    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(Ember.cardRadius),
    );
    final path = Path()..addRRect(rrect);
    for (final metric in path.computeMetrics()) {
      var d = 0.0;
      while (d < metric.length) {
        canvas.drawPath(metric.extractPath(d, math.min(d + 7, metric.length)), paint);
        d += 11;
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// The big glowing power ring of the home screens.
class PowerRing extends StatefulWidget {
  final bool on;
  final bool busy;
  final VoidCallback onTap;
  final double size;
  const PowerRing({
    super.key,
    required this.on,
    required this.busy,
    required this.onTap,
    this.size = 218,
  });

  @override
  State<PowerRing> createState() => _PowerRingState();
}

class _PowerRingState extends State<PowerRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1900),
  );

  @override
  void initState() {
    super.initState();
    if (widget.on) _pulse.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(PowerRing old) {
    super.didUpdateWidget(old);
    if (widget.on && !_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    } else if (!widget.on && _pulse.isAnimating) {
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
  Widget build(BuildContext context) {
    final on = widget.on;
    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, _) {
        final glow = on ? 0.30 + 0.14 * _pulse.value : 0.0;
        return GestureDetector(
          onTap: widget.busy ? null : widget.onTap,
          child: Container(
            width: widget.size,
            height: widget.size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Ember.orange.withValues(alpha: glow),
                  blurRadius: 60,
                  spreadRadius: 6,
                ),
              ],
            ),
            child: CustomPaint(
              painter: _RingPainter(on: on, busy: widget.busy),
              child: Center(
                child: widget.busy
                    ? const SizedBox(
                        width: 44,
                        height: 44,
                        child: CircularProgressIndicator(
                          color: Ember.orange,
                          strokeWidth: 3,
                        ),
                      )
                    : Icon(
                        Icons.power_settings_new_rounded,
                        size: 64,
                        color: on ? Ember.amber : Ember.dim,
                      ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _RingPainter extends CustomPainter {
  final bool on;
  final bool busy;
  const _RingPainter({required this.on, required this.busy});

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final r = size.width / 2 - 7;
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 9
      ..color = const Color(0xFF26272E);
    canvas.drawCircle(center, r, track);
    final rect = Rect.fromCircle(center: center, radius: r);
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 9
      ..strokeCap = StrokeCap.round
      ..shader = Ember.gradient.createShader(rect);
    if (on || busy) {
      canvas.drawArc(rect, -math.pi / 2, math.pi * 2, false, ring);
    } else {
      canvas.drawArc(rect, -math.pi / 2, math.pi * 0.72, false, ring);
    }
    final inner = Paint()..color = const Color(0xFF131318);
    canvas.drawCircle(center, r - 14, inner);
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.on != on || old.busy != busy;
}

/// A circular usage ring with the percentage in the middle.
class UsageRing extends StatelessWidget {
  final double fraction; // 0..1
  final String centerText;
  final String? subText;
  final double size;
  const UsageRing({
    super.key,
    required this.fraction,
    required this.centerText,
    this.subText,
    this.size = 92,
  });

  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size,
        child: CustomPaint(
          painter: _UsageRingPainter(fraction.clamp(0.0, 1.0)),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  centerText,
                  style: TextStyle(
                    fontSize: size * 0.24,
                    fontWeight: FontWeight.w800,
                    color: Ember.text,
                  ),
                ),
                if (subText != null)
                  Text(subText!, style: Ember.caption.copyWith(fontSize: 10)),
              ],
            ),
          ),
        ),
      );
}

class _UsageRingPainter extends CustomPainter {
  final double fraction;
  const _UsageRingPainter(this.fraction);

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final r = size.width / 2 - 5;
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 7
      ..color = const Color(0xFF2A2B33);
    canvas.drawCircle(center, r, track);
    final rect = Rect.fromCircle(center: center, radius: r);
    final fill = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 7
      ..strokeCap = StrokeCap.round
      ..shader = Ember.gradient.createShader(rect);
    canvas.drawArc(rect, -math.pi / 2, math.pi * 2 * fraction, false, fill);
  }

  @override
  bool shouldRepaint(_UsageRingPainter old) => old.fraction != fraction;
}

/// The thick gradient usage bar of the account cards.
class UsageBar extends StatelessWidget {
  final double fraction;
  final double height;
  const UsageBar({super.key, required this.fraction, this.height = 9});

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(height),
        child: Container(
          height: height,
          color: const Color(0xFF2A2B33),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: FractionallySizedBox(
              widthFactor: fraction.clamp(0.0, 1.0),
              child: Container(
                decoration: const BoxDecoration(gradient: Ember.gradient),
              ),
            ),
          ),
        ),
      );
}

/// The mockups' toggle: a gradient pill when on, grey when off.
class EmberToggle extends StatelessWidget {
  final bool value;
  final ValueChanged<bool>? onChanged;
  const EmberToggle({super.key, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onChanged == null ? null : () => onChanged!(!value),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          width: 50,
          height: 29,
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            gradient: value ? Ember.gradient : null,
            color: value ? null : const Color(0xFF34353D),
          ),
          child: AnimatedAlign(
            duration: const Duration(milliseconds: 180),
            alignment: value ? Alignment.centerRight : Alignment.centerLeft,
            child: Container(
              width: 23,
              height: 23,
              decoration: const BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
              ),
            ),
          ),
        ),
      );
}

/// A small pill chip; [selected] fills it with the gradient.
class EmberChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final Color? dot;
  const EmberChip({
    super.key,
    required this.label,
    this.selected = false,
    this.onTap,
    this.dot,
  });

  @override
  Widget build(BuildContext context) {
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        gradient: selected ? Ember.gradient : null,
        color: selected ? null : Ember.cardSoft,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: selected ? Colors.transparent : Ember.line,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dot != null) ...[
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: selected ? const Color(0xFF1A1206) : Ember.dim,
            ),
          ),
        ],
      ),
    );
    if (onTap == null) return chip;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: chip,
      ),
    );
  }
}

/// The two-way mode switch of the home screens (موزیلا | V2Ray).
class ModeSwitch extends StatelessWidget {
  final int index; // 0 = Mozilla, 1 = V2Ray, 2 = Psiphon, 3 = Lantern
  final ValueChanged<int> onChanged;
  final List<String> labels;
  const ModeSwitch({
    super.key,
    required this.index,
    required this.onChanged,
    required this.labels,
  });

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: Ember.field,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Ember.line),
        ),
        child: Row(
          children: [
            for (var i = 0; i < labels.length; i++)
              Expanded(
                child: GestureDetector(
                  onTap: () => onChanged(i),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(
                      gradient: index == i ? Ember.gradient : null,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      labels[i],
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: index == i
                            ? const Color(0xFF1A1206)
                            : Ember.dim,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
}

/// A segmented control in the mockups' settings style (VPN | Proxy).
class EmberSegmented<T> extends StatelessWidget {
  final List<(T, String, IconData?)> options;
  final T value;
  final ValueChanged<T> onChanged;
  const EmberSegmented({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: Ember.field,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Ember.line),
        ),
        child: Row(
          children: [
            for (final (v, label, icon) in options)
              Expanded(
                child: GestureDetector(
                  onTap: () => onChanged(v),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    padding: const EdgeInsets.symmetric(vertical: 11),
                    decoration: BoxDecoration(
                      gradient: value == v ? Ember.gradient : null,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (icon != null) ...[
                          Icon(
                            icon,
                            size: 17,
                            color: value == v
                                ? const Color(0xFF1A1206)
                                : Ember.dim,
                          ),
                          const SizedBox(width: 6),
                        ],
                        Text(
                          label,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: value == v
                                ? const Color(0xFF1A1206)
                                : Ember.dim,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
}

/// The floating glass bottom navigation of the mockups.
class EmberBottomNav extends StatelessWidget {
  final int index;
  final ValueChanged<int> onChanged;
  final List<(IconData, String)> items;
  const EmberBottomNav({
    super.key,
    required this.index,
    required this.onChanged,
    required this.items,
  });

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.fromLTRB(18, 0, 18, 16),
        padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 8),
        decoration: BoxDecoration(
          color: const Color(0xF21A1B20),
          borderRadius: BorderRadius.circular(30),
          border: Border.all(color: Ember.line),
          boxShadow: const [
            BoxShadow(color: Color(0x66000000), blurRadius: 24, offset: Offset(0, 8)),
          ],
        ),
        child: Row(
          children: [
            for (var i = 0; i < items.length; i++)
              Expanded(
                child: GestureDetector(
                  onTap: () => onChanged(i),
                  behavior: HitTestBehavior.opaque,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    padding: const EdgeInsets.symmetric(vertical: 7),
                    decoration: BoxDecoration(
                      color: index == i
                          ? Ember.orange.withValues(alpha: 0.16)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          items[i].$1,
                          size: 21,
                          color: index == i ? Ember.orange : Ember.faint,
                        ),
                        const SizedBox(height: 3),
                        Text(
                          items[i].$2,
                          style: TextStyle(
                            fontSize: 10.5,
                            fontWeight:
                                index == i ? FontWeight.w700 : FontWeight.w500,
                            color: index == i ? Ember.orange : Ember.faint,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
}

/// A circular country flag from the bundled assets, initials behind it.
class FlagCircle extends StatelessWidget {
  final String code;
  final double size;
  const FlagCircle({super.key, required this.code, this.size = 42});

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: const BoxDecoration(
          color: Ember.cardSoft,
          shape: BoxShape.circle,
        ),
        child: ClipOval(
          child: code.isEmpty
              ? Icon(Icons.public, size: size * 0.55, color: Ember.dim)
              : SvgPicture.asset(
                  'assets/flags/${code.toLowerCase()}.svg',
                  fit: BoxFit.cover,
                  placeholderBuilder: (_) => Center(
                    child: Text(
                      code.toUpperCase(),
                      style: TextStyle(fontSize: size * 0.3, color: Ember.dim),
                    ),
                  ),
                ),
        ),
      );
}

/// A country code's name in the app's language, English otherwise.
String localizedCountryName(BuildContext context, String code, String fallback) {
  final lang = Localizations.localeOf(context).languageCode;
  return localCountryNames[lang]?[code.toUpperCase()] ??
      countryNames[code.toUpperCase()] ??
      fallback;
}

/// Colored ping text: green under 100, amber under 250, red beyond.
Color pingColor(int ms) {
  if (ms < 0) return Ember.faint;
  if (ms < 100) return Ember.green;
  if (ms < 250) return Ember.warn;
  return Ember.red;
}

/// The top glass pill bar of the home mockup (flame, name, more).
class EmberAppBar extends StatelessWidget {
  final VoidCallback? onMore;
  const EmberAppBar({super.key, this.onMore});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsetsDirectional.fromSTEB(14, 9, 8, 9),
        decoration: BoxDecoration(
          color: Ember.card.withValues(alpha: 0.8),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: Ember.line),
        ),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: const BoxDecoration(
                gradient: Ember.gradient,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.local_fire_department_rounded,
                color: Color(0xFF1A1206),
                size: 20,
              ),
            ),
            const SizedBox(width: 10),
            const Text(
              'Ralysnd Ember',
              style: TextStyle(
                fontSize: 16.5,
                fontWeight: FontWeight.w800,
                color: Ember.text,
              ),
            ),
            const Spacer(),
            if (onMore != null)
              IconButton(
                onPressed: onMore,
                icon: const Icon(Icons.more_horiz_rounded, color: Ember.dim),
                visualDensity: VisualDensity.compact,
              ),
          ],
        ),
      );
}

/// A gradient-filled primary button.
class EmberButton extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  final IconData? icon;
  const EmberButton({super.key, required this.label, required this.onTap, this.icon});

  @override
  Widget build(BuildContext context) => Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 20),
            decoration: BoxDecoration(
              gradient: onTap == null ? null : Ember.gradient,
              color: onTap == null ? Ember.cardSoft : null,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 19, color: const Color(0xFF1A1206)),
                  const SizedBox(width: 8),
                ],
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF1A1206),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
}

/// An input field in the Ember field style.
InputDecoration emberField(BuildContext context, String hint, {Widget? prefix}) =>
    InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: Ember.faint, fontSize: 13.5),
      prefixIcon: prefix,
      filled: true,
      fillColor: Ember.field,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: Ember.line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: Ember.line),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: Ember.orange, width: 1.4),
      ),
    );

/// An empty-state block: icon, a line of text, optional action.
class EmberEmpty extends StatelessWidget {
  final IconData icon;
  final String text;
  final Widget? action;
  const EmberEmpty({super.key, required this.icon, required this.text, this.action});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 34, horizontal: 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: const BoxDecoration(
                color: Ember.cardSoft,
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: Ember.faint, size: 30),
            ),
            const SizedBox(height: 14),
            Text(text, style: Ember.dimStyle, textAlign: TextAlign.center),
            if (action != null) ...[const SizedBox(height: 16), action!],
          ],
        ),
      );
}
