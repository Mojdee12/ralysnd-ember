/// The Map Control building blocks for the phone (Android 2.2.0):
/// the dark glass surfaces, brand panel, engine chips, nav pills,
/// the mobile bottom control bar and the settings controls of the
/// approved mobile samples. Everything floats over the baked
/// dotted world map; nothing here knows about engines — the shell
/// and the pages feed it state. Sibling of the desktop build's
/// map_widgets.dart, re-proportioned for portrait.

import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'ember_theme.dart';
import 'world_map.dart';

/// The baked backdrop alone (base gradient + the offline dot
/// raster), positioned through the shared [MapViewTransform] so
/// the live actors painted with the same transform land exactly
/// on the baked dots. Used as the shell's ground layer and by
/// [EmberBackground] on pushed pages.
class MapBackdropVisual extends StatelessWidget {
  const MapBackdropVisual({super.key});

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final size = constraints.biggest;
      final t = MapViewTransform.of(size);
      return Stack(
        fit: StackFit.expand,
        children: [
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [MapUi.baseTop, MapUi.baseBottom],
              ),
            ),
          ),
          Positioned(
            left: t.offset.dx,
            top: t.offset.dy,
            width: 360 * t.cover,
            height: 180 * t.cover,
            child: Image.asset(
              'assets/backdrop/map_backdrop.png',
              fit: BoxFit.fill,
              filterQuality: FilterQuality.medium,
            ),
          ),
          // A gentle top shade so the brand panel and chips
          // keep their contrast over bright coastlines.
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0x40060B14), Color(0x00060B14)],
                stops: [0, 0.35],
              ),
            ),
          ),
        ],
      );
    },
  );
}

