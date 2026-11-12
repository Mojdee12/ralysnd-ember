/// The Map Control building blocks (2.1.0): the dark glass
/// surfaces, brand panel, engine chips, bottom control bar and
/// settings controls of the approved desktop samples. Everything
/// here floats over the shell's dotted world map; nothing in this
/// file knows about engines — the shell and pages feed it state.

import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'ember_theme.dart';

/// A dark glass surface over the map: a navy translucent fill
/// over a real backdrop blur, a hairline light border, a soft
/// shadow, and (with [rim]) the samples' warm orange rim line.
/// The blur sits in its own RepaintBoundary so ticking siblings
/// never re-run it.
class MapGlass extends StatelessWidget {
  const MapGlass({
    super.key,
    required this.child,
    this.padding = EdgeInsets.zero,
    this.radius = MapUi.panelRadius,
    this.rim = false,
    this.borderColor,
    this.tint,
    this.onTap,
    this.luminous = false,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;

  /// The orange rim line along the top edge (the brand panel and
  /// the bottom bar wear it strongest).
  final bool rim;
  final Color? borderColor;

  /// A wash blended into the glass fill (the ACTIVE engine
  /// chip's warm tint).
  final Color? tint;
  final VoidCallback? onTap;

  /// The luminous treatment the mobile Map Control panels use
  /// (build 2032 pages): the border becomes the ember-orange
  /// rim and the glass carries the rim's glow. Added by the
  /// 2.2.0 parity port so the ported pages keep their look on
  /// the desktop glass.
  final bool luminous;

  @override
  Widget build(BuildContext context) {
    final br = BorderRadius.circular(radius);
    var fillTop = const Color(0x2E1C2C47);
    var fillBottom = const Color(0x24122030);
    if (tint != null) {
      fillTop = Color.alphaBlend(tint!.withValues(alpha: 0.20), fillTop);
      fillBottom = Color.alphaBlend(tint!.withValues(alpha: 0.12), fillBottom);
    }
    final surface = RepaintBoundary(
      child: Container(
        decoration: BoxDecoration(
          borderRadius: br,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.5),
              blurRadius: 36,
              offset: const Offset(0, 16),
            ),
            if (rim || luminous)
              BoxShadow(
                color: Ember.orange.withValues(alpha: luminous ? 0.22 : 0.14),
                blurRadius: 24,
                spreadRadius: 1,
              ),
          ],
        ),
        child: ClipRRect(
          borderRadius: br,
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: Stack(
              children: [
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [fillTop, fillBottom],
                      ),
                    ),
                  ),
                ),
                Container(
                  padding: padding,
                  decoration: BoxDecoration(
                    borderRadius: br,
                    border: Border.all(
                      color:
                          borderColor ??
                          (luminous
                              ? Ember.orange.withValues(alpha: 0.45)
                              : MapUi.line),
                    ),
                  ),
                  child: child,
                ),
                // The glass specular: a pale blue-white highlight
                // along the top edge, fading right and down —
                // the samples' double-layered edge light.
                Positioned(
                  top: 0,
                  left: radius,
                  right: radius * 0.4,
                  child: Container(
                    height: 1,
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        colors: [Color(0x5580A7D8), Color(0x0A2B4263)],
                      ),
                    ),
                  ),
                ),
                if (rim)
                  Positioned(
                    top: 0,
                    left: 30,
                    right: 30,
                    child: Container(
                      height: 1.6,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            Ember.orange.withValues(alpha: 0.05),
                            Ember.orange.withValues(alpha: 0.85),
                            Ember.orange.withValues(alpha: 0.85),
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
      child: InkWell(onTap: onTap, borderRadius: br, child: surface),
    );
  }
}

/// The brand panel of the samples (top-left): the flame mark,
/// the app name, and the version micro-line, over dark glass
/// with a subtle orange bottom glow.
class MapBrandPanel extends StatelessWidget {
  const MapBrandPanel({super.key, required this.versionLine});

  /// "v2.1.0 • BUILD 2026" — real version strings only.
  final String versionLine;

