/// The URnetwork page (build 2154): the owner's
/// URnetwork accounts as a built-in source. Each account
/// is added with its long-lived `urn_` API key — the key
/// goes to the device vault and is never shown again —
/// and the account's hosted proxies become ordinary
/// managed profiles (V2Ray section for SOCKS/HTTP/HTTPS,
/// WireGuard section for the WireGuard configs the plan
/// issues), named by their exit country and riding the
/// existing connect, ping and sweep machinery like every
/// other config.
///
/// The page is the management surface: per account it
/// shows the balances the API reports, refreshes the
/// profiles, creates a hosted proxy in a picked country,
/// rotates a unique exit, and deletes proxies and
/// accounts. With no account added the source is inert —
/// the app never contacts URnetwork.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../urnetwork/urnetwork_client.dart';
import '../../xray/xray_controller.dart';
import 'ember_dialogs.dart';
import 'ember_format.dart';
import 'ember_theme.dart';

Future<void> openUrNetwork(BuildContext context, XrayController xray) =>
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => UrNetworkPage(xray: xray)),
    );

class UrNetworkPage extends StatefulWidget {
  const UrNetworkPage({super.key, required this.xray});

  final XrayController xray;

  @override
  State<UrNetworkPage> createState() => _UrNetworkPageState();
}

class _UrNetworkPageState extends State<UrNetworkPage> {
  final _label = TextEditingController();
  final _key = TextEditingController();
  bool _showAddForm = false;
  bool _addBusy = false;
  String? _addError;

  /// Per-account management rows, fetched on demand —
  /// the store's profiles are the connect surface; these
  /// rows are the account's own truth for delete/rotate.
  final _proxies = <String, List<UrProxy>>{};
  final _proxiesLoading = <String>{};
  final _busy = <String>{};
  final _errors = <String, String>{};

  @override
  void initState() {
    super.initState();
    for (final account in widget.xray.urAccounts) {
      unawaited(_loadProxies(account.id));
    }
  }

  @override
  void dispose() {
    _label.dispose();
    _key.dispose();
    super.dispose();
  }

  Future<void> _loadProxies(String accountId) async {
    if (_proxiesLoading.contains(accountId)) return;
    setState(() => _proxiesLoading.add(accountId));
    try {
      final proxies = await widget.xray.urNetworkProxies(accountId);
      if (!mounted) return;
      setState(() => _proxies[accountId] = proxies);
    } on UrNetworkException catch (e) {
      if (!mounted) return;
      setState(() => _errors[accountId] = e.message);
    } finally {
      if (mounted) setState(() => _proxiesLoading.remove(accountId));
    }
  }

  Future<void> _refresh(UrAccount account) async {
    if (_busy.contains(account.id)) return;
    setState(() {
      _busy.add(account.id);
      _errors.remove(account.id);
    });
    try {
      await widget.xray.refreshUrNetworkAccount(account.id);
      await _loadProxies(account.id);
    } on UrNetworkException catch (e) {
      if (mounted) setState(() => _errors[account.id] = e.message);
    } on StateError catch (e) {
      if (mounted) setState(() => _errors[account.id] = e.message);
    } finally {
      if (mounted) setState(() => _busy.remove(account.id));
    }
  }

  Future<void> _addAccount() async {
    if (_addBusy) return;
    setState(() {
      _addBusy = true;
      _addError = null;
    });
    try {
      final account = await widget.xray.addUrNetworkAccount(
        label: _label.text,
        apiKey: _key.text,
      );
      _label.clear();
      _key.clear();
      if (!mounted) return;
      setState(() => _showAddForm = false);
      // The first refresh is what proves the key: its
      // failure lands on the account's own error line.
      await _refresh(account);
    } on StateError catch (e) {
      if (mounted) setState(() => _addError = e.message);
    } finally {
      if (mounted) setState(() => _addBusy = false);
    }
  }

