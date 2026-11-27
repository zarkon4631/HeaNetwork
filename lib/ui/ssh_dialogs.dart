import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/models/profile.dart';
import '../core/models/ssh.dart';
import '../core/services/ssh_connector.dart';
import '../core/services/ssh_transfer.dart';
import '../l10n/strings.dart';
import '../state/app_state.dart';
import 'widgets.dart';

/// Prompts the user to trust a new or changed SSH server host key (TOFU).
Future<bool> showHostKeyDialog(
  BuildContext context, {
  required String hostLabel,
  required String keyType,
  required String fingerprint,
  required String? previousFingerprint,
}) async {
  final s = S.of(context);
  final changed = previousFingerprint != null;
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      icon: Icon(
        changed ? Icons.warning_amber_rounded : Icons.fingerprint_rounded,
        color: changed ? Theme.of(ctx).colorScheme.error : null,
      ),
      title: Text(changed ? s.sshHostKeyChangedTitle : s.sshHostKeyTitle),
      content: SizedBox(
        width: 460,
        child: SelectableText(
          s.sshHostKeyBody(hostLabel, keyType, fingerprint, previousFingerprint),
          style: const TextStyle(fontSize: 13),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(s.cancel),
        ),
        FilledButton(
          style: changed
              ? FilledButton.styleFrom(
                  backgroundColor: Theme.of(ctx).colorScheme.error)
              : null,
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(s.sshTrust),
        ),
      ],
    ),
  );
  return result == true;
}

