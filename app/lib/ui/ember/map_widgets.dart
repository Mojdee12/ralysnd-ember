/// The Map Control building blocks for the phone (Android 2.2.0):
/// the dark glass surfaces, brand panel, engine chips, nav pills,
/// the mobile bottom control bar and the settings controls of the
/// approved mobile samples. Everything floats over the baked
/// dotted world map; nothing here knows about engines — the shell
/// and the pages feed it state. Sibling of the desktop build's
/// map_widgets.dart, re-proportioned for portrait.

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/android_core.dart';
import 'ember_theme.dart';
import 'world_map.dart';

/// The baked backdrop alone (base gradient + the offline dot
/// raster), positioned through the shared [MapViewTransform] so
/// the live actors painted with the same transform land exactly
/// on the baked dots. Used as the shell's ground layer and by
/// [EmberBackground] on pushed pages.
class MapBackdropVisual extends StatelessWidget {
  const MapBackdropVisual({
    super.key,
    this.banded = false,
    this.faint = false,
    this.bandShort = false,
  });

  /// Build 2147 (strict-audit F1): the Settings variant —
  /// a shorter, fainter band than [banded]: the scrim
  /// settles earlier and never quite reaches full opacity,
  /// so the settings rows ground quickly under a whisper
  /// of map.
  final bool bandShort;

  /// Build 2145 (UI-review fix A3): on text-heavy surfaces the
  /// map reads only as a faint TOP BAND — a scrim settles the
  /// dot field to plain near-black below the band, the way the
  /// approved pro6 settings sample grounds its rows. The map
  /// compositions (the Mozilla / V2Ray homes) keep banded off.
  final bool banded;