  Future<void> _removeAccount(UrAccount account, String displayName) async {
    final confirmed = await showEmberConfirm(
      context,
      title: 'Remove account',
      message:
          'Remove $displayName? Its API key is deleted from '
          'the vault and its managed profiles are removed. '
          'The account itself at URnetwork is not touched.',
      confirmLabel: 'Remove',
    );
    if (!confirmed) return;
    await widget.xray.removeUrNetworkAccount(account.id);
    if (!mounted) return;
    setState(() {
      _proxies.remove(account.id);
      _errors.remove(account.id);
    });
  }

  Future<void> _deleteProxy(UrAccount account, UrProxy proxy) async {
    final confirmed = await showEmberConfirm(
      context,
      title: 'Delete proxy',
      message:
          'Delete this hosted proxy from the account? Its '
          'profiles are removed and the proxy stops working '
          'everywhere it was used.',
      confirmLabel: 'Delete',
    );
    if (!confirmed || _busy.contains(account.id)) return;
    setState(() {
      _busy.add(account.id);
      _errors.remove(account.id);
    });
    try {
      await widget.xray.deleteUrNetworkProxy(account.id, proxy);
      await _loadProxies(account.id);
    } on UrNetworkException catch (e) {
      if (mounted) setState(() => _errors[account.id] = e.message);
    } finally {
      if (mounted) setState(() => _busy.remove(account.id));
    }
  }

  Future<void> _rotateProxy(UrAccount account, UrProxy proxy) async {
    if (_busy.contains(account.id)) return;
    setState(() {
      _busy.add(account.id);
      _errors.remove(account.id);
    });
    try {
      await widget.xray.rotateUrNetworkProxyExit(account.id, proxy);
      await _loadProxies(account.id);
    } on UrNetworkException catch (e) {
      if (mounted) setState(() => _errors[account.id] = e.message);
    } finally {
      if (mounted) setState(() => _busy.remove(account.id));
    }
  }

