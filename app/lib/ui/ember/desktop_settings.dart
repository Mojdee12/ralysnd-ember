/// The DESKTOP settings page, in the Settings mockup's voice:
/// two columns of translucent glass cards — General, DNS,
/// Connection (the capture-mode switcher lives here now, not on
/// the Mozilla home), Routing, About, More — over the dotted map.
/// Every control is a real setting: the app preferences from
/// AppSettings, and the core's routing/DNS through
/// CoreController.settings/editSettings (the same map-based
/// load/edit pattern the phone settings use).

import 'dart:async';

import 'package:flutter/material.dart';

import '../../app_info.dart';
import '../../app_settings.dart';
import '../../core/core_controller.dart';
import '../../core/updates.dart';
import '../../l10n/app_localizations.dart';
import '../connection_mode.dart';
import '../settings_page.dart';
import 'desktop_widgets.dart';
import 'ember_info.dart';
import 'ember_theme.dart';

class DesktopSettingsPage extends StatefulWidget {
  const DesktopSettingsPage({
    super.key,
    required this.core,
    required this.settings,
    required this.engineSection,
    required this.protectionOn,
  });

  final CoreController core;
  final AppSettings settings;

  /// The engine-management cards (Xray, Psiphon, …) the phone
  /// settings compose — appended full-width under the mockup grid.
  final Widget engineSection;

  /// For the bottom bar's Protection state.
  final bool protectionOn;

  @override
  State<DesktopSettingsPage> createState() => _DesktopSettingsPageState();
}

class _DesktopSettingsPageState extends State<DesktopSettingsPage> {
  bool? _routing;
  bool? _doh;
  List<String> _servers = const [];
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
      final servers = dns is Map ? dns['servers'] : null;
      final list = servers is List ? servers : const [];
      if (mounted) {
        setState(() {
          _routing = routing is Map ? routing['enabled'] == true : false;
          _servers = [for (final s in list) s.toString()];
          _doh = list.isNotEmpty &&
              list.every(
                (s) =>
                    s.toString().startsWith('https://') ||
                    s.toString().startsWith('tls://'),
              );
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

  void _setDoh(bool v) => unawaited(_edit((config) {
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
      }));

  void _setDohUrl(String v) => unawaited(_edit((config) {
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
      }));

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final status = core.status;
    final mode = status == null ? 'clear' : connectionModeShown(status);
    final note = status == null ? null : tunNote(l, status);
    return ListenableBuilder(
      listenable: core,
      builder: (context, _) => Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(30, 24, 30, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
            const DesktopHeader(
              title: 'Settings',
              subtitle: 'Manage your app preferences and security',
            ),
            const SizedBox(height: 26),
            // Sample A: the cards stack full-width, one per
            // section, rows hairline-separated inside each.
            _generalCard(l),
            const SizedBox(height: 16),
            _connectionCard(l, mode, note),
            const SizedBox(height: 16),
            _dnsCard(l),
            const SizedBox(height: 16),
            _routingCard(l),
            const SizedBox(height: 16),
            _AboutCard(core: core),
            const SizedBox(height: 16),
            _moreCard(l),
                  const SizedBox(height: 16),
                  widget.engineSection,
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(30, 6, 30, 16),
            child: DesktopStatusBar(
              left: 'Settings are saved automatically',
              protectionOn: widget.protectionOn,
            ),
          ),
        ],
      ),
    );
  }

  // -- General ------------------------------------------------------

