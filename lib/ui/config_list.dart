import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/models/profile.dart';
import '../core/parsers/misc_links.dart';
import '../core/services/lan_receiver.dart';
import '../core/services/subscription_service.dart';
import '../l10n/strings.dart';
import '../state/app_state.dart';
import 'widgets.dart';

/// Turns a subscription failure into something a person can act on.
String describeSubscriptionError(S s, Object error) {
  if (error is SubscriptionException) {
    return switch (error.code) {
      SubscriptionError.deviceLimit => s.deviceLimit,
      SubscriptionError.deviceIdRequired => s.deviceIdRequired,
      SubscriptionError.other => '${s.subscriptionFailed}: ${error.message}',
    };
  }
  return '${s.subscriptionFailed}: $error';
}

void _reportImport(BuildContext context, ImportOutcome outcome) {
  final s = S.of(context);
  if (outcome.failure != null) {
    showSnack(context, describeSubscriptionError(s, outcome.failure!));
    return;
  }
  if (outcome.added == 0) {
    showSnack(
        context,
        outcome.errors.isEmpty
            ? s.nothingImported
            : '${s.nothingImported}: ${outcome.errors.first}');
    return;
  }
  final skipped = outcome.errors.isEmpty ? '' : ' · ${s.skipped(outcome.errors.length)}';
  showSnack(context, '${s.imported(outcome.added)}$skipped');
}

Future<void> importText(BuildContext context, String text) async {
  final state = context.read<AppState>();
  final outcome = await state.importText(text);
  if (context.mounted) _reportImport(context, outcome);
}

Future<void> pasteFromClipboard(BuildContext context) async {
  final data = await Clipboard.getData(Clipboard.kTextPlain);
  if (!context.mounted) return;
  final text = data?.text?.trim() ?? '';
  if (text.isEmpty) {
    showSnack(context, S.of(context).clipboardEmpty);
    return;
  }
  await importText(context, text);
}

Future<void> _importFile(BuildContext context) async {
  final file = await openFile(acceptedTypeGroups: const [
    XTypeGroup(label: 'config', extensions: ['conf', 'json', 'txt']),
    XTypeGroup(label: 'all'),
  ]);
  if (file == null || !context.mounted) return;
  final String text;
  try {
    text = await file.readAsString();
  } on Object {
    if (context.mounted) showSnack(context, S.of(context).nothingImported);
    return;
  }
  if (context.mounted) await importText(context, text);
}

Future<void> _addSubscription(BuildContext context) async {
  final s = S.of(context);
  final url = await promptText(context,
      title: s.addSubscription, label: s.subscriptionUrl, hint: 'https://…');
  if (url == null || url.isEmpty || !context.mounted) return;
  final state = context.read<AppState>();
  try {
    final sub = await state.addSubscription(url);
    if (context.mounted) {
      showSnack(context, s.imported(state.profilesOf(sub.id).length));
    }
  } on Object catch (e) {
    if (context.mounted) showSnack(context, describeSubscriptionError(s, e));
  }
}

Future<void> _addManualProxy(BuildContext context) async {
  final profile = await showDialog<ProxyProfile>(
      context: context, builder: (_) => const _ManualProxyDialog());
  if (profile != null && context.mounted) {
    context.read<AppState>().addProfile(profile);
  }
}

/// Scans a QR code. A HeaNetwork pairing code from another device (a TV
/// waiting for a subscription) is answered by sending this device's
/// configurations there; anything else is imported here.
Future<void> _scanQr(BuildContext context) async {
  final text = await Navigator.push<String>(
      context, MaterialPageRoute(builder: (_) => const _QrScanPage()));
  if (text == null || !context.mounted) return;
  if (!isPairingUrl(text)) {
    await importText(context, text);
    return;
  }
  final s = S.of(context);
  final state = context.read<AppState>();
  final payload = <String>[
    for (final sub in state.subscriptions) sub.url,
    for (final p in state.profilesOf(null))
      if (p.link != null) p.link!,
  ];
  if (payload.isEmpty) {
    showSnack(context, s.serversEmptyTitle);
    return;
  }
  final ok = await confirm(context, s.sendToDevice,
      body: s.sendToDeviceBody(payload.length), action: s.send);
  if (!ok || !context.mounted) return;
  try {
    await sendToDevice(text, payload.join('\n'));
    if (context.mounted) showSnack(context, s.sent);
  } on Object catch (e) {
    if (context.mounted) showSnack(context, '${s.sendFailed}: $e');
  }
}