/// Dialog to create or edit an [SshHost] (optionally pre-filled from a VPN
/// [ProxyProfile]).
Future<SshHost?> showSshHostDialog(
  BuildContext context,
  AppState state, {
  SshHost? existing,
  ProxyProfile? fromProfile,
}) async {
  final s = S.of(context);
  final nameCtrl =
      TextEditingController(text: existing?.name ?? fromProfile?.name ?? '');
  final hostCtrl =
      TextEditingController(text: existing?.host ?? fromProfile?.server ?? '');
  final portCtrl =
      TextEditingController(text: '${existing?.port ?? 22}');
  final userCtrl =
      TextEditingController(text: existing?.username ?? 'root');
  final passCtrl = TextEditingController();

  var auth = existing?.authType ?? SshAuthType.password;
  var keyId = existing?.keyId ??
      (state.sshData.keys.isNotEmpty ? state.sshData.keys.first.id : null);
  var routeMode = existing?.routeMode ?? SshRouteMode.inherit;
  final hasStoredPassword =
      existing != null && state.sshSecrets.passwords.containsKey(existing.id);

  final saved = await showDialog<SshHost>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: Text(existing == null ? s.sshAddHost : s.sshEditHost),
        content: SizedBox(
          width: 440,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameCtrl,
                  decoration: InputDecoration(labelText: s.name),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: TextField(
                        controller: hostCtrl,
                        decoration:
                            InputDecoration(labelText: s.sshHostAddress),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        controller: portCtrl,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(labelText: s.sshPort),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: userCtrl,
                  decoration: InputDecoration(labelText: s.sshUsername),
                ),
                const SizedBox(height: 12),
                SegmentedButton<SshAuthType>(
                  segments: [
                    ButtonSegment(
                      value: SshAuthType.password,
                      label: Text(s.sshAuthPassword),
                      icon: const Icon(Icons.password_rounded, size: 16),
                    ),
                    ButtonSegment(
                      value: SshAuthType.key,
                      label: Text(s.sshAuthKey),
                      icon: const Icon(Icons.key_rounded, size: 16),
                    ),
                  ],
                  selected: {auth},
                  onSelectionChanged: (v) => setState(() => auth = v.first),
                ),
                const SizedBox(height: 10),
                if (auth == SshAuthType.password)
                  TextField(
                    controller: passCtrl,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: s.sshPassword,
                      hintText:
                          hasStoredPassword ? s.sshPasswordKeepHint : null,
                    ),
                  )
                else if (state.sshData.keys.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(s.sshNoKeys),
                  )
                else
                  DropdownButtonFormField<String>(
                    initialValue:
                        state.sshData.keys.any((k) => k.id == keyId)
                            ? keyId
                            : state.sshData.keys.first.id,
                    decoration: InputDecoration(labelText: s.sshAuthKey),
                    items: [
                      for (final k in state.sshData.keys)
                        DropdownMenuItem(value: k.id, child: Text(k.name)),
                    ],
                    onChanged: (v) => setState(() => keyId = v),
                  ),
                const SizedBox(height: 10),
                DropdownButtonFormField<SshRouteMode>(
                  initialValue: routeMode,
                  decoration: InputDecoration(labelText: s.sshRouteLabel),
                  items: [
                    DropdownMenuItem(
                        value: SshRouteMode.inherit,
                        child: Text(s.sshRouteGlobal)),
                    DropdownMenuItem(
                        value: SshRouteMode.direct,
                        child: Text(s.sshRouteDirect)),
                    DropdownMenuItem(
                        value: SshRouteMode.proxy,
                        child: Text(s.sshRouteProxy)),
                  ],
                  onChanged: (v) =>
                      setState(() => routeMode = v ?? SshRouteMode.inherit),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: Text(s.cancel)),
          FilledButton(
            onPressed: () {
              final hostAddr = hostCtrl.text.trim();
              if (hostAddr.isEmpty) return;
              final port = int.tryParse(portCtrl.text.trim()) ?? 22;
              final user = userCtrl.text.trim().isEmpty
                  ? 'root'
                  : userCtrl.text.trim();
              final name = nameCtrl.text.trim().isEmpty
                  ? hostAddr
                  : nameCtrl.text.trim();
              final model = SshHost(
                id: existing?.id,
                name: name,
                host: hostAddr,
                port: port.clamp(1, 65535),
                username: user,
                authType: auth,
                keyId: auth == SshAuthType.key ? keyId : null,
                linkedProfileId: existing?.linkedProfileId ?? fromProfile?.id,
                routeMode: routeMode,
                hostFingerprint: existing?.hostFingerprint,
                lastConnectedAt: existing?.lastConnectedAt,
              );
              final enteredPass = passCtrl.text;
              state.saveSshHost(
                model,
                password: enteredPass.isEmpty ? null : enteredPass,
              );
              Navigator.pop(ctx, model);
            },
            child: Text(s.save),
          ),
        ],
      ),
    ),
  );
  nameCtrl.dispose();
  hostCtrl.dispose();
  portCtrl.dispose();
  userCtrl.dispose();
  passCtrl.dispose();
  return saved;
}