/// A dark glass surface over the map: a navy translucent fill
/// (60–64% over a real backdrop blur, per the samples' glass),
/// a hairline light border with a specular gradient along the
/// top edge, a soft shadow, and (with [rim]) the samples' warm
/// orange rim line. With [luminous] the border becomes the
/// samples' glowing gradient rim (the V2Ray panel, the locations
/// sheet). The blur sits in its own RepaintBoundary so ticking
/// siblings never re-run it.
class MapGlass extends StatelessWidget {
  const MapGlass({
    super.key,
    required this.child,
    this.padding = EdgeInsets.zero,
    this.radius = MapUi.panelRadius,
    this.rim = false,
    this.luminous = false,
    this.glow = false,
    this.borderColor,
    this.tint,
    this.onTap,
    // Build 2074 (audit item 13): repeated list rows pass
    // blur: false — same fill/border/radius, no live
    // BackdropFilter stacked inside the scrolling list.
    this.blur = true,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;

  /// The orange rim line along the top edge (the brand panel and
  /// the bottom bar wear it strongest).
  final bool rim;

  /// The luminous gradient border of the big panels (an orange-
  /// leaning rim light plus a soft outer glow).
  final bool luminous;

  /// The ACTIVE engine chip's treatment: a 1.3 px solid ember
  /// border (#FF8A3D) plus a soft orange outer shadow, on top of
  /// the glass.
  final bool glow;
  final Color? borderColor;

  /// A wash blended into the glass fill (the ACTIVE engine
  /// chip's warm tint, the selected row's glow).
  final Color? tint;
  final VoidCallback? onTap;

  /// Whether the glass blurs what is behind it (see the
  /// constructor note); false renders the identical surface
  /// without the [BackdropFilter].
  final bool blur;

  @override
  Widget build(BuildContext context) {
    final br = BorderRadius.circular(radius);
    var fillTop = MapUi.panelFill;
    var fillBottom = MapUi.panelFillSoft;
    if (tint != null) {
      fillTop = Color.alphaBlend(tint!.withValues(alpha: 0.20), fillTop);
      fillBottom = Color.alphaBlend(tint!.withValues(alpha: 0.12), fillBottom);
    }
    final content = Stack(
      children: [
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: br,
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [fillTop, fillBottom],
              ),
              // Build 2027 — the split-width root cause,
              // found in the render tree: the border used
              // to live on the content Container below,
              // which as a non-positioned Stack child gets
              // LOOSE constraints and shrink-wraps its
              // content. A card whose content was narrower
              // than the card (a profile card's remote
              // line, the Lantern proxies card) drew its
              // border at the CONTENT width (~63%) while
              // this fill spanned the full card — the
              // "inner box" the v5–v7 audits kept seeing.
              // On the fill's decoration the border always
              // spans the card; the content Container
              // remains the Stack's sizer, so shrink-wrap
              // users (chips, the brand panel) are
              // unchanged.
              border: luminous
                  ? null
                  : Border.all(
                      color: glow
                          ? const Color(0xFFFF8A3D)
                          : (borderColor ?? MapUi.line),
                      width: glow ? 1.3 : 1,
                    ),
            ),
          ),
        ),
        Container(padding: padding, child: child),
        // The glass specular: a pale blue-white highlight
        // running the top edge, warming toward the right —
        // the samples' top border gradient.
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: Container(
            height: 1,
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Color(0x007CA2D6),
                  Color(0x6680A7D8),
                  Color(0x40FFB066),
                  Color(0x007CA2D6),
                ],
                stops: [0, 0.35, 0.75, 1],
              ),
            ),
          ),
        ),
        // The luminous gradient ring over the glass edge
        // (the big panels' orange-leaning rim light).
        if (luminous)
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(painter: _LuminousRingPainter(radius)),
            ),
          ),
        if (rim)
          Positioned(
            top: 0,
            left: 26,
            right: 26,
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
    );
    // Build 2074 (audit item 13): blur:false skips the filter
    // only — fill, border and radius are identical.
    final glass = ClipRRect(
      borderRadius: br,
      child: blur
          ? BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
              child: content,
            )
          : content,
    );
    final surface = RepaintBoundary(
      child: Container(
        decoration: BoxDecoration(
          borderRadius: br,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.5),
              blurRadius: 30,
              offset: const Offset(0, 12),
            ),
            if (rim)
              BoxShadow(
                color: Ember.orange.withValues(alpha: 0.14),
                blurRadius: 22,
                spreadRadius: 1,
              ),
            if (luminous)
              BoxShadow(
                color: Ember.orange.withValues(alpha: 0.16),
                blurRadius: 24,
                spreadRadius: 1,
              ),
            if (glow)
              BoxShadow(
                color: const Color(0xFFFF8A3D).withValues(alpha: 0.30),
                blurRadius: 16,
                spreadRadius: 0.5,
              ),
          ],
        ),
        child: glass,
      ),
    );
    if (onTap == null) return surface;
    return Material(
      color: Colors.transparent,
      child: InkWell(onTap: onTap, borderRadius: br, child: surface),
    );
  }
}

/// The luminous gradient ring of the big panels: a 1.1 px
/// orange-leaning stroke drawn OVER the glass edge. (Painting
/// the gradient as a backing box instead would bleed through
/// the translucent fill and wash the whole panel brown.)
class _LuminousRingPainter extends CustomPainter {
  const _LuminousRingPainter(this.radius);

  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xFFFFC38A), Color(0xB3FF8A3D), Color(0x7FE65116)],
      ).createShader(rect);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        rect.deflate(0.55),
        Radius.circular(radius - 0.55),
      ),
      paint,
    );
  }

  @override
  bool shouldRepaint(_LuminousRingPainter oldDelegate) =>
      oldDelegate.radius != radius;
}

/// The brand panel of the samples (top-left): the flame mark in
/// a warm tile, the app name, and the version micro-line.
class MapBrandPanel extends StatelessWidget {
  const MapBrandPanel({super.key, required this.versionLine});

  /// "v2.2.0 • BUILD 2020" — real version strings only.
  final String versionLine;

  @override
  Widget build(BuildContext context) => MapGlass(
    radius: 14,
    rim: true,
    padding: const EdgeInsets.fromLTRB(9, 7, 12, 7),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
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
          child: const Center(child: EmberShieldMark(size: 18)),
        ),
        const SizedBox(width: 8),
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Ralysnd Ember',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: MapUi.text,
                height: 1.15,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              versionLine.toUpperCase(),
              style: const TextStyle(
                // Build 2058 (audit §5 micro-type): 8.5 px in
                // low-contrast slate carried real info — floored
                // at 9.5 px, colour lifted.
                // Build 2074 (audit item 23): floored at 11 px;
                // the colour already sits a step above dim.
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.9,
                color: Color(0xFF93A8BE),
              ),
            ),
          ],
        ),
      ],
    ),
  );
}

