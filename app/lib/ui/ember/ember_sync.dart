/// Multi-device sync (build 2075, feature item 20): the
/// owner's configs, subscriptions and V2Ray settings travel
/// between his devices through HIS OWN GitHub account — an
/// encrypted backup in a secret gist, nothing on any Ember
/// server (there is none).
///
/// The backup document is the app's ordinary export
/// (XrayController.exportBackup), sealed with the same
/// crypto as the protected share links (PBKDF2-HMAC-SHA256,
/// 120k rounds, AES-256-GCM; see shared_link.dart) under a
/// sync password the user types per operation — the
/// password is never stored. The GitHub token he pastes
/// lives in the Keystore-backed vault (build 2116, E-7) —
/// never in the settings document — and is only ever
/// sent to api.github.com. (Build 2119, audit F-19: this
/// header said "stored in the app-private settings" from
/// 2075 to 2118, which stopped being true in 2116.)
///
/// Push creates the gist on first use and updates it after;
/// Pull downloads, unseals and restores through the
/// transactional importBackup — a bad password or a damaged
/// document changes nothing.

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pointycastle/export.dart' hide State;

import '../../aether/aether_controller.dart';
import '../../aether/aether_platform.dart';
import '../../app_settings.dart';
import '../../openvpn/openvpn_controller.dart';
import '../../openvpn/openvpn_models.dart';
import '../../psiphon/psiphon_controller.dart';
import '../../xray/xray_controller.dart';
import 'ember_dialogs.dart';
import 'ember_theme.dart';
import 'map_widgets.dart';

/// Build 2116 (AB-05): assembles the backup's other-engine
/// sections from whichever engine controllers the caller
/// has. OpenVPN profiles travel WITHOUT their credentials
/// (those stay in the device vault); Psiphon settings and
/// both Aether options sets travel whole.
Map<String, Object?> buildEngineSections({
  OpenVpnController? openvpn,
  PsiphonController? psiphon,
  AetherController? warp,
  AetherController? masque,
}) => {
  if (openvpn != null)
    'openVpnProfiles': [
      for (final p in openvpn.userProfiles) p.toJson(),
    ],
  if (psiphon != null) 'psiphonSettings': psiphon.settings.toJson(),
  if (warp != null || masque != null)
    'aetherOptions': {
      if (masque != null) 'masque': masque.options.toJson(),
      if (warp != null) 'cfwarp': warp.options.toJson(),
    },
};