/// Dialog to manage SSH keys (import from file, paste PEM, or generate Ed25519).
Future<void> showSshKeysDialog(BuildContext context, AppState state) async {
  final s = S.of(context);
  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: Text(s.sshKeys),
        content: SizedBox(
          width: 480,
          height: 340,
          child: Column(
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.tonalIcon(
                    onPressed: () async {
                      final xf = await openFile();
                      if (xf == null || !ctx.mounted) return;
                      final pem = await File(xf.path).readAsString();
                      final pub = extractPublicKeyFromPem(pem);
                      state.saveSshKey(
                        SshKey(name: xf.name, publicKey: pub),
                        privateKey: pem,
                      );
                      setState(() {});
                    },
                    icon: const Icon(Icons.file_open_outlined, size: 16),
                    label: Text(s.sshImportKeyFile),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: () async {
                      await _showPasteKeyDialog(ctx, state);
                      setState(() {});
                    },
                    icon: const Icon(Icons.paste_rounded, size: 16),
                    label: Text(s.sshPasteKey),
                  ),
                  FilledButton.icon(
                    onPressed: () async {
                      final pair = await generateEd25519KeyPair();
                      final key = SshKey(
                        name: 'ed25519-${state.sshData.keys.length + 1}',
                        publicKey: pair.publicKey,
                      );
                      state.saveSshKey(key, privateKey: pair.privateKey);
                      setState(() {});
                    },
                    icon: const Icon(Icons.auto_fix_high_rounded, size: 16),
                    label: Text(s.sshGenerateKey),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              const Divider(height: 1),
              Expanded(
                child: state.sshData.keys.isEmpty
                    ? Center(child: Text(s.sshNoKeys))
                    : ListView.separated(
                        itemCount: state.sshData.keys.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (_, i) {
                          final k = state.sshData.keys[i];
                          return ListTile(
                            dense: true,
                            leading: const Icon(Icons.key_rounded, size: 18),
                            title: Text(k.name),
                            subtitle: k.publicKey.isNotEmpty
                                ? Text(k.publicKey,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        fontFamily: 'Consolas', fontSize: 11))
                                : null,
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (k.publicKey.isNotEmpty)
                                  IconButton(
                                    tooltip: s.sshCopyPublicKey,
                                    iconSize: 18,
                                    onPressed: () {
                                      Clipboard.setData(
                                          ClipboardData(text: k.publicKey));
                                      showSnack(context, s.copied);
                                    },
                                    icon: const Icon(Icons.copy_rounded),
                                  ),
                                IconButton(
                                  tooltip: s.delete,
                                  iconSize: 18,
                                  onPressed: () {
                                    state.deleteSshKey(k.id);
                                    setState(() {});
                                  },
                                  icon:
                                      const Icon(Icons.delete_outline_rounded),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
        actions: [
          FilledButton(
              onPressed: () => Navigator.pop(ctx), child: Text(s.close)),
        ],
      ),
    ),
  );
}

Future<void> _showPasteKeyDialog(BuildContext context, AppState state) async {
  final s = S.of(context);
  final nameCtrl = TextEditingController();
  final pemCtrl = TextEditingController();
  final passCtrl = TextEditingController();
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(s.sshPasteKey),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
                controller: nameCtrl,
                decoration: InputDecoration(labelText: s.name)),
            const SizedBox(height: 8),
            TextField(
              controller: pemCtrl,
              maxLines: 6,
              style: const TextStyle(fontFamily: 'Consolas', fontSize: 12),
              decoration: InputDecoration(labelText: s.sshPrivateKey),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: passCtrl,
              obscureText: true,
              decoration: InputDecoration(labelText: s.sshPassphrase),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: Text(s.cancel)),
        FilledButton(
          onPressed: () {
            final pem = pemCtrl.text.trim();
            if (pem.isEmpty) return;
            final name = nameCtrl.text.trim().isEmpty
                ? 'key-${state.sshData.keys.length + 1}'
                : nameCtrl.text.trim();
            final pass = passCtrl.text;
            final pub =
                extractPublicKeyFromPem(pem, pass.isEmpty ? null : pass);
            state.saveSshKey(
              SshKey(name: name, publicKey: pub),
              privateKey: pem,
              passphrase: pass.isEmpty ? null : pass,
            );
            Navigator.pop(ctx);
          },
          child: Text(s.save),
        ),
      ],
    ),
  );
  nameCtrl.dispose();
  pemCtrl.dispose();
  passCtrl.dispose();
}

