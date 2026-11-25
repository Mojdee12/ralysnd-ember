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
  // Build 2144 (full-app reskin): the approved pro3/pro5/pro6
  // samples' near-black ground replaces the deep-navy base.
  static const bg = Color(0xFF050607);
  static const surface = Color(0xFF0C0D10);
  // Build 2137 (visual review V-01): the graphite card pair
  // is retired — card/cardSoft alias the MapUi navy ramp
  // (see MapUi.card for the derivation), so every solid
  // fill in the app sits in the one palette. Call sites
  // unchanged.
  static const card = MapUi.card;
  static const cardSoft = MapUi.cardSoft;
  static const field = Color(0xFF0A0B0D);
  static const line = Color(0x1FFFFFFF);
  // Build 2137 (visual review V-01): text and dim alias
  // the MapUi ramp too — one text palette for the whole
  // app; the warm graphite whites are retired.
  static const text = MapUi.text;
  static const dim = MapUi.dim;
  // Build 2136 (visual review V-04): lifted from #6E6C78
  // (3.26:1 on Ember.card — below WCAG AA for the real text
  // this token carries) to a value that passes 4.5:1 on the
  // card while staying the quietest text tier.
  // Build 2144: neutralised to the samples' grey ramp (was the
  // warm graphite #9B98A4); lightness kept so the AA contrast
  // the 2136 lift bought is preserved on the new near-black.
  static const faint = Color(0xFF9C9CA2);
  // Build 2074 (audit item 15): the spec orange is #FF7A29.
  // Build 2144: the approved samples' accent is #FF7A29.
  static const orange = Color(0xFFFF7A29);
  static const amber = Color(0xFFFFB347);
  static const green = Color(0xFF41D97E);
  static const warn = Color(0xFFFFB020);
  static const red = Color(0xFFFF5A5A);
  // Build 2137 (visual review V-03): the gradient stops
  // are the approved spec's (#FF8533 → #E65116 —
  // gemini-mobile-spec.md: "button/switch gradient #FF8533
  // → (deep)"); the flat [orange] token above is unchanged
  // (the spec's #FF9E42 flat primary is a separate,
  // later question — not this build).
  // Build 2144: the samples' primary surfaces are FLAT
  // #FF7A29 (the DISCONNECT/CONNECT pills carry no gradient),
  // so the one gradient token flattens to the single accent;
  // every consumer (buttons, toggles, rings, bars) follows.
  static const gradient = LinearGradient(
    colors: [Color(0xFFFF7A29), Color(0xFFFF7A29)],
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
  );
  static const gradientVertical = LinearGradient(
    colors: [Color(0xFFFF8A3D), Color(0xFFFF7A29)],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
  );
  // Build 2074 (audit item 15): ONE panel radius + ONE control
  // radius; every other radius token aliases one of these.
  // Build 2136 (visual review V-02): the tokens split to the
  // approved spec — panels 20, the bottom bar 24, buttons and
  // fields 10 (radiusButton); radiusControl keeps the wider
  // controls (chips, rows) at their shipped 18.
  static const double radiusPanel = 20;
  static const double radiusBar = 24;
  static const double radiusButton = 10;
  static const double radiusControl = 18;
  static const cardRadius = radiusPanel;
  static const radius = BorderRadius.all(Radius.circular(cardRadius));

  // Build 2138 (visual review V-06): THE type scale — six
  // steps, frozen. Every font size in the app is one of
  // these (as a literal through these constants, or via the
  // named styles below); the ~148 half-point literals the
  // review counted are swept onto the nearest step. Steps
  // derive from the dominant shipped sizes and the spec
  // ramp (row title 13.5, title 15–16, micro floor 11):
  // micro labels 11, small labels 12.5, body text 13.5,
  // titles 15, headlines 17, display 21. Recorded ties:
  // heading 16 → 15 (the spec's title step, and the step
  // in-shell panel titles land on — V-26's mismatch closes);
  // dimStyle 13 → 13.5 (reading text follows body, its
  // sibling style); body 14 → 13.5 (nearest step).
  static const double fontMicro = 11;
  static const double fontSmall = 12.5;
  static const double fontBody = 13.5;
  static const double fontTitle = 15;
  static const double fontHeadline = 17;
  static const double fontDisplay = 21;
  // Build 2144 (reskin): the samples' editorial display tier —
  // two ADDITIVE steps above the frozen six (the six steps and
  // their consumers are untouched). fontHero carries the big
  // light status words and page titles of the samples
  // (w300); fontNumeral the huge light hero numerals (w200).
  static const double fontHero = 54;
  static const double fontNumeral = 100;
  // Batch 5 (fidelity rollout): the rollout's measured
  // display steps, named so the V-06 pin holds — fontStat
  // the diagnostics hero figures (between fontDisplay
  // and fontHero), fontCode the RegionHop giant
  // country-code letters (the widest pair measures
  // ≈109 dp at this size and fits the tile's slot; at
  // fontNumeral it measured ≈133 dp and painted nothing
  // — see the tile's own note), fontHeroPing the
  // servers-row hero ping (batch 3) and fontRegion the
  // Psiphon region names (batch 4) — the last two were
  // literals in their pages until this batch's full
  // gate run caught them; their values are unchanged.
  static const double fontStat = 44;
  // Build 2147 (strict-audit F6 + the owner's display
  // ruling): fontCode steps 82 -> 68, the sample's measured
  // letter size — at 82 the pair overflowed its slot on the
  // owner's width class.
  static const double fontCode = 68;
  static const double fontHeroPing = 76;
  static const double fontRegion = 27;

  /// The samples' hero word (Connected / Disconnected / page
  /// titles): very large, light, tight.
  static TextStyle get hero => const TextStyle(
    fontSize: fontHero,
    fontWeight: FontWeight.w300,
    color: text,
    height: 1.05,
    letterSpacing: -0.5,
  );

  /// The samples' hero numeral (the 38 ms / 62% figures):
  /// extra-light at display size, tabular by the font's own
  /// figures.
  static TextStyle get numeral => const TextStyle(
    fontSize: fontNumeral,
    fontWeight: FontWeight.w200,
    color: text,
    height: 1.0,
  );

  /// The samples' tracked uppercase micro-label (PING /
  /// SESSION / TRAFFIC / PROTECTED).
  static TextStyle get microLabel => const TextStyle(
    fontSize: fontMicro,
    fontWeight: FontWeight.w600,
    color: dim,
    letterSpacing: 2.2,
  );

  /// [microLabel] in the one accent (CONNECTING / ACTIVE).
  static TextStyle get microLabelOrange => const TextStyle(
    fontSize: fontMicro,
    fontWeight: FontWeight.w600,
    color: orange,
    letterSpacing: 2.2,
  );

  static TextStyle get title => const TextStyle(
    fontSize: fontDisplay,
    fontWeight: FontWeight.w800,
    color: text,
  );
  static TextStyle get heading => const TextStyle(
    fontSize: fontTitle,
    fontWeight: FontWeight.w700,
    color: text,
  );
  static TextStyle get body =>
      const TextStyle(fontSize: fontBody, color: text, height: 1.35);
  static TextStyle get dimStyle =>
      const TextStyle(fontSize: fontBody, color: dim, height: 1.35);
  static TextStyle get caption =>
      // Build 2074 (audit item 23): colour lifted one step from
      // faint toward dim (size already at the ~11 sp floor).
      // Build 2092 (audit item 38): captions carry real
      // explanations across the homes — the colour completes
      // the lift to dim (#A5A2AC, ≈7:1 on the card), so
      // informational text sits at the dim floor everywhere
      // this style is used.
      const TextStyle(fontSize: fontMicro, color: dim, height: 1.3);
}

