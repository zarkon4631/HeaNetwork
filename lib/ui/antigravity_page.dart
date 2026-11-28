import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/config/config_builder.dart';
import '../core/models/settings.dart';
import '../core/services/antigravity_check.dart';
import '../l10n/strings.dart';
import '../state/app_state.dart';
import 'widgets.dart';

class AntigravityPage extends StatefulWidget {
  const AntigravityPage({super.key});

  @override
  State<AntigravityPage> createState() => _AntigravityPageState();
}

class _AntigravityPageState extends State<AntigravityPage> {
  final _proxyController = TextEditingController();
  bool _obscureProxy = true;
  bool _applying = false;
  bool _checking = false;
  String? _inputError;
  String _lastSynced = '';
  List<AntigravityCheckResult>? _results;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final saved = context.read<AppState>().settings.antigravityProxy;
    if (saved != _lastSynced) {
      if (_proxyController.text == _lastSynced) {
        _proxyController.text = saved;
      }
      _lastSynced = saved;
    }
  }

  @override
  void dispose() {
    _proxyController.dispose();
    super.dispose();
  }

  Future<void> _connectProxy(AppState state) async {
    if (_applying) return;
    final s = S.of(context);
    final raw = _proxyController.text.trim();
    final parsed = AntigravityProxy.tryParse(raw);
    if (parsed == null) {
      setState(() => _inputError = s.antigravityProxyInvalid);
      return;
    }
    setState(() {
      _inputError = null;
      _applying = true;
    });
    try {
      await state.applyAntigravityProxy(raw, enabled: true);
      _lastSynced = parsed.raw;
      if (_proxyController.text != parsed.raw) {
        _proxyController.text = parsed.raw;
      }
    } on ElevationRequired {
      _lastSynced = parsed.raw;
      if (!mounted) return;
      final restart = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          icon: const Icon(Icons.admin_panel_settings_outlined),
          title: Text(s.needAdminTitle),
          content: SizedBox(width: 420, child: Text(s.antigravityNeedAdminHint)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(s.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(s.restartAsAdmin),
            ),
          ],
        ),
      );
      if (restart == true && mounted) {
        await state.restartElevated(connect: state.isConnected);
      }
    } on FormatException {
      if (mounted) setState(() => _inputError = s.antigravityProxyInvalid);
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  Future<void> _disconnectProxy(AppState state, {bool clear = false}) async {
    if (_applying) return;
    setState(() {
      _inputError = null;
      _applying = true;
    });
    try {
      final text = clear ? '' : _proxyController.text.trim();
      await state.applyAntigravityProxy(text, enabled: false);
      _lastSynced = state.settings.antigravityProxy;
      if (clear) _proxyController.clear();
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  Future<void> _check(AppState state, AntigravityProxy? proxy) async {
    if (_checking) return;
    final port = state.activeMixedPort;
    if (proxy == null && port == null) return;
    setState(() {
      _checking = true;
      _results = null;
    });
    final results = await Future.wait([
      for (final domain in antigravityDomains)
        checkAntigravity(
          Uri.https(domain, '/'),
          httpProxy: proxy,
          proxyPort: proxy == null ? port : null,
        ),
    ]);
    if (!mounted) return;
    setState(() {
      _checking = false;
      _results = results;
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final s = S.of(context);
    final scheme = Theme.of(context).colorScheme;
    final st = state.settings;
    final vpnConnected = state.isConnected;
    final tun = state.activeMode == ConnectionMode.tun;

    final savedProxy = st.parsedAntigravityProxy;
    final typedProxy = AntigravityProxy.tryParse(_proxyController.text);
    final dedicatedEnabled = st.antigravityProxyEnabled && savedProxy != null;
    final proxyRunning = state.antigravityProxyRunning;
    final proxyBusy = _applying || state.antigravityProxyBusy;
    final needsAdmin = dedicatedEnabled && state.antigravityNeedsElevation;
    final hasChanged =
        typedProxy != null &&
        (!dedicatedEnabled || typedProxy != savedProxy);
    final checkProxy = dedicatedEnabled ? savedProxy : typedProxy;
    final canCheck = !_checking && (checkProxy != null || vpnConnected);
    final results = _results;

    final IconData statusIcon;
    final Color statusColor;
    final String statusTitle;
    final String statusSubtitle;

    if (dedicatedEnabled) {
      if (proxyBusy) {
        statusIcon = Icons.sync_rounded;
        statusColor = scheme.primary;
        statusTitle = s.antigravityProxyConnecting;
        statusSubtitle = savedProxy.endpoint;
      } else if (needsAdmin) {
        statusIcon = Icons.admin_panel_settings_outlined;
        statusColor = scheme.tertiary;
        statusTitle = s.needAdminTitle;
        statusSubtitle = savedProxy.endpoint;
      } else if (state.antigravityError != null) {
        statusIcon = Icons.error_outline_rounded;
        statusColor = scheme.error;
        statusTitle = s.antigravityProxyError;
        statusSubtitle = state.antigravityError!;
      } else if (proxyRunning) {
        statusIcon = Icons.vpn_lock_rounded;
        statusColor = scheme.primary;
        statusTitle = s.antigravityProxyActive;
        final modeLabel = vpnConnected
            ? s.antigravityProxyWithVpn
            : s.antigravityProxyStandalone;
        statusSubtitle = '${savedProxy.endpoint} · $modeLabel';
      } else {
        statusIcon = Icons.cloud_off_outlined;
        statusColor = scheme.onSurfaceVariant;
        statusTitle = s.antigravityProxyStopped;
        statusSubtitle = savedProxy.endpoint;
      }
    } else {
      statusIcon =
          vpnConnected ? Icons.vpn_lock_rounded : Icons.cloud_off_outlined;
      statusColor = vpnConnected ? scheme.primary : scheme.onSurfaceVariant;
      statusTitle = vpnConnected
          ? s.antigravityRoutingActive
          : s.antigravityDisconnected;
      statusSubtitle = state.selectedProfile?.name ?? s.noServer;
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(title: const Text('Antigravity')),
      body: PageBody(
        children: [
          Section(
            title: s.antigravityStatus,
            subtitle: s.antigravityStatusHint,
            children: [
              ListTile(
                leading: proxyBusy
                    ? const SizedBox.square(
                        dimension: 22,
                        child: CircularProgressIndicator(strokeWidth: 2.2),
                      )
                    : Icon(statusIcon, color: statusColor),
                title: Text(statusTitle),
                subtitle: Text(
                  statusSubtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (needsAdmin) ...[
                _Notice(
                  icon: Icons.admin_panel_settings_outlined,
                  color: scheme.tertiary,
                  text: s.antigravityNeedAdminHint,
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: FilledButton.tonalIcon(
                    onPressed: () =>
                        state.restartElevated(connect: vpnConnected),
                    icon: const Icon(Icons.admin_panel_settings_rounded, size: 18),
                    label: Text(s.restartAsAdmin),
                  ),
                ),
              ] else if (!dedicatedEnabled && !vpnConnected)
                _Notice(
                  icon: Icons.link_off_rounded,
                  color: scheme.tertiary,
                  text: s.antigravityConnectHint,
                )
              else if (!dedicatedEnabled && vpnConnected && !tun)
                _Notice(
                  icon: Icons.warning_amber_rounded,
                  color: scheme.tertiary,
                  text: s.antigravityTunHint,
                ),
            ],
          ),
          Section(
            title: s.antigravityProxySection,
            subtitle: s.antigravityProxySectionHint,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: TextField(
                  controller: _proxyController,
                  obscureText: _obscureProxy,
                  autocorrect: false,
                  enableSuggestions: false,
                  onChanged: (_) => setState(() => _inputError = null),
                  onSubmitted: (_) => _connectProxy(state),
                  decoration: InputDecoration(
                    labelText: s.antigravityProxyLabel,
                    hintText: s.antigravityProxyHint,
                    errorText: _inputError,
                    prefixIcon: const Icon(Icons.http_rounded),
                    suffixIcon: IconButton(
                      tooltip: _obscureProxy
                          ? s.antigravityShowProxy
                          : s.antigravityHideProxy,
                      onPressed: () =>
                          setState(() => _obscureProxy = !_obscureProxy),
                      icon: Icon(
                        _obscureProxy
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                      ),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: proxyBusy ||
                              _proxyController.text.trim().isEmpty ||
                              (dedicatedEnabled &&
                                  proxyRunning &&
                                  !hasChanged)
                          ? null
                          : () => _connectProxy(state),
                      icon: Icon(
                        dedicatedEnabled && hasChanged
                            ? Icons.check_rounded
                            : Icons.power_settings_new_rounded,
                        size: 18,
                      ),
                      label: Text(
                        dedicatedEnabled && hasChanged
                            ? s.antigravityProxyApply
                            : s.antigravityProxyConnect,
                      ),
                    ),
                    if (dedicatedEnabled)
                      OutlinedButton.icon(
                        onPressed: proxyBusy
                            ? null
                            : () => _disconnectProxy(state),
                        icon: const Icon(Icons.link_off_rounded, size: 18),
                        label: Text(s.antigravityProxyDisconnect),
                      ),
                    if (_proxyController.text.trim().isNotEmpty ||
                        st.antigravityProxy.isNotEmpty)
                      TextButton(
                        onPressed: proxyBusy
                            ? null
                            : () => _disconnectProxy(state, clear: true),
                        child: Text(s.antigravityProxyClear),
                      ),
                  ],
                ),
              ),
            ],
          ),
          Section(
            title: s.antigravityRoutes,
            subtitle: s.antigravityRoutesHint,
            children: [
              for (final domain in antigravityDomains)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.public_rounded, size: 20),
                  title: Text(domain),
                  trailing: Text(
                    dedicatedEnabled ? s.antigravityActionProxy : s.actionVpn,
                  ),
                ),
              const Divider(height: 8),
              ListTile(
                dense: true,
                leading: const Icon(Icons.dns_outlined, size: 20),
                title: Text(s.antigravityDns),
                subtitle: Text(
                  dedicatedEnabled
                      ? antigravityDnsSpec(st.remoteDns)
                      : st.remoteDns,
                ),
              ),
              const ListTile(
                dense: true,
                leading: Icon(Icons.terminal_rounded, size: 20),
                title: Text('Antigravity · agy.exe · Language Server'),
                subtitle: Text(
                  'language_server.exe · language_server_windows_x64.exe',
                ),
              ),
            ],
          ),
          Section(
            title: s.antigravityCheckTitle,
            subtitle: s.antigravityCheckHint,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
                child: FilledButton.tonalIcon(
                  onPressed: canCheck ? () => _check(state, checkProxy) : null,
                  icon: _checking
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.network_check_rounded, size: 18),
                  label: Text(_checking ? s.antigravityChecking : s.measure),
                ),
              ),
              if (results != null)
                for (final result in results)
                  ListTile(
                    dense: true,
                    leading: Icon(
                      result.proxyAuthFailed
                          ? Icons.lock_outline_rounded
                          : result.regionBlocked
                          ? Icons.location_off_outlined
                          : result.reachable
                          ? Icons.check_circle_outline_rounded
                          : Icons.error_outline_rounded,
                      color:
                          result.proxyAuthFailed ||
                              result.regionBlocked ||
                              !result.reachable
                          ? scheme.error
                          : scheme.primary,
                    ),
                    title: Text(result.host),
                    subtitle: Text(
                      result.proxyAuthFailed
                          ? s.antigravityProxyAuthFailed
                          : (result.error ??
                              (result.regionBlocked
                                  ? s.antigravityRegionBlocked
                                  : 'HTTP ${result.statusCode} · ${s.antigravityLatency(result.elapsed.inMilliseconds)}')),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: Text(
                  s.antigravityClientNote,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.color, required this.text});

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: 10),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}
