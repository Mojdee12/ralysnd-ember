/// The URnetwork engine's pages, Map Control edition
/// (build 2156): the home's status composition, the
/// Servers tab (the location picker — one Best Available
/// default plus the provider-locations catalogue), the
/// Accounts tab (the 2154 account this engine connects
/// with, and the session's numbers), the settings page,
/// and the log viewer.
///
/// The owner's ruling shapes the picker: URnetwork has
/// far too many servers to add one by one, so the primary
/// action is ONE Best Available connect; a country is
/// picked only when he wants a specific one. Nothing here
/// auto-connects — the engine is inert until the connect
/// control is tapped.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../urnetwork/ur_engine_controller.dart';
import '../../urnetwork/urnetwork_client.dart';
import '../widgets.dart' show CountryFlag;
import 'ember_dialogs.dart';
import 'ember_format.dart';
import 'ember_theme.dart';
import 'map_widgets.dart';

/// The URnetwork home: the hero word and the status line
/// open over the map (the Lantern home's composition),
/// then — loudly, by design — the failure card when a
/// start went wrong.
class UrHomePage extends StatelessWidget {
  const UrHomePage({super.key, required this.ur});

  final UrEngineController ur;

  @override
  Widget build(BuildContext context) {
    final state = ur.state;
    final on = state.connected;
    final error = ur.lastError;
    return LayoutBuilder(
      builder: (context, constraints) => ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        children: [
          SizedBox(height: emberHomeTopGap(constraints.maxHeight)),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('URnetwork', style: Ember.hero),
              const SizedBox(height: 8),
              Row(
                children: [
                  Container(
                    width: 9,
                    height: 9,
                    decoration: BoxDecoration(
                      color: on
                          ? Ember.green
                          : state.running
                          ? Ember.amber
                          : Ember.faint,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      on ? 'Connected' : state.stageLabel,
                      style: Ember.heading,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                on && state.exitLine.isNotEmpty
                    ? 'Exit: ${state.exitLine}'
                    : state.reqName.isNotEmpty
                    ? 'Location: ${state.reqName}'
                    : 'Best Available — URnetwork picks the strongest '
                          'exit itself.',
                style: Ember.body,
              ),
              if (!state.available) ...[
                const SizedBox(height: 8),
                Text(
                  'The URnetwork core is not included in this build '
                  '(it ships for arm64 phones).',
                  style: Ember.caption,
                ),
              ],
              if (ur.activeAccount == null) ...[
                const SizedBox(height: 8),
                Text(
                  'No URnetwork account yet — add one under '
                  'Settings → URnetwork.',
                  style: Ember.caption,
                ),
              ],
            ],
          ),
          if (error != null && !state.running) ...[
            const SizedBox(height: 12),
            MapGlass(
              blur: false,
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.error_outline_rounded,
                        size: 16,
                        color: Ember.red,
                      ),
                      SizedBox(width: 7),
                      Expanded(
                        child: Text(
                          'The URnetwork engine failed to start',
                          style: Ember.heading,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SelectableText(
                    error.contains('Exception')
                        ? 'The engine reported an error — the '
                              'detail is in the engine logs.'
                        : error,
                    style: Ember.body,
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The Servers tab in URnetwork mode: the location
/// picker. Best Available is the first row and the
/// default; below it the country catalogue (provider
/// locations, fetched through the active account). With
/// more than one URnetwork account, an account picker
/// rides at the top. A pick made during a session applies
/// to the next connect — the page says so.
class UrServersView extends StatefulWidget {
  const UrServersView({super.key, required this.ur});

  final UrEngineController ur;

  @override
  State<UrServersView> createState() => _UrServersViewState();
}

class _UrServersViewState extends State<UrServersView> {
  @override
  void initState() {
    super.initState();
    unawaited(widget.ur.refreshCountries());
  }

  @override
  Widget build(BuildContext context) {
    final ur = widget.ur;
    return ListenableBuilder(
      listenable: ur,
      builder: (context, _) {
        final accounts = ur.accountsProvider();
        final state = ur.state;
        return ListView(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
          children: [
            Center(child: Text('Location', style: Ember.title)),
            Center(
              child: Text(
                state.running
                    ? 'Applies to the next connect'
                    : 'Best Available is the default',
                style: Ember.caption,
              ),
            ),
            const SizedBox(height: 16),
            if (accounts.length > 1) ...[
              MapGlass(
                blur: false,
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Account', style: Ember.heading),
                    const SizedBox(height: 8),
                    for (final account in accounts)
                      _PickRow(
                        label: account.label,
                        selected: ur.activeAccount?.id == account.id,
                        onTap: () => unawaited(ur.setAccount(account.id)),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ],
            MapGlass(
              blur: false,
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _PickRow(
                    label: 'Best Available',
                    subtitle: 'The strongest exit, chosen by URnetwork',
                    selected: ur.locationId.isEmpty,
                    onTap: () => unawaited(ur.setLocation(null)),
                  ),
                  if (ur.countriesError != null && ur.countries.isEmpty) ...[
                    const SizedBox(height: 8),
                    Text(ur.countriesError!, style: Ember.caption),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        onPressed: () => unawaited(ur.refreshCountries()),
                        child: Text('Retry', style: Ember.microLabelOrange),
                      ),
                    ),
                  ] else if (ur.countries.isEmpty) ...[
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Ember.orange,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text('Loading locations…', style: Ember.body),
                      ],
                    ),
                  ] else ...[
                    const SizedBox(height: 4),
                    for (final country in ur.countries)
                      _CountryRow(
                        country: country,
                        selected: ur.locationId == country.locationId,
                        onTap: () => unawaited(ur.setLocation(country)),
                      ),
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _PickRow extends StatelessWidget {
  const _PickRow({
    required this.label,
    this.subtitle,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String? subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Row(
          children: [
            Icon(
              selected
                  ? Icons.radio_button_checked_rounded
                  : Icons.radio_button_unchecked_rounded,
              size: 18,
              color: selected ? Ember.orange : Ember.faint,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: Ember.body),
                  if (subtitle != null)
                    Text(subtitle!, style: Ember.caption),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CountryRow extends StatelessWidget {
  const _CountryRow({
    required this.country,
    required this.selected,
    required this.onTap,
  });

  final UrCountry country;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          children: [
            CountryFlag(code: country.countryCode, width: 24),
            const SizedBox(width: 10),
            Expanded(child: Text(country.name, style: Ember.body)),
            Text(
              latDigits(country.providerCount),
              style: Ember.caption,
            ),
            const SizedBox(width: 8),
            Icon(
              selected
                  ? Icons.radio_button_checked_rounded
                  : Icons.radio_button_unchecked_rounded,
              size: 18,
              color: selected ? Ember.orange : Ember.faint,
            ),
          ],
        ),
      ),
    );
  }
}

/// The Accounts tab in URnetwork mode: the account this
/// engine connects with (managed under Settings →
/// URnetwork, build 2154) and the session's status and
/// numbers.
class UrAboutView extends StatelessWidget {
  const UrAboutView({super.key, required this.ur});

  final UrEngineController ur;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: ur,
      builder: (context, _) {
        final state = ur.state;
        final account = ur.activeAccount;
        return ListView(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
          children: [
            Center(child: Text(l.navAccounts, style: Ember.title)),
            Center(child: Text('URnetwork', style: Ember.caption)),
            const SizedBox(height: 16),
            MapGlass(
              blur: false,
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(Icons.person_rounded, color: Ember.dim),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      account == null
                          ? 'No URnetwork account — add one under '
                                'Settings → URnetwork.'
                          : 'Account: ${account.label}'
                                '${account.planName.isNotEmpty ? ' · ${account.planName}' : ''}',
                      style: Ember.body,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            MapGlass(
              blur: false,
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 9,
                        height: 9,
                        decoration: BoxDecoration(
                          color: state.connected
                              ? Ember.green
                              : state.running
                              ? Ember.amber
                              : Ember.faint,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        state.connected
                            ? l.statusConnected
                            : state.running
                            ? l.stateConnecting
                            : l.statusDisconnected,
                        style: Ember.heading,
                      ),
                    ],
                  ),
                  if (state.exitLine.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text('Exit: ${state.exitLine}', style: Ember.body),
                  ],
                  if (state.killSwitchHeld) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Kill switch holding: the session dropped, '
                      'and its tunnel is being held so traffic '
                      'stays blocked instead of going direct. '
                      'Reconnect or disconnect to clear it.',
                      style: Ember.caption,
                    ),
                  ],
                  if (state.providers > 0) ...[
                    const SizedBox(height: 6),
                    Text(
                      'Providers: ${latDigits(state.providers)}',
                      style: Ember.body,
                    ),
                  ],
                  if (state.upBytes > 0 || state.downBytes > 0) ...[
                    const SizedBox(height: 6),
                    Directionality(
                      textDirection: TextDirection.ltr,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.arrow_downward_rounded,
                            size: 14,
                            color: Ember.dim,
                          ),
                          const SizedBox(width: 3),
                          Text(fmtBytes(state.downBytes), style: Ember.body),
                          const SizedBox(width: 10),
                          const Icon(
                            Icons.arrow_upward_rounded,
                            size: 14,
                            color: Ember.dim,
                          ),
                          const SizedBox(width: 3),
                          Text(fmtBytes(state.upBytes), style: Ember.body),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// The URnetwork engine's settings page: the bound
/// account and location summaries, and the log viewer.
/// (Accounts themselves are managed on the build-2154
/// URnetwork page, which this page links to in words —
/// the engine adds no second account store.)
class UrEngineSettingsPage extends StatelessWidget {
  const UrEngineSettingsPage({super.key, required this.ur});

  final UrEngineController ur;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Ember.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Ember.text,
        title: Text('URnetwork', style: Ember.heading),
      ),
      body: EmberBackground(
        banded: true,
        child: ListenableBuilder(
          listenable: ur,
          builder: (context, _) {
            final state = ur.state;
            final account = ur.activeAccount;
            return ListView(
              padding: EdgeInsets.fromLTRB(
                18,
                MediaQuery.of(context).padding.top + kToolbarHeight + 8,
                18,
                18,
              ),
              children: [
                MapGlass(
                  blur: false,
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Engine', style: Ember.heading),
                      const SizedBox(height: 6),
                      Text(
                        account == null
                            ? 'No account yet. Accounts and hosted '
                                  'proxies live on the URnetwork page '
                                  'in Settings.'
                            : 'Connects with: ${account.label}',
                        style: Ember.body,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        ur.locationId.isEmpty
                            ? 'Location: Best Available'
                            : 'Location: ${ur.locationName}',
                        style: Ember.body,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        state.connected
                            ? 'Connected${state.exitLine.isNotEmpty ? ' · ${state.exitLine}' : ''}'
                            : state.running
                            ? 'Connecting…'
                            : 'Not connected',
                        style: Ember.body,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                MapGlass(
                  blur: false,
                  padding: const EdgeInsets.all(16),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => UrLogsPage(ur: ur)),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.terminal_rounded, color: Ember.dim),
                      SizedBox(width: 10),
                      Expanded(child: Text('Engine logs', style: Ember.body)),
                      Icon(Icons.chevron_right_rounded, color: MapUi.faint),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// The URnetwork log viewer: the service's journal and
/// the shared crash.log tail.
class UrLogsPage extends StatefulWidget {
  const UrLogsPage({super.key, required this.ur});

  final UrEngineController ur;

  @override
  State<UrLogsPage> createState() => _UrLogsPageState();
}

class _UrLogsPageState extends State<UrLogsPage> {
  late Future<String> _logs = widget.ur.readLogs();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Ember.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Ember.text,
        title: Text('URnetwork logs', style: Ember.heading),
        actions: [
          IconButton(
            onPressed: () => setState(() => _logs = widget.ur.readLogs()),
            icon: const Icon(Icons.refresh_rounded, color: Ember.dim),
          ),
          IconButton(
            tooltip: 'Clear logs',
            onPressed: () async {
              final confirmed = await showEmberConfirm(
                context,
                title: 'Clear logs?',
                message: 'Delete the saved URnetwork logs?',
                confirmLabel: 'Clear',
              );
              if (!confirmed) return;
              await widget.ur.clearLogs();
              setState(() => _logs = widget.ur.readLogs());
            },
            icon: const Icon(Icons.delete_outline_rounded, color: Ember.dim),
          ),
        ],
      ),
      body: EmberBackground(
        banded: true,
        child: FutureBuilder<String>(
          future: _logs,
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const Center(
                child: CircularProgressIndicator(color: Ember.orange),
              );
            }
            if (snap.hasError) {
              return ListView(
                padding: EdgeInsets.fromLTRB(
                  18,
                  MediaQuery.of(context).padding.top + kToolbarHeight + 8,
                  18,
                  18,
                ),
                children: [
                  GlassCard(
                    padding: const EdgeInsets.all(13),
                    child: Text(
                      'The logs could not be loaded.',
                      style: Ember.body,
                    ),
                  ),
                ],
              );
            }
            final text = snap.data ?? '';
            return ListView(
              padding: EdgeInsets.fromLTRB(
                18,
                MediaQuery.of(context).padding.top + kToolbarHeight + 8,
                18,
                18,
              ),
              children: [
                GlassCard(
                  padding: const EdgeInsets.all(13),
                  child: SelectableText(
                    text.isEmpty ? 'No logs yet.' : text,
                    style: Ember.body,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