/// The "add" menu with every way to get a configuration into the app.
Future<void> showAddServerSheet(BuildContext context) {
  final s = S.of(context);
  final tv = context.read<AppState>().isTv;
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    constraints: const BoxConstraints(maxWidth: 560),
    builder: (sheet) {
      Widget item(IconData icon, String title, String? subtitle,
          Future<void> Function(BuildContext) run, {bool autofocus = false}) {
        return ListTile(
          autofocus: autofocus,
          leading: Icon(icon),
          title: Text(title),
          subtitle: subtitle == null ? null : Text(subtitle),
          onTap: () {
            Navigator.pop(sheet);
            run(context);
          },
        );
      }

      final receive = item(Icons.qr_code_2_rounded, s.receiveFromPhone,
          s.receiveFromPhoneHint, showReceiveDialog,
          autofocus: tv);
      return SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // On a TV typing is painful, so the phone route comes first.
              if (tv) receive,
              item(Icons.content_paste_rounded, s.pasteFromClipboard, null,
                  pasteFromClipboard),
              if (Platform.isAndroid && !tv)
                item(Icons.qr_code_scanner_rounded, s.scanQr, null, _scanQr),
              item(Icons.link_rounded, s.addSubscription, null, _addSubscription),
              if (!tv) receive,
              item(Icons.file_open_outlined, s.importFile, s.importFileHint, _importFile),
              item(Icons.tune_rounded, s.addManually, null, _addManualProxy),
              const SizedBox(height: 8),
            ],
          ),
        ),
      );
    },
  );
}

/// Shows a QR code another device can scan to send configurations here.
Future<void> showReceiveDialog(BuildContext context) =>
    showDialog<void>(context: context, builder: (_) => const _ReceiveDialog());

class _ReceiveDialog extends StatefulWidget {
  const _ReceiveDialog();

  @override
  State<_ReceiveDialog> createState() => _ReceiveDialogState();
}

