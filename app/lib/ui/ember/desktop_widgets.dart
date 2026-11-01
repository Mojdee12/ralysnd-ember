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
  });

  final String title;
  final String subtitle;
  final List<Widget> actions;

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
                  style: const TextStyle(
                    fontSize: 27,
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

/// The wide toggle pill of the mockups' connection cards: gradient
/// orange with its knob at the left while connected, a dark pill
/// with the knob at the right while off. One tap toggles.
class DesktopTogglePill extends StatelessWidget {
  const DesktopTogglePill({
    super.key,
    required this.on,
    required this.busy,
    required this.onLabel,
    required this.offLabel,
    required this.onTap,
  });

  final bool on;
  final bool busy;
  final String onLabel;
  final String offLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: busy ? null : onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          height: 52,
          padding: const EdgeInsets.symmetric(horizontal: 7),
          decoration: BoxDecoration(
            gradient: on ? Ember.gradient : null,
            color: on ? null : Ember.cardSoft,
            borderRadius: BorderRadius.circular(999),
            border: on
                ? null
                : Border.all(color: Ember.orange.withValues(alpha: 0.4)),
            boxShadow: on
                ? [
                    BoxShadow(
                      color: Ember.orange.withValues(alpha: 0.35),
                      blurRadius: 16,
                      spreadRadius: 1,
                    ),
                  ]
                : const [],
          ),
          child: Row(
            children: [
              if (on) _knob(dark: true),
              Expanded(
                child: Text(
                  busy
                      ? '…'
                      : on
                          ? onLabel
                          : offLabel,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 15.5,
                    fontWeight: FontWeight.w800,
                    color: on ? const Color(0xFF1A1206) : Ember.text,
                  ),
                ),
              ),
              if (!on) _knob(dark: false),
            ],
          ),
        ),
      ),
    );
  }

  Widget _knob({required bool dark}) => Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: dark ? const Color(0xFFFFD9A8) : Ember.orange,
          shape: BoxShape.circle,
        ),
        child: Icon(
          Icons.power_settings_new_rounded,
          size: 20,
          color: dark ? const Color(0xFF7A3A00) : const Color(0xFF1A1206),
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
    final color = pingColor(ms);
    return SizedBox(
      width: 88,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 5),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.18),
          border: Border.all(color: color.withValues(alpha: 0.5)),
          borderRadius: BorderRadius.circular(999),
        ),
        alignment: Alignment.center,
        child: Text(
          '${latDigits(ms)} $unit',
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w800,
            color: color,
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
                    : Ember.line,
              ),
              borderRadius: BorderRadius.circular(13),
              color: Ember.card.withValues(alpha: 0.6),
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