  Widget _generalCard(AppLocalizations l) {
    final settings = widget.settings;
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) => GlassCard(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _CardTitle(icon: Icons.tune_rounded, title: 'General'),
            _SettingRow(
              icon: Icons.power_settings_new_rounded,
              title: l.startOnBoot,
              subtitle: 'Open Ralysnd Ember when you sign in to Windows',
              trailing: DesktopSwitch(
                value: settings.autostart,
                onChanged: (v) => settings.update(autostart: v),
              ),
            ),
            _SettingRow(
              icon: Icons.picture_in_picture_alt_rounded,
              title: l.minimizeToTray,
              subtitle: l.closeBody,
              trailing: DesktopSwitch(
                value: settings.closeAction == CloseAction.tray,
                onChanged: (v) => settings.update(
                  closeAction: v ? CloseAction.tray : CloseAction.quit,
                ),
              ),
            ),
            _SettingRow(
              icon: Icons.bolt_rounded,
              title: l.connectOnStartup,
              subtitle: 'Reconnect the last engine when the app starts',
              divider: false,
              trailing: DesktopSwitch(
                value: settings.autoConnect,
                onChanged: settings.autostart
                    ? (v) => settings.update(autoConnect: v)
                    : null,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // -- DNS ----------------------------------------------------------

  Widget _dnsCard(AppLocalizations l) {
    final dohUrl = _servers.firstWhere(
      (x) => x.startsWith('https://'),
      orElse: () => '',
    );
    return GlassCard(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _CardTitle(icon: Icons.dns_rounded, title: 'DNS'),
          _SettingRow(
            icon: Icons.lock_rounded,
            title: l.doh,
            subtitle: l.dohSub,
            divider: false,
            trailing: DesktopSwitch(
              value: _doh ?? true,
              onChanged: _busy || _doh == null ? null : _setDoh,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'Remote DNS',
            style: Desk.caption.copyWith(
              color: Desk.dim,
              fontWeight: FontWeight.w600,
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
          Text(l.dnsCustomHint, style: Desk.caption),
        ],
      ),
    );
  }

  // -- Connection (the capture-mode switcher) -----------------------

  Widget _connectionCard(
    AppLocalizations l,
    String mode,
    ({String text, String detail, bool problem, bool install, bool again})?
        note,
  ) {
    final busy = core.installingTun || core.removingTun;
    return GlassCard(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _CardTitle(icon: Icons.cable_rounded, title: l.connectionMode),
          const SizedBox(height: 12),
          Row(
            children: [
              DesktopModeChip(
                label: l.modeProxyOnly,
                selected: mode == 'clear',
                onTap: () =>
                    unawaited(chooseConnectionMode(context, core, 'clear')),
              ),
              const SizedBox(width: 7),
              DesktopModeChip(
                label: l.systemProxy,
                selected: mode == 'set',
                onTap: () =>
                    unawaited(chooseConnectionMode(context, core, 'set')),
              ),
              const SizedBox(width: 7),
              DesktopModeChip(
                label: 'TUN',
                selected: mode == 'tun',
                onTap: () =>
                    unawaited(chooseConnectionMode(context, core, 'tun')),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            mode == 'tun'
                ? 'Every app on this PC is covered through the tunnel.'
                : mode == 'set'
                    ? 'Apps on this PC are covered through the system '
                        'proxy settings.'
                    : 'Proxy only: apps that use the local proxy are '
                        'covered; the rest of the system connects '
                        'directly. Pick TUN for every app.',
            style: Desk.caption,
          ),
          if (note != null) ...[
            const SizedBox(height: 10),
            if (note.problem)
              Row(
                children: [
                  const Icon(Icons.warning_amber_rounded,
                      size: 16, color: Ember.warn),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Tooltip(
                      message: note.detail,
                      child: Text(
                        note.text,
                        style:
                            const TextStyle(fontSize: 12.5, color: Ember.warn),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  if (note.install)
                    TextButton(
                      onPressed:
                          busy ? null : () => installTunService(context, core),
                      child:
                          Text(note.again ? l.tunInstallAgain : l.tunInstall),
                    ),
                ],
              )
            else
              Text(
                note.text,
                style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: Ember.warn,
                ),
              ),
          ],
        ],
      ),
    );
  }

  // -- Routing --------------------------------------------------------

  Widget _routingCard(AppLocalizations l) {
    return GlassCard(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _CardTitle(icon: Icons.route_rounded, title: 'Routing'),
          _SettingRow(
            icon: Icons.alt_route_rounded,
            title: l.smartRouting,
            subtitle: l.smartRoutingSub,
            trailing: DesktopSwitch(
              value: _routing ?? false,
              onChanged: _busy || _routing == null
                  ? null
                  : (v) => unawaited(_edit((config) {
                        final routing = config['routing'];
                        if (routing is Map<String, Object?>) {
                          routing['enabled'] = v;
                        }
                      })),
            ),
          ),
          _SettingRow(
            icon: Icons.rule_rounded,
            title: 'Routing rules',
            subtitle: l.routingDirectHint,
            divider: false,
            trailing: const Icon(Icons.chevron_right_rounded,
                size: 20, color: Desk.faint),
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
      ),
    );
  }

  // -- More -----------------------------------------------------------

  Widget _moreCard(AppLocalizations l) {
    void open(Widget page) => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => page),
        );
    return GlassCard(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _CardTitle(icon: Icons.more_horiz_rounded, title: 'More'),
          _SettingRow(
            icon: Icons.settings_rounded,
            title: l.allSettings,
            subtitle: 'Languages, updates, accounts and diagnostics',
            trailing: const Icon(Icons.chevron_right_rounded,
                size: 20, color: Desk.faint),
            onTap: () => open(SettingsPage(
              core: core,
              settings: widget.settings,
            )),
          ),
          _SettingRow(
            icon: Icons.language_rounded,
            title: l.languageRow,
            subtitle: 'App language and appearance',
            trailing: const Icon(Icons.chevron_right_rounded,
                size: 20, color: Desk.faint),
            onTap: () => open(SettingsPage(
              core: core,
              settings: widget.settings,
              opening: SettingsSection.general,
            )),
          ),
          _SettingRow(
            icon: Icons.info_outline_rounded,
            title: l.infoRow,
            subtitle: 'About the app and its engines',
            divider: false,
            trailing: const Icon(Icons.chevron_right_rounded,
                size: 20, color: Desk.faint),
            onTap: () => open(const EmberInfoPage()),
          ),
        ],
      ),
    );
  }
}

/// The About card: the maker credit, the real version, and the
/// update check wired to the app's existing flow.
class _AboutCard extends StatefulWidget {
  const _AboutCard({required this.core});

