/// Mozilla bootstrap (build 2034): the serverless answer to the
/// Guardian HTTP 451 region block, after Kumiho's Prepare pattern.
///
/// When the core has no stored, still-valid Guardian pass, the
/// connect flow runs ONE handoff first: a donor engine the user
/// picked (Psiphon / a V2Ray config / the WARP profile) connects,
/// the core fetches a fresh pass through that engine's local
/// SOCKS (plus the server list, inside the same window), the pass
/// is persisted by the core, the donor stops, and Mozilla then
/// connects directly on the stored pass. The Cloudflare Worker
/// relay is the fifth choice: no engine involved, the core's
/// prepare call rides the relay instead. Nothing here routes
/// tunnel traffic — only the control-plane handoff.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../aether/aether_controller.dart';
import '../../aether/aether_platform.dart';
import '../../app_settings.dart';
import '../../core/core_api.dart';
import '../../core/core_controller.dart';
import '../../core/models.dart';
import '../../psiphon/psiphon_controller.dart';
import '../../psiphon/psiphon_platform.dart';
import '../../xray/xray_controller.dart';
import '../../xray/xray_models.dart';
import 'ember_theme.dart';
import 'map_widgets.dart';

/// The outcome of a bootstrap handoff attempt.
class BootstrapVerdict {
  const BootstrapVerdict.proceed() : message = null, cancelled = false;
  const BootstrapVerdict.cancelled() : message = null, cancelled = true;
  const BootstrapVerdict.failed(this.message) : cancelled = false;

  /// Why the handoff failed; null when it did not.
  final String? message;
  final bool cancelled;

  bool get proceed => message == null && !cancelled;
}

/// Owns the bootstrap donor choice's runtime: the handoff dance
/// before a Mozilla connect, and the relay credential save. The
/// choice itself persists in [AppSettings.mozillaBootstrap].
class MozillaBootstrap extends ChangeNotifier {
  MozillaBootstrap({
    required this.core,
    required this.settings,
    required this.psiphon,
    required this.xray,
    required this.warp,
  });

  final CoreController core;
  final AppSettings settings;
  final PsiphonController psiphon;
  final XrayController xray;
  final AetherController warp;

  bool busy = false;
  String busyLabel = '';
  int _generation = 0;

  String get donor => settings.mozillaBootstrap;

  void setDonor(String choice) {
    settings.update(mozillaBootstrap: choice);
    notifyListeners();
  }

  static String donorName(String choice) => switch (choice) {
    'psiphon' => 'Psiphon',
    'v2ray' => 'V2Ray',
    'warp' => 'WARP',
    'relay' => 'Cloudflare relay',
    _ => 'Off',
  };

  /// The loopback SOCKS address of the chosen donor engine, or
  /// null for the choices that have none (off / relay).
  String? donorSocksAddress() => switch (donor) {
    'psiphon' => '127.0.0.1:${PsiphonPlatform.socksPort}',
    'v2ray' => '127.0.0.1:${xray.settings.socksPort}',
    'warp' => '127.0.0.1:${AetherPlatform.cfwarpSocksPort}',
    _ => null,
  };

  /// Whether the core holds a stored pass with more than a
  /// minute of life — the connect then needs no handoff.
  bool get passReady {
    final exp = core.status?.passExpiresAt ?? 0;
    return exp * 1000 > DateTime.now().millisecondsSinceEpoch + 60000;
  }

  /// The honest status line for the Mozilla page, composed from
  /// the donor choice and the core's pass state. Pure, so tests
  /// can pin every branch.
  static String statusLine({
    required String donor,
    required bool connected,
    required bool busy,
    required String busyLabel,
    required int passExpiresAt,
    required DateTime now,
  }) {
    if (busy) return busyLabel;
    if (connected) return 'Direct';
    if (passExpiresAt * 1000 > now.millisecondsSinceEpoch) {
      return 'Pass ready';
    }
    return switch (donor) {
      'off' => 'Direct',
      'relay' => 'Bootstrap via Cloudflare relay on next connect',
      _ => 'Bootstrap via ${donorName(donor)} on next connect',
    };
  }

  /// Aborts an in-flight handoff (the user switched engines): the
  /// donor is stopped by the handoff's own cleanup.
  void cancel() {
    _generation++;
  }

