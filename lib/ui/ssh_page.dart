import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:xterm/xterm.dart';

import '../core/models/ssh.dart';
import '../l10n/strings.dart';
import '../state/app_state.dart';
import 'ssh_dialogs.dart';
import 'ssh_sftp.dart';
import 'widgets.dart';

/// Windows-only SSH client screen: host manager (including VPN servers),
/// tabbed xterm terminals, snippets side panel, SFTP browser, and encrypted
/// app-to-app transfer.
class SshPage extends StatefulWidget {
  const SshPage({super.key});

  @override
  State<SshPage> createState() => _SshPageState();
}

class _SshPageState extends State<SshPage> {
  // null = Hosts tab; otherwise active session tab.
  SshTabSession? _activeSession;
  String _search = '';
  bool _showSnippets = false;

  @override
  void initState() {
    super.initState();
    final state = context.read<AppState>();
    unawaited(state.ensureSshLoaded().then((_) {
      if (!mounted) return;
      _consumePendingImport();
    }));
  }

  void _consumePendingImport() {
    final state = context.read<AppState>();
    final pending = state.takePendingSshImport();
    if (pending == null || !mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      showSshTransferDialog(context, state, initialBundleText: pending);
    });
  }

  Future<void> _connectHost(AppState state, SshHost host) async {
    final s = S.of(context);
    if (state.effectiveSshViaProxy(host) && !state.isConnected) {
      showSnack(context, s.sshVpnNotRunning);
      return;
    }
    final session = state.openSshSession(
      host,
      onVerifyHostKey: ({
        required hostLabel,
        required keyType,
        required fingerprint,
        required previousFingerprint,
      }) =>
          showHostKeyDialog(
        context,
        hostLabel: hostLabel,
        keyType: keyType,
        fingerprint: fingerprint,
        previousFingerprint: previousFingerprint,
      ),
    );
    setState(() => _activeSession = session);
  }

  Future<void> _closeSession(AppState state, SshTabSession session) async {
    if (_activeSession == session) {
      final idx = state.sshSessions.indexOf(session);
      setState(() {
        if (state.sshSessions.length <= 1) {
          _activeSession = null;
        } else {
          _activeSession = state.sshSessions[idx > 0 ? idx - 1 : 1];
        }
      });
    }
    await state.closeSshSession(session);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final s = S.of(context);
    final scheme = Theme.of(context).colorScheme;

    if (state.pendingSshImport != null) {
      _consumePendingImport();
    }

    if (_activeSession != null && !state.sshSessions.contains(_activeSession)) {
      _activeSession = state.sshSessions.isEmpty ? null : state.sshSessions.last;
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Column(
        children: [
          // Top bar: tabs + global SSH route switch + actions
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
            child: Row(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        _TabChip(
                          label: s.sshHosts,
                          icon: Icons.dns_outlined,
                          selected: _activeSession == null,
                          onTap: () => setState(() => _activeSession = null),
                        ),
                        for (final session in state.sshSessions)
                          ListenableBuilder(
                            listenable: session,
                            builder: (_, _) => _TabChip(
                              label: session.host.name,
                              icon: Icons.terminal_rounded,
                              statusColor: switch (session.status) {
                                SshSessionStatus.connected => Colors.greenAccent,
                                SshSessionStatus.connecting => Colors.amber,
                                SshSessionStatus.error => scheme.error,
                                SshSessionStatus.disconnected =>
                                  scheme.outline,
                              },
                              selected: _activeSession == session,
                              onTap: () =>
                                  setState(() => _activeSession = session),
                              onClose: () => _closeSession(state, session),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SegmentedButton<bool>(
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  segments: [
                    ButtonSegment(
                        value: false,
                        label: Text(s.sshRouteDirect,
                            style: const TextStyle(fontSize: 12))),
                    ButtonSegment(
                        value: true,
                        label: Text(s.sshRouteProxy,
                            style: const TextStyle(fontSize: 12))),
                  ],
                  selected: {state.settings.sshRouteViaProxy},
                  onSelectionChanged: (v) => state.setSshRouteViaProxy(v.first),
                ),
                const SizedBox(width: 6),
                IconButton(
                  tooltip: s.sshKeys,
                  onPressed: () => showSshKeysDialog(context, state),
                  icon: const Icon(Icons.key_rounded, size: 20),
                ),
                IconButton(
                  tooltip: s.sshTransfer,
                  onPressed: () => showSshTransferDialog(context, state),
                  icon: const Icon(Icons.sync_alt_rounded, size: 20),
                ),
                FilledButton.icon(
                  onPressed: () => showSshHostDialog(context, state),
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: Text(s.sshAddHost),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _activeSession == null
                ? _buildHostsView(context, state)
                : _buildSessionView(context, state, _activeSession!),
          ),
        ],
      ),
    );
  }

  Widget _buildHostsView(BuildContext context, AppState state) {
    final s = S.of(context);
    final q = _search.trim().toLowerCase();
    final hosts = [
      for (final h in state.sshData.hosts)
        if (q.isEmpty ||
            h.name.toLowerCase().contains(q) ||
            h.host.toLowerCase().contains(q) ||
            h.username.toLowerCase().contains(q))
          h,
    ];
    final vpnServers = [
      for (final p in state.vpnServersForSsh)
        if (q.isEmpty ||
            p.name.toLowerCase().contains(q) ||
            p.server.toLowerCase().contains(q))
          p,
    ];

    return PageBody(
      maxWidth: 920,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 6, bottom: 10),
          child: TextField(
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search_rounded, size: 20),
              hintText: s.search,
              isDense: true,
            ),
            onChanged: (v) => setState(() => _search = v),
          ),
        ),
        Section(
          title: s.sshHosts,
          count: hosts.length,
          children: [
            if (hosts.isEmpty)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(s.sshNoHosts),
              )
            else
              for (final h in hosts)
                ListTile(
                  leading: Icon(
                    h.authType == SshAuthType.key
                        ? Icons.vpn_key_outlined
                        : Icons.terminal_rounded,
                  ),
                  title: Text(h.name),
                  subtitle: Text(
                    '${h.username}@${h.host}:${h.port} · '
                    '${state.effectiveSshViaProxy(h) ? s.sshRouteProxy : s.sshRouteDirect}',
                  ),
                  onTap: () => _connectHost(state, h),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      FilledButton.tonal(
                        onPressed: () => _connectHost(state, h),
                        child: Text(s.sshConnect),
                      ),
                      IconButton(
                        tooltip: s.sshEditHost,
                        iconSize: 18,
                        onPressed: () =>
                            showSshHostDialog(context, state, existing: h),
                        icon: const Icon(Icons.edit_outlined),
                      ),
                      IconButton(
                        tooltip: s.delete,
                        iconSize: 18,
                        onPressed: () async {
                          final ok = await showDialog<bool>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              title: Text(s.delete),
                              content: Text(s.sshDeleteHostQ),
                              actions: [
                                TextButton(
                                    onPressed: () => Navigator.pop(ctx, false),
                                    child: Text(s.cancel)),
                                FilledButton(
                                    onPressed: () => Navigator.pop(ctx, true),
                                    child: Text(s.delete)),
                              ],
                            ),
                          );
                          if (ok == true) state.deleteSshHost(h.id);
                        },
                        icon: const Icon(Icons.delete_outline_rounded),
                      ),
                    ],
                  ),
                ),
          ],
        ),
        if (vpnServers.isNotEmpty)
          Section(
            title: s.sshVpnServers,
            count: vpnServers.length,
            children: [
              for (final p in vpnServers)
                ListTile(
                  leading: const Icon(Icons.public_rounded),
                  title: Text(p.name),
                  subtitle: Text('${p.server} · ${p.summary}'),
                  trailing: FilledButton.tonal(
                    onPressed: () async {
                      final created = await showSshHostDialog(
                        context,
                        state,
                        fromProfile: p,
                      );
                      if (created != null && mounted) {
                        await _connectHost(state, created);
                      }
                    },
                    child: Text(s.sshConfigureForVpn),
                  ),
                ),
            ],
          ),
      ],
    );
  }

  Widget _buildSessionView(
    BuildContext context,
    AppState state,
    SshTabSession session,
  ) {
    final s = S.of(context);
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        return Column(
          children: [
            // Session toolbar
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              color: scheme.surfaceContainerLow.withValues(alpha: 0.7),
              child: Row(
                children: [
                  SegmentedButton<bool>(
                    style: const ButtonStyle(
                      visualDensity: VisualDensity.compact,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    segments: [
                      ButtonSegment(
                          value: false,
                          icon: const Icon(Icons.terminal_rounded, size: 15),
                          label: Text(s.sshTerminal)),
                      ButtonSegment(
                          value: true,
                          icon: const Icon(Icons.folder_outlined, size: 15),
                          label: Text(s.sshSftp)),
                    ],
                    selected: {session.showSftp},
                    onSelectionChanged: (v) => session.setShowSftp(v.first),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    '${session.host.username}@${session.host.host}:${session.host.port} · '
                    '${switch (session.status) {
                      SshSessionStatus.connecting => s.sshConnecting,
                      SshSessionStatus.connected => s.sshConnected,
                      SshSessionStatus.disconnected => s.sshDisconnected,
                      SshSessionStatus.error => session.errorMessage ?? 'Error',
                    }}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12.5),
                  ),
                  const Spacer(),
                  if (!session.showSftp)
                    FilterChip(
                      avatar: const Icon(Icons.bolt_rounded, size: 15),
                      label: Text(s.sshSnippets,
                          style: const TextStyle(fontSize: 12)),
                      selected: _showSnippets,
                      onSelected: (v) => setState(() => _showSnippets = v),
                      visualDensity: VisualDensity.compact,
                    ),
                  const SizedBox(width: 6),
                  if (session.status == SshSessionStatus.disconnected ||
                      session.status == SshSessionStatus.error)
                    FilledButton.tonalIcon(
                      onPressed: () => state.connectSshSession(
                        session,
                        onVerifyHostKey: ({
                          required hostLabel,
                          required keyType,
                          required fingerprint,
                          required previousFingerprint,
                        }) =>
                            showHostKeyDialog(
                          context,
                          hostLabel: hostLabel,
                          keyType: keyType,
                          fingerprint: fingerprint,
                          previousFingerprint: previousFingerprint,
                        ),
                      ),
                      icon: const Icon(Icons.refresh_rounded, size: 16),
                      label: Text(s.sshReconnect),
                    )
                  else if (session.isConnected)
                    OutlinedButton(
                      onPressed: () => session.disconnect(),
                      child: Text(s.sshDisconnect),
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: session.showSftp
                  ? (session.isConnected
                      ? SshSftpView(
                          key: ValueKey('sftp-${session.host.id}'),
                          session: session,
                        )
                      : Center(child: Text(s.sshDisconnected)))
                  : Row(
                      children: [
                        Expanded(
                          child: TerminalView(
                            session.terminal,
                            controller: session.terminalController,
                            autofocus: true,
                            hardwareKeyboardOnly: true,
                            textStyle: const TerminalStyle(
                              fontFamily: 'Consolas',
                              fontSize: 13.5,
                            ),
                            padding: const EdgeInsets.all(8),
                          ),
                        ),
                        if (_showSnippets)
                          _SnippetsDrawer(
                            state: state,
                            onRun: (snippet) {
                              final payload = snippet.autoRun
                                  ? '${snippet.command}\n'
                                  : snippet.command;
                              session.sendText(payload);
                            },
                          ),
                      ],
                    ),
            ),
          ],
        );
      },
    );
  }
}

