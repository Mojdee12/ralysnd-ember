/// The Ember shell, Map Control edition (2.2.0): the baked
/// dotted world map as the ground, the floating brand panel and
/// engine chips as the navigation, the live map actors (home
/// marker, exit pin, arc) over the map, the pages floating in
/// glass panels, and the wide bottom control bar that drives
/// whichever engine the chips have chosen. Exactly one tunnel
/// is ever up: the arbitration hooks below are unchanged from
/// the pre-reskin shell.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../aether/aether_controller.dart';
import '../../app_info.dart';
import '../../app_settings.dart';
import '../../core/android_core.dart';
import '../../core/core_controller.dart';
import '../../core/models.dart';
import '../../lantern/lantern_controller.dart';
import '../../l10n/app_localizations.dart';
import '../../net/network_info.dart';
import '../../openvpn/openvpn_controller.dart';
import '../../psiphon/psiphon_controller.dart';
import '../../xray/xray_controller.dart';
import '../../xray/xray_models.dart';
import 'aether_pages.dart';
import 'ember_accounts.dart';
import 'mozilla_bootstrap.dart';
import 'ember_format.dart';
import 'ember_home.dart';
import 'ember_servers.dart';
import 'ember_settings.dart';
import 'ember_theme.dart';
import 'lantern_pages.dart';
import 'map_widgets.dart';
import 'openvpn_pages.dart';
import 'profile_country.dart';
import 'psiphon_pages.dart';
import 'wireguard_pages.dart';
import 'world_map.dart';

class EmberShell extends StatefulWidget {
  const EmberShell({
    super.key,
    required this.core,
    required this.settings,
    this.banner,
    this.noCore,
  });

  final CoreController core;
  final AppSettings settings;
  final Widget? banner;
  final Widget? noCore;

  @override
  State<EmberShell> createState() => _EmberShellState();
}

class _EmberShellState extends State<EmberShell> with WidgetsBindingObserver {
  int _tab = 0;
  late final XrayController _xray = XrayController();
  late final PsiphonController _psiphon = PsiphonController();
  late final LanternController _lantern = LanternController();
  late final OpenVpnController _openvpn = OpenVpnController();
  // Build 2032: the ralysnd Aether engines — the standalone
  // WARP slot and the MASQUE slot.
  late final AetherController _warp = AetherController('cfwarp');
  late final AetherController _masque = AetherController('masque');

  /// The Mozilla bootstrap helper (build 2034): runs the
  /// one-handoff pass fetch before a Mozilla connect when the
  /// region blocks Guardian and no stored pass is valid.
  late final MozillaBootstrap _bootstrap = MozillaBootstrap(
    core: core,
    settings: widget.settings,
    psiphon: _psiphon,
    xray: _xray,
    warp: _warp,
  );
  bool _defaultsApplied = false;
  bool _mozBusy = false;

  // Build 2074 (audit item 1): the engine rail is horizontal —
  // one key per chip (8 engines + Settings) so the selected
  // chip can be scrolled into view when the selection changes,
  // and the rail's own controller for that scroll.
  final List<GlobalKey> _railKeys = List<GlobalKey>.generate(
    9,
    (_) => GlobalKey(),
  );
  final ScrollController _railController = ScrollController();
  int _railCenteredIndex = -1;