/// Type-floor exception (owner order, build 2083 — recorded
/// here in build 2137, visual review V-11): the shell bottom
/// bar's label, value and state type is 10/10.5 sp, below
/// the app's 11 sp micro-type floor, because the owner
/// ordered the bar's type smaller on his phone. It is a
/// deliberate exception, not a defect — future audits must
/// not re-flag it.
///
/// Type-scale exceptions (build 2138, visual review V-06):
/// computed glyph sizes that scale with their widget are
/// not scale steps and stay computed — the shield-mark and
/// badge glyphs in this file (`size * 0.24`, `size * 0.3`),
/// the avatar initial in `ui/widgets.dart` (`height * 0.45`)
/// and the world map's labels (`px(11)` in world_map.dart,
/// a painter size in map units, already at the floor step).

/// The Map Control palette (2.2.0): the deep-navy glass system
/// of the approved mobile samples, layered over the Ember
/// graphite tokens. Panels are navy glass over the baked dotted
/// map; text is a cool white-blue ramp.
abstract final class MapUi {
  /// Build 2144: the reskin samples' ground is near-black
  /// (#050607) with the faintest top lift — the navy ramp
  /// (#0C1520 → #101C2C) is retired.
  static const baseTop = Color(0xFF07080A);
  static const baseBottom = Color(0xFF050607);

