import 'dart:convert';
import 'dart:io';

/// The ONE way the Dart side persists a JSON store document
/// (build 2054, audit F-H8): serialized tmp + flush + rename
/// writes, and a torn file quarantined to `<name>.corrupt`
/// instead of silently resetting the store.
///
/// Before this file the 2033/2034 atomic fix lived in exactly
/// ONE Dart store (the Xray store in xray_controller.dart,
/// which stays as-is and is the reference). Everywhere else
/// wrote directly to the live file — openvpn_controller.dart,
/// psiphon_controller.dart, aether_controller.dart and
/// app_settings.dart — so a process kill or power loss
/// mid-save could empty the OpenVPN profile list or silently
/// reset Psiphon/Aether settings on the next launch.
///
/// A store instance is bound to ONE file; all writes for that
/// file go through the same instance so the chain serializes
/// them. Reads are direct (a rename is atomic, so a reader
/// can never meet a half-written document).
/// The user-facing sentence a controller puts on its error
/// surface when its store could not be written (build 2071,
/// review §5.4): the change lives in memory only, and the
/// surface keeps saying so until a save succeeds again.
const storeSaveFailedMessage =
    'Could not save to disk — changes are kept only until '
    'the app closes.';

/// The user-facing sentence for a store file that was there
/// but could not be read at load: the section started fresh
/// instead of pretending nothing was ever saved, and the
/// damaged bytes were quarantined (see [AtomicJsonStore.read]).
const storeDamagedMessage =
    'The saved data was damaged and could not be read, so '
    'this section started fresh. The damaged file was kept '
    'aside.';

class AtomicJsonStore {
  AtomicJsonStore(this.file);

  final File file;

  /// The last write's failure, when it failed (build 2071,
  /// review §5.4). [write] still never throws — a persistence
  /// failure must not take the UI down — but it is no longer
  /// invisible: the owning controller reads this after each
  /// save and surfaces it on its error surface until the next
  /// save succeeds (which clears it back to null).
  Object? lastWriteError;

  /// Why the last [read] found no document although a file
  /// was there: 'damaged' (bytes that are not a JSON document
  /// — quarantined to `<name>.corrupt`) or 'unreadable' (a
  /// filesystem error). Null when the last read was clean —
  /// including "no file yet", a normal first run, not damage.
  String? lastReadProblem;

  Future<void> _chain = Future<void>.value();

  /// Reads the document, or null when there is none (or it is
  /// torn — in which case the torn bytes are quarantined to
  /// `<name>.corrupt` first, so the evidence survives and the
  /// next save does not silently overwrite it).
  Future<Map<String, dynamic>?> read() async {
    try {
      if (!await file.exists()) {
        lastReadProblem = null;
        return null;
      }
      final text = await file.readAsString();
      final doc = jsonDecode(text);
      if (doc is Map<String, dynamic>) {
        lastReadProblem = null;
        return doc;
      }
      // A JSON scalar/array in a store file is torn by
      // definition: quarantine it like a parse failure.
      lastReadProblem = 'damaged';
      await _quarantine();
      return null;
    } on FormatException {
      lastReadProblem = 'damaged';
      await _quarantine();
      return null;
    } on FileSystemException {
      lastReadProblem = 'unreadable';
      return null;
    }
  }

  Future<void> _quarantine() async {
    try {
      final corrupt = File('${file.path}.corrupt');
      if (await corrupt.exists()) await corrupt.delete();
      await file.rename(corrupt.path);
    } catch (_) {
      // Best effort: a torn file the app cannot even move is
      // still better left in place than crashing the load.
    }
  }

  /// Serialized atomic write: the document is encoded once,
  /// written to a sibling temp file with a flush, and renamed
  /// over the live file. Never throws — a persistence failure
  /// must not take the UI down (the Xray store's contract) —
  /// so a failed write is swallowed and the chain continues;
  /// the failure itself is kept in [lastWriteError] for the
  /// owning controller to surface (build 2071, review §5.4).
  Future<void> write(Map<String, dynamic> doc) {
    _chain = _chain.then((_) => _write(doc));
    return _chain;
  }

  Future<void> _write(Map<String, dynamic> doc) async {
    try {
      await file.parent.create(recursive: true);
      await writeText(file, jsonEncode(doc));
      lastWriteError = null;
    } catch (e) {
      // Persistence failure must not take the UI down — but
      // since build 2071 it is recorded, not just swallowed.
      lastWriteError = e;
    }
  }

  /// One atomic text write (tmp + flush + rename), for files
  /// that are not JSON documents: the Mozilla core's
  /// config.json (audit F-M18) and the geo data files (F-M19).
  /// Throws on failure — the caller decides what a failed
  /// write means (both callers already catch it).
  static Future<void> writeText(File file, String text) async {
    await writeBytes(file, utf8.encode(text));
  }

  /// One atomic byte write (tmp + flush + rename).
  static Future<void> writeBytes(File file, List<int> bytes) async {
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(file.path);
  }
}
