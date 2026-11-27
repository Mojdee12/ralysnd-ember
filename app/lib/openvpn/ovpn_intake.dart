/// The ovpn:// intake seam (build 2157's feature, W2 port):
/// the generic link intakes (paste sheet, QR scan, an OS
/// protocol activation) meet links the Xray link parser
/// cannot read. The shell owns the OpenVPN controller, so it
/// registers [handler] at start; an intake that meets an
/// ovpn:// link offers it there instead of failing it as an
/// unknown V2Ray link. The handler returns true when it
/// imported a profile.
library;

abstract final class OvpnLinkIntake {
  /// The shell's ovpn:// handler (see EmberShell).
  static Future<bool> Function(String link)? handler;

  /// True when a handler is registered and consumed the
  /// link (imported or not — the handler words failures
  /// itself, as the Android shell does).
  static Future<bool> handle(String link) async {
    final h = handler;
    if (h == null) return false;
    await h(link);
    return true;
  }
}
