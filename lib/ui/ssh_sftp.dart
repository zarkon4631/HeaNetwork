import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../l10n/strings.dart';
import '../platform/windows/win32.dart' as win32;
import '../state/app_state.dart';
import 'widgets.dart';

/// Basic SFTP file browser running on top of an already-authenticated
/// [SshTabSession]. Supports navigation, download, upload, mkdir, rename,
/// delete, and opening remote files in the OS default editor.
class SshSftpView extends StatefulWidget {
  const SshSftpView({super.key, required this.session});

  final SshTabSession session;

  @override
  State<SshSftpView> createState() => _SshSftpViewState();
}

class _SshSftpViewState extends State<SshSftpView> {
  String _cwd = '.';
  List<SftpName> _entries = [];
  bool _loading = true;
  bool _showHidden = false;
  String? _error;
  String? _transferStatus;
  double? _transferProgress;

  @override
  void initState() {
    super.initState();
    _initDir();
  }

  Future<void> _initDir() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final sftp = await widget.session.ensureSftp();
      final home = await sftp.absolute('.');
      await _loadDir(home);
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  Future<void> _loadDir(String path) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final sftp = await widget.session.ensureSftp();
      final resolved = await sftp.absolute(path);
      final list = await sftp.listdir(resolved);
      list.removeWhere((e) => e.filename == '.' || e.filename == '..');
      list.sort((a, b) {
        final ad = a.attr.isDirectory ? 0 : 1;
        final bd = b.attr.isDirectory ? 0 : 1;
        if (ad != bd) return ad.compareTo(bd);
        return a.filename.toLowerCase().compareTo(b.filename.toLowerCase());
      });
      if (!mounted) return;
      setState(() {
        _cwd = resolved;
        _entries = list;
        _loading = false;
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  String _join(String name) =>
      _cwd.endsWith('/') ? '$_cwd$name' : '$_cwd/$name';

  String _parentDir() {
    if (_cwd == '/' || _cwd.isEmpty) return '/';
    final clean = _cwd.endsWith('/') ? _cwd.substring(0, _cwd.length - 1) : _cwd;
    final idx = clean.lastIndexOf('/');
    return idx <= 0 ? '/' : clean.substring(0, idx);
  }

  Future<void> _download(SftpName entry) async {
    final s = S.of(context);
    final loc = await getSaveLocation(suggestedName: entry.filename);
    if (loc == null || !mounted) return;
    final total = entry.attr.size ?? 0;
    setState(() {
      _transferStatus = '${s.sftpDownload}: ${entry.filename}';
      _transferProgress = total > 0 ? 0 : null;
    });
    try {
      final sftp = await widget.session.ensureSftp();
      final sink = File(loc.path).openWrite();
      try {
        await sftp.download(
          _join(entry.filename),
          sink,
          onProgress: (read) {
            if (!mounted || total <= 0) return;
            setState(() => _transferProgress = (read / total).clamp(0.0, 1.0));
          },
        );
      } finally {
        await sink.close();
      }
      if (mounted) showSnack(context, s.sftpDownloaded(entry.filename));
    } on Object catch (e) {
      if (mounted) showSnack(context, '$e');
    } finally {
      if (mounted) {
        setState(() {
          _transferStatus = null;
          _transferProgress = null;
        });
      }
    }
  }

  Future<void> _openInOsEditor(SftpName entry) async {
    final s = S.of(context);
    final total = entry.attr.size ?? 0;
    setState(() {
      _transferStatus = '${s.sftpOpenEditor}: ${entry.filename}';
      _transferProgress = total > 0 ? 0 : null;
    });
    try {
      final sftp = await widget.session.ensureSftp();
      final tmpRoot = await getTemporaryDirectory();
      final sep = Platform.pathSeparator;
      final dir = Directory(
          '${tmpRoot.path}${sep}heanetwork_sftp$sep${widget.session.host.id}');
      await dir.create(recursive: true);
      final safeName =
          entry.filename.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
      final localFile = File('${dir.path}$sep$safeName');
      final remotePath = _join(entry.filename);
      final sink = localFile.openWrite();
      try {
        await sftp.download(
          remotePath,
          sink,
          onProgress: (read) {
            if (!mounted || total <= 0) return;
            setState(() => _transferProgress = (read / total).clamp(0.0, 1.0));
          },
        );
      } finally {
        await sink.close();
      }
      final stat = await localFile.stat();
      widget.session.watchOpenedFile(SftpWatchedFile(
        remotePath: remotePath,
        fileName: entry.filename,
        localFile: localFile,
        initialModified: stat.modified,
        initialSize: stat.size,
      ));
      if (Platform.isWindows) {
        win32.shellExecute(localFile.path);
      }
    } on Object catch (e) {
      if (mounted) showSnack(context, '$e');
    } finally {
      if (mounted) {
        setState(() {
          _transferStatus = null;
          _transferProgress = null;
        });
      }
    }
  }

  Future<void> _upload() async {
    final s = S.of(context);
    final files = await openFiles();
    if (files.isEmpty || !mounted) return;
    try {
      final sftp = await widget.session.ensureSftp();
      for (final xf in files) {
        final local = File(xf.path);
        final total = await local.length();
        if (!mounted) return;
        setState(() {
          _transferStatus = '${s.sftpUpload}: ${xf.name}';
          _transferProgress = total > 0 ? 0 : null;
        });
        final remote = await sftp.open(
          _join(xf.name),
          mode: SftpFileOpenMode.create |
              SftpFileOpenMode.write |
              SftpFileOpenMode.truncate,
        );
        try {
          await remote
              .write(
                local.openRead().map(Uint8List.fromList),
                onProgress: (written) {
                  if (!mounted || total <= 0) return;
                  setState(
                      () => _transferProgress = (written / total).clamp(0.0, 1.0));
                },
              )
              .done;
        } finally {
          await remote.close();
        }
        if (mounted) showSnack(context, s.sftpUploaded(xf.name));
      }
      await _loadDir(_cwd);
    } on Object catch (e) {
      if (mounted) showSnack(context, '$e');
    } finally {
      if (mounted) {
        setState(() {
          _transferStatus = null;
          _transferProgress = null;
        });
      }
    }
  }

  Future<void> _mkdir() async {
    final s = S.of(context);
    final name = await _promptText(title: s.sftpNewFolder, hint: s.sftpFolderName);
    if (name == null || name.isEmpty || !mounted) return;
    try {
      final sftp = await widget.session.ensureSftp();
      await sftp.mkdir(_join(name));
      await _loadDir(_cwd);
    } on Object catch (e) {
      if (mounted) showSnack(context, '$e');
    }
  }

  Future<void> _rename(SftpName entry) async {
    final s = S.of(context);
    final next = await _promptText(
      title: s.rename,
      hint: s.sftpNewName,
      initial: entry.filename,
    );
    if (next == null || next.isEmpty || next == entry.filename || !mounted) {
      return;
    }
    try {
      final sftp = await widget.session.ensureSftp();
      await sftp.rename(_join(entry.filename), _join(next));
      await _loadDir(_cwd);
    } on Object catch (e) {
      if (mounted) showSnack(context, '$e');
    }
  }

  Future<void> _delete(SftpName entry) async {
    final s = S.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.delete),
        content: Text(s.sftpDeleteQ(entry.filename)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false), child: Text(s.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true), child: Text(s.delete)),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      final sftp = await widget.session.ensureSftp();
      final full = _join(entry.filename);
      if (entry.attr.isDirectory) {
        await sftp.rmdir(full);
      } else {
        await sftp.remove(full);
      }
      await _loadDir(_cwd);
    } on Object catch (e) {
      if (mounted) showSnack(context, '$e');
    }
  }

  Future<String?> _promptText({
    required String title,
    required String hint,
    String initial = '',
  }) async {
    final s = S.of(context);
    final ctrl = TextEditingController(text: initial);
    final res = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(labelText: hint),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(s.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: Text(s.save)),
        ],
      ),
    );
    ctrl.dispose();
    return res;
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final scheme = Theme.of(context).colorScheme;
    final visible = [
      for (final e in _entries)
        if (_showHidden || !e.filename.startsWith('.')) e,
    ];
    final modifiedFiles = [
      for (final f in widget.session.watchedFiles)
        if (f.modified) f,
    ];

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
          child: Row(
            children: [
              IconButton(
                tooltip: s.sftpUp,
                onPressed: _cwd == '/' ? null : () => _loadDir(_parentDir()),
                icon: const Icon(Icons.arrow_upward_rounded, size: 18),
              ),
              IconButton(
                tooltip: s.refresh,
                onPressed: () => _loadDir(_cwd),
                icon: const Icon(Icons.refresh_rounded, size: 18),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    _cwd,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontFamily: 'Consolas', fontSize: 13),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilterChip(
                label: Text(s.sftpShowHidden, style: const TextStyle(fontSize: 12)),
                selected: _showHidden,
                onSelected: (v) => setState(() => _showHidden = v),
                visualDensity: VisualDensity.compact,
              ),
              const SizedBox(width: 6),
              FilledButton.tonalIcon(
                onPressed: _mkdir,
                icon: const Icon(Icons.create_new_folder_outlined, size: 16),
                label: Text(s.sftpNewFolder),
              ),
              const SizedBox(width: 6),
              FilledButton.icon(
                onPressed: _upload,
                icon: const Icon(Icons.upload_file_rounded, size: 16),
                label: Text(s.sftpUpload),
              ),
            ],
          ),
        ),
        if (_transferStatus != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_transferStatus!, style: const TextStyle(fontSize: 12)),
                const SizedBox(height: 4),
                LinearProgressIndicator(value: _transferProgress),
              ],
            ),
          ),
        for (final wf in modifiedFiles)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 2, 12, 4),
            child: Material(
              color: scheme.tertiaryContainer,
              borderRadius: BorderRadius.circular(10),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Row(
                  children: [
                    Icon(Icons.edit_document,
                        size: 16, color: scheme.onTertiaryContainer),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        s.sftpModifiedBanner(wf.fileName),
                        style: TextStyle(
                            fontSize: 12.5, color: scheme.onTertiaryContainer),
                      ),
                    ),
                    if (wf.uploading)
                      const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    else ...[
                      TextButton(
                        onPressed: () async {
                          try {
                            await widget.session.uploadWatchedFile(wf);
                            if (context.mounted) {
                              showSnack(context, s.sftpUploaded(wf.fileName));
                            }
                          } on Object catch (e) {
                            if (context.mounted) showSnack(context, '$e');
                          }
                        },
                        child: Text(s.sftpUploadBack),
                      ),
                      IconButton(
                        tooltip: s.close,
                        iconSize: 16,
                        onPressed: () => widget.session.dismissWatchedFile(wf),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        const Divider(height: 1),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(_error!, textAlign: TextAlign.center),
                            const SizedBox(height: 12),
                            FilledButton.tonal(
                                onPressed: _initDir, child: Text(s.refresh)),
                          ],
                        ),
                      ),
                    )
                  : visible.isEmpty
                      ? Center(child: Text(s.sftpEmptyDir))
                      : ListView.separated(
                          itemCount: visible.length,
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (ctx, i) {
                            final e = visible[i];
                            final isDir = e.attr.isDirectory;
                            final size = e.attr.size;
                            final mtime = e.attr.modifyTime;
                            return ListTile(
                              dense: true,
                              leading: Icon(
                                isDir
                                    ? Icons.folder_rounded
                                    : Icons.insert_drive_file_outlined,
                                color: isDir ? scheme.primary : null,
                              ),
                              title: Text(e.filename,
                                  maxLines: 1, overflow: TextOverflow.ellipsis),
                              subtitle: Text(
                                [
                                  if (!isDir && size != null) formatBytes(size),
                                  if (mtime != null)
                                    formatDateTime(
                                        DateTime.fromMillisecondsSinceEpoch(
                                            mtime * 1000)),
                                ].join(' · '),
                                style: const TextStyle(fontSize: 11.5),
                              ),
                              onTap: isDir
                                  ? () => _loadDir(_join(e.filename))
                                  : () => _openInOsEditor(e),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (!isDir) ...[
                                    IconButton(
                                      tooltip: s.sftpOpenEditor,
                                      iconSize: 18,
                                      onPressed: () => _openInOsEditor(e),
                                      icon: const Icon(Icons.open_in_new_rounded),
                                    ),
                                    IconButton(
                                      tooltip: s.sftpDownload,
                                      iconSize: 18,
                                      onPressed: () => _download(e),
                                      icon: const Icon(Icons.download_rounded),
                                    ),
                                  ],
                                  IconButton(
                                    tooltip: s.rename,
                                    iconSize: 18,
                                    onPressed: () => _rename(e),
                                    icon: const Icon(Icons.drive_file_rename_outline),
                                  ),
                                  IconButton(
                                    tooltip: s.delete,
                                    iconSize: 18,
                                    onPressed: () => _delete(e),
                                    icon: const Icon(Icons.delete_outline_rounded),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
        ),
      ],
    );
  }
}