class _ReceiveDialogState extends State<_ReceiveDialog> {
  LanReceiver? _receiver;
  StreamSubscription<String>? _sub;
  var _starting = true;
  String? _lastResult;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_starting && _receiver == null) _start();
  }

  Future<void> _start() async {
    final russian = Localizations.localeOf(context).languageCode == 'ru';
    LanReceiver? receiver;
    try {
      receiver = await LanReceiver.start(russian: russian);
    } on Object {
      receiver = null;
    }
    if (!mounted) {
      await receiver?.close();
      return;
    }
    setState(() {
      _receiver = receiver;
      _starting = false;
    });
    _sub = receiver?.received.listen(_onText);
  }

  Future<void> _onText(String text) async {
    final state = context.read<AppState>();
    final s = S.of(context);
    final outcome = await state.importText(text);
    if (!mounted) return;
    setState(() {
      _lastResult = outcome.failure != null
          ? describeSubscriptionError(s, outcome.failure!)
          : (outcome.added > 0 ? s.imported(outcome.added) : s.nothingImported);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _receiver?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final theme = Theme.of(context);
    final receiver = _receiver;
    final muted = theme.colorScheme.onSurfaceVariant;

    Widget step(int n, String text) => Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                radius: 10,
                backgroundColor: theme.colorScheme.primaryContainer,
                child: Text('$n',
                    style: TextStyle(
                        fontSize: 11, color: theme.colorScheme.onPrimaryContainer)),
              ),
              const SizedBox(width: 10),
              Expanded(child: Text(text)),
            ],
          ),
        );

    return AlertDialog(
      title: Text(s.receiveTitle),
      content: SizedBox(
        width: 520,
        child: _starting
            ? const SizedBox(height: 180, child: Center(child: CircularProgressIndicator()))
            : receiver == null
                ? Text(s.receiveNoNetwork)
                : SingleChildScrollView(
                    child: Wrap(
                      spacing: 24,
                      runSpacing: 16,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                              color: Colors.white, borderRadius: BorderRadius.circular(14)),
                          child: QrImageView(data: receiver.url, size: 200),
                        ),
                        SizedBox(
                          width: 250,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              step(1, s.receiveStep1),
                              step(2, s.receiveStep2),
                              step(3, s.receiveStep3),
                              const SizedBox(height: 6),
                              SelectableText(receiver.url,
                                  style: theme.textTheme.bodySmall?.copyWith(color: muted)),
                              const SizedBox(height: 10),
                              Row(
                                children: [
                                  if (_lastResult == null)
                                    const SizedBox.square(
                                        dimension: 14,
                                        child: CircularProgressIndicator(strokeWidth: 2))
                                  else
                                    Icon(Icons.check_circle_rounded,
                                        size: 18, color: theme.colorScheme.primary),
                                  const SizedBox(width: 8),
                                  Expanded(
                                      child: Text(_lastResult ?? s.receiveWaiting,
                                          style: theme.textTheme.bodyMedium)),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
      ),
      actions: [
        FilledButton(
          autofocus: true,
          onPressed: () => Navigator.pop(context),
          child: Text(s.close),
        ),
      ],
    );
  }
}

/// Every configuration the user has, grouped by subscription, with the
/// actions that apply to all of them in the header.
class ConfigList extends StatelessWidget {
  const ConfigList({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final s = S.of(context);
    final theme = Theme.of(context);
    final own = state.profilesOf(null);
    final empty = state.profiles.isEmpty && state.subscriptions.isEmpty;

    Future<void> refreshAll() async {
      if (state.subscriptions.isEmpty) {
        showSnack(context, s.noSubscriptions);
        return;
      }
      final failures = await state.refreshAllSubscriptions();
      if (!context.mounted) return;
      showSnack(
          context,
          failures.isEmpty
              ? s.subsRefreshed
              : describeSubscriptionError(s, failures.first));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(builder: (context, c) {
          final labels = c.maxWidth >= 430;
          Widget action(IconData icon, String label, String tooltip, bool busy,
              VoidCallback? onPressed) {
            final glyph = busy
                ? const SizedBox.square(
                    dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : Icon(icon, size: 18);
            return Tooltip(
              message: tooltip,
              child: labels
                  ? FilledButton.tonalIcon(
                      onPressed: busy ? null : onPressed, icon: glyph, label: Text(label))
                  : IconButton.filledTonal(onPressed: busy ? null : onPressed, icon: glyph),
            );
          }

          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              children: [
                Expanded(
                  child: Text(s.configs,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w600)),
                ),
                action(Icons.sync_rounded, s.refreshShort, s.refreshSubs,
                    state.refreshingSubscriptions, refreshAll),
                const SizedBox(width: 6),
                action(Icons.speed_rounded, s.pingShort, s.pingAll, state.testingLatency,
                    state.profiles.isEmpty ? null : () => state.testLatency()),
                const SizedBox(width: 6),
                Tooltip(
                  message: s.addServer,
                  child: IconButton.filled(
                    onPressed: () => showAddServerSheet(context),
                    icon: const Icon(Icons.add_rounded),
                  ),
                ),
              ],
            ),
          );
        }),
        if (empty)
          const _EmptyConfigs()
        else ...[
          if (own.isNotEmpty)
            Section(
              title: s.myServers,
              children: [for (final p in own) _ServerTile(profile: p)],
            ),
          for (final sub in state.subscriptions) _SubscriptionSection(sub: sub),
        ],
      ],
    );
  }
}