/// One engine chip of the top-right stack: status dot, name, and
/// the state tag. The chip IS the navigation: [highlight] (the
/// current engine page) lights the name; [active] (this engine
/// is the connected one) owns EVERYTHING orange on the chip —
/// the glowing border, the warm tint and the ACTIVE tag all
/// follow that one state (2023 polish, Gemini round-3 audit:
/// in 2022 a live-but-unviewed engine's border glowed while its
/// tag stayed dull, and the viewed engine's tag could read
/// ACTIVE beside a slate border).
class MapEngineChip extends StatelessWidget {
  const MapEngineChip({
    super.key,
    required this.name,
    required this.active,
    required this.highlight,
    required this.onTap,
    this.icon,
  });

  final String name;
  final bool active;
  final bool highlight;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final lit = active;
    // Build 2058 (audit §5 shared widgets): the visible chip
    // stays 128×30, but the tap target is 44 dp tall — the
    // outer InkWell owns the tap over the full 44 px box and the
    // glass is centred inside it, so the glass keeps its
    // approved size while a finger lands the navigation.
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          width: 128,
          height: 44,
          child: Center(
            child: MapGlass(
              radius: 10,
              // The live engine's chip glows: a solid ember border and a
              // soft orange shadow around the glass, beside its ACTIVE tag.
              glow: active,
              tint: lit ? Ember.orange : null,
              borderColor: lit
                  ? Ember.orange.withValues(alpha: 0.65)
                  : const Color(0x2E4B6B94),
              child: SizedBox(
                // 2025 (Gemini audit v5, item 2): 106 -> 120 so the
                // longest names ("Mozilla", "Settings") keep their full
                // text beside the ACTIVE pill instead of truncating.
                // 2027 (v7 audit): 120 -> 128 — "OpenVPN" still lost
                // its last letters to the ACTIVE pill at 120.
                width: 128,
                height: 30,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 9),
                  child: Row(
                    children: [
                      if (icon != null) ...[
                        Icon(
                          icon,
                          size: 13,
                          color: highlight ? Ember.orange : MapUi.dim,
                        ),
                        const SizedBox(width: 6),
                      ] else ...[
                        Container(
                          width: 6,
                          height: 6,
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
                                      blurRadius: 5,
                                    ),
                                  ]
                                : const [],
                          ),
                        ),
                        const SizedBox(width: 7),
                      ],
                      Expanded(
                        child: Text(
                          name,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: highlight
                                ? FontWeight.w600
                                : FontWeight.w500,
                            color: highlight
                                ? Ember.orange
                                : const Color(0xFFD9E4F2),
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      // The approved rule (round 3): the ACTIVE pill
                      // belongs to the LIVE engine only; the viewed
                      // engine keeps only its orange name — no IDLE pill.
                      if (active)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            gradient: Ember.gradient,
                            borderRadius: BorderRadius.circular(5),
                          ),
                          child: const Text(
                            'ACTIVE',
                            style: TextStyle(
                              // Build 2058 (audit §5 micro-type):
                              // 7.5 px in low-contrast slate carried
                              // real info — floored at 9.5 px.
                              fontSize: 9.5,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.7,
                              color: Colors.white,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A floating glass nav pill under the brand panel (Locations,
/// Account, Configurations…): an orange icon and a white label.
class MapNavPill extends StatelessWidget {
  const MapNavPill({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  // Build 2074 (audit item 4): the glass keeps its size, but
  // the hit area is at least 48 dp tall — the transparent
  // padding around the glass is part of the InkWell (the
  // MapGlass therefore renders without its own onTap).
  Widget build(BuildContext context) => Material(
    color: Colors.transparent,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(11),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: MapGlass(
          radius: 11,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 15, color: Ember.orange),
              const SizedBox(width: 7),
              Text(
                label,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: MapUi.text,
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
/// (a plain hairline outline for the non-primary kind) — the
/// samples' Import / + Add / Test All / Ping all shape.
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
      padding: const EdgeInsets.only(left: 6),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: busy ? null : onTap,
          borderRadius: BorderRadius.circular(9),
          // Build 2074 (audit item 4): the visible chip keeps
          // its size, but the hit area is at least 48 dp tall —
          // the transparent padding is part of the InkWell.
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 9),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
              decoration: BoxDecoration(
                border: Border.all(
                  color: primary
                      ? Ember.orange.withValues(alpha: 0.8)
                      : MapUi.lineStrong,
                ),
                borderRadius: BorderRadius.circular(9),
                color: Colors.white.withValues(alpha: 0.04),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (busy)
                    const SizedBox(
                      width: 13,
                      height: 13,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Ember.orange,
                      ),
                    )
                  else
                    Icon(icon, size: 13, color: color),
                  const SizedBox(width: 4),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: color,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A compact action pill of the panel header rows (the mobile
/// samples' Import / + Add / Test All): 24 px tall, a 12 px icon
/// and a 10.5 px label. The [primary] kind (+ Add) wears the
/// orange outline and text; the rest are slate.
class MapActionPill extends StatelessWidget {
  const MapActionPill({
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
    final color = primary ? Ember.orange : MapUi.body;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: busy ? null : onTap,
        borderRadius: BorderRadius.circular(8),
        // Build 2058 (audit §5 shared widgets): the visible pill
        // stays 24 px, but the tap target is 44 dp tall — the
        // 10 px of transparent padding above/below the border
        // is part of the InkWell, so a finger lands the action.
        // Build 2074 (audit item 4): padding 10 -> 12, so the
        // hit area reaches the full 48 dp.
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Container(
            height: 24,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              border: Border.all(
                color: primary
                    ? Ember.orange.withValues(alpha: 0.85)
                    : MapUi.lineStrong,
              ),
              borderRadius: BorderRadius.circular(8),
              color: primary
                  ? Ember.orange.withValues(alpha: 0.10)
                  : Colors.white.withValues(alpha: 0.04),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (busy)
                  const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Ember.orange,
                    ),
                  )
                else
                  Icon(icon, size: 12, color: color),
                const SizedBox(width: 4),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 10.5,
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

/// A panel's header row: the title at the left, optional actions,
/// and (with [onClose]) the samples' close ✕ at the right.
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
          // Build 2074 (audit item 4): 48 dp hit area, icon unchanged.
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
        ),
    ],
  );
}

/// The settings panels' knob-less pill toggle (see
/// [EmberToggle], which carries the implementation).
class MapToggle extends StatelessWidget {
  const MapToggle({super.key, required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) =>
      EmberToggle(value: value, onChanged: onChanged);
}

/// A value chip of the settings rows (dns.google / English):
/// a solid orange gradient capsule with dark text and a soft
/// glow — the mobile samples' value pill. In a chip group the
/// unchosen ones ([selected] false) fall back to a dark inset
/// pill; tappable when [onTap] is set.
class MapValueChip extends StatelessWidget {
  const MapValueChip({
    super.key,
    required this.text,
    this.onTap,
    this.selected,
  });

  final String text;
  final VoidCallback? onTap;

  /// In a chip group, the chosen one wears the orange capsule.
  final bool? selected;

  @override
  Widget build(BuildContext context) {
    final lit = selected != false;
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
      decoration: BoxDecoration(
        gradient: lit
            ? const LinearGradient(
                colors: [Color(0xFFFF9E42), Color(0xFFE65116)],
              )
            : null,
        color: lit ? null : MapUi.insetFill,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: lit ? Colors.transparent : MapUi.line),
        boxShadow: lit
            ? [
                BoxShadow(
                  color: Ember.orange.withValues(alpha: 0.30),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ]
            : null,
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
          color: lit ? const Color(0xFF1A1206) : MapUi.dim,
        ),
        overflow: TextOverflow.ellipsis,
      ),
    );
    if (onTap == null) return chip;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: chip,
      ),
    );
  }
}

/// One settings panel: dark glass, a caps slate micro-header,
/// then hairline-separated rows (the mobile samples' cards).
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
    luminous: true,
    padding: const EdgeInsets.fromLTRB(18, 14, 18, 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title.toUpperCase(),
          style: const TextStyle(
            // Build 2074 (audit item 23): colour lifted one step
            // toward dim (size already at the ~11 sp floor).
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.1,
            color: Color(0xFF7E93A8),
          ),
        ),
        const SizedBox(height: 4),
        ...children,
      ],
    ),
  );
}

/// One settings row: label at the left, the control at the
/// right, a hairline under all but the last row.
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
      constraints: const BoxConstraints(minHeight: 50),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
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
                      fontSize: 13.5,
                      fontWeight: FontWeight.w500,
                      color: MapUi.text,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      style: const TextStyle(
                        fontSize: 10,
                        color: MapUi.faint,
                        height: 1.3,
                      ),
                      // Build 2056 (audit Batch 9): the _XraySection
                      // passes long explanations (MTU, Fallback,
                      // Auto-reconnect, DNS group) — one line showed
                      // half-sentences. Three lines keep the row
                      // compact while letting the explanation read.
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
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

/// One cell of the bottom bar's telemetry grid: a caps slate
/// micro-label over a white tabular value.
class MapBarCell extends StatelessWidget {
  const MapBarCell({super.key, required this.label, required this.value});

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
          // Build 2058 (audit §5 micro-type): 8 px in
          // low-contrast slate carried real info — floored at
          // 9.5 px, colour lifted.
          // Build 2074 (audit item 23): floored at 11 px,
          // colour lifted one step to dim.
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.9,
          color: Color(0xFF8FA3BC),
        ),
      ),
      const SizedBox(height: 2),
      Text(
        value,
        style: const TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
          color: MapUi.text,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
        overflow: TextOverflow.ellipsis,
        maxLines: 1,
      ),
    ],
  );
}