/// Build 2116 (AB-05): applies a restored backup's engine
/// sections to whichever controllers the caller has. Every
/// section decodes tolerantly — a damaged entry is skipped,
/// never fatal to the restore that carried it.
///
/// Build 2125 (audit A25-07): the sections that were
/// PRESENT but could not be applied are RETURNED by name
/// — up to 2124 every failure was swallowed and all three
/// restore surfaces reported plain success while OpenVPN
/// profiles / Psiphon settings / Aether options silently
/// never landed. Callers name the failures in their
/// result line; the restore itself still never fails
/// over an engine section.
Future<List<String>> applyEngineSections(
  Map<String, Object?> sections, {
  OpenVpnController? openvpn,
  PsiphonController? psiphon,
  AetherController? warp,
  AetherController? masque,
}) async {
  final failed = <String>[];
  final ovpn = sections['openVpnProfiles'];
  if (openvpn != null && ovpn is List) {
    final restored = <OvpnProfile>[];
    var damaged = 0;
    for (final e in ovpn) {
      if (e is Map) {
        try {
          restored.add(OvpnProfile.fromJson(e.cast<dynamic, dynamic>()));
        } catch (_) {
          damaged++;
        }
      } else {
        damaged++;
      }
    }
    try {
      await openvpn.restoreProfiles(restored);
      if (damaged > 0) failed.add('OpenVPN profiles');
    } catch (_) {
      failed.add('OpenVPN profiles');
    }
  } else if (ovpn != null) {
    // Build 2126 (audit A26-12): a present section that
    // could not be applied at all (mistyped payload, or
    // its controller unavailable) is NAMED — up to 2125
    // it fell through silently and the restore reported
    // success over data that never landed.
    failed.add('OpenVPN profiles');
  }
  final psi = sections['psiphonSettings'];
  if (psiphon != null && psi is Map) {
    try {
      await psiphon.updateSettings(
        PsiphonSettings.fromJson(psi.cast<String, dynamic>()),
      );
    } catch (_) {
      failed.add('Psiphon settings');
    }
  } else if (psi != null) {
    // Build 2126 (A26-12): named, not skipped.
    failed.add('Psiphon settings');
  }
  final aether = sections['aetherOptions'];
  if (aether is Map) {
    final m = aether['masque'];
    if (masque != null && m is Map) {
      try {
        await masque.setOptions(AetherOptions.fromJson(m.cast<String, dynamic>()));
      } catch (_) {
        failed.add('MASQUE options');
      }
    } else if (m != null) {
      // Build 2126 (A26-12): named, not skipped.
      failed.add('MASQUE options');
    }
    final w = aether['cfwarp'];
    if (warp != null && w is Map) {
      try {
        await warp.setOptions(AetherOptions.fromJson(w.cast<String, dynamic>()));
      } catch (_) {
        failed.add('WARP options');
      }
    } else if (w != null) {
      // Build 2126 (A26-12): named, not skipped.
      failed.add('WARP options');
    }
  } else if (aether != null) {
    // Build 2126 (A26-12): the whole Aether container
    // was present but unusable — name both halves.
    failed.add('MASQUE options');
    failed.add('WARP options');
  }
  return failed;
}

class SyncException implements Exception {
  final String message;
  const SyncException(this.message);
  @override
  String toString() => message;
}

const _gistFileName = 'ember-backup.json';
const _iterations = 120000;

/// Seals [backupJson] under [password]: base64 of
/// salt | nonce | AES-256-GCM ciphertext, in a small JSON
/// envelope so a wrong file is recognisable before decrypt.
String sealBackup(String backupJson, String password) {
  final rnd = Random.secure();
  final salt = Uint8List.fromList(List.generate(16, (_) => rnd.nextInt(256)));
  final nonce = Uint8List.fromList(List.generate(12, (_) => rnd.nextInt(256)));
  final derivator = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
    ..init(Pbkdf2Parameters(salt, _iterations, 32));
  final key = derivator.process(Uint8List.fromList(utf8.encode(password)));
  final cipher = GCMBlockCipher(AESEngine())
    ..init(true, AEADParameters(KeyParameter(key), 128, nonce, Uint8List(0)));
  final sealed = cipher.process(Uint8List.fromList(utf8.encode(backupJson)));
  final blob = Uint8List.fromList([...salt, ...nonce, ...sealed]);
  return jsonEncode({
    'app': 'ralysnd-ember-sync',
    'v': 1,
    'data': base64Url.encode(blob).replaceAll('=', ''),
  });
}

/// Unseals an envelope from [sealBackup]. Null when the
/// envelope is not one, or the password is wrong (GCM's tag
/// makes a wrong password and corruption indistinguishable).
String? unsealBackup(String envelope, String password) {
  try {
    final doc = jsonDecode(envelope);
    if (doc is! Map || doc['app'] != 'ralysnd-ember-sync') return null;
    var data = (doc['data'] as String)
        .replaceAll('-', '+')
        .replaceAll('_', '/');
    while (data.length % 4 != 0) {
      data += '=';
    }
    final blob = base64.decode(data);
    if (blob.length < 29) return null;
    final salt = Uint8List.sublistView(blob, 0, 16);
    final nonce = Uint8List.sublistView(blob, 16, 28);
    final sealed = Uint8List.sublistView(blob, 28);
    final derivator = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
      ..init(Pbkdf2Parameters(salt, _iterations, 32));
    final key = derivator.process(Uint8List.fromList(utf8.encode(password)));
    final cipher = GCMBlockCipher(
      AESEngine(),
    )..init(false, AEADParameters(KeyParameter(key), 128, nonce, Uint8List(0)));
    return utf8.decode(cipher.process(sealed));
  } catch (_) {
    return null;
  }
}