class _TabChip extends StatelessWidget {
  const _TabChip({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
    this.statusColor,
    this.onClose,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
  final Color? statusColor;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Material(
        color: selected
            ? scheme.primary.withValues(alpha: 0.16)
            : scheme.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(10),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (statusColor != null) ...[
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: statusColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                ] else ...[
                  Icon(icon, size: 15),
                  const SizedBox(width: 6),
                ],
                Text(label, style: const TextStyle(fontSize: 13)),
                if (onClose != null) ...[
                  const SizedBox(width: 4),
                  InkWell(
                    onTap: onClose,
                    child: const Icon(Icons.close_rounded, size: 15),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SnippetsDrawer extends StatelessWidget {
  const _SnippetsDrawer({required this.state, required this.onRun});

  final AppState state;
  final ValueChanged<SshSnippet> onRun;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final scheme = Theme.of(context).colorScheme;
    final snippets = state.sshData.snippets;
    return Container(
      width: 260,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border(left: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
            child: Row(
              children: [
                Text(s.sshSnippets,
                    style: Theme.of(context).textTheme.titleSmall),
                const Spacer(),
                IconButton(
                  tooltip: s.sshAddSnippet,
                  iconSize: 18,
                  onPressed: () => showSshSnippetDialog(context, state),
                  icon: const Icon(Icons.add_rounded),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.separated(
              itemCount: snippets.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (ctx, i) {
                final sn = snippets[i];
                return ListTile(
                  dense: true,
                  title: Text(sn.name,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    sn.command,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontFamily: 'Consolas', fontSize: 11),
                  ),
                  onTap: () => onRun(sn),
                  trailing: PopupMenuButton<String>(
                    iconSize: 16,
                    onSelected: (v) {
                      if (v == 'edit') {
                        showSshSnippetDialog(context, state, existing: sn);
                      } else if (v == 'delete') {
                        state.deleteSshSnippet(sn.id);
                      }
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem(value: 'edit', child: Text(s.rename)),
                      PopupMenuItem(value: 'delete', child: Text(s.delete)),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