  Future<void> _createProxy(UrAccount account) async {
    final pick = await showUrCreateSheet(context, widget.xray, account.id);
    if (pick == null || !mounted) return;
    if (_busy.contains(account.id)) return;
    setState(() {
      _busy.add(account.id);
      _errors.remove(account.id);
    });
    try {
      await widget.xray.createUrNetworkProxy(
        account.id,
        countryCode: pick.countryCode,
        bestAvailable: pick.bestAvailable,
        uniqueExit: pick.uniqueExit,
      );
      await _loadProxies(account.id);
    } on UrNetworkException catch (e) {
      if (mounted) setState(() => _errors[account.id] = e.message);
    } on StateError catch (e) {
      if (mounted) setState(() => _errors[account.id] = e.message);
    } finally {
      if (mounted) setState(() => _busy.remove(account.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Ember.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Ember.text,
      ),
      body: EmberBackground(
        banded: true,
        child: ListenableBuilder(
          listenable: widget.xray,
          builder: (context, _) {
            final accounts = widget.xray.urAccounts;
            return ListView(
              padding: EdgeInsets.fromLTRB(
                18,
                MediaQuery.of(context).padding.top + kToolbarHeight + 6,
                18,
                24,
              ),
              children: [
                Text('URnetwork', style: Ember.hero),
                const SizedBox(height: 6),
                const Text(
                  'Residential exits from your URnetwork accounts',
                  style: TextStyle(
                    fontSize: Ember.fontDisplay,
                    fontWeight: FontWeight.w300,
                    color: Ember.dim,
                  ),
                ),
                const SizedBox(height: 18),
                if (accounts.isEmpty && !_showAddForm)
                  const EmberEmpty(
                    icon: Icons.public_rounded,
                    text:
                        'No URnetwork accounts yet. Add an account '
                        'with its API key and its hosted proxies '
                        'appear as configs, named by their exit '
                        'country.',
                  ),
                for (final account in accounts)
                  _AccountSection(
                    account: account,
                    displayName: widget.xray.urAccountDisplayName(
                      account,
                      accounts,
                    ),
                    profileCount: widget.xray.profiles
                        .where(
                          (p) => urAccountIdOfProfileId(p.id) == account.id,
                        )
                        .length,
                    proxies: _proxies[account.id],
                    proxiesLoading: _proxiesLoading.contains(account.id),
                    busy: _busy.contains(account.id),
                    error: _errors[account.id],
                    onRefresh: () => unawaited(_refresh(account)),
                    onCreate: () => unawaited(_createProxy(account)),
                    onRemove: () =>
                        unawaited(_removeAccount(account, _displayOf(account, accounts))),
                    onDeleteProxy: (p) => unawaited(_deleteProxy(account, p)),
                    onRotateProxy: (p) => unawaited(_rotateProxy(account, p)),
                  ),
                if (_showAddForm)
                  _AddAccountSection(
                    labelController: _label,
                    keyController: _key,
                    busy: _addBusy,
                    error: _addError,
                    onAdd: _addBusy ? null : () => unawaited(_addAccount()),
                    onCancel: () => setState(() {
                      _showAddForm = false;
                      _addError = null;
                    }),
                  )
                else
                  DashedAddButton(
                    label: 'Add account',
                    onTap: () => setState(() => _showAddForm = true),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  String _displayOf(UrAccount account, List<UrAccount> accounts) =>
      widget.xray.urAccountDisplayName(account, accounts);
}

/// The create-picker's outcome: one country (or best
/// available) and the unique-exit choice.
class UrCreatePick {
  const UrCreatePick({
    this.countryCode,
    this.bestAvailable = false,
    required this.uniqueExit,
  });

  final String? countryCode;
  final bool bestAvailable;
  final bool uniqueExit;
}

/// The create sheet: the country catalogue with its
/// provider counts, Best available on top, and the
/// unique-exit switch (a unique exit pins the proxy to
/// one provider whose address no other proxy of the
/// account shares, and is what reports its exit country
/// back; it is a UR Pro feature).
Future<UrCreatePick?> showUrCreateSheet(
  BuildContext context,
  XrayController xray,
  String accountId,
) {
  var uniqueExit = false;
  return showModalBottomSheet<UrCreatePick>(
    context: context,
    backgroundColor: Ember.bg,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(Ember.radiusPanel)),
    ),
    builder: (sheetContext) => StatefulBuilder(
      builder: (sheetContext, setSheetState) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('New hosted proxy'.toUpperCase(), style: Ember.microLabelOrange),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: Text('Unique exit (UR Pro)', style: Ember.body),
                  ),
                  EmberToggle(
                    value: uniqueExit,
                    onChanged: (v) => setSheetState(() => uniqueExit = v),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              const Text(
                'One provider\u2019s exit, yours alone, reporting '
                'its country. Off: a shared exit in the country.',
                style: TextStyle(color: Ember.dim, fontSize: Ember.fontBody),
              ),
              const SizedBox(height: 12),
              Flexible(
                child: FutureBuilder<List<UrCountry>>(
                  future: xray.urNetworkCountries(accountId),
                  builder: (context, snapshot) {
                    if (snapshot.connectionState != ConnectionState.done) {
                      return const Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: Center(child: CircularProgressIndicator()),
                      );
                    }
                    if (snapshot.hasError) {
                      return _urErrorLine(
                        snapshot.error is UrNetworkException
                            ? (snapshot.error as UrNetworkException).message
                            : 'URnetwork answered in an unexpected way.',
                      );
                    }
                    final countries = snapshot.data ?? const <UrCountry>[];
                    return ListView(
                      shrinkWrap: true,
                      children: [
                        ListTile(
                          title: Text('Best available', style: Ember.body),
                          subtitle: const Text(
                            'Any provider on the network',
                            style: TextStyle(color: Ember.dim),
                          ),
                          onTap: () => Navigator.of(sheetContext).pop(
                            UrCreatePick(
                              bestAvailable: true,
                              uniqueExit: uniqueExit,
                            ),
                          ),
                        ),
                        for (final country in countries)
                          ListTile(
                            title: Text(country.name, style: Ember.body),
                            subtitle: Text(
                              latDigits('${country.providerCount} providers'),
                              style: const TextStyle(color: Ember.dim),
                            ),
                            onTap: () => Navigator.of(sheetContext).pop(
                              UrCreatePick(
                                countryCode: country.countryCode,
                                uniqueExit: uniqueExit,
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

Widget _urErrorLine(String text) => Padding(
      padding: const EdgeInsets.only(bottom: 11),
      child: Text(
        text,
        style: const TextStyle(color: Ember.orange, fontSize: Ember.fontBody),
      ),
    );

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title.toUpperCase(), style: Ember.microLabelOrange),
            const SizedBox(height: 13),
            ...children,
          ],
        ),
      );
}

class _SmallButton extends StatelessWidget {
  const _SmallButton(this.label, this.onPressed);

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => TextButton(
        onPressed: onPressed,
        child: Text(
          label,
          style: TextStyle(
            color: onPressed == null ? Ember.dim : Ember.orange,
            fontSize: Ember.fontBody,
          ),
        ),
      );
}

/// One account: its balance and plan lines, its proxy
/// rows, and its actions.
class _AccountSection extends StatelessWidget {
  const _AccountSection({
    required this.account,
    required this.displayName,
    required this.profileCount,
    required this.proxies,
    required this.proxiesLoading,
    required this.busy,
    required this.error,
    required this.onRefresh,
    required this.onCreate,
    required this.onRemove,
    required this.onDeleteProxy,
    required this.onRotateProxy,
  });

  final UrAccount account;
  final String displayName;
  final int profileCount;
  final List<UrProxy>? proxies;
  final bool proxiesLoading;
  final bool busy;
  final String? error;
  final VoidCallback onRefresh;
  final VoidCallback onCreate;
  final VoidCallback onRemove;
  final void Function(UrProxy) onDeleteProxy;
  final void Function(UrProxy) onRotateProxy;

  @override
  Widget build(BuildContext context) {
    final balanceLines = <String>[
      if (account.pro) 'UR Pro',
      for (final entry in account.balances)
        if (entry.balanceBytes >= 0)
          '${entry.label} · ${urFormatBytes(entry.balanceBytes)} left'
          '${entry.startBytes >= 0 ? ' of ${urFormatBytes(entry.startBytes)}' : ''}',
      if (account.balances.isEmpty && account.balanceBytes >= 0)
        'Balance · ${urFormatBytes(account.balanceBytes)} left',
    ];
    return _Section(
      title: displayName,
      children: [
        GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final line in balanceLines)
                Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Text(line, style: Ember.body),
                ),
              Text(
                profileCount == 0
                    ? 'No configs yet'
                    : latDigits('$profileCount configs'),
                style: const TextStyle(
                  color: Ember.dim,
                  fontSize: Ember.fontBody,
                ),
              ),
              Text(
                account.lastRefreshMs == 0
                    ? 'Not refreshed yet'
                    : 'Refreshed ${_timeOf(account.lastRefreshMs)}',
                style: const TextStyle(
                  color: Ember.dim,
                  fontSize: Ember.fontBody,
                ),
              ),
              if (error != null) ...[
                const SizedBox(height: 8),
                _urErrorLine(error!),
              ],
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  _SmallButton('Remove', busy ? null : onRemove),
                  _SmallButton('Add proxy', busy ? null : onCreate),
                  _SmallButton('Refresh', busy ? null : onRefresh),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        if (proxiesLoading && proxies == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 10),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (proxies != null && proxies!.isEmpty)
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text(
              'No hosted proxies on this account yet — '
              'add one to get its configs.',
              style: TextStyle(color: Ember.dim, fontSize: Ember.fontBody),
            ),
          )
        else if (proxies != null)
          for (final proxy in proxies!)
            _ProxyRow(
              account: account,
              proxy: proxy,
              busy: busy,
              onDelete: () => onDeleteProxy(proxy),
              onRotate: proxy.exit == null
                  ? null
                  : () => onRotateProxy(proxy),
            ),
      ],
    );
  }

  static String _timeOf(int ms) {
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int v) => v.toString().padLeft(2, '0');
    return latDigits('${two(t.hour)}:${two(t.minute)}');
  }
}

/// One hosted proxy: its country/city name and exit
/// state, with its delete (and rotate, when it has an
/// exit) actions.
class _ProxyRow extends StatelessWidget {
  const _ProxyRow({
    required this.account,
    required this.proxy,
    required this.busy,
    required this.onDelete,
    required this.onRotate,
  });

  final UrAccount account;
  final UrProxy proxy;
  final bool busy;
  final VoidCallback onDelete;
  final VoidCallback? onRotate;

  @override
  Widget build(BuildContext context) {
    final code = urProxyCountryCode(account, proxy);
    final name = code.isEmpty ? 'Proxy' : urCountryName(code);
    final exit = proxy.exit;
    final detail = exit == null
        ? 'Shared exit'
        : [
            if (exit.city.isNotEmpty) exit.city,
            if (exit.state == 'replacing')
              'exit replacing'
            else if (exit.state == 'no_supply')
              'waiting for an exit'
            else
              'unique exit',
          ].join(' · ');
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GlassCard(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name, style: Ember.body),
                  Text(
                    detail,
                    style: const TextStyle(
                      color: Ember.dim,
                      fontSize: Ember.fontBody,
                    ),
                  ),
                ],
              ),
            ),
            if (onRotate != null)
              _SmallButton('Rotate', busy ? null : onRotate),
            _SmallButton('Delete', busy ? null : onDelete),
          ],
        ),
      ),
    );
  }
}

/// The add-account form: a label and the API key. The
/// key field is obscured and is cleared the moment the
/// account is added — it lives in the vault from then
/// on and is never displayed again.
class _AddAccountSection extends StatelessWidget {
  const _AddAccountSection({
    required this.labelController,
    required this.keyController,
    required this.busy,
    required this.error,
    required this.onAdd,
    required this.onCancel,
  });