/// The mobile bottom control bar: a full-width floating glass
/// pill with the rim light. Inside: the power SWITCH at the left
/// (the mobile samples' compact pill — a recessed track with a
/// bright round thumb and the power glyph — with the state word
/// beside it in the bar's left chamber), a hair divider, and the
/// 2×2 telemetry grid at the right. Under it, right-aligned, the
/// latency/engine micro-line. Only real values ever reach it; a
/// cell without one shows "—".
class MobileMapBar extends StatelessWidget {
  const MobileMapBar({
    super.key,
    required this.on,
    required this.busy,
    required this.onToggle,
    required this.stateWord,
    required this.cells,
    required this.microLine,
  });

  final bool on;
  final bool busy;
  final VoidCallback? onToggle;
  final String stateWord;

  /// 2–4 (label, value) cells, laid out 2 per row.
  final List<({String label, String value})> cells;

  /// "LATENCY 86ms • VLESS" — or just the engine tag when no
  /// latency is truly known.
  final String microLine;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(25),
          gradient: const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0x5580A7D8), Color(0x1A35506E), Color(0x2EE65A1E)],
            stops: [0, 0.45, 1],
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.45),
              blurRadius: 26,
              offset: const Offset(0, 12),
            ),
            BoxShadow(
              color: Ember.orange.withValues(alpha: 0.10),
              blurRadius: 22,
              spreadRadius: 1,
            ),
          ],
        ),
        padding: const EdgeInsets.all(1),
        child: MapGlass(
          radius: 24,
          borderColor: Colors.transparent,
          // Build 2074 (audit item 16): min-height, not a fixed
          // height — at large font scales the cells grow the bar
          // instead of clipping.
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 84),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 14, 0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Flexible(
                    flex: 5,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _PowerSwitch(on: on, busy: busy, onTap: onToggle),
                        const SizedBox(width: 9),
                        Flexible(
                          child: Text(
                            stateWord,
                            style: TextStyle(
                              // 2027 (v7 audit): 12.5 -> 11.5 so the
                              // longest state word, "Connected via
                              // OpenVPN", fits its two lines whole
                              // instead of dropping "OpenVPN".
                              fontSize: 11.5,
                              fontWeight: FontWeight.w700,
                              height: 1.15,
                              color: on ? const Color(0xFFFFA652) : MapUi.dim,
                            ),
                            maxLines: 2,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    width: 1,
                    height: 46,
                    margin: const EdgeInsets.symmetric(horizontal: 11),
                    color: const Color(0xFF1E3147),
                  ),
                  Expanded(flex: 6, child: _CellGrid(cells: cells)),
                ],
              ),
            ),
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.only(top: 5, right: 8),
        child: Text(
          microLine,
          textAlign: TextAlign.right,
          style: const TextStyle(
            // Build 2058 (audit §5 micro-type): 8 px floored at
            // 9.5 px, colour lifted.
            fontSize: 9.5,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.8,
            color: Color(0xFF7E93A8),
          ),
        ),
      ),
    ],
  );
}