  /// Panel glass: build 2144 — the samples' panels are
  /// near-opaque charcoal over the black ground (the navy
  /// translucent fills are retired); the blur still runs
  /// underneath where a call site asks for it, but the fill
  /// now carries the surface almost alone.
  static const panelFill = Color(0xE6131417);
  static const panelFillSoft = Color(0xE60C0D10);

  /// Inset fields (search, text inputs): darker than the panel.
  static const insetFill = Color(0xCC070708);

  /// Build 2137 (visual review V-01): the opaque card
  /// colours of the navy ramp. [card] is the approved glass
  /// made solid — panelFill (#8C142236, 55% alpha)
  /// composited over baseBottom (#FF101C2C) — for the sites
  /// that need a plain fill rather than a panel. [cardSoft]
  /// is one lift step above it, the navy counterpart of the
  /// old graphite card→cardSoft step. Computed contrast on
  /// card: text 15.29:1, dim 6.42:1, faint 5.26:1; on
  /// cardSoft: 14.14 / 5.94 / 4.86 — every tier AA.
  // Build 2144: the opaque pair follows the reskin — neutral
  // charcoal steps of the samples (#101216 / #17191E) replace
  // the navy pair; contrast re-derived on card: text ≈15:1,
  // dim ≈6.5:1, faint ≈4.9:1 — every tier still AA.
  static const card = Color(0xFF101216);
  static const cardSoft = Color(0xFF17191E);

  static const line = Color(0x17FFFFFF);
  static const lineStrong = Color(0x29FFFFFF);
  static const text = Color(0xFFF5F5F4);
  static const body = Color(0xFFC9C9CC);
  static const dim = Color(0xFF9A9AA0);
  // Build 2136 (visual review V-04): lifted from #5F728C
  // (3.52:1 on the panel colour — below WCAG AA for the
  // real text this token carries at 69 call sites) to
  // #7E93AC, ≈4.6:1 on the panel: the quietest tier now
  // passes AA everywhere it carries text.
  // Build 2144: neutralised alongside the ramp (was the
  // blue-grey #7E93AC); lightness matched so its AA standing
  // on the panel colour is unchanged.
  static const faint = Color(0xFF82828A);

  /// Build 2092 (item 60): the brightened steel label the
  /// v7 audit set for OpenVPN's "Change" / status captions
  /// (#9BB0C7 — MapUi.dim read too faint over the map). It
  /// was a one-off literal at two sites; now a named token,
  /// same value, no visual change.
  /// Build 2144: the steel is neutral now (#A8A8AE), same
  /// lightness step above dim.
  static const steelLabel = Color(0xFFA8A8AE);
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

  /// The selected-row treatment: a faint orange wash,
  /// stronger at the left edge, over the glass — the row's
  /// rim (its border) carries the selection, not the fill.
  /// Build 2119 (audit F-15): the wash softens from
  /// 27.8%→10.2% alpha to 10.2%→3.1% — at the 2118 weights
  /// it read as a broad warm fill rather than a rim on
  /// glass.
  static const selectedGradient = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [Color(0x1AFF7A29), Color(0x08FF7A29)],
  );
}

/// Build 2074 (audit item 14): ONE ping rule — [pingColor]:
/// the owner's frozen pair (green at or under 150 ms,
/// yellow above; a failed test is faint). This name stays
/// for its Map Control callers but delegates, so every
/// surface colours the same delay the same way. (Build
/// 2119, audit F-19: this comment used to describe a
/// retired three-band green/amber/red rule the code no
/// longer implements.)
Color mapPingColor(int ms) => pingColor(ms);

/// The app background: the baked Map Control backdrop (the
/// offline dot raster over the deep-navy base), shared by the
/// shell and every pushed Ember page.
class EmberBackground extends StatelessWidget {
  final Widget child;

  /// Build 2145 (UI-review fix A3): text-heavy pushed pages
  /// pass banded so their rows sit on plain near-black below
  /// a faint map band (see MapBackdropVisual.banded).
  final bool banded;

