/// Per-platform feature flags (PLAN.md §1: "Scope enforcement").
///
/// One tree serves every platform; an engine whose backend does not
/// exist on the running platform is simply never offered there.
/// Through 2.1.0 the Windows scope was Mozilla + V2Ray + Psiphon.
/// The 2.2.0 parity port brought every Android engine across:
/// Lantern (honest unavailable state — its core is an Android
/// library; see lantern_platform.dart), WARP+ (warp-plus.exe),
/// WireGuard (via the Xray core), OpenVPN (openvpn.exe), and the
/// Aether engines (aether.exe: standalone WARP + MASQUE).
library;

import 'dart:io';

abstract final class Features {
  /// SCREENSHOT HARNESS OVERRIDE (win-work copy only): with
  /// EMBER_FORCE_DESKTOP=1 in the environment, this build behaves
  /// like the Windows one — desktop Fluent shell, Windows engine
  /// scope — so the real app can be rendered and photographed on
  /// Linux. Unset (every normal run) nothing changes anywhere.
  static final bool forceDesktop =
      Platform.environment['EMBER_FORCE_DESKTOP'] == '1';

  /// The desktop shell (left rail, Fluent glass) instead of the phone
  /// shell with its bottom navigation.
  static final bool desktopShell = Platform.isWindows || forceDesktop;

  /// Engines offered on this platform.
  static final bool mozilla = true;
  static final bool xray = true;
  static final bool psiphon = true;

  /// Lantern and WARP+ have Windows presence since the parity
  /// port (Lantern as an honest unavailable state, WARP+ with its
  /// warp-plus.exe backend), so both are offered on every platform.
  static final bool lantern = true;
  static final bool warp = true;

  /// The Ember engine modes (settings.emberMode) this platform may
  /// show, in rail/switch order: 0 Mozilla, 1 V2Ray, 2 Psiphon,
  /// 3 Lantern, 4 WARP+, 5 WireGuard, 6 OpenVPN, 7 WARP (Aether),
  /// 8 MASQUE. (The desktop numbering extends the 2.1.0 tree's —
  /// Android's own shell numbers OpenVPN 4 / WireGuard 5 / WARP 6 /
  /// MASQUE 7; the persisted desktop values 3/4 keep their desktop
  /// meanings here.)
  static List<int> get engineModes => [0, 1, 2, 3, 4, 5, 6, 7, 8];

  /// [mode] clamped to an offered engine: a settings file written on
  /// Android (or an older build) may persist 3/4, which Windows must
  /// never land on.
  static int clampMode(int mode) => engineModes.contains(mode) ? mode : 0;
}