  @override
  Widget build(BuildContext context) => MapGlass(
    radius: 18,
    padding: const EdgeInsets.fromLTRB(14, 10, 20, 10),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // The samples' lockup: the flame mark inside a rounded
        // warm tile.
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Ember.orange.withValues(alpha: 0.24),
                Ember.orange.withValues(alpha: 0.08),
              ],
            ),
            border: Border.all(color: Ember.orange.withValues(alpha: 0.35)),
          ),
          child: const Center(child: EmberShieldMark(size: 26)),
        ),
        const SizedBox(width: 12),
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Ralysnd Ember',
              style: TextStyle(
                fontSize: 16.5,
                fontWeight: FontWeight.w600,
                color: MapUi.text,
                height: 1.15,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              versionLine.toUpperCase(),
              style: TextStyle(
                fontSize: 9.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.1,
                color: Ember.orange.withValues(alpha: 0.75),
              ),
            ),
          ],
        ),
      ],
    ),
  );
}

/// One engine chip of the top-right stack: status dot, name,
/// and the state tag. The chip IS the navigation: [highlight]
/// (the current page, or the connected engine) lights the orange
/// glow border and the orange name; [active] (this engine is the
/// connected one) fills the tag orange and reads ACTIVE.
class MapEngineChip extends StatelessWidget {
  const MapEngineChip({
    super.key,
    required this.name,
    required this.active,
    required this.highlight,
    required this.onTap,
  });