class _CellGrid extends StatelessWidget {
  const _CellGrid({required this.cells});
  final List<({String label, String value})> cells;

  @override
  Widget build(BuildContext context) {
    Widget rowOf(List<({String label, String value})> row) => Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < row.length; i++) ...[
          if (i > 0)
            Container(
              width: 1,
              height: 26,
              margin: const EdgeInsets.symmetric(horizontal: 9),
              color: Colors.white.withValues(alpha: 0.06),
            ),
          Expanded(
            child: MapBarCell(label: row[i].label, value: row[i].value),
          ),
        ],
      ],
    );
    if (cells.length <= 2) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [Expanded(child: rowOf(cells))],
      );
    }
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        rowOf(cells.sublist(0, 2)),
        const SizedBox(height: 5),
        Container(height: 1, color: Colors.white.withValues(alpha: 0.05)),
        const SizedBox(height: 5),
        rowOf(cells.sublist(2)),
      ],
    );
  }
}

/// The bar's power switch, the mobile samples' shape: a compact
/// pill track — an orange gradient with a glow when ON, a dark
/// recessed slate when OFF — holding a bright round thumb at its
/// left end and the power glyph beside it. The state word lives
/// outside the track, in the bar's left chamber (see
/// [MobileMapBar]).
class _PowerSwitch extends StatelessWidget {
  const _PowerSwitch({
    required this.on,
    required this.busy,
    required this.onTap,
  });