  /// Build 2147 (strict-audit F1): the shorter, fainter
  /// band (Settings).
  final bool bandShort;
  const EmberBackground({
    super.key,
    required this.child,
    this.banded = false,
    this.bandShort = false,
  });

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      MapBackdropVisual(banded: banded, bandShort: bandShort),
      child,
    ],
  );
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
      // Build 2149 (audit A43-31): explicit blur — the
      // MapGlass default is now blur:false.
      MapGlass(blur: true, padding: padding, glow: glow, onTap: onTap, child: child);
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
                  fontSize: Ember.fontTitle,
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
                        // Build 2144: the samples' power glyph
                        // is the flat accent, on or off-state
                        // dim — amber is retired from the ring.
                        color: on ? Ember.orange : Ember.dim,
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
      ..color = const Color(0xFF1D1E21);
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
    final inner = Paint()..color = const Color(0xFF0A0B0D);
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
              // Build 2092 (UI audit item 52): sub-text at the
              // caption size (11.5 sp), not the old 10 sp shrink.
              Text(subText!, style: Ember.caption),
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
      ..color = const Color(0xFF232428);
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
      color: const Color(0xFF232428),
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
  Widget build(BuildContext context) => Semantics(
    // Build 2116 (B9-5): switch semantics — the bare
    // GestureDetector was invisible to TalkBack, so no
    // Ember settings toggle could be announced or operated
    // by a screen reader. The visual is excluded from the
    // semantics tree; this node carries the toggle.
    button: true,
    toggled: value,
    enabled: onChanged != null,
    onTap: onChanged == null ? null : () => onChanged!(!value),
    child: ExcludeSemantics(
      child: GestureDetector(
        onTap: onChanged == null ? null : () => onChanged!(!value),
    // Build 2058 (audit §5 shared widgets): the visible knob
    // stays 50×26, but the tap target carries transparent
    // padding above/below the track as part of the
    // GestureDetector. Build 2092 (UI audit 2026-11-16 item 22):
    // padding 9→11 dp so the shared target meets the app's
    // 48 dp floor (26 + 11×2); visuals unchanged.
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 11),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        width: 50,
        height: 26,
        alignment: value ? Alignment.centerRight : Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 3),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          // Build 2119 (audit F-18): the ON gradient is the
          // design system's one token — this switch used to
          // hard-code a second stop pair (FF9E42→E65116)
          // that drifted from Ember.gradient.
          gradient: value ? Ember.gradient : null,
          // Build 2144: the OFF track is the reskin samples'
          // dark charcoal with a hairline rim (was the 2023
          // mid-slate).
          color: value ? null : const Color(0xFF2A2B2F),
          border: value ? null : Border.all(color: const Color(0x33FFFFFF)),
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
        // Build 2149 (owner expansion 2026-11-25, un-holding
        // the toggle-form decision): the approved samples
        // (pro6-settings, pro7-dns) draw a SLIDING SWITCH —
        // a knob, no state word — so the knob replaces the
        // ON/OFF text the 2137 V-05 fix put inside the pill.
        // ON: white knob on the orange track; OFF: grey knob
        // on the dark track. The switch semantics above
        // (toggled state for TalkBack) are unchanged, so the
        // state stays announced without the word.
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          width: 20,
          height: 20,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: value ? Colors.white : const Color(0xFF9A9AA0),
            boxShadow: const [
              BoxShadow(
                color: Color(0x55000000),
                blurRadius: 3,
                offset: Offset(0, 1),
              ),
            ],
          ),
        ),
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
        // Build 2119 (audit F-16): the UNSELECTED chip lifts
        // slightly — fill 0.05 -> 0.09 and a defined white
        // hairline instead of the faintest line token; it stays
        // flat (no shadow) and dim-text.
        // Build 2145 (UI-review fix A7): ONE selected treatment
        // app-wide — the flat accent fill with dark text, the
        // same as EmberSegmented's selected segment and the
        // filter chips. The old translucent wash + glow was a
        // third rendering of "selected" next to those two.
        color: selected
            ? Ember.orange
            : Colors.white.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: selected
              ? Ember.orange
              : Colors.white.withValues(alpha: 0.16),
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
          // Build 2149 (audit A48-07): the label flexes and
          // ellipsises — at 360dp × 2.0 text scale a long
          // chip label (the chain builder's underlay chips)
          // overflowed the chip's Row by 39 px, a cell the
          // new scale matrix caught. Unconstrained, the
          // Flexible changes nothing.
          Flexible(
            child: Text(
              label,
              style: TextStyle(
                fontSize: compact ? Ember.fontMicro : Ember.fontSmall,
                fontWeight: FontWeight.w700,
                color: selected ? const Color(0xFF1A1206) : MapUi.dim,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
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
                    fontSize: Ember.fontTitle,
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

  /// Batch 5 (fidelity rollout, pro7-routing sample): the
  /// FLAT form — no tray, no fills; the options are tracked
  /// text, the chosen one orange with a 2 px underline bar.
  /// Opt-in per call site; every other site keeps the tray
  /// form below.
  final bool flat;

  const EmberSegmented({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
    this.flat = false,
  });

  @override
  Widget build(BuildContext context) {
    if (flat) {
      return Row(
        children: [
          for (final (v, label, icon) in options)
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onChanged(v),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (icon != null) ...[
                            Icon(
                              icon,
                              size: 16,
                              color: value == v
                                  ? Ember.orange
                                  : MapUi.faint,
                            ),
                            const SizedBox(width: 6),
                          ],
                          Flexible(
                            child: Text(
                              label.toUpperCase(),
                              style: TextStyle(
                                fontSize: Ember.fontSmall,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 1.6,
                                color: value == v
                                    ? Ember.orange
                                    : MapUi.faint,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 7),
                      Container(
                        height: 2,
                        width: 44,
                        decoration: BoxDecoration(
                          color: value == v
                              ? Ember.orange
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(1),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      );
    }
    return Container(
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
                  // Build 2118 (appearance fix round): the
                  // selected cell was translucent orange (0.18)
                  // over the near-black inset — it read as a
                  // dull brown fill with an orange outline.
                  // The samples' chosen value (dns.google,
                  // English) is a SOLID gradient capsule with
                  // dark text — the exact treatment MapValueChip
                  // already uses; the segmented now matches it.
                  // Batch 5 (fidelity rollout): flat orange,
                  // no gradient, no glow — the A7 unification,
                  // as on EmberChip and MapValueChip.
                  color: value == v ? Ember.orange : Colors.transparent,
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
                            : MapUi.dim,
                      ),
                      const SizedBox(width: 6),
                    ],
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: Ember.fontBody,
                        fontWeight: FontWeight.w700,
                        color: value == v
                            ? const Color(0xFF1A1206)
                            : MapUi.dim,
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

/// Colored ping text — the ONE ping colour rule (build 2116, AP-04): the
/// spec-frozen pair — green at or under 150 ms, yellow
/// above. Three rules coexisted (this one at <100/<250,
/// the legacy delayColor at <400/<1000, and the frozen
/// MapUi.pingGreen/pingYellow pair defined but unused), so
/// the same 200 ms read amber on mobile and green on
/// desktop. Every ping/delay display now routes here; a
/// negative reading is not a slow ping but no reading.
Color pingColor(int ms) {
  if (ms < 0) return Ember.faint;
  if (ms <= 150) return MapUi.pingGreen;
  return MapUi.pingYellow;
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
      // Build 2144: the primary button is the samples' full
      // pill (the flat accent now comes from Ember.gradient);
      // fields keep the radiusButton token — this radius is
      // the button's own, not the shared token.
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 20),
        decoration: BoxDecoration(
          gradient: onTap == null ? null : Ember.gradient,
          color: onTap == null ? Ember.cardSoft : null,
          borderRadius: BorderRadius.circular(999),
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
                  fontSize: Ember.fontTitle,
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
  // Build 2092 (UI audit item 49): hints are the only label
  // several fields have — MapUi.dim (6.6:1), not faint (3.44:1).
  hintStyle: const TextStyle(color: MapUi.dim, fontSize: Ember.fontBody),
  prefixIcon: prefix,
  filled: true,
  fillColor: MapUi.insetFill,
  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
  // Build 2074 (audit item 15): fields alias the control radius.
  border: OutlineInputBorder(
    borderRadius: BorderRadius.circular(Ember.radiusButton),
    borderSide: const BorderSide(color: Ember.line),
  ),
  enabledBorder: OutlineInputBorder(
    borderRadius: BorderRadius.circular(Ember.radiusButton),
    borderSide: const BorderSide(color: Ember.line),
  ),
  focusedBorder: OutlineInputBorder(
    borderRadius: BorderRadius.circular(Ember.radiusButton),
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
