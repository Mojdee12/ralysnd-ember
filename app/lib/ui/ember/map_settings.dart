/// The Settings page of the Map Control shell (2.1.0): floating
/// dark glass panels in a two-column masonry over the map —
/// Connection and General down the left (the sample's
/// composition: connection-mode chips, the H2 protocol chip,
/// the local-port chip, Start with Windows), About / DNS /
/// Routing / More down the right, and the engine-management
/// section full-width underneath. Every control is a real
/// setting, wired exactly as the old desktop page wired it:
/// AppSettings for the app's own preferences, the core's
/// config map (routing / DNS / proxy transport) through
/// CoreController.settings/editSettings.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../app_info.dart';
import '../../app_settings.dart';
import '../../core/core_controller.dart';
import '../../core/updates.dart';
import '../../l10n/app_localizations.dart';
import '../../xray/xray_controller.dart';
import '../connection_mode.dart';
import '../settings_page.dart';
import 'ember_info.dart';
import 'ember_theme.dart';
import 'map_widgets.dart';

class MapSettingsPage extends StatefulWidget {
  const MapSettingsPage({
    super.key,
    required this.core,
    required this.settings,
    required this.engineSection,
    required this.xray,
  });

  final CoreController core;
  final AppSettings settings;

  /// The engine-management cards (Xray, Psiphon, …) the phone
  /// settings compose — appended full-width under the panel grid.
  final Widget engineSection;

  /// For the Connection panel's local-port chip (the V2Ray
  /// SOCKS port — edited in the engine section below).
  final XrayController xray;

  @override
  State<MapSettingsPage> createState() => _MapSettingsPageState();
}

class _MapSettingsPageState extends State<MapSettingsPage> {
  bool? _routing;
  bool? _doh;
  List<String> _servers = const [];
  String _transport = 'h2';
  bool _busy = false;