  /// Scrolls the rail so the chip at [index] is visible
  /// (build 2074, audit item 1). Runs after the frame so the
  /// newly selected chip has been laid out; a no-op when the
  /// selection has not changed since the last centering.
  void _ensureRailVisible(int index) {
    if (_railCenteredIndex == index) return;
    _railCenteredIndex = index;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _railKeys[index].currentContext;
      if (ctx == null) return;
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
        alignment: 0.5,
      );
    });
  }

  // Pause with auto-resume (build 2033): the mode whose
  // connection is paused, when it comes back, and the timers
  // that drive the countdown and the resume. In-memory only —
  // if the app process dies, the pause dies with it and the
  // engine simply stays off (nothing is faked with a native
  // alarm the tree does not have).
  int? _pausedMode;
  DateTime? _resumeAt;
  Timer? _pauseTimer;
  Timer? _pauseTicker;

  CoreController get core => widget.core;

  /// Whether the app is in the foreground, for the poll
  /// cadence feed (build 2050, audit §3 battery): every engine
  /// controller polls at its live 2 s cadence only while this
  /// is true, and the Mozilla core poller also keys on the
  /// engine on stage. Tunnels behave identically either way —
  /// only the UI-side supervision slows down.
  bool _foreground = true;

  /// Pushes the cadence state into every controller.
  void _applyCadence() {
    _xray.setForeground(_foreground);
    _psiphon.setForeground(_foreground);
    _lantern.setForeground(_foreground);
    _openvpn.setForeground(_foreground);
    _warp.setForeground(_foreground);
    _masque.setForeground(_foreground);
    core.setForeground(_foreground);
    core.setEngineFocus(mode == 0);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _applyCadence();
    // Build 2055 (audit B-M1): leaving the foreground lands
    // any debounced stats totals — a backgrounded app may be
    // killed before the next 30 s write, and the disconnect
    // flush never runs for a killed process.
    if (!_foreground) unawaited(_xray.flushStatsOnBackground());
  }

  /// The engine the panel shows: 0 = Mozilla, 1 = V2Ray,
  /// 2 = Psiphon, 3 = Lantern, 4 = OpenVPN (persisted). 2024:
  /// Lantern is back as mode 3; 2025: OpenVPN takes mode 4 —
  /// the slot WARP held before 2023, so a stored 4 from that
  /// era now opens OpenVPN, the same benign resurrection
  /// Lantern's 3 had. Build 2032 adds 5 = WireGuard (the Xray
  /// carrier's own section), 6 = WARP and 7 = MASQUE (the
  /// ralysnd Aether engines). A stored value outside 0..7
  /// reads as Mozilla here too (AppSettings.load already
  /// clamps it), never a dead page.
  int get mode {
    final m = widget.settings.emberMode;
    return m >= 0 && m <= 7 ? m : 0;
  }

  set mode(int value) => widget.settings.update(emberMode: value);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _applyCadence();
    _xray.stopOtherEngine = () async {
      await _stopMozilla();
      await _stopPsiphon();
      await _stopLantern();
      await _stopOpenVpn();
      await _stopAether();
    };
    // The chain underlay (build 2029A) starts with the Psiphon
    // engine's own settings — region, upstream, protocols —
    // so the Psiphon page stays the one place they are chosen.
    _xray.underlayParams = () => (
      region: _psiphon.settings.region,
      upstream: _psiphon.settings.upstream,
      protocols: _psiphon.settings.protocols.toList(),
    );
    // The global tunnel MTU (build 2038, queue 2f) lives in the
    // Xray settings; the other engines read it at connect time
    // through these callbacks, so a change in Settings applies
    // to the next connect without an app restart.
    _psiphon.tunnelMtu = () => _xray.settings.tunnelMtu;
    _lantern.tunnelMtu = () => _xray.settings.tunnelMtu;
    _warp.tunnelMtu = () => _xray.settings.tunnelMtu;
    _masque.tunnelMtu = () => _xray.settings.tunnelMtu;
    // The tunnel DNS (build 2057, audit §6 engine low) lives in
    // the Xray settings too; Psiphon and Lantern read it at
    // connect time through these callbacks, so a change in
    // Settings applies to the next connect without an app
    // restart — neither tunnel silently keeps 1.1.1.1 anymore.
    _psiphon.localDns = () => _xray.settings.localDns;
    _lantern.localDns = () => _xray.settings.localDns;
    // Build 2057 (audit F-M4): Psiphon's TUN captures IPv6 only
    // when the Xray settings say so (ipv6Route) — same callback
    // shape as the MTU/DNS above, read at connect time.
    _psiphon.tunnelIpv6 = () => _xray.settings.ipv6Route;
    _psiphon.stopOtherEngine = () async {
      await _stopMozilla();
      if (_xray.state.running) await _xray.disconnect();
      await _stopLantern();
      await _stopOpenVpn();
      await _stopAether();
    };
    _lantern.stopOtherEngine = () async {
      await _stopMozilla();
      if (_xray.state.running) await _xray.disconnect();
      await _stopPsiphon();
      await _stopOpenVpn();
      await _stopAether();
    };
    _openvpn.stopOtherEngine = () async {
      await _stopMozilla();
      if (_xray.state.running) await _xray.disconnect();
      await _stopPsiphon();
      await _stopLantern();
      await _stopAether();
    };
    _warp.stopOtherEngine = () async {
      await _stopMozilla();
      if (_xray.state.running) await _xray.disconnect();
      await _stopPsiphon();
      await _stopLantern();
      await _stopOpenVpn();
      if (_masque.state.running || _masque.tunRunning) {
        await _masque.disconnect();
      }
    };
    _masque.stopOtherEngine = () async {
      await _stopMozilla();
      if (_xray.state.running) await _xray.disconnect();
      await _stopPsiphon();
      await _stopLantern();
      await _stopOpenVpn();
      if (_warp.state.running || _warp.tunRunning) {
        await _warp.disconnect();
      }
    };
    unawaited(
      _xray.load().then((_) {
        // The Mozilla connect path (AndroidCore.setOn) cannot take
        // the MTU as an argument — CoreController's turnOn is (bool)
        // and shared with desktop — so the shell mirrors the loaded
        // value into AndroidCore.tunnelMtu (build 2038, queue 2f);
        // the settings page keeps it in sync on every change.
        AndroidCore.tunnelMtu.value = _xray.settings.tunnelMtu;
      }),
    );
    _psiphon.load();
    _lantern.load();
    _openvpn.load();
    _warp.load();
    _masque.load();
    // Build 2065: per-network winner memory, auto-connect
    // triggers and the scheduled-health tick all ride the
    // platform network callback armed here.
    _armNetworkTracking();
    _applyEmber2Defaults();
    unawaited(_applyTransportDefault());
    // Keep the controllers' view of their services fresh on return.
    unawaited(_xray.refreshState());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _railController.dispose();
    _pauseTimer?.cancel();
    _pauseTicker?.cancel();
    _netSub?.cancel();
    _healthTimer?.cancel();
    _xray.dispose();
    _psiphon.dispose();
    _lantern.dispose();
    _openvpn.dispose();
    _warp.dispose();
    _masque.dispose();
    super.dispose();
  }

  /// Ember 2's baked-in first-run defaults, applied once per install:
  /// VPN mode (not proxy), smart routing off, encrypted DNS on — the
  /// three settings behind the "sites do not open" reports on v1.
  /// Applied only while neither engine is connected.
  Future<void> _applyEmber2Defaults() async {
    if (widget.settings.ember2DefaultsApplied || _defaultsApplied) return;
    _defaultsApplied = true;
    // The Mozilla core needs a moment to answer after launch.
    for (var i = 0; i < 30 && core.status == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    try {
      if (core.status?.state.phase != Phase.running) {
        // 1. The connection mode: VPN.
        await AndroidCore.setMode('vpn');
        // 2. Smart routing off, 3. DoH defaults in place.
        await core.editSettings((config) {
          final routing = config['routing'];
          if (routing is Map<String, Object?>) {
            routing['enabled'] = false;
          }
          final dns = config['dns'];
          if (dns is Map<String, Object?>) {
            final servers = dns['servers'];
            final list = servers is List ? servers : const [];
            final encrypted =
                list.isNotEmpty &&
                list.every(
                  (s) =>
                      s.toString().startsWith('https://') ||
                      s.toString().startsWith('tls://'),
                );
            if (!encrypted) {
              dns['servers'] = [
                'https://1.1.1.1/dns-query',
                'https://8.8.8.8/dns-query',
                'https://9.9.9.9/dns-query',
              ];
            }
          }
        });
      }
    } catch (_) {
      // A core that is not answering keeps its settings; the flag stays
      // unset so the next launch tries again.
      _defaultsApplied = false;
      return;
    }
    // Build 2057 (audit F-H10): this runs from an async continuation
    // (core-status waits + platform calls) that the test clock — and
    // on a slow device, a frame boundary — can land inside a build,
    // and notifyListeners() mid-build throws "setState() called
    // during build" on the shell's ListenableBuilders. The flag is
    // bookkeeping; apply it after the current frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.settings.update(ember2DefaultsApplied: true);
    });
  }

  bool _transportApplied = false;

  /// The Mozilla transport default, pinned once (2024 — the
  /// desktop 2.0.5 pin brought to Android): proxy.transport =
  /// "h2". The core's factory default is already "h2" (its
  /// config defaults set it), but an install whose SAVED core
  /// config says "h3" — the Settings transport choice writes it,
  /// and its unset state displays as h3 — pays for it on every
  /// connect on a UDP-hostile network: the H3 (QUIC) session
  /// attempt runs under the core's whole 20 s ConnectTimeout
  /// across the server's addresses before the engine falls back
  /// to H2. That is the owner's ~10 s Android connect. Pin H2
  /// once, while the engine is not running; afterwards the
  /// Settings choice owns the value (AppSettings.transportPinned).
  Future<void> _applyTransportDefault() async {
    if (widget.settings.transportPinned || _transportApplied) return;
    _transportApplied = true;
    // The Mozilla core needs a moment to answer after launch.
    for (var i = 0; i < 30 && core.status == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    final status = core.status;
    if (status == null || status.state.phase == Phase.running) {
      // Nothing answered, or a tunnel is already up: keep the flag
      // unset so a later launch tries again.
      _transportApplied = false;
      return;
    }
    try {
      await core.editSettings((config) {
        final proxy = config['proxy'];
        if (proxy is Map<String, Object?>) {
          proxy['transport'] = 'h2';
        }
      });
    } catch (_) {
      _transportApplied = false;
      return;
    }
    // Build 2057 (audit F-H10): same mid-build notify hazard as
    // _applyEmber2Defaults above — the flag is bookkeeping, so it
    // lands after the current frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.settings.update(transportPinned: true);
    });
  }

  /// The Xray engine's arbitration hook: Mozilla goes fully off first.
  Future<void> _stopMozilla() async {
    if (core.status?.state.phase == Phase.running ||
        core.status?.state.phase == Phase.starting) {
      await core.setOn(false);
      for (var i = 0; i < 30; i++) {
        if (core.status?.state.phase == Phase.off ||
            core.status?.state.phase == Phase.waiting) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
  }

  /// The Psiphon engine goes off (the other engines' hooks pass
  /// through here).
  Future<void> _stopPsiphon() async {
    if (_psiphon.state.running) await _psiphon.disconnect();
  }

  /// The Lantern engine goes off (the other engines' hooks pass
  /// through here).
  Future<void> _stopLantern() async {
    if (_lantern.state.running || _lantern.state.coreRunning) {
      await _lantern.disconnect();
    }
  }

  /// The OpenVPN engine goes off (the other engines' hooks
  /// pass through here).
  Future<void> _stopOpenVpn() async {
    if (_openvpn.state.running) await _openvpn.disconnect();
  }

  /// Both Aether slots go off (the other engines' hooks pass
  /// through here; each slot's own hook spares itself).
  Future<void> _stopAether() async {
    if (_warp.state.running || _warp.tunRunning) {
      await _warp.disconnect();
    }
    if (_masque.state.running || _masque.tunRunning) {
      await _masque.disconnect();
    }
  }

  /// The Mozilla engine's matching hook, used by the home page:
  /// all other engines go off before Mozilla starts.
  Future<void> stopXray() async {
    if (_xray.state.running) await _xray.disconnect();
    await _stopPsiphon();
    await _stopLantern();
    await _stopOpenVpn();
    await _stopAether();
  }

  // ------------------------------------------------------------ toggles
  // The bottom bar's power capsule drives the current engine.
  // These are the home pages' old toggles, moved here unchanged
  // in behavior (same arbitration, same error faces).

  Future<void> _toggleMozilla(BuildContext context) async {
    final on = core.status?.state.phase == Phase.running;
    setState(() => _mozBusy = true);
    try {
      if (!on) {
        // Build 2034: the bootstrap handoff runs BEFORE Mozilla
        // takes over — the donor engine connects, the core
        // fetches and stores a Guardian pass through it, the
        // donor stops, and only then does Mozilla connect,
        // directly, on the stored pass.
        final verdict = await _bootstrap.prepareIfNeeded();
        if (verdict.cancelled) return;
        if (!verdict.proceed) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(verdict.message ?? 'Bootstrap failed')),
            );
          }
          return;
        }
        await stopXray();
      }
      await core.setOn(!on);
    } catch (e) {
      // Build 2070 (review §3.4): a plain line, not the raw
      // exception — the technical detail lives in the core's
      // own log and, for native failures, in crash.log.
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).startFailed)),
        );
      }
    } finally {
      if (mounted) setState(() => _mozBusy = false);
    }
  }

  Future<void> _toggleXray(BuildContext context) async {
    final l = AppLocalizations.of(context);
    try {
      if (_xray.state.running) {
        await _xray.disconnect();
      } else {
        await _xray.connect();
        // Build 2065 (item 4): a connect that stays up and
        // carries traffic becomes this network's winner.
        unawaited(_recordXrayWinnerDelayed());
      }
    } on StateError catch (e) {
      if (!context.mounted) return;
      final message = switch (e.message) {
        'no-profile' => l.noProfileSelected,
        'unsupported' => l.unsupportedProtocol,
        _ => l.startFailed,
      };
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    } catch (e) {
      // Build 2070 (review §3.4): the technical detail is
      // journaled — it lands in diagnostics.log, the log
      // viewer's first section — and the snackbar shows the
      // plain line instead of the raw exception.
      _xray.diagnostics.add('start', '$e', ok: false);
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(l.startFailed)));
      }
    }
  }

  Future<void> _toggleLantern(BuildContext context) async {
    try {
      if (_lantern.state.running) {
        await _lantern.disconnect();
      } else {
        await _lantern.connect();
      }
    } on StateError catch (e) {
      if (!context.mounted) return;
      // Loud failure, by design: the platform's own words (the
      // core's error or the service's) reach the user, not a
      // generic line — the log tail is on the Lantern page.
      final message = _lantern.lastError ?? e.message;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            message.length > 160 ? '${message.substring(0, 160)}…' : message,
          ),
        ),
      );
    } catch (e) {
      // Build 2070 (review §3.4): a plain line, not the raw
      // exception — the detail stays in the controller's
      // lastError and the engine's log page.
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).startFailed)),
        );
      }
    }
  }

  Future<void> _toggleOpenVpn(BuildContext context) async {
    try {
      if (_openvpn.state.running) {
        await _openvpn.disconnect();
      } else {
        await connectOpenVpnWithPrompt(context, _openvpn);
      }
    } on StateError catch (e) {
      if (!context.mounted) return;
      // Loud failure, like Lantern's: the platform's own words
      // reach the user; the log tail is on the OpenVPN page.
      final message = _openvpn.lastError ?? e.message;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            message.length > 160 ? '${message.substring(0, 160)}…' : message,
          ),
        ),
      );
    } catch (e) {
      // Build 2070 (review §3.4): a plain line, not the raw
      // exception — the detail stays in the controller's
      // lastError and the engine's log page.
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).startFailed)),
        );
      }
    }
  }

  /// The WireGuard section's toggle: the Xray engine's, except
  /// a WireGuard selection connects with peer fallback.
  Future<void> _toggleWireGuard(BuildContext context) async {
    final l = AppLocalizations.of(context);
    final selected = _xray.selected;
    try {
      if (_xray.state.running) {
        await _xray.disconnect();
      } else if (selected != null && selected.protocol == Protocol.wireguard) {
        await _xray.connectWireGuardWithFallback(selected);
      } else {
        await _toggleXray(context);
      }
    } on StateError catch (e) {
      if (context.mounted) {
        // Build 2074 (audit item 6): the plain-sentence pattern
        // like the sibling toggles — the raw StateError message
        // (unbounded, possibly platform-localised) no longer
        // reaches the SnackBar; only the one known code keeps
        // its own plain sentence, everything else is the
        // shared start-failed line.
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              e.message == 'wg-all-peers-failed'
                  ? 'No peer of this config carried traffic'
                  : l.startFailed,
            ),
          ),
        );
      }
    } catch (e) {
      // Build 2070 (review §3.4): a plain line, not the raw
      // exception — the detail stays in the controller's
      // lastError and the engine's log page.
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).startFailed)),
        );
      }
    }
  }

  Future<void> _toggleAether(
    BuildContext context,
    AetherController controller,
  ) async {
    try {
      if (controller.tunRunning || controller.state.running) {
        await controller.disconnect();
      } else {
        await controller.connect();
      }
    } on StateError catch (e) {
      if (!context.mounted) return;
      final message = controller.lastError ?? e.message;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            message.length > 160 ? '${message.substring(0, 160)}…' : message,
          ),
        ),
      );
    } catch (e) {
      // Build 2070 (review §3.4): a plain line, not the raw
      // exception — the detail stays in the controller's
      // lastError and the engine's log page.
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).startFailed)),
        );
      }
    }
  }

  Future<void> _togglePsiphon(BuildContext context) async {
    final l = AppLocalizations.of(context);
    try {
      if (_psiphon.state.running) {
        await _psiphon.disconnect();
      } else {
        await _psiphon.connect();
      }
    } on StateError {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(l.startFailed)));
      }
    } catch (e) {
      // Build 2070 (review §3.4): a plain line, not the raw
      // exception — the detail stays in the controller's
      // lastError and the engine's log page.
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(l.startFailed)));
      }
    }
  }

  // -------------------------------------------------------------- state

  bool _engineActive(int m) {
    switch (m) {
      case 0:
        final phase = core.status?.state.phase;
        return phase == Phase.running || phase == Phase.starting;
      case 1:
        return _xray.state.running || _xray.connecting;
      case 2:
        return _psiphon.state.connected || _psiphon.state.running;
      case 3:
        return _lantern.state.connected || _lantern.state.running;
      case 4:
        return _openvpn.state.connected || _openvpn.state.running;
      case 5:
        return _xray.state.running || _xray.connecting;
      case 6:
        return _warp.connected || _warp.state.running;
      case 7:
        return _masque.connected || _masque.state.running;
    }
    return false;
  }

  void _chipTap(int m) {
    // Switching to a different engine abandons a pending
    // pause-resume (build 2033): the timer must never connect
    // an engine the user has navigated away from.
    if (_pausedMode != null && m != _pausedMode) _cancelPause();
    // Same rule for a Mozilla bootstrap handoff (build 2034):
    // navigating away cancels it, and its cleanup stops the
    // donor it started.
    if (m != 0) _bootstrap.cancel();
    setState(() {
      if (m == mode && _tab != 0) {
        _tab = 0;
      } else {
        mode = m;
        if (_tab == 3) _tab = 0;
      }
    });
    _applyCadence();
  }

  // ------------------------------------------------------ pause (2033)

  /// The current mode's own power toggle — the same matched
  /// connect/disconnect pair the bottom bar drives.
  Future<void> _toggleForMode(BuildContext context, int m) {
    switch (m) {
      case 0:
        return _toggleMozilla(context);
      case 1:
        return _toggleXray(context);
      case 2:
        return _togglePsiphon(context);
      case 3:
        return _toggleLantern(context);
      case 4:
        return _toggleOpenVpn(context);
      case 5:
        return _toggleWireGuard(context);
      case 6:
        return _toggleAether(context, _warp);
      case 7:
        return _toggleAether(context, _masque);
    }
    return Future<void>.value();
  }

  bool get _anyEngineActive =>
      _engineActive(0) ||
      _engineActive(1) ||
      _engineActive(2) ||
      _engineActive(3) ||
      _engineActive(4) ||
      _engineActive(6) ||
      _engineActive(7);

  // ------------------------------------- build 2065: fallback chain
  // (item 5), per-network winner memory (item 4), auto-connect
  // triggers (item 14), scheduled subscription health (item 12).

  StreamSubscription<NetworkIdentity>? _netSub;
  Timer? _healthTimer;
  String _currentNetworkKey = '';

  /// The cross-engine chain's live status line, shown above the
  /// power bar while a chain run is in flight (and briefly after).
  String _chainStatus = '';
  bool _chainRunning = false;

  static String _engineLabel(int m) => switch (m) {
    0 => 'Mozilla',
    1 => 'V2Ray',
    2 => 'Psiphon',
    3 => 'Lantern',
    4 => 'OpenVPN',
    5 => 'WireGuard',
    6 => 'WARP',
    7 => 'MASQUE',
    _ => 'Engine',
  };

  /// The power capsule's single entry point (build 2065): a
  /// power-off always goes to the current engine's own toggle; a
  /// power-on routes through the fallback chain when the owner
  /// enabled it and the current engine is part of the chain.
  Future<void> _powerToggle(BuildContext context, int m) async {
    if (_anyEngineActive || _chainRunning) {
      if (_chainRunning) return;
      await _toggleForMode(context, m);
      return;
    }
    final s = widget.settings;
    if (s.fallbackChainEnabled && s.fallbackChain.contains(m)) {
      await _connectWithChain(context);
      return;
    }
    await _toggleForMode(context, m);
  }

  /// One engine's raw connect with a hard budget. Returns true
  /// only when the engine reports itself up afterwards. A connect
  /// that outlives its budget is treated as failed and stopped by
  /// the caller before the next engine starts (single-engine
  /// rule). The chain advances on CONNECT failure only — a tunnel
  /// that drops later belongs to auto-reconnect and the kill
  /// switch, not to the chain.
  Future<bool> _tryConnectMode(int m) async {
    try {
      switch (m) {
        case 0:
          await core.setOn(true).timeout(const Duration(seconds: 45));
          for (var i = 0; i < 20; i++) {
            if (core.status?.state.phase == Phase.running) return true;
            if (core.status?.state.phase == Phase.off) break;
            await Future<void>.delayed(const Duration(milliseconds: 500));
          }
          return core.status?.state.phase == Phase.running;
        case 1:
        case 5:
          await _xray.connect().timeout(const Duration(seconds: 60));
          return _xray.state.running;
        case 2:
          await _psiphon.connect().timeout(const Duration(seconds: 150));
          return _psiphon.state.running;
        case 3:
          await _lantern.connect().timeout(const Duration(seconds: 90));
          return _lantern.state.running;
        case 4:
          await _openvpn.connect().timeout(const Duration(seconds: 60));
          return _openvpn.state.running;
        case 6:
          await _warp.connect().timeout(const Duration(seconds: 60));
          return _warp.connected;
        case 7:
          await _masque.connect().timeout(const Duration(seconds: 60));
          return _masque.connected;
      }
    } catch (_) {
      return false;
    }
    return false;
  }

  Future<void> _disconnectMode(int m) async {
    try {
      switch (m) {
        case 0:
          await _stopMozilla();
        case 1:
        case 5:
          if (_xray.state.running) await _xray.disconnect();
        case 2:
          await _stopPsiphon();
        case 3:
          await _stopLantern();
        case 4:
          await _stopOpenVpn();
        case 6:
        case 7:
          await _stopAether();
      }
    } catch (_) {
      // A failed stop must not wedge the chain; the next engine's
      // own stopOtherEngine arbitration is the backstop.
    }
  }

  /// The cross-engine fallback run (build 2065, item 5): tries the
  /// owner's chain starting from the selected engine, each with
  /// its own budget, until one connects. Bounded by the chain
  /// length — no loops.
  Future<void> _connectWithChain(BuildContext context) async {
    if (_chainRunning || _anyEngineActive) return;
    final chain = widget.settings.fallbackChain;
    if (chain.isEmpty) return;
    final start = mode;
    final idx = chain.indexOf(start);
    final order = idx >= 0
        ? [...chain.sublist(idx), ...chain.sublist(0, idx)]
        : [...chain];
    _chainRunning = true;
    try {
      for (var i = 0; i < order.length; i++) {
        final m = order[i];
        if (!mounted) return;
        setState(() {
          mode = m;
          // Build 2074 (audit item 27): the counts route
          // through latDigits like every displayed number.
          _chainStatus =
              'Fallback chain: trying ${_engineLabel(m)} '
              '(${latDigits(i + 1)} of ${latDigits(order.length)}) — '
              '${order.map(_engineLabel).join(' → ')}';
        });
        _applyCadence();
        final ok = await _tryConnectMode(m);
        if (ok) {
          if (mounted) {
            setState(
              () => _chainStatus =
                  'Fallback chain: connected via ${_engineLabel(m)}',
            );
          }
          if (m == 1 || m == 5) unawaited(_recordXrayWinnerDelayed());
          return;
        }
        await _disconnectMode(m);
      }
      if (mounted) {
        setState(
          () => _chainStatus =
              'Fallback chain: every engine failed on this network',
        );
      }
    } finally {
      _chainRunning = false;
    }
  }

  /// Records the Xray winner for the current network once the
  /// tunnel has had time to prove it carries traffic (item 4).
  Future<void> _recordXrayWinnerDelayed() async {
    await Future<void>.delayed(const Duration(seconds: 10));
    if (!mounted) return;
    final st = _xray.state;
    if (st.running &&
        st.upBytes + st.downBytes > 0 &&
        _currentNetworkKey.isNotEmpty) {
      await _xray.rememberWinnerForNetwork(_currentNetworkKey);
    }
  }

  bool _isTrustedNetwork(NetworkIdentity id) =>
      id.isWifi &&
      id.ssid.isNotEmpty &&
      widget.settings.trustedSsids.contains(id.ssid);

  /// Applies a network identity: keys the winner memories,
  /// preselects the remembered Xray profile, and fires the
  /// auto-connect triggers the owner enabled (item 14).
  Future<void> _handleNetwork(
    NetworkIdentity id, {
    required bool initial,
  }) async {
    final changed = !initial && id.key != _currentNetworkKey;
    _currentNetworkKey = id.key;
    _psiphon.settings.networkKey = id.key;
    // Build 2066: edge results measured on the old network are
    // void on the new one — the next Psiphon connect re-probes
    // before feeding anything to the core at probability 1.0.
    if (changed) unawaited(_psiphon.invalidateEdgeResults());
    _xray.preselectForNetwork(id.key);
    unawaited(_xray.maybeRunScheduledHealth());
    final s = widget.settings;
    if (!s.emberAutoConnect || _anyEngineActive || _chainRunning) return;
    if (initial) {
      final booted = await NetworkInfoService.consumeBootPending();
      if (booted && s.autoConnectOnBoot) {
        await _autoConnect();
        return;
      }
      if (s.autoConnectOnUntrustedWifi && id.isWifi && !_isTrustedNetwork(id)) {
        await _autoConnect();
      }
      return;
    }
    if (changed && s.autoConnectOnNetworkChange && !_isTrustedNetwork(id)) {
      await _autoConnect();
    }
  }

  Future<void> _autoConnect() async {
    if (!mounted || _anyEngineActive || _chainRunning) return;
    final s = widget.settings;
    if (s.fallbackChainEnabled && s.fallbackChain.contains(mode)) {
      await _connectWithChain(context);
    } else {
      await _toggleForMode(context, mode);
    }
  }

  void _armNetworkTracking() {
    _netSub = NetworkInfoService.changes.listen((id) {
      if (mounted) unawaited(_handleNetwork(id, initial: false));
    });
    _healthTimer = Timer.periodic(const Duration(minutes: 30), (_) {
      unawaited(_xray.maybeRunScheduledHealth());
    });
    unawaited(
      NetworkInfoService.current().then((id) {
        if (mounted) unawaited(_handleNetwork(id, initial: true));
      }),
    );
  }

  /// Disconnects the current engine and schedules its return.
  Future<void> _pauseConnection(BuildContext context, Duration d) async {
    final m = mode;
    setState(() {
      _pausedMode = m;
      _resumeAt = DateTime.now().add(d);
    });
    _pauseTimer?.cancel();
    _pauseTimer = Timer(d, _onPauseTimer);
    _pauseTicker?.cancel();
    _pauseTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    await _toggleForMode(context, m);
  }

  void _onPauseTimer() {
    _pauseTicker?.cancel();
    _pauseTicker = null;
    final m = _pausedMode;
    _pausedMode = null;
    _resumeAt = null;
    if (!mounted || m == null) return;
    setState(() {});
    // The user resumed by hand meanwhile, or connected
    // something else: the pause's job is done either way —
    // never toggle an engine that is already up.
    if (_anyEngineActive) return;
    unawaited(_toggleForMode(context, m));
  }

  /// Resume now: cancel the schedule and reconnect at once.
  void _resumePause(BuildContext context) {
    final m = _pausedMode;
    if (m == null) return;
    _pauseTimer?.cancel();
    _pauseTimer = null;
    _pauseTicker?.cancel();
    _pauseTicker = null;
    setState(() {
      _pausedMode = null;
      _resumeAt = null;
    });
    if (_anyEngineActive) return;
    unawaited(_toggleForMode(context, m));
  }

  /// Cancel the schedule; the engine stays off.
  void _cancelPause() {
    _pauseTimer?.cancel();
    _pauseTimer = null;
    _pauseTicker?.cancel();
    _pauseTicker = null;
    if (mounted) {
      setState(() {
        _pausedMode = null;
        _resumeAt = null;
      });
    } else {
      _pausedMode = null;
      _resumeAt = null;
    }
  }

  String get _pauseCountdown {
    final at = _resumeAt;
    if (at == null) return '';
    final left = at.difference(DateTime.now());
    if (left.isNegative) return '0:00';
    final mm = left.inMinutes;
    final ss = (left.inSeconds % 60).toString().padLeft(2, '0');
    // Build 2074 (audit item 27): Latin digits, like every
    // other displayed number.
    return latDigits('$mm:$ss');
  }

  /// The strip above the bottom bar (build 2033): a Pause
  /// button while the current engine is connected; the
  /// countdown with Resume/Cancel while a pause is pending
  /// for the mode on screen.
  Widget _pauseStrip(BuildContext context, {required bool engineOn}) {
    if (_pausedMode != null) {
      if (_pausedMode != mode) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.pause_circle_rounded,
              size: 17,
              color: Ember.orange,
            ),
            const SizedBox(width: 6),
            // Build 2058 (audit §5 Shell/Home): the strip was a
            // non-wrapping Row — "Paused · resumes in 59:59" +
            // two buttons overflowed a 360 px phone. The label
            // flexes and ellipsises; the actions stay put.
            Flexible(
              child: Text(
                'Paused · resumes in $_pauseCountdown',
                style: Ember.caption.copyWith(color: Ember.text),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),
            const SizedBox(width: 10),
            TextButton(
              onPressed: () => _resumePause(context),
              child: const Text('Resume now'),
            ),
            TextButton(onPressed: _cancelPause, child: const Text('Cancel')),
          ],
        ),
      );
    }
    if (!engineOn) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Align(
        alignment: Alignment.centerRight,
        child: TextButton.icon(
          onPressed: () => unawaited(_pickPauseDuration(context)),
          icon: const Icon(Icons.pause_rounded, size: 16),
          label: const Text('Pause'),
        ),
      ),
    );
  }

  Future<void> _pickPauseDuration(BuildContext context) async {
    final d = await showModalBottomSheet<Duration>(
      context: context,
      backgroundColor: Ember.surface,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Build 2058 (audit §5 Shell/Home): the sheet was a
            // bare stock list — now a titled Ember sheet with
            // the orange pause mark on every duration row.
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
              child: Row(
                children: [
                  const Icon(
                    Icons.pause_rounded,
                    size: 17,
                    color: Ember.orange,
                  ),
                  const SizedBox(width: 8),
                  Text('Pause connection', style: Ember.heading),
                ],
              ),
            ),
            for (final (label, dur) in [
              ('Pause for 5 minutes', const Duration(minutes: 5)),
              ('Pause for 15 minutes', const Duration(minutes: 15)),
              ('Pause for 30 minutes', const Duration(minutes: 30)),
              ('Pause for 1 hour', const Duration(hours: 1)),
            ])
              ListTile(
                leading: const Icon(
                  Icons.pause_rounded,
                  size: 18,
                  color: Ember.orange,
                ),
                title: Text(label, style: Ember.body),
                onTap: () => Navigator.of(sheetContext).pop(dur),
              ),
          ],
        ),
      ),
    );
    if (d == null || !context.mounted) return;
    await _pauseConnection(context, d);
  }

  /// The map actors for the current mode, derived only from real
  /// data: a chosen location, profile remarks, or a through-tunnel
  /// exit lookup. Null selection = no pin, no arc.
  ({Set<String> pins, String? selected, bool connected, String? badge})
  _actors() {
    final home = (
      pins: <String>{},
      selected: null,
      connected: false,
      badge: null,
    );
    switch (mode) {
      case 0:
        final status = core.status;
        final on = status?.state.phase == Phase.running;
        final exit = status?.exit;
        final proxy = status?.proxy;
        final code = on && exit != null && exit.countryCode.isNotEmpty
            ? exit.countryCode
            : proxy?.countryCode;
        if (code == null || code.isEmpty) return home;
        final country = on && exit != null && exit.countryName.isNotEmpty
            ? exit.countryName
            : proxy?.countryName ?? '';
        final city = on && exit != null && exit.city.isNotEmpty
            ? exit.city
            : proxy?.cityName ?? '';
        final badge = country.isEmpty
            ? null
            : (city.isEmpty ? country : '$country • $city').toUpperCase();
        return (pins: <String>{}, selected: code, connected: on, badge: badge);
      case 1:
        final pins = <String>{};
        for (final profile in _xray.profiles) {
          final code = profileCountryCode(profile);
          if (code != null) pins.add(code);
        }
        final on = _xray.state.running;
        final exitCode = on ? _xray.exitInfo?.countryCode : null;
        if (exitCode != null && exitCode.isNotEmpty) pins.add(exitCode);
        final selected = _xray.selected == null
            ? null
            : profileCountryCode(_xray.selected!);
        final active =
            selected ??
            (exitCode != null && exitCode.isNotEmpty ? exitCode : null);
        final badge = on && _xray.exitInfo != null
            ? _xray.exitInfo!.displayName.toUpperCase()
            : null;
        return (pins: pins, selected: active, connected: on, badge: badge);
      case 2:
        final state = _psiphon.state;
        final code = state.connected && state.region.isNotEmpty
            ? state.region
            : (_psiphon.settings.region.isNotEmpty
                  ? _psiphon.settings.region
                  : null);
        return (
          pins: <String>{},
          selected: code,
          connected: state.connected,
          badge: code == null
              ? null
              : 'EXIT • ${regionName(code).toUpperCase()}',
        );
      case 3:
        final state = _lantern.state;
        final code = state.connected && state.exitCode.isNotEmpty
            ? state.exitCode
            : null;
        final badge = !state.connected || state.exitLine.isEmpty
            ? null
            : 'EXIT • ${state.exitLine.toUpperCase()}';
        return (
          pins: <String>{},
          selected: code,
          connected: state.connected,
          badge: badge,
        );
      case 4:
        final state = _openvpn.state;
        // Build 2028: imported profiles carry no country —
        // the pin is the exit's code once connected, nothing
        // before (the bundled TunnelBear list that supplied a
        // per-profile code is gone).
        final code = state.connected && state.exitCode.isNotEmpty
            ? state.exitCode
            : null;
        final badge = !state.connected || state.exitCountry.isEmpty
            ? null
            : 'EXIT • ${state.exitCountry.toUpperCase()}';
        return (
          pins: <String>{},
          selected: code,
          connected: state.connected,
          badge: badge,
        );
      case 5:
        // WireGuard: V2Ray's actors, narrowed to the section —
        // pins from WG profiles' remarks, the badge from the
        // live exit lookup.
        final pins = <String>{};
        for (final profile in _xray.profiles) {
          if (profile.protocol != Protocol.wireguard) continue;
          final code = profileCountryCode(profile);
          if (code != null) pins.add(code);
        }
        final on = _xray.state.running;
        final exitCode = on ? _xray.exitInfo?.countryCode : null;
        if (exitCode != null && exitCode.isNotEmpty) pins.add(exitCode);
        final sel = _xray.selected;
        final selected = (sel != null && sel.protocol == Protocol.wireguard)
            ? profileCountryCode(sel)
            : (exitCode != null && exitCode.isNotEmpty ? exitCode : null);
        final badge = on && _xray.exitInfo != null
            ? _xray.exitInfo!.displayName.toUpperCase()
            : null;
        return (pins: pins, selected: selected, connected: on, badge: badge);
      case 6:
      case 7:
        // WARP / MASQUE: the pin is the trace's country once
        // the engine is connected and a trace has answered.
        final c = mode == 6 ? _warp : _masque;
        final t = c.exitTrace;
        final loc = (t?['loc'] ?? '').toUpperCase();
        final code = c.connected && loc.length == 2 ? loc : null;
        final badge = code == null
            ? null
            : 'EXIT • ${(t?['ip'] ?? '').isEmpty ? code : '${t!['ip']} • $code'}';
        return (
          pins: <String>{},
          selected: code,
          connected: c.connected,
          badge: badge,
        );
    }
    return home;
  }

  /// The bottom bar's model for the current engine: the power
  /// state, the state word, up to four telemetry cells (real
  /// backend values only; "—" where an engine has none), and the
  /// latency/engine micro-line.
  ({
    bool on,
    bool busy,
    String stateWord,
    List<({String label, String value})> cells,
    String microLine,
    VoidCallback onToggle,
  })
  _barModel(BuildContext context) {
    switch (mode) {
      case 0:
        final status = core.status;
        final phase = status?.state.phase ?? Phase.off;
        final on = phase == Phase.running;
        final busy = _mozBusy || phase == Phase.starting;
        final proxy = status?.proxy;
        final traffic = status?.traffic;
        final cityCountry = proxy == null
            ? ''
            : [
                if (proxy.cityName.isNotEmpty) proxy.cityName,
                if (proxy.countryName.isNotEmpty) proxy.countryName,
              ].join(' • ');
        final exitIp = status?.exit?.ipv4.isNotEmpty == true
            ? status!.exit!.ipv4
            : (status?.lastTest?.exitIpv4 ?? '');
        final test = status?.lastTest;
        return (
          on: on,
          busy: busy,
          stateWord: on
              ? 'Connected'
              : busy
              ? 'Connecting…'
              : 'Not connected',
          cells: [
            (label: 'LOCATION', value: cityCountry.isEmpty ? '—' : cityCountry),
            (label: 'EXIT IP', value: exitIp.isEmpty ? '—' : exitIp),
            (
              label: 'UP',
              value: on && traffic != null ? fmtRate(traffic.upRate) : '—',
            ),
            (
              label: 'DOWN',
              value: on && traffic != null ? fmtRate(traffic.downRate) : '—',
            ),
          ],
          microLine: on && test != null && test.ok && test.responseMs > 0
              ? 'LATENCY ${latDigits(test.responseMs)}ms • MOZILLA'
              : 'MOZILLA',
          onToggle: () => unawaited(_powerToggle(context, mode)),
        );
      case 1:
        final on = _xray.state.running;
        final p = _xray.selected;
        final exit = _xray.exitInfo;
        final proto = p?.protocol.label;
        return (
          on: on,
          busy: _xray.connecting,
          stateWord: on
              ? 'Connected'
              : _xray.connecting
              ? 'Connecting…'
              : 'Not connected',
          cells: [
            // Build 2027: a running core whose config is no
            // longer in the list (see the V2Ray home card)
            // reads "Running", never a contradictory "—"
            // beside a connected engine.
            (
              label: 'ACTIVE CONFIG',
              value: p?.displayName ?? (on ? 'Running' : '—'),
            ),
            (
              label: 'EXIT IP',
              value: on && exit != null && exit.ip.isNotEmpty ? exit.ip : '—',
            ),
            (label: 'UP', value: on ? fmtRate(_xray.upRate) : '—'),
            (label: 'DOWN', value: on ? fmtRate(_xray.downRate) : '—'),
          ],
          microLine: on && p != null && p.delayMs >= 0
              ? 'LATENCY ${latDigits(p.delayMs)}ms • ${proto!.toUpperCase()}'
              : (proto?.toUpperCase() ?? 'V2RAY'),
          onToggle: () => unawaited(_powerToggle(context, mode)),
        );
      case 2:
        final state = _psiphon.state;
        final on = state.connected;
        final busy = _psiphon.connecting || (state.running && !on);
        final region = state.region.isNotEmpty
            ? state.region
            : _psiphon.settings.region;
        return (
          on: on,
          busy: busy,
          stateWord: on
              ? 'Connected via Psiphon'
              : busy
              ? 'Connecting…'
              : 'Not connected',
          cells: [
            (
              label: 'EXIT REGION',
              value: region.isEmpty ? 'Automatic' : regionName(region),
            ),
            (
              label: 'SESSION',
              value: state.running && state.sinceMs > 0
                  ? fmtDuration(
                      DateTime.now().difference(
                        DateTime.fromMillisecondsSinceEpoch(state.sinceMs),
                      ),
                    )
                  : '—',
            ),
            (
              label: 'UP',
              value: state.running ? fmtRate(_psiphon.upRate) : '—',
            ),
            (
              label: 'DOWN',
              value: state.running ? fmtRate(_psiphon.downRate) : '—',
            ),
          ],
          microLine: 'PSIPHON',
          onToggle: () => unawaited(_powerToggle(context, mode)),
        );
      case 3:
        final state = _lantern.state;
        final on = state.connected;
        final busy =
            _lantern.connecting ||
            (state.running && !on) ||
            (state.coreRunning && !on);
        return (
          on: on,
          busy: busy,
          stateWord: on
              ? 'Connected via Lantern'
              : busy
              ? 'Connecting…'
              : 'Not connected',
          cells: [
            (
              label: 'EXIT',
              value: state.exitLine.isEmpty ? '—' : state.exitLine,
            ),
            (
              label: 'SERVERS',
              value: state.servers >= 0 ? latDigits(state.servers) : '—',
            ),
            (
              label: 'UP',
              value: state.running ? fmtRate(_lantern.upRate) : '—',
            ),
            (
              label: 'DOWN',
              value: state.running ? fmtRate(_lantern.downRate) : '—',
            ),
          ],
          microLine: 'LANTERN',
          onToggle: () => unawaited(_powerToggle(context, mode)),
        );
      case 4:
        final state = _openvpn.state;
        final on = state.connected;
        final busy = _openvpn.connecting || (state.running && !on);
        final p = _openvpn.selected;
        return (
          on: on,
          busy: busy,
          stateWord: on
              ? 'Connected via OpenVPN'
              : busy
              ? 'Connecting…'
              : 'Not connected',
          cells: [
            (label: 'PROFILE', value: p?.name ?? '—'),
            (
              label: 'EXIT IP',
              value: on && state.exitIp.isNotEmpty ? state.exitIp : '—',
            ),
            (
              label: 'UP',
              value: state.running ? fmtRate(_openvpn.upRate) : '—',
            ),
            (
              label: 'DOWN',
              value: state.running ? fmtRate(_openvpn.downRate) : '—',
            ),
          ],
          microLine: 'OPENVPN',
          onToggle: () => unawaited(_powerToggle(context, mode)),
        );
      case 5:
        final on = _xray.state.running;
        final p = _xray.selected;
        final wg = p != null && p.protocol == Protocol.wireguard ? p : null;
        final exit = _xray.exitInfo;
        return (
          on: on,
          busy: _xray.connecting,
          stateWord: on
              ? 'Connected'
              : _xray.connecting
              ? 'Connecting…'
              : 'Not connected',
          cells: [
            (label: 'CONFIG', value: wg?.displayName ?? (on ? 'Running' : '—')),
            (
              label: 'EXIT IP',
              value: on && exit != null && exit.ip.isNotEmpty ? exit.ip : '—',
            ),
            (label: 'UP', value: on ? fmtRate(_xray.upRate) : '—'),
            (label: 'DOWN', value: on ? fmtRate(_xray.downRate) : '—'),
          ],
          microLine: 'WIREGUARD',
          onToggle: () => unawaited(_powerToggle(context, mode)),
        );
      case 6:
      case 7:
        final c = mode == 6 ? _warp : _masque;
        final state = c.state;
        final on = c.connected;
        final busy = c.connecting || (state.running && !on);
        final t = c.exitTrace;
        return (
          on: on,
          busy: busy,
          stateWord: on
              ? 'Connected via ${mode == 6 ? 'WARP' : 'MASQUE'}'
              : busy
              ? (state.stageLabel.isNotEmpty ? state.stageLabel : 'Connecting…')
              : 'Not connected',
          cells: [
            (
              label: 'ENDPOINT',
              value: state.server.isEmpty ? '—' : state.server,
            ),
            (
              label: 'EXIT IP',
              value: on && t != null && (t['ip'] ?? '').isNotEmpty
                  ? t['ip']!
                  : '—',
            ),
            (label: 'UP', value: c.tunRunning ? fmtRate(c.upRate) : '—'),
            (label: 'DOWN', value: c.tunRunning ? fmtRate(c.downRate) : '—'),
          ],
          microLine: mode == 6
              ? 'WARP'
              : 'MASQUE • ${c.options.protocol.toUpperCase()}',
          onToggle: () => unawaited(_powerToggle(context, mode)),
        );
    }
    throw StateError('unknown mode $mode');
  }

  // --------------------------------------------------------------- build

  Widget _header() {
    const names = [
      'Mozilla',
      'V2Ray',
      'Psiphon',
      'Lantern',
      'OpenVPN',
      'WireGuard',
      'WARP',
      'MASQUE',
    ];
    // The chips read every engine's live state, so the header
    // rebuilds on every engine controller — not only Mozilla's
    // (build 2025 fix: the shell's own rebuild used to be the
    // only trigger, and a non-Mozilla chip could sit stale,
    // missing its ACTIVE pill, until an incidental rebuild).
    return ListenableBuilder(
      listenable: Listenable.merge([
        core,
        _xray,
        _psiphon,
        _lantern,
        _openvpn,
        _warp,
        _masque,
      ]),
      builder: (context, _) {
        // Build 2074 (audit item 1): the rail is a horizontally
        // scrollable strip under the brand row — the same nine
        // chips, in the same order, with the same tap behaviour
        // — instead of the vertical stack that took 436 dp of
        // header (and, per build 2057's note, overflowed short
        // windows). The selected chip is scrolled into view
        // whenever the selection changes.
        if (_tab != 3) _ensureRailVisible(mode);
        final rail = <Widget>[
          for (var i = 0; i < names.length; i++)
            MapEngineChip(
              key: _railKeys[i],
              name: names[i],
              active: _engineActive(i),
              highlight: mode == i,
              onTap: () => _chipTap(i),
            ),
          MapEngineChip(
            key: _railKeys[8],
            name: 'Settings',
            icon: Icons.settings_rounded,
            active: false,
            highlight: false,
            onTap: () => setState(() => _tab = 3),
          ),
        ];
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      MapBrandPanel(
                        versionLine: 'v$appVersion • BUILD $appBuildNumber',
                      ),
                      if (_tab == 0 && (mode == 0 || mode == 4)) ...[
                        const SizedBox(height: 8),
                        MapNavPill(
                          icon: Icons.place_rounded,
                          label: 'Locations',
                          onTap: () => setState(() => _tab = 1),
                        ),
                        // Build 2028: no Account pill in OpenVPN
                        // mode — OpenVPN is a generic client with
                        // per-profile credentials, no account page.
                        if (mode == 0) ...[
                          const SizedBox(height: 6),
                          MapNavPill(
                            icon: Icons.person_rounded,
                            label: 'Account',
                            onTap: () => setState(() => _tab = 2),
                          ),
                        ],
                      ],
                    ],
                  ),
                  const Spacer(),
                  if (_tab == 3)
                    MapEngineChip(
                      name: 'Settings',
                      icon: Icons.close_rounded,
                      active: true,
                      highlight: true,
                      onTap: () => setState(() => _tab = 0),
                    ),
                ],
              ),
              if (_tab != 3) ...[
                const SizedBox(height: 10),
                SizedBox(
                  height: 44,
                  child: SingleChildScrollView(
                    controller: _railController,
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (var i = 0; i < rail.length; i++) ...[
                          if (i > 0) const SizedBox(width: 6),
                          rail[i],
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.noCore != null) {
      return Scaffold(
        backgroundColor: MapUi.baseBottom,
        body: EmberBackground(child: SafeArea(child: widget.noCore!)),
      );
    }
    final v2ray = mode == 1;
    final psiphonMode = mode == 2;
    final lanternMode = mode == 3;
    final openvpnMode = mode == 4;
    final wgMode = mode == 5;
    final warpMode = mode == 6;
    final masqueMode = mode == 7;
    final pages = [
      EmberHome(
        core: core,
        xray: _xray,
        psiphon: _psiphon,
        lantern: _lantern,
        openvpn: _openvpn,
        warp: _warp,
        masque: _masque,
        mode: mode,
        onModeChanged: (m) {
          setState(() => mode = m);
          _applyCadence();
        },
        onOpenServers: () => setState(() => _tab = 1),
        onOpenAccounts: () => setState(() => _tab = 2),
        stopOtherEngine: stopXray,
      ),
      // In Psiphon mode the Servers tab is the exit-region list and
      // the Accounts tab the no-account status page; Lantern mode
      // swaps in its list-state view and its own status page.
      // Build 2032: WireGuard swaps in its own configurations
      // view; WARP/MASQUE swap in the endpoint view.
      if (psiphonMode)
        PsiphonRegionsView(
          psiphon: _psiphon,
          onClose: () => setState(() => _tab = 0),
        )
      else if (lanternMode)
        LanternServersView(
          lantern: _lantern,
          onClose: () => setState(() => _tab = 0),
        )
      else if (openvpnMode)
        OpenVpnServersView(
          openvpn: _openvpn,
          onClose: () => setState(() => _tab = 0),
        )
      else if (wgMode)
        WireGuardServersView(
          xray: _xray,
          onClose: () => setState(() => _tab = 0),
        )
      else if (warpMode)
        AetherServersView(
          controller: _warp,
          onClose: () => setState(() => _tab = 0),
        )
      else if (masqueMode)
        AetherServersView(
          controller: _masque,
          onClose: () => setState(() => _tab = 0),
        )
      else
        EmberServers(
          core: core,
          xray: _xray,
          v2ray: v2ray,
          onOpenAccounts: () => setState(() => _tab = 2),
          onClose: () => setState(() => _tab = 0),
          psiphon: _psiphon,
        ),
      if (psiphonMode)
        PsiphonAboutView(psiphon: _psiphon)
      else if (lanternMode)
        LanternAboutView(lantern: _lantern)
      else if (openvpnMode)
        OpenVpnStatusView(openvpn: _openvpn)
      else if (wgMode)
        WireGuardAboutView(xray: _xray)
      else if (warpMode)
        AetherAboutView(controller: _warp)
      else if (masqueMode)
        AetherAboutView(controller: _masque)
      else
        EmberAccounts(
          core: core,
          xray: _xray,
          v2ray: v2ray,
          onClose: () => setState(() => _tab = 0),
          bootstrap: _bootstrap,
        ),
      EmberSettings(
        core: core,
        xray: _xray,
        psiphon: _psiphon,
        lantern: _lantern,
        openvpn: _openvpn,
        settings: widget.settings,
        // Build 2056 (audit A-H5): the WARP/MASQUE modes need
        // their controllers for their own Settings sections.
        warp: _warp,
        masque: _masque,
      ),
    ];
    // Build 2050 (battery): hidden tabs get no tickers.
    // IndexedStack keeps every page mounted, so without this a
    // hidden page's perpetual animations (the Home power ring
    // above all) kept ticking — and repainting — through every
    // other tab.
    final gatedPages = [
      for (var i = 0; i < pages.length; i++)
        TickerMode(enabled: _tab == i, child: pages[i]),
    ];
    // The actors ride the map on the home page, and behind the
    // Mozilla locations panel (the samples keep the arc visible
    // around the sheet); panels elsewhere get the clean map.
    final showActors = _tab == 0 || (_tab == 1 && mode == 0);
    return Scaffold(
      backgroundColor: MapUi.baseBottom,
      body: Stack(
        children: [
          const Positioned.fill(child: MapBackdropVisual()),
          if (showActors)
            Positioned.fill(
              child: ListenableBuilder(
                listenable: Listenable.merge([
                  core,
                  _xray,
                  _psiphon,
                  _lantern,
                  _openvpn,
                  _warp,
                  _masque,
                ]),
                builder: (context, _) {
                  final a = _actors();
                  return _ActorsLayer(
                    pins: a.pins,
                    selected: a.selected,
                    connected: a.connected,
                    badge: a.badge,
                  );
                },
              ),
            ),
          SafeArea(
            bottom: false,
            child: Column(
              children: [
                if (widget.banner != null) widget.banner!,
                _header(),
                Expanded(
                  child: IndexedStack(index: _tab, children: gatedPages),
                ),
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                    child: ListenableBuilder(
                      listenable: Listenable.merge([
                        core,
                        _xray,
                        _psiphon,
                        _lantern,
                        _openvpn,
                        _warp,
                        _masque,
                      ]),
                      builder: (context, _) {
                        final bar = _barModel(context);
                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (_chainStatus.isNotEmpty)
                              // Build 2074 (audit item 10): the
                              // chain line caps at two lines with
                              // an ellipsis so it can no longer
                              // push the bottom bar over the page;
                              // the full chain stays one tap (or
                              // long-press tooltip) away in a sheet.
                              Padding(
                                padding: const EdgeInsets.only(bottom: 6),
                                child: Tooltip(
                                  message: _chainStatus,
                                  child: GestureDetector(
                                    onTap: () {
                                      showModalBottomSheet<void>(
                                        context: context,
                                        backgroundColor: Ember.surface,
                                        builder: (sheetContext) => SafeArea(
                                          child: Padding(
                                            padding: const EdgeInsets.fromLTRB(
                                              20,
                                              18,
                                              20,
                                              18,
                                            ),
                                            child: Text(
                                              _chainStatus,
                                              style: Ember.body,
                                            ),
                                          ),
                                        ),
                                      );
                                    },
                                    child: Text(
                                      _chainStatus,
                                      style: Ember.caption,
                                      textAlign: TextAlign.center,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ),
                              ),
                            _pauseStrip(context, engineOn: bar.on && !bar.busy),
                            MobileMapBar(
                              on: bar.on,
                              busy: bar.busy,
                              onToggle: bar.onToggle,
                              stateWord: bar.stateWord,
                              cells: bar.cells,
                              microLine: bar.microLine,
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The pulsing live-actors layer over the baked backdrop
/// (home marker, exit pin and badge, arc). Pointer-transparent:
/// it is pure decoration over the map.
class _ActorsLayer extends StatefulWidget {
  const _ActorsLayer({
    required this.pins,
    required this.selected,
    required this.connected,
    required this.badge,
  });

  final Set<String> pins;
  final String? selected;
  final bool connected;
  final String? badge;

  @override
  State<_ActorsLayer> createState() => _ActorsLayerState();
}

class _ActorsLayerState extends State<_ActorsLayer>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1700),
  );

  /// The painter's repaint clock (build 2050, audit B-H4):
  /// bucketed to ~12 fps. This layer paints the FULL screen;
  /// at frame rate it repainted the whole display for the
  /// entire connected time. A 1700 ms pulse is
  /// indistinguishable at 12 fps.
  late final _BucketedRepaint _repaint = _BucketedRepaint(_pulse);

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
  void didUpdateWidget(_ActorsLayer old) {
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
    _foreground = state == AppLifecycleState.resumed;
    _sync();
  }

  void _sync() {
    // Build 2057 (audit F-H10): a user (or the test harness) who
    // turns animations off gets no pulse — the perpetual controller
    // otherwise never lets pumpAndSettle settle, so no widget test
    // could ever cover the connected phone shell.
    final still = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (widget.connected && widget.selected != null && _foreground && !still) {
      if (!_pulse.isAnimating) _pulse.repeat();
    } else {
      _pulse.stop();
      _pulse.value = 0;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _repaint.dispose();
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: CustomPaint(
      painter: MapActorsPainter(
        pins: widget.pins,
        selected: widget.selected,
        connected: widget.connected,
        homeLabel: 'HOME • IRAN',
        exitBadge: widget.badge,
        pulseAnim: _pulse,
        repaint: _repaint,
      ),
      size: Size.infinite,
    ),
  );
}

/// A repaint listenable that quantizes an animation into
/// [stepsPerCycle] buckets, so a CustomPaint listening to it
/// repaints at a bounded rate instead of every frame
/// (build 2050).
class _BucketedRepaint extends ChangeNotifier {
  _BucketedRepaint(this._source) {
    _source.addListener(_onTick);
  }

  /// 20 buckets over the 1700 ms pulse cycle ≈ a 12 fps repaint.
  static const int stepsPerCycle = 20;

  final Animation<double> _source;
  int _bucket = -1;

  void _onTick() {
    final b = (_source.value * stepsPerCycle).floor();
    if (b != _bucket) {
      _bucket = b;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _source.removeListener(_onTick);
    super.dispose();
  }
}
