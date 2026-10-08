import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/models/settings.dart';
import '../core/services/core_controller.dart';
import '../l10n/strings.dart';
import '../platform/windows/win32.dart' as win32;
import '../state/app_state.dart';
import 'shell.dart';
import 'theme.dart';
import 'widgets.dart';

/// Connects, or explains why it cannot and offers the way out.
Future<void> connectWithPrompts(BuildContext context) async {
  final state = context.read<AppState>();
  try {
    await state.toggle();
  } on ElevationRequired {
    if (!context.mounted) return;
    final s = S.of(context);
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.admin_panel_settings_outlined),
        title: Text(s.needAdminTitle),
        content: SizedBox(width: 420, child: Text(s.needAdminBody)),
        actionsOverflowButtonSpacing: 4,
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: Text(s.cancel)),
          TextButton(
              onPressed: () => Navigator.pop(context, 'proxy'),
              child: Text(s.useProxyInstead)),
          FilledButton(
              onPressed: () => Navigator.pop(context, 'admin'),
              child: Text(s.restartAsAdmin)),
        ],
      ),
    );
    if (choice == 'proxy') {
      state.updateSettings((st) => st.mode = ConnectionMode.systemProxy);
      await state.connect();
    } else if (choice == 'admin') {
      // The elevated copy takes over; `--elevated` lets it past the
      // single-instance guard while this one is still closing. Settings are
      // flushed first so it starts with what is on screen.
      await state.store.flush();
      if (win32.shellExecute(Platform.resolvedExecutable,
          verb: 'runas', args: '--elevated --connect')) {
        exit(0);
      }
    }
  }
}

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final s = S.of(context);
    final hasServer = state.connectionProfiles.isNotEmpty;

    return PageBody(
      maxWidth: 560,
      children: [
        const SizedBox(height: 12),
        Center(child: _PowerButton(state: state, enabled: hasServer)),
        const SizedBox(height: 18),
        _StatusText(state: state),
        const SizedBox(height: 20),
        if (state.error != null) _ErrorCard(state: state),
        _ServerCard(state: state),
        const SizedBox(height: 12),
        if (state.isWindows) ...[
          _ModeCard(state: state),
          const SizedBox(height: 12),
        ],
        _RoutingCard(state: state),
        const SizedBox(height: 12),
        _StatsCard(state: state),
        if (state.isWindows && state.elevated)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.admin_panel_settings_outlined,
                    size: 14, color: Theme.of(context).colorScheme.outline),
                const SizedBox(width: 6),
                Text(s.runningAsAdmin,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: Theme.of(context).colorScheme.outline)),
              ],
            ),
          ),
      ],
    );
  }
}

class _PowerButton extends StatelessWidget {
  const _PowerButton({required this.state, required this.enabled});

  final AppState state;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final colors = StatusColors.of(context);
    final status = state.status;
    final color = switch (status) {
      CoreStatus.running => colors.connected,
      CoreStatus.starting || CoreStatus.stopping => colors.connecting,
      CoreStatus.stopped => enabled ? scheme.primary : scheme.outline,
    };
    final on = status == CoreStatus.running;
    final s = S.of(context);