  /// Home fidelity round R1 (owner order 2026-11-23): the
  /// approved pro3 home sample's map is a FINE, FAINT halftone
  /// — the baked raster read at full strength renders coarse
  /// and loud behind the hero. On the Home tab a scrim settles
  /// the whole field (deepest toward the bottom, where the
  /// hero type sits) so the dots read as the sample's quiet
  /// texture while the live actors stay lit above it.
  final bool faint;

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
              // Build 2116 (B12-1/AP-03): the backdrop is a
              // WebP now (was a 10.4 MB 4680px PNG decoded at
              // full size on every page — ≈44 MB of RGBA for
              // a 360×180-unit field).
              // Build 2118 (appearance fix round): the 2116
              // asset was 2048px wide (5.7 px/unit) decoded at
              // cacheWidth 1440 (4 px/unit), while the portrait
              // cover transform displays ~9.4 px/unit on the
              // golden surface and ~13.3 on a 1080p phone —
              // the dots upscaled 2×+ and read as coarse
              // blocks. The asset is 3200px now (8.9 px/unit,
              // re-baked with finer, greyer dots) and the
              // decode cap rises to 2880 to match.
              // Batch 2 (fidelity rollout, owner order
              // 2026-11-23): the HOME variant of the field —
              // the same geography and projection baked on a
              // 0.5-unit lattice with a smaller core and a
              // warm taupe palette (tool/bake_backdrop_home.py),
              // so under the faint scrim the Home backdrop
              // reads as the pro3 sample's fine halftone
              // instead of the shared bake's coarser grain.
              // [faint] is only ever true on the shell's Home
              // tab, so every other backdrop keeps the shared
              // asset byte-for-byte.
              faint
                  ? 'assets/backdrop/map_backdrop_home.webp'
                  : 'assets/backdrop/map_backdrop.webp',
              fit: BoxFit.fill,
              filterQuality: FilterQuality.medium,
              cacheWidth: 2880,
            ),
          ),
          // A gentle top shade so the brand panel and chips
          // keep their contrast over bright coastlines.
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0x40000000), Color(0x00000000)],
                stops: [0, 0.35],
              ),
            ),
          ),
          // Build 2145 (UI-review fix A3): the banded scrim —
          // the dot field stays at full strength only in the
          // top band, then settles through a soft ramp to the
          // plain base color, so body text and rows below sit
          // on near-black, not on texture.
          if (banded)
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color(0x00000000),
                    Color(0x00000000),
                    Color(0xF2050607),
                    Color(0xFF050607),
                  ],
                  stops: [0, 0.20, 0.42, 0.60],
                ),
              ),
            ),
          // Build 2147 (strict-audit F1): the short band.
          if (bandShort)
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color(0x00000000),
                    Color(0x00000000),
                    Color(0xD9050607),
                    Color(0xE6050607),
                  ],
                  stops: [0, 0.10, 0.24, 0.38],
                ),
              ),
            ),
          // R1: the faint-home scrim (see [faint]).
          // R2: one notch stronger at every stop — the R1
          // renders still read slightly louder than the
          // samples' halftone. [faint] is only ever true on
          // the shell's Home tab, so no other backdrop moves.
          // Batch 2 (owner's halftone note on the accepted
          // R2): the ramp steepens below the map band — the
          // top eases a touch (0x7A) so the fine halftone of
          // the Home bake still reads where the arc flies,
          // and the lower stops deepen hard (0xC2 / 0xE6) so
          // the field dissolves under the hero the way the
          // pro3 sample's does, instead of showing through it.
          if (faint)
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color(0x7A050607),
                    Color(0x90050607),
                    Color(0xC2050607),
                    Color(0xE6050607),
                  ],
                  stops: [0, 0.32, 0.64, 1],
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
/// Build 2092 (UI audit 2026-11-16 items 39, 59): the
/// engine-home top spacer, derived from the page's OWN
/// viewport height (the home ListView's LayoutBuilder
/// constraints) — not the full device height. The old
/// device-height figure ignored the ≈348 dp chip header and
/// ≈120 dp bottom bar, so the spacer ate roughly half the
/// visible page and pushed the first card toward the fold.
/// R1 (pro3/pro5 home): the chip header is GONE from the
/// Home tab and the samples compose a tall quiet map band
/// above the hero — the fraction rises to 0.36, capped at
/// 260 dp, so the hero block lands in the page's lower half
/// like the samples instead of crowding the pin zone.
double emberHomeTopGap(double pageHeight) =>
    (pageHeight * 0.36).clamp(0.0, 260.0);

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
                  Color(0x00FFFFFF),
                  Color(0x4DFFFFFF),
                  Color(0x40FFB066),
                  Color(0x00FFFFFF),
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
              // Build 2119 (audit F-14): the luminous
              // shadow softens with the ring (0.16/24 ->
              // 0.12/20).
              BoxShadow(
                color: Ember.orange.withValues(alpha: 0.12),
                blurRadius: 20,
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

/// One frosted-glass backdrop for a whole scrolling list
/// (build 2095, owner-reported appearance fix —
/// screenshots Screenshot_2026-11-17-04-46-05-797 (the
/// model: the V2Ray header panel on its blurred glass) and
/// Screenshot_2026-11-17-04-46-01-557 (the problem: the
/// config rows below it rendering almost directly on the
/// dotted map, names and subtitles hard to read)).
///
/// The header panels read clearly because MapGlass blurs
/// what is behind them (sigma 10) under the panel fill.
/// The list rows cannot each carry that blur — a live
/// BackdropFilter per row in a scrolling list is the
/// standing jank source (builds 2074/2092) — so the list
/// region gets ONE backdrop filter behind the whole
/// scroll view instead: the map behind the rows is frosted
/// once, the rows keep their own fills and borders on top,
/// and scrolling never re-runs the filter (the backdrop
/// under these tabs is static). Blur only, no tint: each
/// surface above keeps exactly the colours it had.
class MapListFrost extends StatelessWidget {
  const MapListFrost({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: ClipRect(
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
              child: const SizedBox.expand(),
            ),
          ),
        ),
        child,
      ],
    );
  }
}