class _EmptyConfigs extends StatelessWidget {
  const _EmptyConfigs();

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final theme = Theme.of(context);
    final tv = context.read<AppState>().isTv;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.dns_outlined, size: 44, color: theme.colorScheme.outline),
            const SizedBox(height: 12),
            Text(s.serversEmptyTitle,
                style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: Text(s.serversEmptyBody,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                if (tv)
                  FilledButton.icon(
                    autofocus: true,
                    onPressed: () => showReceiveDialog(context),
                    icon: const Icon(Icons.qr_code_2_rounded),
                    label: Text(s.receiveFromPhone),
                  )
                else
                  FilledButton.icon(
                    onPressed: () => pasteFromClipboard(context),
                    icon: const Icon(Icons.content_paste_rounded),
                    label: Text(s.pasteFromClipboard),
                  ),
                OutlinedButton(
                  onPressed: () => _addSubscription(context),
                  child: Text(s.addSubscription),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SubscriptionSection extends StatelessWidget {
  const _SubscriptionSection({required this.sub});
  final Subscription sub;

  String _info(S s) {
    final parts = <String>[
      s.updatedAt(sub.updatedAt == null ? s.never : formatDateTime(sub.updatedAt!)),
    ];
    final total = sub.totalBytes;
    if (total != null && total > 0) {
      final used = (sub.uploadBytes ?? 0) + (sub.downloadBytes ?? 0);
      parts.add(s.usedOf(formatBytes(used), formatBytes(total)));
    }
    if (sub.expireAt != null) parts.add(s.expires(formatDate(sub.expireAt!)));
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final s = S.of(context);
    final theme = Theme.of(context);
    final servers = state.profilesOf(sub.id);
    final auto = state.autoSubscription?.id == sub.id;

    Future<void> refresh() async {
      try {
        await state.refreshSubscription(sub);
        if (context.mounted) showSnack(context, s.imported(state.profilesOf(sub.id).length));
      } on Object catch (e) {
        if (context.mounted) showSnack(context, describeSubscriptionError(s, e));
      }
    }

    return Section(
      title: sub.name,
      subtitle: _info(s),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
              tooltip: s.refresh, onPressed: refresh, icon: const Icon(Icons.refresh_rounded)),
          PopupMenuButton<String>(
            onSelected: (v) async {
              switch (v) {
                case 'rename':
                  final name = await promptText(context,
                      title: s.rename, initial: sub.name, label: s.name);
                  if (name != null && name.isNotEmpty) state.renameSubscription(sub, name);
                case 'copy':
                  await Clipboard.setData(ClipboardData(text: sub.url));
                  if (context.mounted) showSnack(context, s.copied);
                case 'support':
                  await launchUrl(Uri.parse(sub.supportUrl!),
                      mode: LaunchMode.externalApplication);
                case 'delete':
                  if (await confirm(context, s.deleteSubscriptionQ)) {
                    state.deleteSubscription(sub);
                  }
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(value: 'rename', child: Text(s.rename)),
              PopupMenuItem(value: 'copy', child: Text(s.copy)),
              if (sub.supportUrl != null)
                PopupMenuItem(value: 'support', child: Text(s.support)),
              PopupMenuItem(value: 'delete', child: Text(s.delete)),
            ],
          ),
        ],
      ),
      children: [
        if (sub.announce != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.campaign_outlined, size: 16, color: theme.colorScheme.tertiary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(sub.announce!,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.tertiary)),
                ),
              ],
            ),
          ),
        if (servers.length > 1)
          _SelectableRow(
            selected: auto,
            onTap: () => state.selectAuto(sub.id),
            leading: const Icon(Icons.auto_awesome_rounded, size: 18),
            title: s.autoSelect,
            subtitle: s.autoSelectOf(sub.name),
          ),
        for (final p in servers) _ServerTile(profile: p),
      ],
    );
  }
}

/// A row with a radio-style marker, used for servers and "auto-select".
class _SelectableRow extends StatelessWidget {
  const _SelectableRow({
    required this.selected,
    required this.onTap,
    required this.title,
    required this.subtitle,
    this.leading,
    this.trailing,
  });

