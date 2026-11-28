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
  bool _checking = false;
  List<AntigravityCheckResult>? _results;

  Future<void> _check(AppState state) async {
    final port = state.activeMixedPort;
    if (port == null || _checking) return;
    setState(() {
      _checking = true;
      _results = null;
    });
    final results = await Future.wait([
      for (final domain in antigravityDomains)
        checkAntigravity(Uri.https(domain, '/'), proxyPort: port),
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
    final connected = state.isConnected;
    final tun = state.activeMode == ConnectionMode.tun;
    final results = _results;

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
                leading: Icon(
                  connected ? Icons.vpn_lock_rounded : Icons.cloud_off_outlined,
                  color: connected ? scheme.primary : scheme.onSurfaceVariant,
                ),
                title: Text(
                  connected
                      ? s.antigravityRoutingActive
                      : s.antigravityDisconnected,
                ),
                subtitle: Text(state.selectedProfile?.name ?? s.noServer),
              ),
              if (!connected)
                _Notice(
                  icon: Icons.link_off_rounded,
                  color: scheme.tertiary,
                  text: s.antigravityConnectHint,
                )
              else if (!tun)
                _Notice(
                  icon: Icons.warning_amber_rounded,
                  color: scheme.tertiary,
                  text: s.antigravityTunHint,
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
                  trailing: Text(s.actionVpn),
                ),
              const Divider(height: 8),
              ListTile(
                dense: true,
                leading: const Icon(Icons.dns_outlined, size: 20),
                title: Text(s.antigravityDns),
                subtitle: Text(state.settings.remoteDns),
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
                  onPressed: connected && !_checking
                      ? () => _check(state)
                      : null,
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
                      result.regionBlocked
                          ? Icons.location_off_outlined
                          : result.reachable
                          ? Icons.check_circle_outline_rounded
                          : Icons.error_outline_rounded,
                      color: result.regionBlocked || !result.reachable
                          ? scheme.error
                          : scheme.primary,
                    ),
                    title: Text(result.host),
                    subtitle: Text(
                      result.error ??
                          (result.regionBlocked
                              ? s.antigravityRegionBlocked
                              : 'HTTP ${result.statusCode} · ${s.antigravityLatency(result.elapsed.inMilliseconds)}'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: Text(
                  s.antigravityClientNote,
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
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
