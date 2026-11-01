/// Shared building blocks of the Ember DESKTOP pages (the locked
/// Windows Fluent mockups): a page header, the bottom status bar,
/// the wide toggle pill of the connection cards, the fixed-width
/// ping pill of the V2Ray grid, and a rectangular flag. These exist
/// only for the desktop shell; the phone pages never use them.

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'ember_format.dart';
import 'ember_theme.dart';

/// The mockups' page header: a large title, a muted subtitle, and
/// optional actions at the right (the V2Ray page's Add / Import /
/// Test All buttons).
class DesktopHeader extends StatelessWidget {
  const DesktopHeader({
    super.key,
    required this.title,
    required this.subtitle,
    this.actions = const [],
    this.titleSize = 30,
  });

  final String title;
  final String subtitle;
  final List<Widget> actions;

  /// The V2Ray mockup's title is oversized; the other pages use 30.
  final double titleSize;

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: titleSize,
                    fontWeight: FontWeight.w800,
                    color: Ember.text,
                    height: 1.1,
                  ),
                ),
                const SizedBox(height: 4),
                Text(subtitle, style: Ember.dimStyle.copyWith(fontSize: 13.5)),
              ],
            ),
          ),
          if (actions.isNotEmpty) ...[
            const SizedBox(width: 16),
            Row(mainAxisSize: MainAxisSize.min, children: actions),
          ],
        ],
      );
}

/// The mockups' bottom status bar: a summary line at the left and
/// the protection state at the right, over a hairline.
class DesktopStatusBar extends StatelessWidget {
  const DesktopStatusBar({
    super.key,
    required this.left,
    required this.protectionOn,
  });

  final String left;
  final bool protectionOn;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(4, 10, 4, 2),
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: Ember.line)),
        ),
        child: Row(
          children: [
            Icon(
              protectionOn
                  ? Icons.check_circle_outline_rounded
                  : Icons.radio_button_unchecked_rounded,
              size: 16,
              color: protectionOn ? Ember.green : Ember.faint,
            ),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                left,
                style: Ember.caption.copyWith(fontSize: 12.5),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Icon(
              Icons.shield_rounded,
              size: 16,
              color: protectionOn ? Ember.orange : Ember.faint,
            ),
            const SizedBox(width: 6),
            Text(
              protectionOn ? 'Protection: ON' : 'Protection: OFF',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w800,
                color: protectionOn ? Ember.orange : Ember.faint,
              ),
            ),
          ],
        ),
      );
}

/// The wide toggle pill of the mockups' connection cards: while ON
/// an orange GRADIENT pill with a big pale knob at the LEFT and a
/// bold white label; while OFF the same shape and height in dark
/// glass, the knob still at the left in muted orange, the label
/// "Connect". One tap toggles.
class DesktopTogglePill extends StatelessWidget {
  const DesktopTogglePill({
    super.key,
    required this.on,
    required this.busy,
    required this.onLabel,
    required this.offLabel,
    required this.onTap,
    this.labelIcon,
  });

  final bool on;
  final bool busy;
  final String onLabel;
  final String offLabel;
  final VoidCallback onTap;

