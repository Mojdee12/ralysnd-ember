/// The Ember design system, built from the approved mockups: graphite
/// surfaces, glass cards, the ember-orange gradient, one radius and
/// spacing scale everywhere — Mozilla screens and V2Ray screens alike.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../country_names.dart';
import '../local_country_names.dart';
import 'map_widgets.dart';

abstract final class Ember {
  static const bg = Color(0xFF0B1320);
  static const surface = Color(0xFF17181C);
  static const card = Color(0xFF1C1D23);
  static const cardSoft = Color(0xFF23242B);
  static const field = Color(0xFF121317);
  static const line = Color(0x1FFFFFFF);
  static const text = Color(0xFFF4F1EA);
  static const dim = Color(0xFFA5A2AC);
  static const faint = Color(0xFF6E6C78);
  // Build 2074 (audit item 15): the spec orange is #FF7A1A.
  static const orange = Color(0xFFFF7A1A);
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
  // Build 2074 (audit item 15): ONE panel radius + ONE control
  // radius; every other radius token aliases one of these.
  static const double radiusPanel = 24;
  static const double radiusControl = 18;
  static const cardRadius = radiusPanel;
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
      // Build 2074 (audit item 23): colour lifted one step from
      // faint toward dim (size already at the ~11 sp floor).
      const TextStyle(fontSize: 11.5, color: Color(0xFF8A8792), height: 1.3);
}

/// The Map Control palette (2.2.0): the deep-navy glass system
/// of the approved mobile samples, layered over the Ember
/// graphite tokens. Panels are navy glass over the baked dotted
/// map; text is a cool white-blue ramp.
abstract final class MapUi {
  /// The backdrop gradient of the samples (#0C1520 → #101C2C).
  static const baseTop = Color(0xFF0C1520);
  static const baseBottom = Color(0xFF101C2C);

  /// Panel glass: a navy fill at ~52–55% over a backdrop blur
  /// (round 3 lowered it from ~60–64% toward the samples'
  /// airier glass; text contrast re-verified in renders).
  static const panelFill = Color(0x8C142236);
  static const panelFillSoft = Color(0x85122030);

  /// Inset fields (search, text inputs): darker than the panel.
  static const insetFill = Color(0x990A1220);

  static const line = Color(0x17FFFFFF);
  static const lineStrong = Color(0x29FFFFFF);
  static const text = Color(0xFFF2F6FC);
  static const body = Color(0xFFC9D6E8);
  static const dim = Color(0xFF8FA3BC);
  static const faint = Color(0xFF5F728C);
  static const orange = Ember.orange;
  static const amber = Ember.amber;
  static const red = Color(0xFFFF5A5A);

  /// The frozen ping hues (green at or under 150 ms, yellow
  /// above) — the owner's frozen pair, #1E9E4A / #C99300.
  static const pingGreen = Color(0xFF1E9E4A);
  static const pingYellow = Color(0xFFC99300);

  // Build 2074 (audit item 15): panel surfaces share Ember's
  // panel radius (was a drifting 20).
  static const panelRadius = Ember.radiusPanel;
  static const panelBorder = BorderRadius.all(Radius.circular(panelRadius));

  /// The selected-row treatment of the samples: an orange wash,
  /// stronger at the left edge, over the glass.
  static const selectedGradient = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [Color(0x47FF7A1A), Color(0x1AFF7A1A)],
  );
}

/// Build 2074 (audit item 14): ONE ping rule survives —
/// [pingColor] (green <100 ms, amber <250, red beyond). This
/// name stays for its Map Control callers but delegates, so
/// every surface colours the same delay the same way.
Color mapPingColor(int ms) => pingColor(ms);

/// The app background: the baked Map Control backdrop (the
/// offline dot raster over the deep-navy base), shared by the
/// shell and every pushed Ember page.
class EmberBackground extends StatelessWidget {
  final Widget child;
  const EmberBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) =>
      Stack(fit: StackFit.expand, children: [const MapBackdropVisual(), child]);
}