  /// Runs the handoff when the chosen bootstrap needs one.
  /// Returns proceed when Mozilla may connect (pass already
  /// stored, bootstrap off, or the handoff just stored a pass).
  Future<BootstrapVerdict> prepareIfNeeded() async {
    if (donor == 'off' || passReady) {
      return const BootstrapVerdict.proceed();
    }
    final gen = ++_generation;
    busy = true;
    busyLabel = 'Bootstrap via ${donorName(donor)}…';
    notifyListeners();
    try {
      if (donor == 'relay') {
        await core.call((api) => api.prepareBootstrapRelay());
        return const BootstrapVerdict.proceed();
      }
      try {
        final startError = await _startDonor();
        if (gen != _generation) return const BootstrapVerdict.cancelled();
        if (startError != null) return BootstrapVerdict.failed(startError);
        final up = await _waitForDonor(gen);
        if (gen != _generation) return const BootstrapVerdict.cancelled();
        if (!up) {
          return BootstrapVerdict.failed(
            'Bootstrap via ${donorName(donor)} timed out — the donor did not come up.',
          );
        }
        await core.call(
          (api) => api.prepareBootstrapSocks(donorSocksAddress()!),
        );
        if (gen != _generation) return const BootstrapVerdict.cancelled();
        return const BootstrapVerdict.proceed();
      } finally {
        await _stopDonor();
      }
    } on CoreApiException {
      // Build 2074 (audit item 6): a plain sentence — the core's
      // raw message stays out of the UI (it remains in the
      // core's own diagnostics).
      return BootstrapVerdict.failed(
        'Bootstrap via ${donorName(donor)} failed.',
      );
    } catch (_) {
      return BootstrapVerdict.failed(
        'Bootstrap via ${donorName(donor)} failed.',
      );
    } finally {
      busy = false;
      busyLabel = '';
      notifyListeners();
    }
  }

  Future<String?> _startDonor() async {
    try {
      switch (donor) {
        case 'psiphon':
          await psiphon.connect();
        case 'v2ray':
          final selected = xray.selected;
          if (selected == null) {
            return 'No V2Ray config is selected to bootstrap through.';
          }
          if (selected.protocol == Protocol.wireguard) {
            await xray.connectWireGuardWithFallback(selected);
          } else {
            await xray.connect();
          }
        case 'warp':
          await warp.connect();
      }
    } catch (_) {
      // Build 2074 (audit item 6): a plain sentence, not the
      // raw exception.
      return 'Bootstrap via ${donorName(donor)} could not start.';
    }
    return null;
  }

  Future<void> _stopDonor() async {
    try {
      switch (donor) {
        case 'psiphon':
          await psiphon.disconnect();
        case 'v2ray':
          await xray.disconnect();
        case 'warp':
          await warp.disconnect();
      }
    } catch (_) {
      // Cleanup only: a donor that will not stop must not mask the
      // handoff's own result.
    }
  }

  bool _donorReportsUp() => switch (donor) {
    'psiphon' => psiphon.state.connected,
    'v2ray' => xray.state.running,
    'warp' => warp.connected,
    _ => false,
  };

  /// Waits until the donor both reports itself up and its SOCKS
  /// accepts a connection (a listening socket alone is not proof
  /// the donor's tunnel carries traffic, and a reported tunnel
  /// without the socket is useless to the core).
  Future<bool> _waitForDonor(int gen) async {
    final address = donorSocksAddress()!;
    final port = int.parse(address.substring(address.lastIndexOf(':') + 1));
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    while (DateTime.now().isBefore(deadline)) {
      if (gen != _generation) return false;
      if (_donorReportsUp()) {
        try {
          final socket = await Socket.connect(
            '127.0.0.1',
            port,
            timeout: const Duration(seconds: 2),
          );
          socket.destroy();
          return true;
        } catch (_) {
          // Not accepting yet.
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 600));
    }
    return false;
  }

  /// Saves (or clears, when both are empty) the Worker relay pair
  /// in the core. Returns an error message, or null on success.
  Future<String?> saveRelay(String url, String key) async {
    try {
      await core.call((api) => api.saveBootstrapRelay(url.trim(), key));
      return null;
    } on CoreApiException {
      // Build 2074 (audit item 6): the relay result is not
      // shown verbatim — a plain sentence instead.
      return 'The relay could not be saved — check the URL and key.';
    } catch (_) {
      return 'The relay could not be saved — check the URL and key.';
    }
  }
}

/// The Bootstrap card on the Mozilla accounts page: the donor
/// picker, the honest status line, and — when the relay is the
/// chosen donor — the Control-plane relay fields.
class MozillaBootstrapCard extends StatefulWidget {
  const MozillaBootstrapCard({super.key, required this.bootstrap});

  final MozillaBootstrap bootstrap;

  @override
  State<MozillaBootstrapCard> createState() => _MozillaBootstrapCardState();
}

class _MozillaBootstrapCardState extends State<MozillaBootstrapCard> {
  final _url = TextEditingController();
  final _key = TextEditingController();
  String? _relayNote;
  bool _saving = false;

  MozillaBootstrap get _b => widget.bootstrap;

  @override
  void initState() {
    super.initState();
    _url.text = _b.core.status?.bootstrap?.relayUrl ?? '';
  }