/// The GitHub API call behind the sync transport (build 2082,
/// verification V-6): [apiBase] is the test seam — production
/// calls leave it null and hit api.github.com; tests point it
/// at a local HttpServer so the push/pull round-trip is pinned
/// without touching the network.
Future<HttpClientResponse> _github(
  String method,
  String path,
  String token, {
  Object? body,
  Uri? apiBase,
}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final request = await client.openUrl(
      method,
      (apiBase ?? Uri.parse('https://api.github.com')).resolve(
        path.startsWith('/') ? path.substring(1) : path,
      ),
    );
    request.headers.set('Authorization', 'Bearer $token');
    request.headers.set('Accept', 'application/vnd.github+json');
    request.headers.set('X-GitHub-Api-Version', '2022-11-28');
    request.headers.set('User-Agent', 'Ralysnd-Ember');
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    return await request.close();
  } finally {
    client.close();
  }
}

/// The largest sync response accepted: a gist carrying a
/// full encrypted backup is a few megabytes at the extreme;
/// anything beyond this is not a sync document.
const syncResponseMaxBytes = 16 * 1024 * 1024;

/// Build 2125 (audit A25-51): the response body used to be
/// joined unbounded — an endpoint (or the route serving
/// it) streaming an endless body was buffered whole in
/// memory before jsonDecode (the P-55 class, in the Gist
/// fetcher). The read is now byte-capped as it arrives and
/// stall-timed per chunk, mirroring the DPI feed's
/// discipline in dpi_remote.dart.
Future<String> _body(HttpClientResponse r) async {
  final builder = BytesBuilder(copy: false);
  await for (final chunk in r.timeout(const Duration(seconds: 30))) {
    builder.add(chunk);
    if (builder.length > syncResponseMaxBytes) {
      throw const SyncException(
        'The sync response is too large to accept safely.',
      );
    }
  }
  return utf8.decode(builder.toBytes());
}

SyncException _githubError(int status) => switch (status) {
  401 || 403 => const SyncException(
    'GitHub rejected the token. Check it is a personal access token with the "gist" scope.',
  ),
  404 => const SyncException(
    'The sync gist was not found. Push from the device that has your configs first.',
  ),
  _ => SyncException('GitHub answered with an error ($status).'),
};

/// Pushes the sealed backup to the owner's gist (creating
/// it on first use). Returns the gist id.
Future<String> syncPush({
  required AppSettings settings,
  required String backupJson,
  required String password,
  Uri? apiBase,
}) async {
  final token = settings.syncGithubToken.trim();
  if (token.isEmpty) {
    throw const SyncException('Paste a GitHub token first.');
  }
  final sealed = sealBackup(backupJson, password);
  final payload = {
    'files': {
      _gistFileName: {'content': sealed},
    },
  };
  try {
    final gistId = settings.syncGistId.trim();
    final HttpClientResponse response;
    if (gistId.isEmpty) {
      response = await _github(
        'POST',
        '/gists',
        token,
        apiBase: apiBase,
        body: {
          'description': 'Ralysnd Ember — encrypted config sync',
          'public': false,
          ...payload,
        },
      );
    } else {
      response = await _github(
        'PATCH',
        '/gists/$gistId',
        token,
        apiBase: apiBase,
        body: payload,
      );
    }
    final text = await _body(response);
    if (response.statusCode != 200 && response.statusCode != 201) {
      throw _githubError(response.statusCode);
    }
    final doc = jsonDecode(text);
    final id = (doc is Map ? doc['id'] : null)?.toString() ?? gistId;
    settings.update(
      syncGistId: id,
      syncLastMs: DateTime.now().millisecondsSinceEpoch,
    );
    return id;
  } on SyncException {
    rethrow;
  } catch (_) {
    throw const SyncException(
      'Could not reach GitHub. Check the connection and try again.',
    );
  }
}