/// A mockup glass card — since 2.2.0 the Map Control glass:
/// a navy translucent fill over a real backdrop blur, a hairline
/// border (an orange glow border with [glow]), a soft shadow.
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
  // Build 2059 (audit §5 appearance): one card system — GlassCard
  // renders through MapGlass now (same gradient fill, border and
  // specular top line; the old drop shadow is gone). The 15 call
  // sites keep their padding/glow/onTap API unchanged.
  Widget build(BuildContext context) =>
      MapGlass(padding: padding, glow: glow, onTap: onTap, child: child);
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
        canvas.drawPath(
          metric.extractPath(d, math.min(d + 7, metric.length)),
          paint,
        );
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
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1900),
  );

  bool _foreground = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // No _sync() here: it reads MediaQuery (disableAnimations),
    // which initState may not subscribe to — didChangeDependencies
    // runs right after initState and on every MediaQuery change.
  }

  @override
  void didUpdateWidget(PowerRing old) {
    super.didUpdateWidget(old);
    _sync();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Build 2050 (battery): no pulsing while backgrounded.
    // (Hidden tabs are covered by the shell's TickerMode.)
    _foreground = state == AppLifecycleState.resumed;
    _sync();
  }

  void _sync() {
    // Build 2057 (audit F-H10): honour "reduce motion" — the
    // perpetual pulse otherwise never lets pumpAndSettle settle.
    final still = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (widget.on && _foreground && !still) {
      if (!_pulse.isAnimating) _pulse.repeat(reverse: true);
    } else if (_pulse.isAnimating) {
      _pulse.stop();
      _pulse.value = 0;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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

/// The Map Control toggle: a knob-less pill — a solid orange
/// gradient capsule with a soft glow and the dark ON micro-text
/// when on, a mid-grey capsule with dark OFF text when off (the
/// mobile samples' switch).
class EmberToggle extends StatelessWidget {
  final bool value;
  final ValueChanged<bool>? onChanged;
  const EmberToggle({super.key, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onChanged == null ? null : () => onChanged!(!value),
    // Build 2058 (audit §5 shared widgets): the visible knob
    // stays 50×26, but the tap target is 44 dp tall — the 9 px
    // of transparent padding above/below the track is part of
    // the GestureDetector.
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        width: 50,
        height: 26,
        alignment: value ? Alignment.centerRight : Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          gradient: value
              ? const LinearGradient(
                  colors: [Color(0xFFFF9E42), Color(0xFFE65116)],
                )
              : null,
          // OFF wears the samples' mid-slate (2023 polish,
          // Gemini round-3 audit), not the old light grey.
          color: value ? null : const Color(0xFF5A6878),
          border: value ? null : Border.all(color: const Color(0xFF758699)),
          boxShadow: value
              ? [
                  BoxShadow(
                    color: Ember.orange.withValues(alpha: 0.35),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ]
              : null,
        ),
        child: Text(
          value ? 'ON' : 'OFF',
          style: TextStyle(
            fontSize: 9,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.6,
            color: value ? const Color(0xFF1A1206) : const Color(0xFF22262D),
          ),
        ),
      ),
    ),
  );
}

/// A small glass chip; [selected] tints it ember with an
/// orange border and text (the Map Control filter/badge chip).
class EmberChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final Color? dot;

  /// A slimmer chip (the V2Ray panel's protocol filter row):
  /// tighter padding, a smaller label.
  final bool compact;
  const EmberChip({
    super.key,
    required this.label,
    this.selected = false,
    this.onTap,
    this.dot,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final chip = Container(
      padding: compact
          ? const EdgeInsets.symmetric(horizontal: 10, vertical: 4)
          : const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
      decoration: BoxDecoration(
        color: selected
            ? Ember.orange.withValues(alpha: 0.16)
            : Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: selected ? Ember.orange.withValues(alpha: 0.7) : MapUi.line,
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
              fontSize: compact ? 11 : 12,
              fontWeight: FontWeight.w700,
              color: selected ? const Color(0xFFFFAE85) : MapUi.dim,
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
        borderRadius: BorderRadius.circular(999),
        // Build 2074 (audit item 4): the visual chip keeps its
        // size, but a tappable chip's hit area is at least
        // 48 dp tall — the transparent padding is part of the
        // InkWell.
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: compact ? 13 : 11),
          child: chip,
        ),
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
                    color: index == i ? const Color(0xFF1A1206) : Ember.dim,
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
      color: MapUi.insetFill,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: MapUi.line),
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
                  color: value == v
                      ? Ember.orange.withValues(alpha: 0.18)
                      : Colors.transparent,
                  border: Border.all(
                    color: value == v
                        ? Ember.orange.withValues(alpha: 0.75)
                        : Colors.transparent,
                  ),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (icon != null) ...[
                      Icon(
                        icon,
                        size: 17,
                        color: value == v ? Ember.orange : MapUi.dim,
                      ),
                      const SizedBox(width: 6),
                    ],
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: value == v ? Ember.orange : MapUi.dim,
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
        BoxShadow(
          color: Color(0x66000000),
          blurRadius: 24,
          offset: Offset(0, 8),
        ),
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
                        fontWeight: index == i
                            ? FontWeight.w700
                            : FontWeight.w500,
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
String localizedCountryName(
  BuildContext context,
  String code,
  String fallback,
) {
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

/// A gradient-filled primary button.
class EmberButton extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  final IconData? icon;
  const EmberButton({
    super.key,
    required this.label,
    required this.onTap,
    this.icon,
  });

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.transparent,
    child: InkWell(
      onTap: onTap,
      // Build 2074 (audit item 15): buttons alias the control radius.
      borderRadius: BorderRadius.circular(Ember.radiusControl),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 20),
        decoration: BoxDecoration(
          gradient: onTap == null ? null : Ember.gradient,
          color: onTap == null ? Ember.cardSoft : null,
          borderRadius: BorderRadius.circular(Ember.radiusControl),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (icon != null) ...[
              Icon(
                icon,
                size: 19,
                // Build 2050 (audit A-H2): a disabled button
                // drops the gradient for a dark fill — the
                // label/icon switch to the dim tone with it,
                // instead of staying near-black on dark grey.
                color: onTap == null ? Ember.dim : const Color(0xFF1A1206),
              ),
              const SizedBox(width: 8),
            ],
            // Build 2074 (audit item 16): a long label can no
            // longer overflow the button — it scales down to fit.
            // FittedBox, not a Flexible: as a plain child of a Row
            // the button gets unbounded width (a flex child there
            // is a layout error), and inside an AlertDialog the
            // actions are measured intrinsically (a LayoutBuilder
            // cannot answer intrinsic queries). scaleDown sizes
            // naturally in both and only shrinks when squeezed.
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  color: onTap == null ? Ember.dim : const Color(0xFF1A1206),
                ),
                maxLines: 1,
                softWrap: false,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// An input field in the Ember field style.
InputDecoration emberField(
  BuildContext context,
  String hint, {
  Widget? prefix,
}) => InputDecoration(
  hintText: hint,
  hintStyle: const TextStyle(color: MapUi.faint, fontSize: 13.5),
  prefixIcon: prefix,
  filled: true,
  fillColor: MapUi.insetFill,
  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
  // Build 2074 (audit item 15): fields alias the control radius.
  border: OutlineInputBorder(
    borderRadius: BorderRadius.circular(Ember.radiusControl),
    borderSide: const BorderSide(color: Ember.line),
  ),
  enabledBorder: OutlineInputBorder(
    borderRadius: BorderRadius.circular(Ember.radiusControl),
    borderSide: const BorderSide(color: Ember.line),
  ),
  focusedBorder: OutlineInputBorder(
    borderRadius: BorderRadius.circular(Ember.radiusControl),
    borderSide: const BorderSide(color: Ember.orange, width: 1.4),
  ),
);

/// An empty-state block: icon, a line of text, optional action.
class EmberEmpty extends StatelessWidget {
  final IconData icon;
  final String text;
  final Widget? action;
  const EmberEmpty({
    super.key,
    required this.icon,
    required this.text,
    this.action,
  });

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