  final bool on;
  final bool busy;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.transparent,
    child: InkWell(
      onTap: busy ? null : onTap,
      borderRadius: BorderRadius.circular(999),
      // Build 2058 (audit §5 shared widgets): the visible
      // track stays 56×30, but the tap target is 44 dp tall —
      // the 7 px of transparent padding above/below the track
      // is part of the InkWell.
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Container(
          width: 56,
          height: 30,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            gradient: on
                ? const LinearGradient(
                    colors: [Color(0xFFFF9E42), Color(0xFFE65116)],
                  )
                : null,
            color: on ? null : const Color(0xFF16222F),
            border: Border.all(
              color: on
                  ? const Color(0xFFFFB066).withValues(alpha: 0.5)
                  : const Color(0x2E4B6B94),
            ),
            boxShadow: on
                ? [
                    BoxShadow(
                      color: const Color(0xFFE65116).withValues(alpha: 0.35),
                      blurRadius: 10,
                      offset: const Offset(0, 2),
                    ),
                  ]
                : null,
          ),
          child: Row(
            children: [
              const SizedBox(width: 3),
              Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  // OFF: a bright silver thumb (2024, Gemini
                  // audit v4 — the old slate 0xFF54687F read as
                  // switched-off hardware, not a control).
                  gradient: on
                      ? const RadialGradient(
                          center: Alignment(-0.3, -0.4),
                          colors: [Color(0xFFFFD9A0), Color(0xFFFF8A3D)],
                        )
                      : const RadialGradient(
                          center: Alignment(-0.3, -0.4),
                          colors: [Color(0xFFC3D2E2), Color(0xFFA6B6C7)],
                        ),
                  color: null,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.30),
                      blurRadius: 3,
                      offset: const Offset(0, 1),
                    ),
                  ],
                ),
              ),
              const Spacer(),
              if (busy)
                const SizedBox(
                  width: 13,
                  height: 13,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              else
                Icon(
                  Icons.power_settings_new_rounded,
                  size: 14,
                  color: on ? Colors.white : const Color(0xFF54687F),
                ),
              const SizedBox(width: 7),
            ],
          ),
        ),
      ),
    ),
  );
}

/// The brand mark: a FLAME inside a SHIELD OUTLINE, orange-red
/// gradient, no tile behind it. Painted (not the app icon) so it
/// stays crisp at panel size. (Ported unchanged from the desktop
/// build — the logo itself was never the problem.)
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