  final TextEditingController labelController;
  final TextEditingController keyController;
  final bool busy;
  final String? error;
  final VoidCallback? onAdd;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) => _Section(
        title: 'Add account',
        children: [
          TextField(
            controller: labelController,
            style: Ember.body,
            textDirection: TextDirection.ltr,
            decoration: emberField(context, 'Label').copyWith(
              labelText: 'Label (optional)',
              labelStyle: const TextStyle(
                color: Ember.faint,
                fontSize: Ember.fontBody,
              ),
              floatingLabelStyle: const TextStyle(color: Ember.orange),
            ),
          ),
          const SizedBox(height: 11),
          TextField(
            controller: keyController,
            obscureText: true,
            style: Ember.body,
            textDirection: TextDirection.ltr,
            decoration: emberField(context, 'API key').copyWith(
              labelText: 'API key (urn_…)',
              labelStyle: const TextStyle(
                color: Ember.faint,
                fontSize: Ember.fontBody,
              ),
              floatingLabelStyle: const TextStyle(color: Ember.orange),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'The key is stored in the device vault only — '
            'never in the app\u2019s settings or backups.',
            style: TextStyle(color: Ember.dim, fontSize: Ember.fontBody),
          ),
          if (error != null) ...[
            const SizedBox(height: 8),
            _urErrorLine(error!),
          ],
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              _SmallButton('Cancel', busy ? null : onCancel),
              _SmallButton('Add account', onAdd),
            ],
          ),
        ],
      );
}