  /// A small glyph before the label (the Psiphon mockup's soundwave).
  final IconData? labelIcon;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: busy ? null : onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          height: 54,
          decoration: BoxDecoration(
            gradient: on ? Ember.gradient : null,
            color: on ? null : Colors.white.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(999),
            border: on
                ? null
                : Border.all(color: Colors.white.withValues(alpha: 0.16)),
            boxShadow: on
                ? [
                    BoxShadow(
                      color: Ember.orange.withValues(alpha: 0.45),
                      blurRadius: 20,
                      spreadRadius: 1,
                    ),
                  ]
                : const [],
          ),
          child: Stack(
            children: [
              Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (labelIcon != null && !busy) ...[
                      Icon(labelIcon, size: 19, color: Ember.text),
                      const SizedBox(width: 8),
                    ],
                    Text(
                      busy ? '…' : (on ? onLabel : offLabel),
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: Ember.text,
                      ),
                    ),
                  ],
                ),
              ),
              Positioned(
                left: 7,
                top: 7,
                bottom: 7,
                child: Container(
                  width: 40,
                  decoration: BoxDecoration(
                    gradient: on
                        ? const LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [Color(0xFFFFF6E0), Color(0xFFFFD9A0)],
                          )
                        : null,
                    color: on ? null : const Color(0xFF7A4210),
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.30),
                        blurRadius: 6,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The mockups' settings switch: a wide orange pill with the pale
/// knob at the LEFT while on; a grey pill with the knob at the RIGHT
/// while off. (The knob side is the mockups' own convention, the
/// same as the connection pill.)
class DesktopSwitch extends StatelessWidget {
  const DesktopSwitch({super.key, required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onChanged == null ? null : () => onChanged!(!value),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          width: 62,
          height: 34,
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            gradient: value ? Ember.gradient : null,
            color: value ? null : const Color(0xFF3B3C45),
            boxShadow: value
                ? [
                    BoxShadow(
                      color: Ember.orange.withValues(alpha: 0.35),
                      blurRadius: 10,
                    ),
                  ]
                : const [],
          ),
          child: AnimatedAlign(
            duration: const Duration(milliseconds: 180),
            alignment: value ? Alignment.centerLeft : Alignment.centerRight,
            child: Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                color: value
                    ? const Color(0xFFFFE9C4)
                    : const Color(0xFFD8D8DE),
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.25),
                    blurRadius: 4,
                    offset: const Offset(0, 1),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
}

/// The outlined engine pill at the connection cards' top right
/// ("MOZILLA" / "PSIPHON" in the mockups): orange letterspaced text
/// in a thin orange outline.
class DesktopEnginePill extends StatelessWidget {
  const DesktopEnginePill({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 4),
        decoration: BoxDecoration(
          border: Border.all(color: Ember.orange.withValues(alpha: 0.65)),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.2,
            color: Ember.orange,
          ),
        ),
      );
}

/// A hero stat of the session cards: a small-caps label with an
/// orange glyph above a big bold value — the numbers dominate, as
/// in the mockups ("12.4 MB/s" under DOWNLOAD).
class DesktopHeroStat extends StatelessWidget {
  const DesktopHeroStat({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    this.valueSize = 27,
  });

  final IconData icon;
  final String label;
  final String value;
  final double valueSize;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 15, color: Ember.orange),
              const SizedBox(width: 6),
              Text(
                label,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.1,
                  color: Ember.dim,
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Directionality(
            textDirection: TextDirection.ltr,
            child: Text(
              value,
              style: TextStyle(
                fontSize: valueSize,
                fontWeight: FontWeight.w800,
                color: Ember.text,
                height: 1.05,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      );
}

/// One capture-mode chip (Proxy only / System proxy / TUN), shared
/// by the desktop Settings page's Connection card.
class DesktopModeChip extends StatelessWidget {
  const DesktopModeChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(999),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
            decoration: BoxDecoration(
              gradient: selected ? Ember.gradient : null,
              color: selected ? null : Colors.white.withValues(alpha: 0.07),
              borderRadius: BorderRadius.circular(999),
              border: selected
                  ? null
                  : Border.all(color: Colors.white.withValues(alpha: 0.14)),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w800,
                color: selected ? const Color(0xFF1A1206) : Ember.dim,
              ),
            ),
          ),
        ),
      );
}

/// A state badge of the mockups ("SECURE" / "OFF" / "Connected"):
/// a dot and an outlined label in the state's color.
class DesktopStateBadge extends StatelessWidget {
  const DesktopStateBadge({super.key, required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            decoration: BoxDecoration(
              border: Border.all(color: color.withValues(alpha: 0.65)),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.6,
                color: color,
              ),
            ),
          ),
        ],
      );
}

/// The V2Ray grid's ping column: one fixed width (88 px) in every
/// row so the values form a straight right-aligned column, exactly
/// as the approved clean mockup fixed it. States: a colored pill, a
/// spinner while testing, "Failed" in ember red, an em dash.
class DesktopPingPill extends StatelessWidget {
  const DesktopPingPill({
    super.key,
    required this.ms,
    required this.failed,
    required this.testing,
    required this.unit,
  });

  final int ms;
  final bool failed;
  final bool testing;
  final String unit;

  @override
  Widget build(BuildContext context) {
    if (testing) {
      return const SizedBox(
        width: 88,
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2, color: Ember.orange),
          ),
        ),
      );
    }
    if (ms < 0 && failed) {
      return const SizedBox(
        width: 88,
        child: Text(
          'Failed',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: Ember.red,
          ),
        ),
      );
    }
    if (ms < 0) {
      return const SizedBox(
        width: 88,
        child: Text(
          '—',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13, color: Ember.faint),
        ),
      );
    }
    // The mockups' pills are saturated pastel fills with dark text:
    // light green, yellow, orange-red by latency band.
    final (fill, ink) = ms < 100
        ? (const Color(0xFF9BDC7F), const Color(0xFF1E2A10))
        : ms < 250
            ? (const Color(0xFFFFC94D), const Color(0xFF33230A))
            : (const Color(0xFFFF9E6B), const Color(0xFF3A1C08));
    return SizedBox(
      width: 88,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 5),
        decoration: BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.circular(999),
        ),
        alignment: Alignment.center,
        child: Text(
          '${latDigits(ms)} $unit',
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w800,
            color: ink,
          ),
        ),
      ),
    );
  }
}

/// A rectangular flag (the config rows of the mockups), from the
/// bundled flag assets; a flag-emoji text stands in where a code has
/// no asset.
class FlagRect extends StatelessWidget {
  const FlagRect({super.key, required this.code, this.width = 46});

  final String code;
  final double width;

  @override
  Widget build(BuildContext context) {
    final height = width * 0.7;
    if (code.length != 2) {
      return SizedBox(
        width: width,
        height: height,
        child: const Center(
          child: Icon(Icons.public_rounded, size: 22, color: Ember.dim),
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: width,
        height: height,
        child: SvgPicture.asset(
          'assets/flags/${code.toLowerCase()}.svg',
          fit: BoxFit.cover,
          placeholderBuilder: (_) => Center(
            child: Text(
              code.toUpperCase(),
              style: const TextStyle(fontSize: 12, color: Ember.dim),
            ),
          ),
        ),
      ),
    );
  }
}

/// A label/value row of the session cards (icon, muted label, then
/// the value in heading style), with a hairline under it when asked.
class DesktopKvRow extends StatelessWidget {
  const DesktopKvRow({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    this.divider = true,
  });

