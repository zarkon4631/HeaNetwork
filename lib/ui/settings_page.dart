import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/models/settings.dart';
import '../core/services/updater.dart';
import '../l10n/strings.dart';
import '../state/app_state.dart';
import 'widgets.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final s = S.of(context);
    final st = state.settings;

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(title: Text(s.navSettings)),
      body: PageBody(
        children: [
          _AntiDpiSection(state: state),
          Section(
            title: s.secConnection,
            children: [
              ListTile(
                title: Text(s.localPort),
                subtitle: Text(s.localPortHint),
                trailing: _NumberField(
                  value: st.mixedPort,
                  min: 1,
                  max: 65535,
                  onChanged: (v) => state.updateSettings((x) => x.mixedPort = v),
                ),
              ),
              SwitchListTile(
                title: Text(s.allowLan),
                subtitle: Text(s.allowLanHint),
                value: st.allowLan,
                onChanged: (v) => state.updateSettings((x) => x.allowLan = v),
              ),
              SwitchListTile(
                title: Text(s.killSwitch),
                subtitle: Text(s.killSwitchHint),
                value: st.strictRoute,
                onChanged: (v) => state.updateSettings((x) => x.strictRoute = v),
              ),
              SwitchListTile(
                title: Text(s.ipv6),
                subtitle: Text(s.ipv6Hint),
                value: st.ipv6,
                onChanged: (v) => state.updateSettings((x) => x.ipv6 = v),
              ),
              ListTile(
                title: Text(s.tunStack),
                trailing: DropdownButton<String>(
                  value: st.tunStack,
                  underline: const SizedBox.shrink(),
                  items: const [
                    DropdownMenuItem(value: 'mixed', child: Text('mixed')),
                    DropdownMenuItem(value: 'gvisor', child: Text('gVisor')),
                    DropdownMenuItem(value: 'system', child: Text('system')),
                  ],
                  onChanged: (v) => state.updateSettings((x) => x.tunStack = v!),
                ),
              ),
              // Only Windows can measure through a server, so only it has
              // a choice to offer.
              if (state.isWindows)
                ListTile(
                  title: Text(s.pingMode),
                  subtitle: Text(
                      st.pingMode == PingMode.tcp ? s.pingTcpHint : s.pingUrlHint),
                  trailing: DropdownButton<PingMode>(
                    value: st.pingMode,
                    underline: const SizedBox.shrink(),
                    items: [
                      DropdownMenuItem(value: PingMode.tcp, child: Text(s.pingTcp)),
                      DropdownMenuItem(value: PingMode.url, child: Text(s.pingUrl)),
                    ],
                    onChanged: (v) => state
                        .updateSettings((x) => x.pingMode = v!, affectsCore: false),
                  ),
                ),
            ],
          ),
          Section(
            title: s.secDns,
            children: [
              _DnsSetting(
                title: s.remoteDns,
                value: st.remoteDns,
                presets: remoteDnsPresets,
                hint: s.dnsRemoteHint,
                onChanged: (v) => state.updateSettings((x) => x.remoteDns = v),
              ),
              _DnsSetting(
                title: s.directDns,
                value: st.directDns,
                presets: directDnsPresets,
                hint: s.dnsDirectHint,
                onChanged: (v) => state.updateSettings((x) => x.directDns = v),
              ),
              SwitchListTile(
                title: Text(s.fakeIp),
                subtitle: Text(s.fakeIpHint),
                value: st.fakeIp,
                onChanged: (v) => state.updateSettings((x) => x.fakeIp = v),
              ),
            ],
          ),
          _PortForwardSection(state: state),
          Section(
            title: s.secApp,
            children: [
              ListTile(
                title: Text(s.language),
                trailing: DropdownButton<String>(
                  value: st.locale,
                  underline: const SizedBox.shrink(),
                  items: [
                    DropdownMenuItem(value: 'system', child: Text(s.langSystem)),
                    const DropdownMenuItem(value: 'ru', child: Text('Русский')),
                    const DropdownMenuItem(value: 'en', child: Text('English')),
                  ],
                  onChanged: (v) =>
                      state.updateSettings((x) => x.locale = v!, affectsCore: false),
                ),
              ),
              ListTile(
                title: Text(s.theme),
                trailing: DropdownButton<String>(
                  value: st.themeMode,
                  underline: const SizedBox.shrink(),
                  items: [
                    DropdownMenuItem(value: 'system', child: Text(s.themeSystem)),
                    DropdownMenuItem(value: 'light', child: Text(s.themeLight)),
                    DropdownMenuItem(value: 'dark', child: Text(s.themeDark)),
                  ],
                  onChanged: (v) =>
                      state.updateSettings((x) => x.themeMode = v!, affectsCore: false),
                ),
              ),
              if (state.isWindows)
                SwitchListTile(
                  title: Text(s.launchAtStartup),
                  value: st.launchAtStartup,
                  onChanged: state.setLaunchAtStartup,
                ),
              SwitchListTile(
                title: Text(s.autoConnect),
                value: st.autoConnect,
                onChanged: (v) =>
                    state.updateSettings((x) => x.autoConnect = v, affectsCore: false),
              ),
              if (state.isWindows)
                ListTile(
                  title: Text(s.closeBehaviour),
                  trailing: DropdownButton<CloseAction>(
                    value: st.closeAction,
                    underline: const SizedBox.shrink(),
                    items: [
                      DropdownMenuItem(value: CloseAction.ask, child: Text(s.closeAsk)),
                      DropdownMenuItem(value: CloseAction.tray, child: Text(s.closeToTray)),
                      DropdownMenuItem(value: CloseAction.exit, child: Text(s.closeQuit)),
                    ],
                    onChanged: (v) => state
                        .updateSettings((x) => x.closeAction = v!, affectsCore: false),
                  ),
                ),
              SwitchListTile(
                title: Text(s.animations),
                subtitle: Text(s.animationsHint),
                value: st.animations,
                onChanged: (v) =>
                    state.updateSettings((x) => x.animations = v, affectsCore: false),
              ),
              SwitchListTile(
                title: Text(s.sendHwid),
                subtitle: Text(state.device == null
                    ? s.sendHwidHint
                    : '${s.sendHwidHint}\n${s.deviceId(state.device!.hwid)}'),
                isThreeLine: state.device != null,
                value: st.sendHwid,
                onChanged: (v) =>
                    state.updateSettings((x) => x.sendHwid = v, affectsCore: false),
              ),
              ListTile(
                title: Text(s.logLevel),
                trailing: DropdownButton<String>(
                  value: st.logLevel,
                  underline: const SizedBox.shrink(),
                  items: [
                    DropdownMenuItem(value: 'warn', child: Text(s.logLevelWarn)),
                    DropdownMenuItem(value: 'info', child: Text(s.logLevelInfo)),
                    DropdownMenuItem(value: 'debug', child: Text(s.logLevelDebug)),
                  ],
                  onChanged: (v) => state.updateSettings((x) => x.logLevel = v!),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.article_outlined),
                title: Text(s.logs),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => Navigator.push(
                    context, MaterialPageRoute(builder: (_) => const LogsPage())),
              ),
            ],
          ),
          _UpdateSection(state: state),
          Section(
            title: s.secAbout,
            children: [
              ListTile(
                title: const Text('HeaNetwork'),
                subtitle: Text('${s.version(state.appVersion)}\n${s.aboutBody}'),
                isThreeLine: true,
              ),
              if (state.elevated)
                ListTile(
                  leading: const Icon(Icons.admin_panel_settings_rounded),
                  title: Text(s.runningAsAdmin),
                ),
              ListTile(
                leading: const Icon(Icons.code_rounded),
                title: Text(s.sourceCode),
                subtitle: const Text('github.com/$releaseRepo'),
                trailing: const Icon(Icons.open_in_new_rounded, size: 18),
                onTap: () => launchUrl(Uri.parse('https://github.com/$releaseRepo'),
                    mode: LaunchMode.externalApplication),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _AntiDpiSection extends StatelessWidget {
  const _AntiDpiSection({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final theme = Theme.of(context);
    final a = state.settings.antiDpi;
    final custom = a.preset == AntiDpiPreset.custom;

    void change(void Function(AntiDpiSettings a) f) =>
        state.updateSettings((x) => f(x.antiDpi));

    final hint = switch (a.preset) {
      AntiDpiPreset.off => s.presetOffHint,
      AntiDpiPreset.balanced => s.presetBalancedHint,
      AntiDpiPreset.strong => s.presetStrongHint,
      AntiDpiPreset.custom => null,
    };

    return Section(
      title: s.secAntiDpi,
      subtitle: s.antiDpiIntro,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: SizedBox(
            width: double.infinity,
            child: SegmentedButton<AntiDpiPreset>(
              showSelectedIcon: false,
              segments: [
                ButtonSegment(value: AntiDpiPreset.off, label: Text(s.presetOff)),
                ButtonSegment(value: AntiDpiPreset.balanced, label: Text(s.presetBalanced)),
                ButtonSegment(value: AntiDpiPreset.strong, label: Text(s.presetStrong)),
                ButtonSegment(value: AntiDpiPreset.custom, label: Text(s.presetCustom)),
              ],
              selected: {a.preset},
              onSelectionChanged: (v) => change((x) {
                // Entering "custom" starts from what the preset was doing.
                if (v.first == AntiDpiPreset.custom) {
                  final e = x.effective;
                  x
                    ..tlsFragment = e.tlsFragment
                    ..tlsRecordFragment = e.tlsRecordFragment
                    ..utlsFingerprint = e.utlsFingerprint
                    ..directFragment = e.directFragment;
                }
                x.preset = v.first;
              }),
            ),
          ),
        ),
        if (hint != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
            child: Text(hint,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.verified_user_outlined,
                  size: 15, color: theme.colorScheme.tertiary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(s.profileWins,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ),
            ],
          ),
        ),
        if (custom) ...[
          SwitchListTile(
            title: Text(s.tlsRecordFragment),
            value: a.tlsRecordFragment,
            onChanged: (v) => change((x) => x.tlsRecordFragment = v),
          ),
          SwitchListTile(
            title: Text(s.tlsFragment),
            subtitle: Text(s.tlsFragmentHint),
            value: a.tlsFragment,
            onChanged: (v) => change((x) => x.tlsFragment = v),
          ),
          SwitchListTile(
            title: Text(s.directFragment),
            subtitle: Text(s.directFragmentHint),
            value: a.directFragment,
            onChanged: (v) => change((x) => x.directFragment = v),
          ),
          ListTile(
            title: Text(s.fingerprint),
            trailing: DropdownButton<String>(
              value: a.utlsFingerprint,
              underline: const SizedBox.shrink(),
              items: [
                DropdownMenuItem(value: '', child: Text(s.fingerprintKeep)),
                for (final f in utlsFingerprints)
                  DropdownMenuItem(value: f, child: Text(f)),
              ],
              onChanged: (v) => change((x) => x.utlsFingerprint = v!),
            ),
          ),
          if (state.isWindows)
            _TextSetting(
              title: s.spoofSni,
              value: a.spoofSni,
              hint: s.spoofSniHint,
              placeholder: s.presetOff,
              onChanged: (v) => change((x) => x.spoofSni = v),
            ),
        ],
      ],
    );
  }
}

class _PortForwardSection extends StatelessWidget {
  const _PortForwardSection({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final list = state.settings.portForwards;

    Future<void> add() async {
      final created = await showDialog<PortForward>(
          context: context, builder: (_) => const _PortForwardDialog());
      if (created != null) state.updateSettings((x) => x.portForwards.add(created));
    }

    return Section(
      title: s.secTunnels,
      subtitle: s.tunnelsHint,
      trailing: Padding(
        padding: const EdgeInsets.only(right: 8),
        child: FilledButton.tonalIcon(
          onPressed: add,
          icon: const Icon(Icons.add_rounded, size: 18),
          label: Text(s.add),
        ),
      ),
      children: [
        for (final f in list)
          SwitchListTile(
            secondary: IconButton(
              tooltip: s.delete,
              icon: const Icon(Icons.close_rounded, size: 20),
              onPressed: () => state.updateSettings((x) => x.portForwards.remove(f)),
            ),
            title: Text('127.0.0.1:${f.listenPort}  →  ${f.targetHost}:${f.targetPort}'),
            subtitle: Text(f.viaProxy ? s.actionVpn : s.actionDirect),
            value: f.enabled,
            onChanged: (v) => state.updateSettings((_) => f.enabled = v),
          ),
      ],
    );
  }
}

class _PortForwardDialog extends StatefulWidget {
  const _PortForwardDialog();

  @override
  State<_PortForwardDialog> createState() => _PortForwardDialogState();
}

class _PortForwardDialogState extends State<_PortForwardDialog> {
  final _listen = TextEditingController();
  final _host = TextEditingController();
  final _port = TextEditingController();
  var _viaProxy = true;

  @override
  void dispose() {
    _listen.dispose();
    _host.dispose();
    _port.dispose();
    super.dispose();
  }

  void _save() {
    final listen = int.tryParse(_listen.text) ?? 0;
    final port = int.tryParse(_port.text) ?? 0;
    final host = _host.text.trim();
    bool valid(int p) => p > 0 && p <= 65535;
    if (!valid(listen) || !valid(port) || host.isEmpty) return;
    Navigator.pop(
        context,
        PortForward(
            listenPort: listen, targetHost: host, targetPort: port, viaProxy: _viaProxy));
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final digits = [FilteringTextInputFormatter.digitsOnly];
    return AlertDialog(
      title: Text(s.addTunnel),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _listen,
              autofocus: true,
              keyboardType: TextInputType.number,
              inputFormatters: digits,
              decoration: InputDecoration(labelText: s.localPort, prefixText: '127.0.0.1:'),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: TextField(
                      controller: _host,
                      decoration: InputDecoration(labelText: s.tunnelTarget)),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: _port,
                    keyboardType: TextInputType.number,
                    inputFormatters: digits,
                    decoration: InputDecoration(labelText: s.port),
                  ),
                ),
              ],
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(s.tunnelViaVpn),
              value: _viaProxy,
              onChanged: (v) => setState(() => _viaProxy = v),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(s.cancel)),
        FilledButton(onPressed: _save, child: Text(s.add)),
      ],
    );
  }
}

