/// Per-platform feature flags (PLAN.md §1: "Scope enforcement").
///
/// One tree serves every platform; an engine whose backend does not
/// exist on the running platform is simply never offered there. On
/// Windows the scope locked for Ralysnd Ember is Mozilla + V2Ray +
/// Psiphon: Lantern and WARP stay in the tree for Android (their
/// controllers, pages and settings sections are compiled in but
/// unreachable), while the navigation, the mode switch and the
/// persisted mode are clamped so they can never be selected.
library;

import 'dart:io';

abstract final class Features {
  /// The desktop shell (left rail, Fluent glass) instead of the phone
  /// shell with its bottom navigation.
  static final bool desktopShell = Platform.isWindows;

  /// Engines offered on this platform.
  static final bool mozilla = true;
  static final bool xray = true;
  static final bool psiphon = true;

  /// No Windows backend exists for these two (user's scope cut for the
  /// Windows version); Android keeps both.
  static final bool lantern = !Platform.isWindows;
  static final bool warp = !Platform.isWindows;

  /// The Ember engine modes (settings.emberMode) this platform may
  /// show, in rail/switch order: 0 Mozilla, 1 V2Ray, 2 Psiphon,
  /// 3 Lantern, 4 WARP+.
  static List<int> get engineModes => [
        0,
        1,
        2,
        if (lantern) 3,
        if (warp) 4,
      ];

  /// [mode] clamped to an offered engine: a settings file written on
  /// Android (or an older build) may persist 3/4, which Windows must
  /// never land on.
  static int clampMode(int mode) => engineModes.contains(mode) ? mode : 0;
}