  final bool selected;
  final VoidCallback onTap;
  final String title;
  final String subtitle;
  final Widget? leading;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      color: selected ? scheme.primary.withValues(alpha: 0.14) : Colors.transparent,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 2, 6),
            child: Row(
              children: [
                Icon(
                  selected
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_unchecked_rounded,
                  size: 20,
                  color: selected ? scheme.primary : scheme.outline,
                ),
                const SizedBox(width: 10),
                if (leading != null) ...[leading!, const SizedBox(width: 8)],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 14,
                              fontWeight: selected ? FontWeight.w600 : FontWeight.w500)),
                      Text(subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                    ],
                  ),
                ),
                trailing ?? const SizedBox(width: 12),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ServerTile extends StatelessWidget {
  const _ServerTile({required this.profile});
  final ProxyProfile profile;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final s = S.of(context);
    final selected =
        state.autoSubscription == null && state.selectedProfile?.id == profile.id;
    final inUse = state.autoSubscription != null &&
        state.autoSelectedProfileId == profile.id;

    return _SelectableRow(
      selected: selected,
      onTap: () => state.selectProfile(profile.id),
      title: profile.name,
      subtitle: '${profile.summary} · ${profile.server}',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (inUse)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Icon(Icons.auto_awesome_rounded,
                  size: 16, color: Theme.of(context).colorScheme.primary),
            ),
          LatencyBadge(profile.latencyMs, testing: state.testingLatency),
          PopupMenuButton<String>(
            iconSize: 20,
            onSelected: (v) async {
              switch (v) {
                case 'test':
                  await state.testLatency([profile]);
                case 'share':
                  await showDialog<void>(
                      context: context, builder: (_) => _ShareDialog(profile: profile));
                case 'rename':
                  final name = await promptText(context,
                      title: s.rename, initial: profile.name, label: s.name);
                  if (name != null && name.isNotEmpty) state.renameProfile(profile, name);
                case 'json':
                  final edited = await showDialog<Map<String, dynamic>>(
                      context: context, builder: (_) => _JsonDialog(profile: profile));
                  if (edited != null) state.replaceOutbound(profile, edited);
                case 'delete':
                  if (await confirm(context, s.deleteServerQ)) state.deleteProfile(profile);
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(value: 'test', child: Text(s.measure)),
              PopupMenuItem(value: 'share', child: Text(s.share)),
              PopupMenuItem(value: 'rename', child: Text(s.rename)),
              PopupMenuItem(value: 'json', child: Text(s.editJson)),
              if (profile.subscriptionId == null)
                PopupMenuItem(value: 'delete', child: Text(s.delete)),
            ],
          ),
        ],
      ),
    );
  }
}

class _ShareDialog extends StatelessWidget {
  const _ShareDialog({required this.profile});
  final ProxyProfile profile;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final link = profile.link;
    return AlertDialog(
      title: Text(profile.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      content: SizedBox(
        width: 320,
        child: link == null
            ? Text(s.noShareLink)
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // QR codes hold about 2.9 KB; longer configs are copy-only.
                  if (link.length <= 2200)
                    Container(
                      color: Colors.white,
                      padding: const EdgeInsets.all(8),
                      child: QrImageView(
                        data: link,
                        size: 240,
                        errorCorrectionLevel: QrErrorCorrectLevel.L,
                      ),
                    ),
                  const SizedBox(height: 12),
                  Text(s.shareHint,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
      ),
      actions: [
        if (link != null)
          TextButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: link));
              if (context.mounted) showSnack(context, s.copied);
            },
            icon: const Icon(Icons.copy_rounded, size: 18),
            label: Text(s.copy),
          ),
        FilledButton(onPressed: () => Navigator.pop(context), child: Text(s.close)),
      ],
    );
  }
}

class _JsonDialog extends StatefulWidget {
  const _JsonDialog({required this.profile});
  final ProxyProfile profile;