  CoreController get core => widget.core;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final settings = await core.settings();
      final routing = settings['routing'];
      final dns = settings['dns'];
      final proxy = settings['proxy'];
      final servers = dns is Map ? dns['servers'] : null;
      final list = servers is List ? servers : const [];
      if (mounted) {
        setState(() {
          _routing = routing is Map ? routing['enabled'] == true : false;
          _servers = [for (final s in list) s.toString()];
          _doh =
              list.isNotEmpty &&
              list.every(
                (s) =>
                    s.toString().startsWith('https://') ||
                    s.toString().startsWith('tls://'),
              );
          _transport = proxy is Map && proxy['transport'] == 'h3' ? 'h3' : 'h2';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _routing = false;
          _doh = true;
        });
      }
    }
  }

  Future<void> _edit(void Function(Map<String, Object?>) edit) async {
    setState(() => _busy = true);
    try {
      await core.editSettings(edit);
    } catch (_) {
      // The core's next answer restores the truth.
    } finally {
      if (mounted) setState(() => _busy = false);
      unawaited(_load());
    }
  }

  void _setDoh(bool v) => unawaited(
    _edit((config) {
      final dns = config['dns'];
      if (dns is Map<String, Object?>) {
        dns['servers'] = v
            ? [
                'https://1.1.1.1/dns-query',
                'https://8.8.8.8/dns-query',
                'https://9.9.9.9/dns-query',
              ]
            : ['1.1.1.1', '8.8.8.8'];
      }
    }),
  );

  void _setDohUrl(String v) => unawaited(
    _edit((config) {
      final dns = config['dns'];
      if (dns is Map<String, Object?>) {
        final t = v.trim();
        if (t.isEmpty) {
          dns['servers'] = [
            'https://1.1.1.1/dns-query',
            'https://8.8.8.8/dns-query',
            'https://9.9.9.9/dns-query',
          ];
        } else if (t.startsWith('https://')) {
          dns['servers'] = [t];
        }
      }
    }),
  );

  void _setTransport(String v) => unawaited(
    _edit((config) {
      final proxy = config['proxy'];
      if (proxy is Map<String, Object?>) {
        proxy['transport'] = v;
      }
    }),
  );

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([core, widget.settings]),
      builder: (context, _) {
        final status = core.status;
        final mode = status == null ? 'clear' : connectionModeShown(status);
        final note = status == null ? null : tunNote(l, status);
        return Padding(
          padding: const EdgeInsets.fromLTRB(24, 96, 24, 118),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1060),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final left = Column(
                          children: [
                            _connectionPanel(l, mode, note),
                            const SizedBox(height: 20),
                            _generalPanel(l),
                          ],
                        );
                        final right = Column(
                          children: [
                            _AboutPanel(core: core),
                            const SizedBox(height: 20),
                            _dnsPanel(l),
                            const SizedBox(height: 20),
                            _routingPanel(l),
                            const SizedBox(height: 20),
                            _morePanel(l),
                          ],
                        );
                        if (constraints.maxWidth < 900) {
                          return Column(
                            children: [left, const SizedBox(height: 20), right],
                          );
                        }
                        // The right column starts below the engine
                        // chips' stack (shell chrome at the top
                        // right) — the samples' staggered masonry.
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(child: left),
                            const SizedBox(width: 20),
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.only(top: 148),
                                child: right,
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                    const SizedBox(height: 20),
                    widget.engineSection,
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  // -- Connection ---------------------------------------------------

  Widget _connectionPanel(
    AppLocalizations l,
    String mode,
    ({String text, String detail, bool problem, bool install, bool again})?
    note,
  ) {
    final busy = core.installingTun || core.removingTun;
    return MapSettingsPanel(
      title: 'Connection',
      children: [
        MapSettingRow(
          label: 'Connection mode',
          subtitle: mode == 'tun'
              ? 'Every app on this PC is covered through the tunnel.'
              : mode == 'set'
              ? 'Apps on this PC are covered through the system '
                    'proxy settings.'
              : 'Proxy only: apps that use the local proxy are '
                    'covered; the rest of the system connects '
                    'directly. Pick TUN for every app.',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              MapValueChip(
                text: 'Proxy',
                selected: mode == 'clear',
                onTap: () =>
                    unawaited(chooseConnectionMode(context, core, 'clear')),
              ),
              const SizedBox(width: 6),
              MapValueChip(
                text: 'System',
                selected: mode == 'set',
                onTap: () =>
                    unawaited(chooseConnectionMode(context, core, 'set')),
              ),
              const SizedBox(width: 6),
              MapValueChip(
                text: 'TUN',
                selected: mode == 'tun',
                onTap: () =>
                    unawaited(chooseConnectionMode(context, core, 'tun')),
              ),
            ],
          ),
        ),
        MapSettingRow(
          label: 'System-wide capture',
          subtitle: 'Route every app through the tunnel (TUN mode)',
          trailing: MapToggle(
            value: mode == 'tun',
            onChanged: (v) => unawaited(
              chooseConnectionMode(context, core, v ? 'tun' : 'clear'),
            ),
          ),
        ),
        MapSettingRow(
          label: 'Protocol',
          subtitle: 'Mozilla transport',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              MapValueChip(
                text: 'H2',
                selected: _transport == 'h2',
                onTap: _busy ? null : () => _setTransport('h2'),
              ),
              const SizedBox(width: 6),
              MapValueChip(
                text: 'H3',
                selected: _transport == 'h3',
                onTap: _busy ? null : () => _setTransport('h3'),
              ),
            ],
          ),
        ),
        MapSettingRow(
          label: 'Local port',
          subtitle: 'V2Ray SOCKS port — edit in the V2Ray section below',
          divider: false,
          trailing: MapValueChip(text: '${widget.xray.settings.socksPort}'),
        ),
        if (note != null)
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 8),
            child: Row(
              children: [
                const Icon(
                  Icons.warning_amber_rounded,
                  size: 16,
                  color: Ember.warn,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Tooltip(
                    message: note.detail,
                    child: Text(
                      note.text,
                      style: const TextStyle(fontSize: 12.5, color: Ember.warn),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                if (note.install)
                  TextButton(
                    onPressed: busy
                        ? null
                        : () => installTunService(context, core),
                    child: Text(note.again ? l.tunInstallAgain : l.tunInstall),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  // -- General ------------------------------------------------------

  Widget _generalPanel(AppLocalizations l) {
    final settings = widget.settings;
    return MapSettingsPanel(
      title: 'General',
      children: [
        MapSettingRow(
          label: l.startOnBoot,
          subtitle: 'Open Ralysnd Ember when you sign in to Windows',
          trailing: MapToggle(
            value: settings.autostart,
            onChanged: (v) => settings.update(autostart: v),
          ),
        ),
        MapSettingRow(
          label: l.minimizeToTray,
          subtitle: l.closeBody,
          trailing: MapToggle(
            value: settings.closeAction == CloseAction.tray,
            onChanged: (v) => settings.update(
              closeAction: v ? CloseAction.tray : CloseAction.quit,
            ),
          ),
        ),
        MapSettingRow(
          label: l.connectOnStartup,
          subtitle: 'Reconnect the last engine when the app starts',
          divider: false,
          trailing: MapToggle(
            value: settings.autoConnect,
            onChanged: settings.autostart
                ? (v) => settings.update(autoConnect: v)
                : null,
          ),
        ),
      ],
    );
  }

  // -- DNS ----------------------------------------------------------

  Widget _dnsPanel(AppLocalizations l) {
    final dohUrl = _servers.firstWhere(
      (x) => x.startsWith('https://'),
      orElse: () => '',
    );
    return MapSettingsPanel(
      title: 'DNS',
      children: [
        MapSettingRow(
          label: l.doh,
          subtitle: l.dohSub,
          divider: false,
          trailing: MapToggle(
            value: _doh ?? true,
            onChanged: _busy || _doh == null ? null : _setDoh,
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          'Remote DNS',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: MapUi.dim,
          ),
        ),
        const SizedBox(height: 7),
        _DohField(
          key: ValueKey(_servers.join(',')),
          initial: dohUrl,
          enabled: !_busy,
          onSubmitted: _setDohUrl,
        ),
        const SizedBox(height: 8),
        Text(l.dnsCustomHint, style: Ember.caption),
        const SizedBox(height: 8),
      ],
    );
  }

  // -- Routing --------------------------------------------------------

  Widget _routingPanel(AppLocalizations l) {
    return MapSettingsPanel(
      title: 'Routing',
      children: [
        MapSettingRow(
          label: l.smartRouting,
          subtitle: l.smartRoutingSub,
          trailing: MapToggle(
            value: _routing ?? false,
            onChanged: _busy || _routing == null
                ? null
                : (v) => unawaited(
                    _edit((config) {
                      final routing = config['routing'];
                      if (routing is Map<String, Object?>) {
                        routing['enabled'] = v;
                      }
                    }),
                  ),
          ),
        ),
        MapSettingRow(
          label: 'Routing rules',
          subtitle: l.routingDirectHint,
          divider: false,
          trailing: const Icon(
            Icons.chevron_right_rounded,
            size: 20,
            color: MapUi.faint,
          ),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => SettingsPage(
                core: core,
                settings: widget.settings,
                opening: SettingsSection.routing,
              ),
            ),
          ),
        ),
      ],
    );
  }

  // -- More -----------------------------------------------------------

  Widget _morePanel(AppLocalizations l) {
    void open(Widget page) =>
        Navigator.of(context)
            .push(MaterialPageRoute<void>(builder: (_) => page));
    return MapSettingsPanel(
      title: 'More',
      children: [
        MapSettingRow(
          label: l.allSettings,
          subtitle: 'Languages, updates, accounts and diagnostics',
          trailing: const Icon(
            Icons.chevron_right_rounded,
            size: 20,
            color: MapUi.faint,
          ),
          onTap: () =>
              open(SettingsPage(core: core, settings: widget.settings)),
        ),
        MapSettingRow(
          label: l.languageRow,
          subtitle: 'App language and appearance',
          trailing: const Icon(
            Icons.chevron_right_rounded,
            size: 20,
            color: MapUi.faint,
          ),
          onTap: () => open(
            SettingsPage(
              core: core,
              settings: widget.settings,
              opening: SettingsSection.general,
            ),
          ),
        ),
        MapSettingRow(
          label: l.infoRow,
          subtitle: 'About the app and its engines',
          divider: false,
          trailing: const Icon(
            Icons.chevron_right_rounded,
            size: 20,
            color: MapUi.faint,
          ),
          onTap: () => open(const EmberInfoPage()),
        ),
      ],
    );
  }
}

/// The About panel: the maker credit, the real version, and the
/// update check wired to the app's existing flow.
class _AboutPanel extends StatefulWidget {
  const _AboutPanel({required this.core});

  final CoreController core;

  @override
  State<_AboutPanel> createState() => _AboutPanelState();
}

class _AboutPanelState extends State<_AboutPanel> {
  bool _checking = false;
  String _result = '';

  Future<void> _check() async {
    setState(() {
      _checking = true;
      _result = '';
    });
    try {
      final release = await checkForUpdate(
        proxy: updateProxy(widget.core.status),
      );
      Updates.found(release);
      if (!mounted) return;
      final l = AppLocalizations.of(context);
      setState(() {
        _result = release == null
            ? l.upToDate
            : l.updateAvailable(release.version);
      });
    } on Exception catch (e) {
      if (mounted) {
        setState(
          () => _result = AppLocalizations.of(context).updateCheckFailed('$e'),
        );
      }
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return MapSettingsPanel(
      title: 'About',
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 2, bottom: 10),
          child: Text(
            'Built by Rayan Vakili • Ralysnd',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: MapUi.text,
            ),
          ),
        ),
        Text(l.licenseNote, style: Ember.caption),
        const SizedBox(height: 6),
        MapSettingRow(
          label: 'Ralysnd Ember',
          trailing: const MapValueChip(text: 'v$appVersion'),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 10, bottom: 8),
          child: Row(
            children: [
              MapGhostButton(
                icon: Icons.refresh_rounded,
                label: l.checkUpdates,
                busy: _checking,
                onTap: _checking ? null : () => unawaited(_check()),
              ),
              if (_result.isNotEmpty) ...[
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _result,
                    style: Ember.caption,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// The inset DoH field: dark glass, a lock icon, the URL.
class _DohField extends StatefulWidget {
  const _DohField({
    super.key,
    required this.initial,
    required this.enabled,
    required this.onSubmitted,
  });

  final String initial;
  final bool enabled;
  final ValueChanged<String> onSubmitted;

  @override
  State<_DohField> createState() => _DohFieldState();
}

class _DohFieldState extends State<_DohField> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
    controller: _controller,
    enabled: widget.enabled,
    onSubmitted: widget.onSubmitted,
    style: const TextStyle(fontSize: 13.5, color: MapUi.text),
    decoration: InputDecoration(
      isDense: true,
      filled: true,
      fillColor: MapUi.insetFill,
      prefixIcon: const Icon(Icons.lock_rounded, size: 16, color: MapUi.faint),
      prefixIconConstraints: const BoxConstraints(minWidth: 36, minHeight: 0),
      hintText: 'https://…',
      hintStyle: const TextStyle(color: MapUi.faint),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(11),
        borderSide: const BorderSide(color: MapUi.line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(11),
        borderSide: const BorderSide(color: MapUi.line),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(11),
        borderSide: const BorderSide(color: Ember.orange),
      ),
    ),
  );
}