/// The luminous gradient ring of the big panels: a 1.1 px
/// orange-leaning stroke drawn OVER the glass edge. (Painting
/// the gradient as a backing box instead would bleed through
/// the translucent fill and wash the whole panel brown.)
/// Build 2119 (audit F-14): the stroke alphas soften one
/// notch — at the 2118 weights the rim read as a lit frame
/// around every panel rather than a rim-light.
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
        colors: [Color(0xD9FFC38A), Color(0x99FF8A3D), Color(0x66FF7A29)],
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
    // Build 2121 (owner device verdict 2026-11-19 21:57):
    // the 2118 enlargement of this panel (luminous rim,
    // tile 34, title 15, more air) is REVERTED — on the
    // owner's phone the badge read too big and reached
    // into the middle of the screen. Back to the pre-2118
    // compact footprint (tile 30, title 13); the restored
    // panel's measured full-text width is ~177 dp in
    // Roboto (the version line governs at 117.6 dp).
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
        // Build 2092 (UI audit item 36): the text column flexes
        // and ellipsises — at 320 dp / large font the panel's
        // fixed intrinsic width overflowed the header Row.
        Flexible(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Ralysnd Ember',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: Ember.fontBody,
                  fontWeight: FontWeight.w600,
                  color: MapUi.text,
                  height: 1.15,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                versionLine.toUpperCase(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                // Build 2058 (audit §5 micro-type): 8.5 px in
                // low-contrast slate carried real info — floored
                // at 9.5 px, colour lifted.
                // Build 2074 (audit item 23): floored at 11 px;
                // the colour already sits a step above dim.
                fontSize: Ember.fontMicro,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.9,
                  color: Color(0xFFA8A8AE),
                ),
              ),
            ],
          ),
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
    this.connecting = false,
  });

  final String name;
  final bool active;
  final bool highlight;
  final VoidCallback onTap;
  final IconData? icon;

  /// Build 2092 (UI audit 2026-11-16 item 35): the engine is
  /// connecting — a half state (dimmed ember border, amber
  /// dot, no ACTIVE pill, no glow), distinct from both idle
  /// and connected. The chips used to declare ACTIVE for the
  /// whole connecting window while the bottom bar said
  /// "Connecting…" — two state languages for one moment.
  final bool connecting;

  @override
  Widget build(BuildContext context) {
    final lit = active;
    // Build 2058 (audit §5 shared widgets): the visible chip
    // stays 128×30, but the tap target is taller than the
    // glass — the outer InkWell owns the tap over the full
    // box and the glass is centred inside it, so the glass
    // keeps its approved size while a finger lands the
    // navigation.
    // Build 2083 (owner order, 2026-11-15: the right rail's
    // gaps read too large on his phone): the box is 36 px,
    // not 2058's 44 — with the rail's 3 px run spacing the
    // glass-to-glass gap is 9 px instead of 19. The glass
    // itself is unchanged at 128×30.
    // Build 2137 (visual review V-09, reconciled with the
    // 2083 order): the tap box grows 36 → 39 px. The
    // review's 42–44 px figure assumed the old 3 px run
    // spacing could still be spent as compensation — build
    // 2092 already set the rail's runSpacing to 0, so the
    // glass-to-glass gap is exactly the box slack: at 39 px
    // it is 9 px (was 6), the +3 px the review allows; any
    // taller box would widen the gap past that and break
    // the 2083 order. The glass stays 128×30, centred.
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          width: 128,
          height: 39,
          child: Center(
            child: MapGlass(
              radius: 10,
              // Build 2092 (UI audit item 15): chips render the
              // static glass (blur: false) — the header stacked
              // ~10 live backdrop blurs; the fill/border are
              // identical, only the live filter goes.
              blur: false,
              // The live engine's chip glows: a solid ember border and a
              // soft orange shadow around the glass, beside its ACTIVE tag.
              // Build 2092 (item 35): connecting wears the same
              // border at half strength — a half state, no glow.
              glow: active,
              tint: lit ? Ember.orange : null,
              borderColor: lit
                  ? Ember.orange.withValues(alpha: 0.65)
                  : connecting
                  ? Ember.orange.withValues(alpha: 0.3)
                  : const Color(0x2EFFFFFF),
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
                            // Build 2092 (item 35): the connecting
                            // dot is amber at half strength.
                            color: active
                                ? const Color(0xFFFFA04A)
                                : connecting
                                ? Ember.amber.withValues(alpha: 0.55)
                                : const Color(0xFF6E6E73),
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
                            fontSize: Ember.fontMicro,
                            fontWeight: highlight
                                ? FontWeight.w600
                                : FontWeight.w500,
                            color: highlight
                                ? Ember.orange
                                : const Color(0xFFE8E8EA),
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
                              // Build 2092 (UI audit item 52): the
                              // micro-text floor is 11 sp.
                              fontSize: Ember.fontMicro,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.5,
                              // Build 2136 (visual review V-08):
                              // dark text on the ember gradient —
                              // white measured 1.78–2.61:1 on it;
                              // #1A1206 (7.11:1) is what every
                              // other gradient capsule uses.
                              color: Color(0xFF1A1206),
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
                  fontSize: Ember.fontSmall,
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
                      fontSize: Ember.fontMicro,
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
                    // Build 2092 (UI audit item 52): pill labels
                    // at the 11 sp informational floor.
                    fontSize: Ember.fontMicro,
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
            fontSize: Ember.fontTitle,
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
          tooltip: 'Close',
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
        // Build 2119 (audit F-18): the lit capsule wears
        // the design system's one gradient token — this
        // chip used to hard-code a second stop pair
        // (FF9E42→E65116) that drifted from Ember.gradient.
        // Batch 5 (fidelity rollout): the lit capsule is
        // FLAT orange now, no gradient and no glow — the
        // same unification fix A7 (build 2145) applied to
        // EmberChip's selected state; the pro6/pro7 samples
        // carry no gradient fills anywhere.
        color: lit ? Ember.orange : MapUi.insetFill,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: lit ? Colors.transparent : MapUi.line),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: Ember.fontMicro,
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
  Widget build(BuildContext context) => Padding(
    // Build 2145 (composition rebuild, pro6-settings sample):
    // the panel GLASS is retired — a settings section is now an
    // editorial hairline GROUP: the tracked orange section
    // title over the rows, no fill, no border, no shadow. The
    // rows (MapSettingRow) already carry their own hairlines;
    // the group's horizontal inset comes from the host list's
    // padding, so rows align with the page's hero title exactly
    // as the sample's index does. Same widget, same API, same
    // children — only the container composition changed.
    padding: const EdgeInsets.fromLTRB(0, 10, 0, 2),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title.toUpperCase(), style: Ember.microLabelOrange),
        const SizedBox(height: 6),
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
      // Build 2118 (appearance fix round): the sample settings
      // rows breathe more than the app's 50 dp / 7 dp rhythm —
      // a small step up (52 / 8), shared by every settings panel.
      constraints: const BoxConstraints(minHeight: 52),
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
                      fontSize: Ember.fontBody,
                      fontWeight: FontWeight.w500,
                      color: MapUi.text,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      style: const TextStyle(
                        // Build 2092 (UI audit item 38): row
                        // subtitles carry real explanations —
                        // 11 sp in dim (6.6:1), not 10 sp faint
                        // (3.44:1).
                        fontSize: Ember.fontMicro,
                        color: MapUi.dim,
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
      // Build 2118 (appearance fix round): the label and the
      // value scale down to fit instead of wrapping/ellipsizing
      // — "ACTIVE CONFIG" wrapped onto two lines in its ~85 dp
      // cell and knocked the telemetry grid out of alignment,
      // and values like "Amsterdam • Netherlands" ellipsized
      // where the samples read whole. FittedBox only shrinks
      // when the cell is too narrow; at natural width nothing
      // changes.
      FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Text(
          label.toUpperCase(),
          maxLines: 1,
          softWrap: false,
          style: const TextStyle(
            // Build 2058 (audit §5 micro-type): 8 px in
            // low-contrast slate carried real info — floored at
            // 9.5 px, colour lifted.
            // Build 2074 (audit item 23): floored at 11 px,
            // colour lifted one step to dim.
            // Build 2083 (owner order, 2026-11-15): 11 -> 10 —
            // the bottom bar's type read too large on his phone;
            // still above the 9.5 micro-type floor.
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.9,
            color: Color(0xFF9A9A9E),
          ),
        ),
      ),
      const SizedBox(height: 2),
      // Build 2092 (UI audit item 37): a truncated exit IP or
      // "City • Country" is recoverable — long-press shows the
      // full value.
      Tooltip(
        message: value,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            value,
            style: const TextStyle(
              // Build 2083 (owner order, 2026-11-15): 11.5 -> 10.5,
              // same bottom-bar tightening as the label above.
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              color: MapUi.text,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
            maxLines: 1,
            softWrap: false,
          ),
        ),
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
            colors: [Color(0x40FFFFFF), Color(0x1AFFFFFF), Color(0x2EE65A1E)],
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
                              // Build 2083 (owner order, 2026-11-15):
                              // 11.5 -> 10 — the bottom bar's type
                              // read too large on his phone.
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              height: 1.15,
                              // Build 2092 (UI audit item 12):
                              // Connected wears the palette token
                              // Ember.amber, not the one-off
                              // 0xFFFFA652 (4.35:1, in neither
                              // palette); long words ellipsize
                              // instead of clipping mid-word.
                              color: on ? Ember.amber : MapUi.dim,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    width: 1,
                    height: 46,
                    margin: const EdgeInsets.symmetric(horizontal: 11),
                    color: const Color(0xFF141518),
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
            // Build 2092 (item 52): the floor is 11 sp now.
            fontSize: Ember.fontMicro,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.8,
            color: Color(0xFF8E8E93),
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
            // Build 2119 (audit F-18): Ember.gradient, the
            // one token — not the drifted literal pair.
            gradient: on ? Ember.gradient : null,
            color: on ? null : const Color(0xFF0C0D10),
            border: Border.all(
              color: on
                  ? const Color(0xFFFFB066).withValues(alpha: 0.5)
                  : const Color(0x2EFFFFFF),
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
                  // audit v4 — the old slate 0xFF6E6E73 read as
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
                  color: on ? Colors.white : const Color(0xFF6E6E73),
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
          // Build 2092 (UI audit item 60): the spec orange is
          // #FF7A29 — the painter's #FF7A18 literals aliased.
          colors: [Color(0x2EFF7A29), Color(0x05FF7A29)],
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
          colors: [Color(0xFFFFC46B), Color(0xFFFF7A29), Color(0xFFFF4A17)],
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

/// Overlay-attack protection (build 2075, feature item 30):
/// while a sensitive surface is mounted — a config QR, the
/// scanner, the profile editor, the account pages — the
/// window refuses overlay windows (Android 12+'s
/// setHideOverlayWindows), so a malicious overlay cannot
/// sit on top of what the user is reading or tapping. The
/// guard lifts when the surface unmounts. Older Android
/// versions ignore the call (the platform side guards it).
///
/// Build 2140: the guard counts only while its surface is
/// VISIBLE. The shell keeps every tab page mounted in an
/// IndexedStack, signalling the selected tab through
/// TickerMode (build 2050); the accounts page's root guard
/// therefore never disposed, and its share of the count
/// held FLAG_SECURE (build 2095) app-wide, on every page,
/// forever — screenshots were blocked everywhere, not just
/// on sensitive surfaces. A guard now holds its share only
/// while the surrounding TickerMode is enabled: pushed
/// routes and the lock page have no disabled TickerMode
/// above them, so they keep the original mount-lifetime
/// behaviour, while a hidden-but-mounted tab page holds
/// nothing.
class OverlayGuard extends StatefulWidget {
  final Widget child;

  const OverlayGuard({super.key, required this.child});

  /// Nested sensitive surfaces (the editor opening a QR
  /// dialog) count up and down — the window guard lifts
  /// only when the last VISIBLE one goes away.
  static int depth = 0;

  @override
  State<OverlayGuard> createState() => _OverlayGuardState();
}

class _OverlayGuardState extends State<OverlayGuard> {
  /// Whether THIS guard currently holds a share of
  /// [OverlayGuard.depth] (build 2140): a share is held
  /// only while the surface is visible (see the class
  /// doc), and released when it hides or unmounts.
  bool _counted = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // TickerMode.valuesOf registers a dependency on the
    // surrounding TickerMode, so this runs again whenever
    // the shell selects or deselects the tab this surface
    // lives on. With no TickerMode ancestor (pushed
    // routes, the lock page) it defaults to enabled.
    _setCounted(TickerMode.valuesOf(context).enabled);
  }

  void _setCounted(bool visible) {
    if (visible == _counted) return;
    _counted = visible;
    if (visible) {
      if (++OverlayGuard.depth == 1) {
        AndroidCore.setOverlayGuard(true);
        // Build 2095 (audit #45): the same surfaces also blank
        // the recents thumbnail / screenshots.
        AndroidCore.setSecureFlag(true);
      }
    } else {
      if (--OverlayGuard.depth == 0) {
        AndroidCore.setOverlayGuard(false);
        AndroidCore.setSecureFlag(false);
      }
    }
  }

  @override
  void dispose() {
    _setCounted(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Build 2095 (third-pass audit 5-4): copies a SECRET (a
/// share link, a subscription URL, a whole backup) with a
/// timed self-clear — the clipboard is world-readable on
/// Android, and a copied credential used to sit there until
/// something overwrote it. The clear fires only when the
/// clipboard still holds this exact text (the user may
/// have copied something else since).
Timer? _sensitiveClipboardTimer;

Future<void> copySensitive(String text) async {
  await Clipboard.setData(ClipboardData(text: text));
  _sensitiveClipboardTimer?.cancel();
  _sensitiveClipboardTimer = Timer(const Duration(seconds: 60), () async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      if (data?.text == text) {
        await Clipboard.setData(const ClipboardData(text: ''));
      }
    } catch (_) {
      // The clipboard is best-effort; a failed clear is
      // not worth an error surface.
    }
  });
}