    return Semantics(
      button: true,
      label: on ? s.tapToDisconnect : s.tapToConnect,
      child: SizedBox.square(
        dimension: 184,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // Halo that grows when connected.
            AnimatedContainer(
              duration: const Duration(milliseconds: 400),
              width: on ? 184 : 160,
              height: on ? 184 : 160,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color.withValues(alpha: on ? 0.14 : 0.07),
              ),
            ),
            if (state.isBusy)
              SizedBox.square(
                dimension: 150,
                child: CircularProgressIndicator(strokeWidth: 3, color: color),
              ),
            Material(
              shape: const CircleBorder(),
              color: on ? color : scheme.surface,
              elevation: on ? 6 : 2,
              shadowColor: color.withValues(alpha: 0.5),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: state.isBusy ? null : () => connectWithPrompts(context),
                child: Container(
                  width: 132,
                  height: 132,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: color, width: on ? 0 : 3),
                  ),
                  child: Icon(Icons.power_settings_new_rounded,
                      size: 60, color: on ? Colors.white : color),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusText extends StatelessWidget {
  const _StatusText({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final theme = Theme.of(context);
    final (title, hint) = switch (state.status) {
      CoreStatus.running => (s.statusOn, null),
      CoreStatus.starting => (s.statusConnecting, null),
      CoreStatus.stopping => (s.statusStopping, null),
      CoreStatus.stopped => (
          s.statusOff,
          state.connectionProfiles.isEmpty ? s.noServerHint : s.tapToConnect
        ),
    };
    return Column(
      children: [
        Text(title,
            style: theme.textTheme.headlineSmall
                ?.copyWith(fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        if (state.isConnected && state.connectedSince != null)
          _Elapsed(since: state.connectedSince!)
        else if (hint != null)
          Text(hint,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ],
    );
  }
}

class _Elapsed extends StatefulWidget {
  const _Elapsed({required this.since});
  final DateTime since;

  @override
  State<_Elapsed> createState() => _ElapsedState();
}

class _ElapsedState extends State<_Elapsed> {
  late final Timer _timer =
      Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));

  @override
  void initState() {
    super.initState();
    _timer; // start ticking
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      formatDuration(DateTime.now().difference(widget.since)),
      style: theme.textTheme.titleMedium?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final scheme = Theme.of(context).colorScheme;
    final raw = state.error!;
    final noServer = raw == 'no-server';
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        color: scheme.errorContainer,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.error_outline_rounded, color: scheme.onErrorContainer),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(noServer ? s.noServer : s.errorTitle,
                        style: TextStyle(
                            color: scheme.onErrorContainer,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    SelectableText(noServer ? s.noServerHint : raw,
                        style: TextStyle(color: scheme.onErrorContainer, fontSize: 13)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ServerCard extends StatelessWidget {
  const _ServerCard({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final scheme = Theme.of(context).colorScheme;
    final auto = state.autoSubscription;
    final profile = state.activeProfile;
    final empty = state.connectionProfiles.isEmpty;

    final String title;
    final String subtitle;
    if (empty) {
      title = s.addServer;
      subtitle = s.noServerHint;
    } else if (auto != null) {
      title = profile?.name ?? s.autoSelect;
      subtitle = s.autoSelectOf(auto.name);
    } else {
      title = profile!.name;
      subtitle = profile.summary;
    }

    return Card(
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(16, 6, 12, 6),
        leading: CircleAvatar(
          backgroundColor: scheme.primaryContainer,
          foregroundColor: scheme.onPrimaryContainer,
          child: Icon(empty
              ? Icons.add_rounded
              : (auto != null ? Icons.auto_awesome_rounded : Icons.dns_rounded)),
        ),
        title: Text(title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (profile != null) LatencyBadge(profile.latencyMs),
            const SizedBox(width: 4),
            const Icon(Icons.chevron_right_rounded),
          ],
        ),
        onTap: () => ShellTab.of(context).value = ShellTab.servers,
      ),
    );
  }
}

class _ModeCard extends StatelessWidget {
  const _ModeCard({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final theme = Theme.of(context);
    final mode = state.settings.mode;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SegmentedButton<ConnectionMode>(
              showSelectedIcon: false,
              segments: [
                ButtonSegment(
                  value: ConnectionMode.systemProxy,
                  icon: const Icon(Icons.public_rounded, size: 18),
                  label: Text(s.modeProxy),
                ),
                ButtonSegment(
                  value: ConnectionMode.tun,
                  icon: const Icon(Icons.shield_rounded, size: 18),
                  label: Text(s.modeTun),
                ),
              ],
              selected: {mode},
              onSelectionChanged: (v) =>
                  state.updateSettings((st) => st.mode = v.first),
            ),
            const SizedBox(height: 10),
            Text(
              mode == ConnectionMode.tun ? s.modeTunHint : s.modeProxyHint,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _RoutingCard extends StatelessWidget {
  const _RoutingCard({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final routing = state.routing;
    final exceptions = routing.apps.where((a) => a.enabled).length +
        routing.domains.where((d) => d.enabled).length +
        (routing.ruDirect ? 1 : 0);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        leading: const Icon(Icons.alt_route_rounded),
        title: Text(routing.defaultAction == RouteAction.proxy
            ? s.routingSummaryAll
            : s.routingSummarySelected),
        subtitle: exceptions == 0 ? null : Text(s.routingExceptions(exceptions)),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: () => ShellTab.of(context).value = ShellTab.routing,
      ),
    );
  }
}

class _StatsCard extends StatelessWidget {
  const _StatsCard({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;

    Widget tile(IconData icon, String label, String value, String total) {
      return Expanded(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(icon, size: 16, color: muted),
                const SizedBox(width: 6),
                Text(label, style: theme.textTheme.labelMedium?.copyWith(color: muted)),
              ]),
              const SizedBox(height: 6),
              Text(value,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  )),
              Text('${s.sessionTraffic}: $total',
                  style: theme.textTheme.bodySmall?.copyWith(color: muted)),
            ],
          ),
        ),
      );
    }

    return Card(
      child: IntrinsicHeight(
        child: Row(
          children: [
            tile(Icons.south_rounded, s.download, formatSpeed(state.speed.down),
                formatBytes(state.totalDown)),
            const VerticalDivider(width: 1),
            tile(Icons.north_rounded, s.upload, formatSpeed(state.speed.up),
                formatBytes(state.totalUp)),
          ],
        ),
      ),
    );
  }
}
