import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../core/models/profile.dart';
import '../core/parsers/misc_links.dart';
import '../core/services/subscription_service.dart';
import '../l10n/strings.dart';
import '../state/app_state.dart';
import 'widgets.dart';

void _reportImport(BuildContext context, ImportOutcome outcome) {
  final s = S.of(context);
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

Future<void> _importText(BuildContext context, String text) async {
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
  await _importText(context, text);
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
  if (context.mounted) await _importText(context, text);
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
  } on SubscriptionException catch (e) {
    if (context.mounted) showSnack(context, '${s.subscriptionFailed}: ${e.message}');
  } on Object catch (e) {
    if (context.mounted) showSnack(context, '${s.subscriptionFailed}: $e');
  }
}

Future<void> _addManualProxy(BuildContext context) async {
  final profile = await showDialog<ProxyProfile>(
      context: context, builder: (_) => const _ManualProxyDialog());
  if (profile != null && context.mounted) {
    context.read<AppState>().addProfile(profile);
  }
}

/// The "add server" menu with every way to import.
Future<void> showAddServerSheet(BuildContext context) {
  final s = S.of(context);
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    constraints: const BoxConstraints(maxWidth: 560),
    builder: (sheet) {
      Widget item(IconData icon, String title, String? subtitle,
          Future<void> Function(BuildContext) run) {
        return ListTile(
          leading: Icon(icon),
          title: Text(title),
          subtitle: subtitle == null ? null : Text(subtitle),
          onTap: () {
            Navigator.pop(sheet);
            run(context);
          },
        );
      }

      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            item(Icons.content_paste_rounded, s.pasteFromClipboard, null,
                pasteFromClipboard),
            if (Platform.isAndroid)
              item(Icons.qr_code_scanner_rounded, s.scanQr, null, (c) async {
                final text = await Navigator.push<String>(
                    c, MaterialPageRoute(builder: (_) => const _QrScanPage()));
                if (text != null && c.mounted) await _importText(c, text);
              }),
            item(Icons.link_rounded, s.addSubscription, null, _addSubscription),
            item(Icons.file_open_outlined, s.importFile, s.importFileHint, _importFile),
            item(Icons.tune_rounded, s.addManually, null, _addManualProxy),
            const SizedBox(height: 8),
          ],
        ),
      );
    },
  );
}

class ServersPage extends StatelessWidget {
  const ServersPage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final s = S.of(context);
    final own = state.profilesOf(null);

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: Text(s.navServers),
        actions: [
          if (state.profiles.isNotEmpty)
            IconButton(
              tooltip: s.testAll,
              onPressed: state.testingLatency ? null : () => state.testLatency(),
              icon: state.testingLatency
                  ? const SizedBox.square(
                      dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.speed_rounded),
            ),
          Padding(
            padding: const EdgeInsets.only(right: 12, left: 4),
            child: FilledButton.icon(
              onPressed: () => showAddServerSheet(context),
              icon: const Icon(Icons.add_rounded, size: 20),
              label: Text(s.add),
            ),
          ),
        ],
      ),
      body: state.profiles.isEmpty && state.subscriptions.isEmpty
          ? const _EmptyServers()
          : PageBody(
              children: [
                if (own.isNotEmpty)
                  Section(
                    title: s.myServers,
                    children: [for (final p in own) _ServerTile(profile: p)],
                  ),
                for (final sub in state.subscriptions) _SubscriptionSection(sub: sub),
              ],
            ),
    );
  }
}

class _EmptyServers extends StatelessWidget {
  const _EmptyServers();

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final theme = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.dns_outlined, size: 56, color: theme.colorScheme.outline),
              const SizedBox(height: 16),
              Text(s.serversEmptyTitle,
                  style: theme.textTheme.titleLarge
                      ?.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Text(s.serversEmptyBody,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: () => pasteFromClipboard(context),
                icon: const Icon(Icons.content_paste_rounded),
                label: Text(s.pasteFromClipboard),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => _addSubscription(context),
                child: Text(s.addSubscription),
              ),
            ],
          ),
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
    final servers = state.profilesOf(sub.id);
    final auto = state.autoSubscription?.id == sub.id;

    Future<void> refresh() async {
      try {
        await state.refreshSubscription(sub);
        if (context.mounted) showSnack(context, s.imported(state.profilesOf(sub.id).length));
      } on Object catch (e) {
        if (context.mounted) showSnack(context, '${s.subscriptionFailed}: $e');
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
                case 'delete':
                  if (await confirm(context, s.deleteSubscriptionQ)) {
                    state.deleteSubscription(sub);
                  }
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(value: 'rename', child: Text(s.rename)),
              PopupMenuItem(value: 'copy', child: Text(s.copy)),
              PopupMenuItem(value: 'delete', child: Text(s.delete)),
            ],
          ),
        ],
      ),
      children: [
        if (servers.length > 1)
          _SelectableRow(
            selected: auto,
            onTap: () => state.selectAuto(sub.id),
            leading: const Icon(Icons.auto_awesome_rounded, size: 20),
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
    return Material(
      color: selected ? scheme.primaryContainer.withValues(alpha: 0.45) : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
          child: Row(
            children: [
              Icon(
                selected
                    ? Icons.radio_button_checked_rounded
                    : Icons.radio_button_unchecked_rounded,
                color: selected ? scheme.primary : scheme.outline,
              ),
              const SizedBox(width: 12),
              if (leading != null) ...[leading!, const SizedBox(width: 10)],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontWeight: selected ? FontWeight.w600 : FontWeight.w500)),
                    Text(subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
                  ],
                ),
              ),
              trailing ?? const SizedBox(width: 12),
            ],
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