  final CoreController core;

  @override
  State<_AboutCard> createState() => _AboutCardState();
}

class _AboutCardState extends State<_AboutCard> {
  bool _checking = false;
  String _result = '';

  Future<void> _check() async {
    setState(() {
      _checking = true;
      _result = '';
    });
    try {
      final release =
          await checkForUpdate(proxy: updateProxy(widget.core.status));
      Updates.found(release);
      if (!mounted) return;
      final l = AppLocalizations.of(context);
      setState(() {
        _result =
            release == null ? l.upToDate : l.updateAvailable(release.version);
      });
    } on Exception catch (e) {
      if (mounted) {
        setState(() => _result =
            AppLocalizations.of(context).updateCheckFailed('$e'));
      }
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return GlassCard(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _CardTitle(icon: Icons.info_outline_rounded, title: 'About'),
          const SizedBox(height: 12),
          Text(
            'Built by Rayan Vakili • Ralysnd',
            style: Desk.body.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 5),
          Text(l.licenseNote, style: Desk.caption),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.50),
              borderRadius: BorderRadius.circular(11),
              border: Border.all(color: Desk.line),
            ),
            child: Row(
              children: [
                const Icon(Icons.system_update_alt_rounded,
                    size: 17, color: Desk.dim),
                const SizedBox(width: 9),
                Text('Ralysnd Ember', style: Desk.body),
                const Spacer(),
                const Text(
                  'v$appVersion',
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color: Desk.ink,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 11),
          Row(
            children: [
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: Desk.ink,
                  side: const BorderSide(color: Desk.line),
                ),
                onPressed: _checking ? null : () => unawaited(_check()),
                icon: _checking
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh_rounded, size: 16),
                label: Text(l.checkUpdates),
              ),
              if (_result.isNotEmpty) ...[
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _result,
                    style: Desk.caption,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// A card's title row: small icon tile + heading, the mockups' way.
class _CardTitle extends StatelessWidget {
  const _CardTitle({required this.icon, required this.title});

  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.65),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Desk.line),
            ),
            child: Icon(icon, size: 17, color: Desk.ink),
          ),
          const SizedBox(width: 9),
          Text(title, style: Desk.heading.copyWith(fontSize: 17)),
        ],
      );
}

/// One settings row: icon, title + description, and the control on
/// the right — the Settings mockup's row shape.
class _SettingRow extends StatelessWidget {
  const _SettingRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.trailing,
    this.onTap,
    this.divider = true,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget trailing;
  final VoidCallback? onTap;
  final bool divider;

  @override
  Widget build(BuildContext context) {
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 11),
      child: Row(
        children: [
          Icon(icon, size: 19, color: Desk.faint),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: Desk.body.copyWith(
                        fontSize: 15, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(subtitle, style: Desk.caption),
              ],
            ),
          ),
          const SizedBox(width: 10),
          trailing,
        ],
      ),
    );
    return Column(
      children: [
        if (onTap == null)
          row
        else
          InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(10),
            child: row,
          ),
        if (divider) const Divider(color: Desk.line, height: 1),
      ],
    );
  }
}

/// The mockup's inset DoH field: dark glass, a lock icon, the URL.
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
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial);

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
        style: const TextStyle(fontSize: 13.5, color: Desk.ink),
        decoration: InputDecoration(
          isDense: true,
          filled: true,
          fillColor: Colors.white.withValues(alpha: 0.55),
          prefixIcon:
              const Icon(Icons.lock_rounded, size: 16, color: Desk.faint),
          prefixIconConstraints:
              const BoxConstraints(minWidth: 36, minHeight: 0),
          hintText: 'https://…',
          hintStyle: const TextStyle(color: Desk.faint),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(11),
            borderSide: const BorderSide(color: Desk.line),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(11),
            borderSide: const BorderSide(color: Desk.line),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(11),
            borderSide: const BorderSide(color: Ember.orange),
          ),
        ),
      );
}
