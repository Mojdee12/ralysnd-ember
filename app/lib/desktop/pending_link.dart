/// Links handed to the app by the OS (a protocol activation
/// of ovpn:// / openvpn://): the first instance receives the
/// link in its entrypoint arguments, and a second instance —
/// which exits after asking the first to come forward —
/// leaves it in `pending-link.txt` in the app data folder
/// (written by the runner, main.cpp). The shell drains it at
/// start and whenever the app returns to the foreground, and
/// routes it through the same intakes as a pasted link.
library;

import 'dart:io';

import '../core/core_api.dart';

abstract final class PendingLink {
  static File get _file =>
      File('${CoreLocator.dataDir(const [])}/pending-link.txt');

  /// Stashes a link received in this process's own arguments.
  static Future<void> stash(String link) async {
    try {
      final f = _file;
      await f.parent.create(recursive: true);
      await f.writeAsString(link, flush: true);
    } catch (_) {
      // An OS link is a convenience; losing one is survivable.
    }
  }

  /// Takes the pending link, if any, exactly once.
  static Future<String?> take() async {
    try {
      final f = _file;
      if (!await f.exists()) return null;
      final text = (await f.readAsString()).trim();
      await f.delete();
      return text.isEmpty ? null : text;
    } catch (_) {
      return null;
    }
  }

  /// True when [arg] is a link the OS would hand the app
  /// (the registered protocols, plus the generic config-link
  /// schemes the intakes read).
  static bool looksLikeLink(String arg) {
    final a = arg.trim().toLowerCase();
    return a.startsWith('ovpn://') || a.startsWith('openvpn://');
  }
}