  final IconData icon;
  final String label;
  final String value;
  final bool divider;

  @override
  Widget build(BuildContext context) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 9),
            child: Row(
              children: [
                Icon(icon, size: 17, color: Ember.faint),
                const SizedBox(width: 9),
                Text(label, style: Ember.dimStyle),
                const Spacer(),
                Directionality(
                  textDirection: TextDirection.ltr,
                  child: Text(
                    value,
                    style: Ember.heading.copyWith(fontSize: 14.5),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          if (divider) const Divider(color: Ember.line, height: 1),
        ],
      );
}

/// An outlined action button of the desktop headers (Add / Import /
/// Test All in the V2Ray mockup): ember-orange when [primary].
class DesktopActionButton extends StatelessWidget {
  const DesktopActionButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.primary = false,
    this.busy = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool primary;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final color = primary ? Ember.orange : Ember.text;
    return Padding(
      padding: const EdgeInsets.only(left: 9),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: busy ? null : onTap,
          borderRadius: BorderRadius.circular(13),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 10),
            decoration: BoxDecoration(
              border: Border.all(
                color: primary
                    ? Ember.orange.withValues(alpha: 0.75)
                    : Colors.white.withValues(alpha: 0.16),
              ),
              borderRadius: BorderRadius.circular(13),
              color: Colors.white.withValues(alpha: 0.07),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (busy)
                  const SizedBox(
                    width: 17,
                    height: 17,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Ember.orange,
                    ),
                  )
                else
                  Icon(icon, size: 18, color: color),
                const SizedBox(width: 7),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w800,
                    color: color,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The rail's brand mark, as the mockups draw it: a FLAME inside a
/// SHIELD OUTLINE, orange-red gradient, no tile behind it. Painted
/// (not the app icon) so it stays crisp at rail size.
class EmberShieldMark extends StatelessWidget {
  const EmberShieldMark({super.key, this.size = 72});

  final double size;

  @override
  Widget build(BuildContext context) => CustomPaint(
        painter: _ShieldFlamePainter(),
        size: Size(size, size * 1.08),
      );
}

class _ShieldFlamePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / 100;
    final sy = size.height / 108;
    canvas.save();
    canvas.scale(sx, sy);

    const shieldGradient = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [Color(0xFFFFB347), Color(0xFFFF6A1A), Color(0xFFFF4A17)],
      stops: [0, 0.55, 1],
    );
    final unit = Offset.zero & const Size(100, 108);
    final shield = Path()
      ..moveTo(50, 3)
      ..cubicTo(63, 9, 76, 11, 88, 11)
      ..cubicTo(88, 44, 85, 76, 50, 105)
      ..cubicTo(15, 76, 12, 44, 12, 11)
      ..cubicTo(24, 11, 37, 9, 50, 3)
      ..close();
    // A faint warm interior, then the gradient outline.
    canvas.drawPath(
      shield,
      Paint()
        ..style = PaintingStyle.fill
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x2EFF7A18), Color(0x05FF7A18)],
        ).createShader(unit),
    );
    canvas.drawPath(
      shield,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5.2
        ..strokeJoin = StrokeJoin.round
        ..shader = shieldGradient.createShader(unit),
    );

    // The flame: an outer body and a lighter inner tongue.
    final flame = Path()
      ..moveTo(50, 24)
      ..cubicTo(55, 34, 66, 42, 66, 57)
      ..cubicTo(66, 71, 59, 81, 50, 81)
      ..cubicTo(41, 81, 34, 71, 34, 57)
      ..cubicTo(34, 47, 40, 39, 44, 31)
      ..cubicTo(45, 37, 47, 41, 50, 45)
      ..cubicTo(48.5, 37, 48.5, 30, 50, 24)
      ..close();
    canvas.drawPath(
      flame,
      Paint()
        ..style = PaintingStyle.fill
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFFFC46B), Color(0xFFFF7A18), Color(0xFFFF4A17)],
          stops: [0, 0.5, 1],
        ).createShader(unit),
    );
    final inner = Path()
      ..moveTo(50, 52)
      ..cubicTo(53, 57, 58, 61, 58, 68)
      ..cubicTo(58, 74, 54.5, 79, 50, 79)
      ..cubicTo(45.5, 79, 42, 74, 42, 68)
      ..cubicTo(42, 62, 46, 57, 48, 53)
      ..cubicTo(48.6, 56, 49.2, 58, 50, 60)
      ..cubicTo(49.6, 56, 49.6, 53.5, 50, 52)
      ..close();
    canvas.drawPath(
      inner,
      Paint()
        ..style = PaintingStyle.fill
        ..color = const Color(0xFFFFE3B3).withValues(alpha: 0.95),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