/// Dialog to create or edit a command snippet.
Future<void> showSshSnippetDialog(
  BuildContext context,
  AppState state, {
  SshSnippet? existing,
}) async {
  final s = S.of(context);
  final nameCtrl = TextEditingController(text: existing?.name ?? '');
  final cmdCtrl = TextEditingController(text: existing?.command ?? '');
  var autoRun = existing?.autoRun ?? true;
  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: Text(existing == null ? s.sshAddSnippet : s.sshEditSnippet),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                decoration: InputDecoration(labelText: s.name),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: cmdCtrl,
                maxLines: 4,
                style: const TextStyle(fontFamily: 'Consolas', fontSize: 13),
                decoration: InputDecoration(labelText: s.sshSnippetCommand),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(s.sshSnippetAutoRun),
                value: autoRun,
                onChanged: (v) => setState(() => autoRun = v ?? true),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(s.cancel)),
          FilledButton(
            onPressed: () {
              final cmd = cmdCtrl.text.trim();
              if (cmd.isEmpty) return;
              final name =
                  nameCtrl.text.trim().isEmpty ? cmd : nameCtrl.text.trim();
              state.saveSshSnippet(SshSnippet(
                id: existing?.id,
                name: name,
                command: cmd,
                autoRun: autoRun,
              ));
              Navigator.pop(ctx);
            },
            child: Text(s.save),
          ),
        ],
      ),
    ),
  );
  nameCtrl.dispose();
  cmdCtrl.dispose();
}

/// App-to-app encrypted transfer dialog supporting both LAN (6-digit PIN + UDP
/// discovery) and encrypted `.heassh` file / `heanetwork://ssh-import?...` link.
Future<void> showSshTransferDialog(
  BuildContext context,
  AppState state, {
  String? initialBundleText,
}) async {
  await showDialog<void>(
    context: context,
    builder: (ctx) => _SshTransferDialog(
      state: state,
      initialBundleText: initialBundleText,
    ),
  );
}

class _SshTransferDialog extends StatefulWidget {
  const _SshTransferDialog({required this.state, this.initialBundleText});

  final AppState state;
  final String? initialBundleText;

  @override
  State<_SshTransferDialog> createState() => _SshTransferDialogState();
}

class _SshTransferDialogState extends State<_SshTransferDialog> {
  // 0 = Send, 1 = Receive
  late int _mode = widget.initialBundleText != null ? 1 : 0;
  // 0 = LAN, 1 = File / Link
  late int _transport = widget.initialBundleText != null ? 1 : 0;

  // Selection for sending
  late final Set<String> _hostIds = {
    for (final h in widget.state.sshData.hosts) h.id,
  };
  late final Set<String> _keyIds = {
    for (final k in widget.state.sshData.keys) k.id,
  };
  late final Set<String> _snippetIds = {
    for (final sn in widget.state.sshData.snippets) sn.id,
  };
  bool _includeSecrets = true;

  // Send state
  late final _sendPinCtrl = TextEditingController(text: generateTransferPin());
  SshLanSender? _lanSender;
  StreamSubscription<void>? _deliveredSub;
  String? _statusMsg;

  // Receive state
  late final _recvTextCtrl =
      TextEditingController(text: widget.initialBundleText ?? '');
  final _recvPinCtrl = TextEditingController();
  final _manualAddrCtrl = TextEditingController();
  SshLanDiscoverer? _discoverer;
  StreamSubscription<List<SshLanPeer>>? _peersSub;
  List<SshLanPeer> _peers = [];
  SshLanPeer? _selectedPeer;
  bool _busy = false;
  SshTransferPayload? _decodedPreview;

  @override
  void initState() {
    super.initState();
    if (_mode == 1 && _transport == 0) _startDiscoverer();
  }

  @override
  void dispose() {
    _stopSender();
    _stopDiscoverer();
    _sendPinCtrl.dispose();
    _recvTextCtrl.dispose();
    _recvPinCtrl.dispose();
    _manualAddrCtrl.dispose();
    super.dispose();
  }

  Future<void> _stopSender() async {
    await _deliveredSub?.cancel();
    _deliveredSub = null;
    await _lanSender?.close();
    _lanSender = null;
  }

  Future<void> _startDiscoverer() async {
    await _stopDiscoverer();
    final d = await SshLanDiscoverer.start();
    if (!mounted || d == null) return;
    _discoverer = d;
    _peersSub = d.peers.listen((list) {
      if (!mounted) return;
      setState(() => _peers = list);
    });
  }