  @override
  void dispose() {
    _url.dispose();
    _key.dispose();
    super.dispose();
  }

  Future<void> _saveRelay() async {
    setState(() {
      _saving = true;
      _relayNote = null;
    });
    final error = await _b.saveRelay(_url.text, _key.text);
    if (!mounted) return;
    setState(() {
      _saving = false;
      _relayNote = error ?? 'Relay saved.';
      if (error == null) _key.clear();
    });
  }

  Widget _pill(String choice) {
    final on = _b.donor == choice;
    return InkWell(
      // Build 2074 (audit items 4+15): the control radius (18),
      // palette colours only, and a ≥48dp hit area — the pill
      // used to be ~37dp tall with hardcoded oranges and a
      // 10dp radius.
      borderRadius: BorderRadius.circular(18),
      onTap: _b.busy ? null : () => _b.setDonor(choice),
      child: Container(
        constraints: const BoxConstraints(minHeight: 48),
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        decoration: BoxDecoration(
          gradient: on
              ? LinearGradient(
                  colors: [
                    Ember.orange.withValues(alpha: 0.24),
                    Ember.orange.withValues(alpha: 0.10),
                  ],
                )
              : null,
          color: on ? null : Colors.white.withValues(alpha: 0.045),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: on ? Ember.orange : MapUi.lineStrong,
            width: on ? 1.4 : 1,
          ),
        ),
        child: Text(
          MozillaBootstrap.donorName(choice),
          style: Ember.body.copyWith(
            color: on ? Ember.text : Ember.dim,
            fontSize: 13,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([_b, _b.core, _b.settings]),
      builder: (context, _) {
        final status = _b.core.status;
        final line = MozillaBootstrap.statusLine(
          donor: _b.donor,
          connected: status?.state.phase == Phase.running,
          busy: _b.busy,
          busyLabel: _b.busyLabel,
          passExpiresAt: status?.passExpiresAt ?? 0,
          now: DateTime.now(),
        );
        final relayInfo = status?.bootstrap;
        return MapGlass(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Bootstrap via', style: Ember.heading),
              const SizedBox(height: 4),
              Text(
                'When Mozilla is blocked in this region (HTTP 451), '
                'one sign-in handoff through another route fetches '
                'the pass Mozilla needs; the tunnel itself always '
                'connects directly.',
                style: Ember.caption,
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final choice in AppSettings.bootstrapChoices)
                    _pill(choice),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Icon(
                    _b.busy
                        ? Icons.hourglass_top_rounded
                        : Icons.info_outline_rounded,
                    size: 15,
                    color: Ember.faint,
                  ),
                  const SizedBox(width: 6),
                  Expanded(child: Text(line, style: Ember.dimStyle)),
                ],
              ),
              if (_b.donor == 'relay') ...[
                const SizedBox(height: 14),
                Text('Control-plane relay', style: Ember.body),
                const SizedBox(height: 8),
                TextField(
                  controller: _url,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  textDirection: TextDirection.ltr,
                  style: Ember.body,
                  decoration:
                      emberField(
                        context,
                        'https://your-relay.workers.dev',
                      ).copyWith(
                        labelText: 'Relay base URL',
                        labelStyle: const TextStyle(
                          color: Ember.faint,
                          fontSize: 13,
                        ),
                        floatingLabelStyle: const TextStyle(
                          color: Ember.orange,
                        ),
                      ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _key,
                  obscureText: true,
                  autocorrect: false,
                  textDirection: TextDirection.ltr,
                  style: Ember.body.copyWith(fontFamily: 'monospace'),
                  decoration:
                      emberField(
                        context,
                        (relayInfo?.relayKeySet ?? false)
                            ? 'Key saved — type to replace it'
                            : 'The RELAY_KEY secret of your Worker',
                      ).copyWith(
                        labelText: 'Relay key',
                        labelStyle: const TextStyle(
                          color: Ember.faint,
                          fontSize: 13,
                        ),
                        floatingLabelStyle: const TextStyle(
                          color: Ember.orange,
                        ),
                      ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    // Build 2056 (audit A-H3): the one pill/button
                    // language — a MapActionPill, not a stock
                    // Material button.
                    MapActionPill(
                      icon: Icons.save_rounded,
                      label: _saving ? 'Saving…' : 'Save relay',
                      busy: _saving,
                      onTap: _saveRelay,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Only Mozilla sign-in and pass requests cross '
                        'the relay — never tunnel traffic.',
                        style: Ember.caption,
                      ),
                    ),
                  ],
                ),
                if (_relayNote != null) ...[
                  const SizedBox(height: 6),
                  Text(_relayNote!, style: Ember.caption),
                ],
              ],
            ],
          ),
        );
      },
    );
  }
}