  final String name;
  final bool active;
  final bool highlight;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // The full ACTIVE treatment (tint, glowing border, gradient
    // tag) belongs to the chip that is BOTH the current page and
    // the connected engine; a background-connected engine shows
    // its truth in the orange dot alone.
    final lit = active && highlight;
    return MapGlass(
      radius: 14,
      onTap: onTap,
      tint: lit ? Ember.orange : null,
      borderColor: lit
          ? Ember.orange.withValues(alpha: 0.65)
          : const Color(0x2E4B6B94),
      // The size lives INSIDE the glass (see MapSettingsChip).
      child: SizedBox(
        width: 200,
        height: 52,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: active
                      ? const Color(0xFFFFA04A)
                      : const Color(0xFF54687F),
                  shape: BoxShape.circle,
                  boxShadow: active
                      ? [
                          BoxShadow(
                            color: const Color(0xFFFFA04A)
                                .withValues(alpha: 0.7),
                            blurRadius: 6,
                          ),
                        ]
                      : const [],
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  name,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: lit ? FontWeight.w600 : FontWeight.w500,
                    color: lit ? Ember.orange : const Color(0xFFD9E4F2),
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  gradient: lit ? Ember.gradient : null,
                  color: lit ? null : Colors.white.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  lit ? 'ACTIVE' : 'IDLE',
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.8,
                    color: lit ? Colors.white : MapUi.faint,
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

/// The compact Settings chip under the engine stack (gear +
/// "Settings"); ACTIVE while the settings page is open.
class MapSettingsChip extends StatelessWidget {
  const MapSettingsChip({
    super.key,
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => MapGlass(
    radius: 14,
    onTap: onTap,
    tint: active ? Ember.orange : null,
    borderColor: active
        ? Ember.orange.withValues(alpha: 0.65)
        : const Color(0x2E4B6B94),
    // The size lives INSIDE the glass: the glass wraps its
    // content, so a fixed height imposed outside it would
    // leave the border hugging the content row instead of
    // the chip's full box.
    child: SizedBox(
      width: 200,
      height: 44,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Row(
          children: [
            Icon(
              Icons.settings_rounded,
              size: 18,
              color: active ? Ember.orange : MapUi.dim,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                  color: active ? Ember.orange : const Color(0xFFD9E4F2),
                ),
              ),
            ),
            if (active)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  gradient: Ember.gradient,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Text(
                  'ACTIVE',
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.8,
                    color: Colors.white,
                  ),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

/// The bottom bar's power toggle: a 52 px circle — the ember
/// gradient with a dark glyph while ON, a muted grey-orange disc
/// while OFF; a spinner while the engine is between states.
class MapPowerToggle extends StatelessWidget {
  const MapPowerToggle({
    super.key,
    required this.on,
    required this.busy,
    required this.onTap,
  });

  final bool on;
  final bool busy;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: busy ? null : onTap,
    child: Container(
      width: 52,
      height: 52,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: on ? Ember.gradient : null,
        color: on ? null : const Color(0xFF2C3A4E),
        border: Border.all(
          color: on ? Colors.transparent : Ember.orange.withValues(alpha: 0.35),
        ),
        boxShadow: on
            ? [
                BoxShadow(
                  color: Ember.orange.withValues(alpha: 0.45),
                  blurRadius: 18,
                  spreadRadius: 1,
                ),
              ]
            : const [],
      ),
      child: busy
          ? const Padding(
              padding: EdgeInsets.all(14),
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                color: Ember.orange,
              ),
            )
          : Icon(
              Icons.power_settings_new_rounded,
              size: 26,
              color: on
                  ? const Color(0xFF1A1206)
                  : Ember.orange.withValues(alpha: 0.75),
            ),
    ),
  );
}

/// One divider-separated segment of the bottom bar: a caps
/// grey micro-label (8.5–9.5 px, w700, wide tracking) over a
/// white w600 tabular value.
class MapBarSegment extends StatelessWidget {
  const MapBarSegment({super.key, required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label.toUpperCase(),
        style: const TextStyle(
          fontSize: 9.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.1,
          color: Color(0xFF5A6F87),
        ),
      ),
      const SizedBox(height: 3),
      Text(
        value,
        style: const TextStyle(
          fontSize: 15.5,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
          color: MapUi.text,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
        overflow: TextOverflow.ellipsis,
        maxLines: 1,
      ),
    ],
  );
}

/// The signature bottom control bar: one wide floating glass
/// pill under a gradient rim (cool specular at the top, warm
/// ember at the bottom). Inside: the power CAPSULE anchors the
/// left — a gradient pill housing the round thumb and the state
/// word — then divider-separated segments distributed with
/// EQUAL flex across the full width (no crowding, no dead
/// space, no truncated values), and the latency/engine
/// micro-line overlaid at the bottom-right corner. Only real
/// values ever reach it; a segment without one shows "—" or is
/// omitted by the caller.
class MapBottomBar extends StatelessWidget {
  const MapBottomBar({
    super.key,
    required this.on,
    required this.busy,
    required this.onToggle,
    required this.stateWord,
    required this.segments,
    required this.microLine,
  });

  final bool on;
  final bool busy;
  final VoidCallback? onToggle;
  final String stateWord;
  final List<({String label, String value, int flex})> segments;

  /// "LATENCY 86ms • VLESS" — or just the engine tag when no
  /// latency is truly known.
  final String microLine;

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(45),
      // The rim light of the samples: a cool glass gradient —
      // pale specular at the top edge, deep slate through the
      // body, and only a whisper of warm ember at the bottom
      // (an earlier build let the ember stop wash the bar's
      // whole lower half brown through the translucent glass).
      gradient: const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0x5580A7D8), Color(0x1A35506E), Color(0x2EE65A1E)],
        stops: [0, 0.45, 1],
      ),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.45),
          blurRadius: 30,
          offset: const Offset(0, 14),
        ),
        BoxShadow(
          color: Ember.orange.withValues(alpha: 0.10),
          blurRadius: 26,
          spreadRadius: 1,
        ),
      ],
    ),
    padding: const EdgeInsets.all(1),
    child: MapGlass(
      radius: 44,
      borderColor: Colors.transparent,
      child: SizedBox(
        height: 88,
        child: Stack(
          children: [
            Positioned.fill(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 20, 0),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    _PowerCapsule(
                      on: on,
                      busy: busy,
                      stateWord: stateWord,
                      onTap: onToggle,
                    ),
                    for (final s in segments) ...[
                      Container(
                        width: 1,
                        height: 34,
                        margin: const EdgeInsets.symmetric(horizontal: 13),
                        color: Colors.white.withValues(alpha: 0.07),
                      ),
                      Expanded(
                        flex: s.flex,
                        child: MapBarSegment(label: s.label, value: s.value),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            Positioned(
              right: 28,
              bottom: 10,
              child: Text(
                microLine,
                style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.1,
                  color: MapUi.faint.withValues(alpha: 0.9),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// The bar's power capsule: the samples' connect control — a
/// recessed dark TRACK (deep base, hairline ember rim, capsule-
/// shaped ambient glow) holding a raised gradient pill whose
/// left end carries an embossed radial thumb disc with the
/// power glyph; the state word sits in white beside the thumb.
/// OFF is the same capsule gone quiet: dark track, flat inner
/// pill, grey thumb, dim word.
class _PowerCapsule extends StatelessWidget {
  const _PowerCapsule({
    required this.on,
    required this.busy,
    required this.stateWord,
    required this.onTap,
  });

  final bool on;
  final bool busy;
  final String stateWord;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.transparent,
    child: InkWell(
      onTap: busy ? null : onTap,
      borderRadius: BorderRadius.circular(23),
      child: Container(
        height: 46,
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(23),
          color: on ? const Color(0xFF1A110B) : const Color(0xFF101A29),
          border: Border.all(
            color: on
                ? Ember.orange.withValues(alpha: 0.4)
                : Colors.white.withValues(alpha: 0.10),
          ),
          boxShadow: on
              ? [
                  const BoxShadow(
                    color: Color(0x55E65A1E),
                    blurRadius: 18,
                    offset: Offset(0, 3),
                  ),
                ]
              : const [],
        ),
        child: Container(
          padding: const EdgeInsets.only(right: 15),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(19),
            gradient: on
                ? const LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0xFFFF8533), Color(0xFFE24A0D)],
                  )
                : null,
            color: on ? null : Colors.white.withValues(alpha: 0.04),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: on
                      ? const RadialGradient(
                          center: Alignment(-0.3, -0.4),
                          colors: [Color(0xFFFFA85C), Color(0xFFE04B0A)],
                        )
                      : null,
                  color: on ? null : const Color(0xFF22314A),
                  border: Border.all(
                    color: on
                        ? Colors.white.withValues(alpha: 0.22)
                        : Colors.white.withValues(alpha: 0.10),
                  ),
                  boxShadow: on
                      ? [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.30),
                            blurRadius: 4,
                            offset: const Offset(0, 2),
                          ),
                        ]
                      : const [],
                ),
                child: busy
                    ? const Padding(
                        padding: EdgeInsets.all(9),
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : Icon(
                        Icons.power_settings_new_rounded,
                        size: 17,
                        color: on
                            ? Colors.white
                            : Ember.orange.withValues(alpha: 0.8),
                      ),
              ),
              const SizedBox(width: 9),
              Text(
                stateWord,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                  color: on ? Colors.white : MapUi.dim,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// A ghost button of the panel headers: an orange-outline chip
/// (a plain hairline outline for the non-primary kind), the
/// samples' Import / Add / Test All / Ping all shape.
class MapGhostButton extends StatelessWidget {
  const MapGhostButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.primary = true,
    this.busy = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool primary;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final color = primary ? Ember.orange : MapUi.dim;
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: busy ? null : onTap,
          borderRadius: BorderRadius.circular(11),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
            decoration: BoxDecoration(
              border: Border.all(
                color: primary
                    ? Ember.orange.withValues(alpha: 0.8)
                    : MapUi.lineStrong,
              ),
              borderRadius: BorderRadius.circular(11),
              color: Colors.white.withValues(alpha: 0.04),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (busy)
                  const SizedBox(
                    width: 15,
                    height: 15,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Ember.orange,
                    ),
                  )
                else
                  Icon(icon, size: 15, color: color),
                const SizedBox(width: 5),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
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

/// The settings panels' knob-less pill toggle: ON is a solid
/// orange pill with the ON micro-text, OFF a grey pill — the
/// samples' switch, with no knob.
class MapToggle extends StatelessWidget {
  const MapToggle({super.key, required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onChanged == null ? null : () => onChanged!(!value),
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      width: 48,
      height: 24,
      alignment: value ? Alignment.centerRight : Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 7),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: value ? Ember.orange : const Color(0xFF3A4657),
      ),
      child: Text(
        value ? 'ON' : 'OFF',
        style: TextStyle(
          fontSize: 8.5,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.6,
          color: value ? const Color(0xFF1A1206) : MapUi.faint,
        ),
      ),
    ),
  );
}

/// A value chip of the settings rows (TUN / H2 / 10808): dark
/// inset pill, orange text; tappable when [onTap] is set.
class MapValueChip extends StatelessWidget {
  const MapValueChip({
    super.key,
    required this.text,
    this.onTap,
    this.selected,
  });

  final String text;
  final VoidCallback? onTap;

  /// In a chip group, the chosen one wears the orange border.
  final bool? selected;

  @override
  Widget build(BuildContext context) {
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: MapUi.insetFill,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(
          color: selected == true
              ? Ember.orange.withValues(alpha: 0.85)
              : MapUi.line,
        ),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: selected == false ? MapUi.dim : Ember.orange,
        ),
      ),
    );
    if (onTap == null) return chip;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(9),
        child: chip,
      ),
    );
  }
}