  Future<void> _stopDiscoverer() async {
    await _peersSub?.cancel();
    _peersSub = null;
    await _discoverer?.close();
    _discoverer = null;
  }

  SshTransferPayload _currentPayload() => buildTransferPayload(
        data: widget.state.sshData,
        secrets: widget.state.sshSecrets,
        hostIds: _hostIds,
        keyIds: _keyIds,
        snippetIds: _snippetIds,
        includeSecrets: _includeSecrets,
      );

  Future<void> _startLanSend() async {
    final s = S.of(context);
    final payload = _currentPayload();
    if (payload.isEmpty) return;
    setState(() {
      _busy = true;
      _statusMsg = null;
    });
    try {
      await _stopSender();
      final sender = await SshLanSender.start(
        payload: payload,
        pin: _sendPinCtrl.text.trim(),
      );
      if (!mounted) {
        await sender?.close();
        return;
      }
      if (sender == null) {
        setState(() => _statusMsg = s.sshLanNoNetwork);
      } else {
        _lanSender = sender;
        _deliveredSub = sender.delivered.listen((_) {
          if (mounted) setState(() => _statusMsg = s.sshSentOk);
        });
      }
    } on Object catch (e) {
      if (mounted) setState(() => _statusMsg = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _exportFile() async {
    final s = S.of(context);
    final payload = _currentPayload();
    final pin = _sendPinCtrl.text.trim();
    if (payload.isEmpty || pin.isEmpty) return;
    setState(() => _busy = true);
    try {
      final encoded = await encodeSshBundle(payload, pin);
      final loc = await getSaveLocation(
        suggestedName: 'heanetwork-ssh.heassh',
        acceptedTypeGroups: const [
          XTypeGroup(label: 'HeaNetwork SSH Bundle', extensions: ['heassh']),
        ],
      );
      if (loc != null) {
        await File(loc.path).writeAsString(encoded, flush: true);
        if (mounted) setState(() => _statusMsg = s.backupSaved);
      }
    } on Object catch (e) {
      if (mounted) setState(() => _statusMsg = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copyLink() async {
    final s = S.of(context);
    final payload = _currentPayload();
    final pin = _sendPinCtrl.text.trim();
    if (payload.isEmpty || pin.isEmpty) return;
    setState(() => _busy = true);
    try {
      final encoded = await encodeSshBundle(payload, pin);
      await Clipboard.setData(ClipboardData(text: toSshImportLink(encoded)));
      if (mounted) setState(() => _statusMsg = s.copied);
    } on Object catch (e) {
      if (mounted) setState(() => _statusMsg = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openBundleFile() async {
    final xf = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'HeaNetwork SSH Bundle', extensions: ['heassh']),
      ],
    );
    if (xf == null || !mounted) return;
    final text = (await File(xf.path).readAsString()).trim();
    setState(() {
      _recvTextCtrl.text = text;
      _decodedPreview = null;
      _statusMsg = null;
    });
  }

  Future<void> _decryptAndPreview() async {
    final s = S.of(context);
    final pin = _recvPinCtrl.text.trim();
    if (pin.isEmpty) return;
    setState(() {
      _busy = true;
      _statusMsg = null;
      _decodedPreview = null;
    });
    try {
      String raw;
      if (_transport == 0) {
        final addr = _selectedPeer?.address ?? _manualAddrCtrl.text.trim();
        if (addr.isEmpty) return;
        raw = await fetchSshBundleFromLan(addr);
      } else {
        raw = _recvTextCtrl.text.trim();
      }
      final payload = await decodeSshBundle(raw, pin);
      if (!mounted) return;
      if (payload == null) {
        setState(() => _statusMsg = s.sshBadBundleOrPin);
      } else {
        setState(() => _decodedPreview = payload);
      }
    } on Object catch (e) {
      if (mounted) setState(() => _statusMsg = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _confirmImport() {
    final payload = _decodedPreview;
    if (payload == null) return;
    final s = S.of(context);
    final counts = widget.state.importSshPayload(payload);
    Navigator.pop(context);
    showSnack(
      context,
      s.sshImportedDone(counts.hosts, counts.keys, counts.snippets),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final data = widget.state.sshData;
    return AlertDialog(
      title: Text(s.sshTransfer),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SegmentedButton<int>(
                segments: [
                  ButtonSegment(
                    value: 0,
                    label: Text(s.sshSend),
                    icon: const Icon(Icons.upload_rounded, size: 16),
                  ),
                  ButtonSegment(
                    value: 1,
                    label: Text(s.sshReceive),
                    icon: const Icon(Icons.download_rounded, size: 16),
                  ),
                ],
                selected: {_mode},
                onSelectionChanged: (v) {
                  setState(() {
                    _mode = v.first;
                    _statusMsg = null;
                    _decodedPreview = null;
                  });
                  if (_mode == 1 && _transport == 0) {
                    _startDiscoverer();
                  } else {
                    _stopDiscoverer();
                  }
                  if (_mode != 0) _stopSender();
                },
              ),
              const SizedBox(height: 10),
              SegmentedButton<int>(
                segments: [
                  ButtonSegment(
                      value: 0,
                      label: Text(s.sshTransferLan),
                      icon: const Icon(Icons.wifi_tethering_rounded, size: 16)),
                  ButtonSegment(
                      value: 1,
                      label: Text(s.sshTransferFileLink),
                      icon: const Icon(Icons.link_rounded, size: 16)),
                ],
                selected: {_transport},
                onSelectionChanged: (v) {
                  setState(() {
                    _transport = v.first;
                    _statusMsg = null;
                    _decodedPreview = null;
                  });
                  if (_mode == 1 && _transport == 0) {
                    _startDiscoverer();
                  } else {
                    _stopDiscoverer();
                  }
                  if (_transport != 0) _stopSender();
                },
              ),
              const SizedBox(height: 12),
              if (_mode == 0) ...[
                Text(s.sshTransferSelect,
                    style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    for (final h in data.hosts)
                      FilterChip(
                        label: Text(h.name),
                        selected: _hostIds.contains(h.id),
                        onSelected: (v) => setState(() =>
                            v ? _hostIds.add(h.id) : _hostIds.remove(h.id)),
                      ),
                    for (final sn in data.snippets)
                      FilterChip(
                        avatar: const Icon(Icons.bolt_rounded, size: 14),
                        label: Text(sn.name),
                        selected: _snippetIds.contains(sn.id),
                        onSelected: (v) => setState(() => v
                            ? _snippetIds.add(sn.id)
                            : _snippetIds.remove(sn.id)),
                      ),
                    for (final k in data.keys)
                      FilterChip(
                        avatar: const Icon(Icons.key_rounded, size: 14),
                        label: Text(k.name),
                        selected: _keyIds.contains(k.id),
                        onSelected: (v) => setState(() =>
                            v ? _keyIds.add(k.id) : _keyIds.remove(k.id)),
                      ),
                  ],
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  dense: true,
                  title: Text(s.sshIncludeSecrets),
                  value: _includeSecrets,
                  onChanged: (v) =>
                      setState(() => _includeSecrets = v ?? true),
                ),
                TextField(
                  controller: _sendPinCtrl,
                  decoration: InputDecoration(
                    labelText: s.sshPinCode,
                    suffixIcon: IconButton(
                      onPressed: () =>
                          _sendPinCtrl.text = generateTransferPin(),
                      icon: const Icon(Icons.casino_outlined, size: 18),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                if (_transport == 0) ...[
                  if (_lanSender != null) ...[
                    SelectableText(
                      s.sshLanReady(_lanSender!.address, _lanSender!.pin),
                      style: const TextStyle(
                          fontFamily: 'Consolas', fontSize: 13),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton(
                      onPressed: () async {
                        await _stopSender();
                        if (mounted) setState(() {});
                      },
                      child: Text(s.sshStopLanSend),
                    ),
                  ] else
                    FilledButton.icon(
                      onPressed: _busy ? null : _startLanSend,
                      icon: const Icon(Icons.wifi_tethering_rounded, size: 18),
                      label: Text(s.sshStartLanSend),
                    ),
                ] else ...[
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.icon(
                        onPressed: _busy ? null : _exportFile,
                        icon: const Icon(Icons.save_alt_rounded, size: 18),
                        label: Text(s.sshSaveBundle),
                      ),
                      FilledButton.tonalIcon(
                        onPressed: _busy ? null : _copyLink,
                        icon: const Icon(Icons.link_rounded, size: 18),
                        label: Text(s.sshCopyLink),
                      ),
                    ],
                  ),
                ],
              ] else ...[
                if (_transport == 0) ...[
                  if (_peers.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Row(
                        children: [
                          const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          const SizedBox(width: 10),
                          Expanded(child: Text(s.sshLanScanning)),
                        ],
                      ),
                    )
                  else
                    for (final p in _peers)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          _selectedPeer?.address == p.address
                              ? Icons.radio_button_checked_rounded
                              : Icons.radio_button_off_rounded,
                          size: 20,
                        ),
                        title: Text(p.name),
                        subtitle: Text(p.address),
                        selected: _selectedPeer?.address == p.address,
                        onTap: () => setState(() => _selectedPeer = p),
                      ),
                  TextField(
                    controller: _manualAddrCtrl,
                    decoration: InputDecoration(labelText: s.sshLanManualAddr),
                    onChanged: (_) => setState(() => _selectedPeer = null),
                  ),
                ] else ...[
                  Row(
                    children: [
                      FilledButton.tonalIcon(
                        onPressed: _openBundleFile,
                        icon: const Icon(Icons.file_open_outlined, size: 16),
                        label: Text(s.sshOpenBundle),
                      ),
                      const SizedBox(width: 8),
                      FilledButton.tonalIcon(
                        onPressed: () async {
                          final clip = await Clipboard.getData('text/plain');
                          if (clip?.text != null && mounted) {
                            setState(() {
                              _recvTextCtrl.text = clip!.text!.trim();
                              _decodedPreview = null;
                            });
                          }
                        },
                        icon: const Icon(Icons.paste_rounded, size: 16),
                        label: Text(s.backupPaste),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _recvTextCtrl,
                    maxLines: 3,
                    decoration: InputDecoration(labelText: s.sshPasteLinkHint),
                  ),
                ],
                const SizedBox(height: 10),
                TextField(
                  controller: _recvPinCtrl,
                  decoration: InputDecoration(labelText: s.sshPinCode),
                  onSubmitted: (_) => _decryptAndPreview(),
                ),
                const SizedBox(height: 10),
                if (_decodedPreview != null) ...[
                  Builder(builder: (context) {
                    final prev =
                        _decodedPreview!.previewMerge(widget.state.sshData);
                    return Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        s.sshImportPreview(
                            prev.hosts, prev.keys, prev.snippets),
                      ),
                    );
                  }),
                  const SizedBox(height: 8),
                  FilledButton(
                    onPressed: _confirmImport,
                    child: Text(s.sshImportAction),
                  ),
                ] else
                  FilledButton(
                    onPressed: _busy ? null : _decryptAndPreview,
                    child: _busy
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(s.sshReceive),
                  ),
              ],
              if (_statusMsg != null) ...[
                const SizedBox(height: 10),
                Text(
                  _statusMsg!,
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.primary,
                      fontSize: 13),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(s.close)),
      ],
    );
  }
}