/// Pulls and unseals the backup from the owner's gist.
/// Returns the backup JSON for XrayController.importBackup.
Future<String> syncPull({
  required AppSettings settings,
  required String password,
  Uri? apiBase,
}) async {
  final token = settings.syncGithubToken.trim();
  if (token.isEmpty) {
    throw const SyncException('Paste a GitHub token first.');
  }
  final gistId = settings.syncGistId.trim();
  if (gistId.isEmpty) {
    throw const SyncException(
      'No sync gist is set on this device yet. Push from another device first, or paste its gist id below.',
    );
  }
  try {
    final response = await _github(
      'GET',
      '/gists/$gistId',
      token,
      apiBase: apiBase,
    );
    final text = await _body(response);
    if (response.statusCode != 200) throw _githubError(response.statusCode);
    final doc = jsonDecode(text);
    final files = (doc as Map)['files'];
    final file = (files as Map)[_gistFileName];
    final content = (file as Map)['content'];
    if (content is! String || content.isEmpty) {
      throw const SyncException('The gist holds no Ember backup file.');
    }
    final backup = unsealBackup(content, password);
    if (backup == null) {
      throw const SyncException(
        'The backup could not be opened — the sync password is wrong, or the file is damaged.',
      );
    }
    // Build 2095 (whole-app audit §9 note): the last-sync
    // stamp is NOT written here — it used to advance even
    // when the restore that follows failed. The caller
    // stamps it after a successful importBackup.
    return backup;
  } on SyncException {
    rethrow;
  } catch (_) {
    throw const SyncException(
      'Could not reach GitHub. Check the connection and try again.',
    );
  }
}

/// '2026-11-15 14:03' in Latin digits for the last-sync line.
String _syncStamp(int ms) {
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}

/// The Settings page for multi-device sync.
class SyncPage extends StatefulWidget {
  final AppSettings settings;
  final XrayController xray;

  /// Build 2116 (AB-05): the other engines' controllers,
  /// when the host page has them — their data rides the
  /// backup (see buildEngineSections).
  final OpenVpnController? openvpn;
  final PsiphonController? psiphon;
  final AetherController? warp;
  final AetherController? masque;

  const SyncPage({
    super.key,
    required this.settings,
    required this.xray,
    this.openvpn,
    this.psiphon,
    this.warp,
    this.masque,
  });

  @override
  State<SyncPage> createState() => _SyncPageState();
}

class _SyncPageState extends State<SyncPage> {
  late final TextEditingController _token = TextEditingController(
    text: widget.settings.syncGithubToken,
  );
  late final TextEditingController _gistId = TextEditingController(
    text: widget.settings.syncGistId,
  );
  final TextEditingController _password = TextEditingController();
  bool _busy = false;
  String _status = '';

  /// Build 2125 (audit A25-56 / P-60): mirrors
  /// AppSettings.syncTokenVaultWriteFailed for the token
  /// field below — the page does not listen to settings,
  /// so the token's onChanged refreshes this after each
  /// awaited update() completes.
  bool _tokenVaultFailed = false;

  /// Build 2092 (item 49): the status line's colour — red
  /// on failure, dim on success (the app-lock pattern).
  bool _statusError = false;

  @override
  void initState() {
    super.initState();
    // Build 2126 (audit A26-28): a vault failure that
    // pre-dates this visit shows on open too — up to
    // 2125 the mirror started false and only the token
    // field's onChanged refreshed it, so an earlier
    // failure stayed invisible here until the user
    // typed in the field.
    _tokenVaultFailed = widget.settings.syncTokenVaultWriteFailed;
  }