/// One settings panel of the floating settings area: dark glass,
/// a 20 px title, then hairline-separated rows.
class MapSettingsPanel extends StatelessWidget {
  const MapSettingsPanel({
    super.key,
    required this.title,
    required this.children,
  });

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => MapGlass(
    padding: const EdgeInsets.fromLTRB(22, 18, 22, 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w600,
            color: MapUi.text,
          ),
        ),
        const SizedBox(height: 6),
        ...children,
      ],
    ),
  );
}

/// One settings row: label (15 px white) + optional subtitle at
/// the left, the control at the right, a hairline under all but
/// the last row.
class MapSettingRow extends StatelessWidget {
  const MapSettingRow({
    super.key,
    required this.label,
    this.subtitle,
    required this.trailing,
    this.onTap,
    this.divider = true,
  });

  final String label;
  final String? subtitle;
  final Widget trailing;
  final VoidCallback? onTap;
  final bool divider;

  @override
  Widget build(BuildContext context) {
    final row = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 56),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: MapUi.text,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      style: const TextStyle(
                        fontSize: 12,
                        color: MapUi.faint,
                        height: 1.3,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 12),
            trailing,
          ],
        ),
      ),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (onTap == null)
          row
        else
          InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(10),
            child: row,
          ),
        if (divider) const Divider(color: MapUi.line, height: 1, thickness: 1),
      ],
    );
  }
}