  @override
  State<_JsonDialog> createState() => _JsonDialogState();
}

class _JsonDialogState extends State<_JsonDialog> {
  late final _controller = TextEditingController(
      text: const JsonEncoder.withIndent('  ').convert(widget.profile.outbound));
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    final s = S.of(context);
    try {
      final v = jsonDecode(_controller.text);
      if (v is! Map || v['type'] is! String) throw const FormatException();
      Navigator.pop(context, Map<String, dynamic>.from(v));
    } on FormatException {
      setState(() => _error = s.invalidJson);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return AlertDialog(
      title: Text(s.editJson),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(s.jsonHint, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            Flexible(
              child: TextField(
                controller: _controller,
                maxLines: 16,
                minLines: 8,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                decoration: InputDecoration(errorText: _error),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(s.cancel)),
        FilledButton(onPressed: _save, child: Text(s.save)),
      ],
    );
  }
}

class _ManualProxyDialog extends StatefulWidget {
  const _ManualProxyDialog();

  @override
  State<_ManualProxyDialog> createState() => _ManualProxyDialogState();
}

class _ManualProxyDialogState extends State<_ManualProxyDialog> {
  var _type = 'socks5';
  final _host = TextEditingController();
  final _port = TextEditingController();
  final _user = TextEditingController();
  final _pass = TextEditingController();
  final _name = TextEditingController();

  @override
  void dispose() {
    for (final c in [_host, _port, _user, _pass, _name]) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    final host = _host.text.trim();
    final port = int.tryParse(_port.text.trim()) ?? 0;
    if (host.isEmpty || port <= 0 || port > 65535) return;
    final auth = _user.text.isEmpty
        ? ''
        : '${Uri.encodeComponent(_user.text)}:${Uri.encodeComponent(_pass.text)}@';
    final bracketed = host.contains(':') ? '[$host]' : host;
    final link =
        '$_type://$auth$bracketed:$port#${Uri.encodeComponent(_name.text.trim())}';
    final profile = _type == 'socks5' ? parseSocks(link) : parseHttpProxy(link);
    Navigator.pop(context, profile);
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return AlertDialog(
      title: Text(s.addManually),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SegmentedButton<String>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: 'socks5', label: Text('SOCKS5')),
                  ButtonSegment(value: 'http', label: Text('HTTP')),
                  ButtonSegment(value: 'https', label: Text('HTTPS')),
                ],
                selected: {_type},
                onSelectionChanged: (v) => setState(() => _type = v.first),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: TextField(
                        controller: _host,
                        autofocus: true,
                        decoration: InputDecoration(labelText: s.host)),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 2,
                    child: TextField(
                      controller: _port,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: InputDecoration(labelText: s.port),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                  controller: _user, decoration: InputDecoration(labelText: s.username)),
              const SizedBox(height: 12),
              TextField(
                controller: _pass,
                obscureText: true,
                decoration: InputDecoration(labelText: s.password),
              ),
              const SizedBox(height: 12),
              TextField(controller: _name, decoration: InputDecoration(labelText: s.name)),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(s.cancel)),
        FilledButton(onPressed: _save, child: Text(s.add)),
      ],
    );
  }
}

class _QrScanPage extends StatefulWidget {
  const _QrScanPage();

  @override
  State<_QrScanPage> createState() => _QrScanPageState();
}

class _QrScanPageState extends State<_QrScanPage> {
  var _done = false;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(title: Text(s.scanQr)),
      body: Stack(
        alignment: Alignment.bottomCenter,
        children: [
          MobileScanner(
            onDetect: (capture) {
              if (_done) return;
              final value = capture.barcodes
                  .map((b) => b.rawValue)
                  .whereType<String>()
                  .firstOrNull;
              if (value == null || value.isEmpty) return;
              _done = true;
              Navigator.pop(context, value);
            },
          ),
          Padding(
            padding: const EdgeInsets.all(24),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Text(s.qrPointCamera, style: const TextStyle(color: Colors.white)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