class _UpdateSection extends StatelessWidget {
  const _UpdateSection({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final update = state.availableUpdate;
    final progress = state.updateProgress;

    return Section(
      title: s.secUpdates,
      children: [
        ListTile(
          leading: Icon(update == null
              ? Icons.verified_outlined
              : Icons.system_update_alt_rounded),
          title: Text(update == null ? s.version(state.appVersion) : s.updateAvailable(update.version)),
          subtitle: state.updateError != null
              ? Text('${s.updateFailed}: ${state.updateError}',
                  style: TextStyle(color: Theme.of(context).colorScheme.error))
              : (update == null && state.lastUpdateCheckOk ? Text(s.upToDate) : null),
          trailing: progress != null
              ? SizedBox(
                  width: 96,
                  child: LinearProgressIndicator(value: progress == 0 ? null : progress))
              : (update == null
                  ? OutlinedButton(
                      onPressed: state.checkingUpdate ? null : () => state.checkForUpdate(),
                      child: Text(s.checkNow))
                  : (update.canInstall
                      ? FilledButton(
                          onPressed: state.installUpdate, child: Text(s.installUpdate))
                      : OutlinedButton(
                          onPressed: () => launchUrl(Uri.parse(update.pageUrl),
                              mode: LaunchMode.externalApplication),
                          child: Text(s.openReleasePage)))),
        ),
        if (update != null && update.notes.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(s.whatsNew, style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: 4),
                Text(update.notes.trim(),
                    maxLines: 12,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
        SwitchListTile(
          title: Text(s.checkUpdatesAuto),
          value: state.settings.checkUpdates,
          onChanged: (v) =>
              state.updateSettings((x) => x.checkUpdates = v, affectsCore: false),
        ),
      ],
    );
  }
}

/// A compact numeric field that commits on submit or focus loss.
class _NumberField extends StatefulWidget {
  const _NumberField(
      {required this.value, required this.min, required this.max, required this.onChanged});

  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;

  @override
  State<_NumberField> createState() => _NumberFieldState();
}

class _NumberFieldState extends State<_NumberField> {
  late final _controller = TextEditingController(text: '${widget.value}');
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _commit();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _commit() {
    final v = int.tryParse(_controller.text);
    if (v == null || v < widget.min || v > widget.max) {
      _controller.text = '${widget.value}';
    } else if (v != widget.value) {
      widget.onChanged(v);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 96,
      child: TextField(
        controller: _controller,
        focusNode: _focus,
        textAlign: TextAlign.end,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        onSubmitted: (_) => _commit(),
      ),
    );
  }
}

/// A DNS server picked from a short list of well-known ones, with a last
/// entry for typing in any other.
class _DnsSetting extends StatelessWidget {
  const _DnsSetting({
    required this.title,
    required this.value,
    required this.presets,
    required this.hint,
    required this.onChanged,
  });

  final String title;
  final String value;
  final List<DnsPreset> presets;
  final String hint;
  final ValueChanged<String> onChanged;

  // Cannot collide with an address: a DNS spec never starts with "#".
  static const _manual = '#manual';

  String _describe(S s, DnsPreset p) {
    final note = switch (p.note) {
      DnsNote.noAds => s.dnsNoAds,
      DnsNote.encrypted => s.dnsEncrypted,
      DnsNote.none => null,
    };
    return [
      // The nameless preset is "whatever the system uses".
      if (p.name.isEmpty) s.dnsLocal else ...[p.name, p.value],
      ?note,
    ].join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final scheme = Theme.of(context).colorScheme;
    final current = presets.where((p) => p.value == value).firstOrNull;

    return PopupMenuButton<String>(
      tooltip: '',
      position: PopupMenuPosition.under,
      constraints: const BoxConstraints(minWidth: 320),
      onSelected: (picked) async {
        if (picked != _manual) {
          onChanged(picked);
          return;
        }
        final typed = await promptText(context,
            title: title, initial: current == null ? value : '', hint: hint);
        if (typed != null && typed.isNotEmpty) onChanged(typed);
      },
      itemBuilder: (_) => [
        for (final p in presets)
          PopupMenuItem(
            value: p.value,
            child: Row(
              children: [
                Icon(
                  p.value == value
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_unchecked_rounded,
                  size: 18,
                  color: p.value == value ? scheme.primary : scheme.outline,
                ),
                const SizedBox(width: 12),
                Flexible(child: Text(_describe(s, p))),
              ],
            ),
          ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: _manual,
          child: Row(
            children: [
              Icon(Icons.edit_outlined, size: 18, color: scheme.onSurfaceVariant),
              const SizedBox(width: 12),
              Flexible(child: Text(s.dnsManual)),
            ],
          ),
        ),
      ],
      child: ListTile(
        title: Text(title),
        subtitle: Text(current == null ? s.dnsCustom(value) : _describe(s, current)),
        trailing: const Icon(Icons.arrow_drop_down_rounded),
      ),
    );
  }
}

/// A setting edited as free text in a dialog.
class _TextSetting extends StatelessWidget {
  const _TextSetting({
    required this.title,
    required this.value,
    required this.onChanged,
    this.hint,
    this.placeholder,
  });

  final String title;
  final String value;
  final String? hint;
  final String? placeholder;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(title),
      subtitle: Text(value.isEmpty ? (placeholder ?? '—') : value),
      trailing: const Icon(Icons.edit_outlined, size: 18),
      onTap: () async {
        final v = await promptText(context, title: title, initial: value, hint: hint);
        if (v != null) onChanged(v);
      },
    );
  }
}

class LogsPage extends StatefulWidget {
  const LogsPage({super.key});

  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final s = S.of(context);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(s.logs),
        actions: [
          // The log of this run and of the one before it is also kept on
          // disk, where it outlives the app.
          if (state.coreLogDirectory != null)
            IconButton(
              tooltip: s.openLogFolder,
              icon: const Icon(Icons.folder_open_rounded),
              onPressed: state.openCoreLogDirectory,
            ),
          IconButton(
            tooltip: s.copy,
            icon: const Icon(Icons.copy_rounded),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: state.core.logs.join('\n')));
              if (context.mounted) showSnack(context, s.copied);
            },
          ),
          IconButton(
            tooltip: s.clear,
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: () => setState(state.core.clearLogs),
          ),
        ],
      ),
      body: StreamBuilder<String>(
        stream: state.core.logStream,
        builder: (context, _) {
          final logs = state.core.logs;
          if (logs.isEmpty) {
            return Center(
                child: Text(s.logsEmpty,
                    style: TextStyle(color: theme.colorScheme.onSurfaceVariant)));
          }
          // Newest first, so fresh lines appear without chasing the scroll.
          return SelectionArea(
            child: ListView.builder(
              controller: _scroll,
              padding: const EdgeInsets.all(12),
              itemCount: logs.length,
              itemBuilder: (context, i) {
                final line = logs[logs.length - 1 - i];
                final bad = line.contains('ERROR') || line.contains('FATAL');
                return Text(
                  line,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    height: 1.35,
                    color: bad
                        ? theme.colorScheme.error
                        : (line.contains('WARN') ? theme.colorScheme.tertiary : null),
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}