  @override
  void dispose() {
    _token.dispose();
    _gistId.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() op) async {
    setState(() {
      _busy = true;
      _status = '';
      _statusError = false;
    });
    try {
      await op();
    } on SyncException catch (e) {
      if (mounted) {
        setState(() {
          _status = e.message;
          _statusError = true;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _status = 'Something went wrong. Try again.';
          _statusError = true;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = widget.settings;
    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Ember.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text('Sync via GitHub', style: Ember.heading),
        foregroundColor: Ember.text,
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          const MapBackdropVisual(),
          ListView(
            // Build 2138 (visual review V-26): the body extends
            // behind the transparent bar — keep the first card
            // below it (the profile_editor formula).
            padding: EdgeInsets.fromLTRB(
              16,
              MediaQuery.of(context).padding.top + kToolbarHeight + 16,
              16,
              16,
            ),
            children: [
              Text(
                'Your configs, subscriptions and V2Ray settings, '
                'encrypted with a password only you know, stored in a '
                'secret gist in your own GitHub account. Push from one '
                'device, pull on another. The password is never stored; '
                'the token is kept in this device\'s secure keystore '
                'vault (build 2116) and sent only to api.github.com.',
                style: Ember.body.copyWith(color: Ember.dim),
              ),
              const SizedBox(height: 8),
              Text(
                'OpenVPN profiles, Psiphon settings and WARP/MASQUE '
                'options travel too. What never travels: OpenVPN '
                'usernames and passwords (they stay in each '
                'device\'s own vault), your Mozilla account, pass '
                'and core settings, Aether identity and scan '
                'results, the Lantern server list, '
                'the selected OpenVPN '
                'profile, traffic history, the battery log and '
                'the GitHub token.',
                style: Ember.body.copyWith(color: Ember.dim),
              ),
              const SizedBox(height: 16),
              MapGlass(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('GitHub token (gist scope)', style: Ember.body),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _token,
                      obscureText: true,
                      style: Ember.body,
                      // Build 2092 (item 49): the shared
                      // field, not a stock decoration.
                      decoration: emberField(context, 'ghp_… or github_pat_…'),
                      onChanged: (v) async {
                        await settings.update(syncGithubToken: v.trim());
                        if (mounted &&
                            settings.syncTokenVaultWriteFailed !=
                                _tokenVaultFailed) {
                          setState(
                            () => _tokenVaultFailed =
                                settings.syncTokenVaultWriteFailed,
                          );
                        }
                      },
                    ),
                    if (_tokenVaultFailed) ...[
                      const SizedBox(height: 8),
                      Text(
                        'The secure vault refused this token — it is '
                        'not saved and will be gone at the next launch. '
                        'Paste it again.',
                        style: Ember.body.copyWith(color: Ember.red),
                      ),
                    ],
                    const SizedBox(height: 16),
                    Text('Gist id (set by the first push)', style: Ember.body),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _gistId,
                      style: Ember.body,
                      decoration: emberField(
                        context,
                        'Paste a gist id to pull from it',
                      ),
                      onChanged: (v) => settings.update(syncGistId: v.trim()),
                    ),
                    const SizedBox(height: 16),
                    Text('Sync password', style: Ember.body),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _password,
                      obscureText: true,
                      style: Ember.body,
                      decoration: emberField(
                        context,
                        'The same password on every device',
                      ),
                    ),
                    const SizedBox(height: 20),
                    Row(
                      children: [
                        Expanded(
                          child: EmberButton(
                            label: 'Push to GitHub',
                            onTap: _busy
                                ? null
                                : () => _run(() async {
                                    if (_password.text.isEmpty) {
                                      throw const SyncException(
                                        'Enter a sync password first.',
                                      );
                                    }
                                    final backup = await widget.xray
                                        .exportBackup(
                                        appSettingsJson: settings.toJson(),
                                        engineSections: buildEngineSections(
                                          openvpn: widget.openvpn,
                                          psiphon: widget.psiphon,
                                          warp: widget.warp,
                                          masque: widget.masque,
                                        ),
                                      );
                                    // Build 2098 (post-2097
                                    // audit M11): a protected
                                    // store exports nothing —
                                    // pushing its empty state
                                    // would overwrite the
                                    // healthy synced copy.
                                    if (backup == null) {
                                      throw SyncException(
                                        widget.xray.storeError ??
                                            'The saved data could '
                                                'not be read, so '
                                                'nothing was pushed.',
                                      );
                                    }
                                    await syncPush(
                                      settings: settings,
                                      backupJson: backup,
                                      password: _password.text,
                                    );
                                    if (mounted) {
                                      setState(() {
                                        _gistId.text = settings.syncGistId;
                                        _status =
                                            'Pushed. Your other '
                                            'devices can pull now.';
                                      });
                                    }
                                  }),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: EmberButton(
                            label: 'Pull from GitHub',
                            onTap: _busy
                                ? null
                                : () => _run(() async {
                                    if (_password.text.isEmpty) {
                                      throw const SyncException(
                                        'Enter a sync password first.',
                                      );
                                    }
                                    // Build 2092 (item 49):
                                    // the shared Ember confirm,
                                    // not a stock dialog.
                                    final ok = await showEmberConfirm(
                                      context,
                                      title: 'Replace this device\'s configs?',
                                      message:
                                          'Pulling replaces the configs, '
                                          'subscriptions and V2Ray settings '
                                          'on this device with the synced '
                                          'copy.',
                                      confirmLabel: 'Pull',
                                    );
                                    if (ok != true) return;
                                    final backup = await syncPull(
                                      settings: settings,
                                      password: _password.text,
                                    );
                                    final restored = await widget.xray
                                        .importBackup(backup);
                                    // Build 2095 (V2Ray audit
                                    // #15): the synced app
                                    // settings land too.
                                    if (restored?.appSettingsJson != null) {
                                      await settings.applyRestoredSettings(
                                        restored!.appSettingsJson!,
                                      );
                                    }
                                    // Build 2116 (AB-05): the
                                    // other engines' sections
                                    // land on their controllers
                                    // too. Build 2125 (A25-07):
                                    // sections that could not
                                    // be applied are named in
                                    // the result line below.
                                    var engineFailures = const <String>[];
                                    if (restored?.engineSections != null) {
                                      engineFailures =
                                          await applyEngineSections(
                                            restored!.engineSections!,
                                            openvpn: widget.openvpn,
                                            psiphon: widget.psiphon,
                                            warp: widget.warp,
                                            masque: widget.masque,
                                          );
                                    }
                                    // Build 2095: the stamp
                                    // lands only on a restore
                                    // that actually happened.
                                    if (restored != null) {
                                      settings.update(
                                        syncLastMs: DateTime.now()
                                            .millisecondsSinceEpoch,
                                      );
                                    }
                                    if (mounted) {
                                      setState(
                                        () => _status = restored != null
                                            ? engineFailures.isEmpty
                                                  ? 'Pulled and restored.'
                                                  : 'Pulled and restored — '
                                                        'but these sections '
                                                        'could not be '
                                                        'applied: '
                                                        '${engineFailures.join(', ')}.'
                                            : 'The synced file is not a '
                                                  'backup this build can read.',
                                      );
                                    }
                                  }),
                          ),
                        ),
                      ],
                    ),
                    if (_busy) ...[
                      const SizedBox(height: 14),
                      const LinearProgressIndicator(color: Ember.orange),
                    ],
                    if (_status.isNotEmpty) ...[
                      const SizedBox(height: 14),
                      Text(
                        _status,
                        style: Ember.body.copyWith(
                          color: _statusError ? Ember.red : Ember.dim,
                        ),
                      ),
                    ],
                    if (settings.syncLastMs > 0) ...[
                      const SizedBox(height: 14),
                      Text(
                        'Last sync: ${_syncStamp(settings.syncLastMs)}',
                        style: Ember.caption,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