/// The brand mark: a FLAME inside a SHIELD OUTLINE, orange-red
/// gradient, no tile behind it. Painted (not the app icon) so it
/// stays crisp at panel size. (Ported unchanged from the old
/// desktop widgets — the logo itself was never the problem.)
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

/// A panel's header row: the title at the left, optional actions,
/// and (with [onClose]) the samples' close ✕ at the right.
/// (From the mobile Map Control widgets, build 2032 — the ported
/// engine pages (OpenVPN, WireGuard, Aether) head their panels
/// with it; styled with the desktop MapUi palette here.)
class MapPanelHeader extends StatelessWidget {
  const MapPanelHeader({
    super.key,
    required this.title,
    this.actions = const [],
    this.onClose,
  });

  final String title;
  final List<Widget> actions;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Text(
          title,
          style: const TextStyle(
            fontSize: 15.5,
            fontWeight: FontWeight.w700,
            color: MapUi.text,
            letterSpacing: 0.3,
          ),
          overflow: TextOverflow.ellipsis,
        ),
      ),
      ...actions,
      if (onClose != null)
        IconButton(
          onPressed: onClose,
          icon: const Icon(Icons.close_rounded, size: 19),
          color: MapUi.dim,
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.only(left: 4),
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
        ),
    ],
  );
}
