import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:xterm/xterm.dart';

import '../core/models/profile.dart';
import '../core/models/settings.dart';
import '../core/models/ssh.dart';
import '../core/services/core_controller.dart';
import '../core/services/ssh_connector.dart';
import '../core/services/ssh_transfer.dart';
import '../platform/windows/win32.dart' as win32;
import 'app_state_base.dart';

enum SshSessionStatus { connecting, connected, disconnected, error }

/// Tracks a remote file downloaded into temp and opened in the OS editor so
/// the UI can offer a one-click upload back when the user saves changes.
class SftpWatchedFile {
  SftpWatchedFile({
    required this.remotePath,
    required this.fileName,
    required this.localFile,
    required this.initialModified,
    required this.initialSize,
  });

  final String remotePath;
  final String fileName;
  final File localFile;
  DateTime initialModified;
  int initialSize;
  bool modified = false;
  bool uploading = false;

  Future<bool> checkChanged() async {
    try {
      if (!await localFile.exists()) return false;
      final stat = await localFile.stat();
      modified = stat.modified.isAfter(initialModified) || stat.size != initialSize;
      return modified;
    } on Object {
      return false;
    }
  }

  Future<void> markSynced() async {
    try {
      final stat = await localFile.stat();
      initialModified = stat.modified;
      initialSize = stat.size;
    } on Object {
      // Best-effort.
    }
    modified = false;
  }
}

/// Callback invoked on TOFU host key verification. Returns true to accept.
typedef SshHostKeyPrompt = Future<bool> Function({
  required String hostLabel,
  required String keyType,
  required String fingerprint,
  required String? previousFingerprint,
});

/// One open SSH tab (holds a single [SSHClient] shared by its PTY terminal and
/// optional SFTP client).
class SshTabSession extends ChangeNotifier {
  SshTabSession({required this.host})
      : terminal = Terminal(maxLines: 10000),
        terminalController = TerminalController();

  final SshHost host;
  final Terminal terminal;
  final TerminalController terminalController;

  SshSessionStatus status = SshSessionStatus.disconnected;
  String? errorMessage;
  bool viaProxy = false;
  bool showSftp = false;

  SSHClient? _client;
  SSHSession? _shell;
  SftpClient? _sftp;
  final List<StreamSubscription<Object?>> _subs = [];
  bool _disposed = false;

  /// Temp files opened in the OS editor from SFTP for this session.
  final List<SftpWatchedFile> watchedFiles = [];
  Timer? _watchTimer;

  bool get isConnected => status == SshSessionStatus.connected && _client != null;

  void setShowSftp(bool value) {
    if (showSftp == value) return;
    showSftp = value;
    _notify();
  }

  Future<SftpClient> ensureSftp() async {
    final existing = _sftp;
    if (existing != null) return existing;
    final client = _client;
    if (client == null) throw StateError('SSH is not connected');
    final sftp = await client.sftp();
    _sftp = sftp;
    return sftp;
  }

  void sendText(String text) {
    final shell = _shell;
    if (shell == null || status != SshSessionStatus.connected) return;
    shell.write(Uint8List.fromList(utf8.encode(text)));
  }

  void watchOpenedFile(SftpWatchedFile file) {
    watchedFiles.removeWhere((f) => f.remotePath == file.remotePath);
    watchedFiles.add(file);
    _watchTimer ??= Timer.periodic(const Duration(seconds: 2), (_) async {
      var changed = false;
      for (final f in List.of(watchedFiles)) {
        final was = f.modified;
        if (await f.checkChanged() != was) changed = true;
      }
      if (changed) _notify();
    });
    _notify();
  }

  void dismissWatchedFile(SftpWatchedFile file) {
    watchedFiles.remove(file);
    if (watchedFiles.isEmpty) {
      _watchTimer?.cancel();
      _watchTimer = null;
    }
    _notify();
  }

  Future<void> uploadWatchedFile(SftpWatchedFile file) async {
    if (file.uploading) return;
    file.uploading = true;
    _notify();
    try {
      final sftp = await ensureSftp();
      final remote = await sftp.open(
        file.remotePath,
        mode: SftpFileOpenMode.create |
            SftpFileOpenMode.write |
            SftpFileOpenMode.truncate,
      );
      try {
        await remote
            .write(file.localFile.openRead().map(Uint8List.fromList))
            .done;
      } finally {
        await remote.close();
      }
      await file.markSynced();
    } finally {
      file.uploading = false;
      _notify();
    }
  }

  Future<void> connect({
    required bool useProxy,
    required int? mixedPort,
    required String? directBindAddress,
    required String? password,
    required String? privateKeyPem,
    required String? passphrase,
    required SshHostKeyPrompt onVerifyHostKey,
    required void Function(String fingerprint) onFingerprintAccepted,
  }) async {
    await disconnect(silent: true);
    viaProxy = useProxy;
    status = SshSessionStatus.connecting;
    errorMessage = null;
    _notify();

    try {
      final socket = await openSshSocket(
        host: host.host,
        port: host.port,
        viaProxy: useProxy,
        mixedPort: mixedPort,
        directBindAddress: directBindAddress,
      );

      List<SSHKeyPair>? identities;
      if (host.authType == SshAuthType.key &&
          privateKeyPem != null &&
          privateKeyPem.trim().isNotEmpty) {
        identities = SSHKeyPair.fromPem(
          privateKeyPem,
          passphrase?.isNotEmpty == true ? passphrase : null,
        );
      }

      var passwordTried = false;
      final client = SSHClient(
        socket,
        username: host.username,
        identities: identities,
        keepAliveInterval: const Duration(seconds: 25),
        onPasswordRequest: () {
          if (passwordTried || password == null || password.isEmpty) return null;
          passwordTried = true;
          return password;
        },
        onUserInfoRequest: (req) {
          if (password == null || password.isEmpty) return null;
          return List.filled(req.prompts.length, password);
        },
        onVerifyHostKey: (type, fingerprint) async {
          final fp = '$type:${formatFingerprint(fingerprint)}';
          if (host.hostFingerprint == fp) return true;
          final ok = await onVerifyHostKey(
            hostLabel: '${host.host}:${host.port}',
            keyType: type,
            fingerprint: fp,
            previousFingerprint: host.hostFingerprint,
          );
          if (ok) onFingerprintAccepted(fp);
          return ok;
        },
      );
      _client = client;

      await client.authenticated;
      if (_disposed) {
        client.close();
        return;
      }

      final shell = await client.shell(
        pty: SSHPtyConfig(
          width: terminal.viewWidth,
          height: terminal.viewHeight,
        ),
      );
      _shell = shell;

      terminal.onOutput = (data) {
        if (status == SshSessionStatus.connected) {
          shell.write(Uint8List.fromList(utf8.encode(data)));
        }
      };
      terminal.onResize = (w, h, pw, ph) {
        if (status == SshSessionStatus.connected) {
          shell.resizeTerminal(w, h, pw, ph);
        }
      };

      _subs.add(
        shell.stdout
            .cast<List<int>>()
            .transform(const Utf8Decoder(allowMalformed: true))
            .listen(terminal.write),
      );
      _subs.add(
        shell.stderr
            .cast<List<int>>()
            .transform(const Utf8Decoder(allowMalformed: true))
            .listen(terminal.write),
      );

      unawaited(shell.done.then((_) {
        if (!_disposed && status == SshSessionStatus.connected) {
          status = SshSessionStatus.disconnected;
          terminal.write('\r\n[Connection closed]\r\n');
          _notify();
        }
      }));

      status = SshSessionStatus.connected;
      _notify();
    } on Object catch (e) {
      await disconnect(silent: true);
      status = SshSessionStatus.error;
      errorMessage = '$e';
      terminal.write('\r\n[Error: $e]\r\n');
      _notify();
    }
  }

  Future<void> disconnect({bool silent = false}) async {
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    _subs.clear();
    _sftp?.close();
    _sftp = null;
    _shell?.close();
    _shell = null;
    _client?.close();
    _client = null;
    terminal.onOutput = null;
    terminal.onResize = null;
    if (!silent) {
      status = SshSessionStatus.disconnected;
      _notify();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _watchTimer?.cancel();
    unawaited(disconnect(silent: true));
    terminalController.dispose();
    super.dispose();
  }
}

/// Optional Windows-only SSH client state mixed into [AppState].
/// Lazy: does not touch disk or spawn anything until [settings.sshClientEnabled]
/// is turned on.
mixin AppStateSsh on AppStateBase {
  SshStore? _sshStore;
  final List<SshTabSession> sshSessions = [];

  /// Pending bundle text or `.heassh` path passed via CLI or OS file/URI click.
  String? pendingSshImport;

  SshStore get _storeInstance {
    return _sshStore ??= SshStore(
      paths.data,
      codec: sshSecretCodec ??
          (Platform.isWindows
              ? const SshSecretCodec(
                  protect: win32.dpapiProtect,
                  unprotect: win32.dpapiUnprotect,
                )
              : SshSecretCodec.passthrough),
    );
  }

  SshData get sshData => _storeInstance.data;
  SshSecrets get sshSecrets => _storeInstance.secrets;
  bool get sshLoaded => _sshStore?.isLoaded ?? false;

  Future<void> ensureSshLoaded() async {
    if (!isWindows || !settings.sshClientEnabled) return;
    if (_storeInstance.isLoaded) return;
    await _storeInstance.load();
    if (Platform.isWindows &&
        !Platform.resolvedExecutable.toLowerCase().contains('flutter_tester')) {
      try {
        win32.registerSshAssociations(Platform.resolvedExecutable);
      } on Object {
        // Best-effort HKCU registration.
      }
    }
    notifyListeners();
  }

  Future<void> setSshClientEnabled(bool enabled) async {
    updateSettings((s) => s.sshClientEnabled = enabled, affectsCore: false);
    if (enabled) {
      await ensureSshLoaded();
    } else {
      await closeAllSshSessions();
    }
  }

  void setSshRouteViaProxy(bool viaProxy) {
    updateSettings((s) => s.sshRouteViaProxy = viaProxy, affectsCore: false);
  }

  void setSshTerminalTheme(String themeId) {
    updateSettings((s) => s.sshTerminalTheme = themeId, affectsCore: false);
  }

  /// Resolves whether [host] should route through the active VPN proxy.
  bool effectiveSshViaProxy(SshHost host) => switch (host.routeMode) {
        SshRouteMode.direct => false,
        SshRouteMode.proxy => true,
        SshRouteMode.inherit => settings.sshRouteViaProxy,
      };

  /// VPN servers eligible for quick SSH setup (excluding localhost/empty).
  List<ProxyProfile> get vpnServersForSsh {
    final linkedIds = {
      for (final h in sshData.hosts)
        if (h.linkedProfileId != null) h.linkedProfileId!,
    };
    return [
      for (final p in profiles)
        if (p.server.trim().isNotEmpty &&
            !p.isThisDevice &&
            !linkedIds.contains(p.id))
          p,
    ];
  }

  void saveSshHost(SshHost host, {String? password}) {
    final idx = sshData.hosts.indexWhere((h) => h.id == host.id);
    if (idx >= 0) {
      sshData.hosts[idx] = host;
    } else {
      sshData.hosts.add(host);
    }
    if (password != null) {
      if (password.isEmpty) {
        sshSecrets.passwords.remove(host.id);
      } else {
        sshSecrets.passwords[host.id] = password;
      }
    }
    unawaited(_storeInstance.save());
    notifyListeners();
  }

  void deleteSshHost(String id) {
    sshData.hosts.removeWhere((h) => h.id == id);
    sshSecrets.passwords.remove(id);
    closeSshSessionsForHost(id);
    unawaited(_storeInstance.save());
    notifyListeners();
  }

  void saveSshKey(SshKey key, {String? privateKey, String? passphrase}) {
    final idx = sshData.keys.indexWhere((k) => k.id == key.id);
    if (idx >= 0) {
      sshData.keys[idx] = key;
    } else {
      sshData.keys.add(key);
    }
    if (privateKey != null && privateKey.isNotEmpty) {
      sshSecrets.privateKeys[key.id] = privateKey;
    }
    if (passphrase != null) {
      if (passphrase.isEmpty) {
        sshSecrets.passphrases.remove(key.id);
      } else {
        sshSecrets.passphrases[key.id] = passphrase;
      }
    }
    unawaited(_storeInstance.save());
    notifyListeners();
  }

  void deleteSshKey(String id) {
    sshData.keys.removeWhere((k) => k.id == id);
    sshSecrets.privateKeys.remove(id);
    sshSecrets.passphrases.remove(id);
    for (final h in sshData.hosts) {
      if (h.keyId == id) h.keyId = null;
    }
    unawaited(_storeInstance.save());
    notifyListeners();
  }

  void saveSshSnippet(SshSnippet snippet) {
    final idx = sshData.snippets.indexWhere((s) => s.id == snippet.id);
    if (idx >= 0) {
      sshData.snippets[idx] = snippet;
    } else {
      sshData.snippets.add(snippet);
    }
    unawaited(_storeInstance.save());
    notifyListeners();
  }

  void deleteSshSnippet(String id) {
    sshData.snippets.removeWhere((s) => s.id == id);
    unawaited(_storeInstance.save());
    notifyListeners();
  }

  ({int hosts, int keys, int snippets}) importSshPayload(
      SshTransferPayload payload) {
    final counts = payload.mergeInto(sshData, sshSecrets);
    if (counts.hosts + counts.keys + counts.snippets > 0) {
      unawaited(_storeInstance.save());
      notifyListeners();
    }
    return counts;
  }

  /// Opens (or focuses) a session tab for [host] and connects it.
  SshTabSession openSshSession(
    SshHost host, {
    required SshHostKeyPrompt onVerifyHostKey,
  }) {
    final session = SshTabSession(host: host);
    sshSessions.add(session);
    notifyListeners();
    unawaited(connectSshSession(session, onVerifyHostKey: onVerifyHostKey));
    return session;
  }

  Future<void> connectSshSession(
    SshTabSession session, {
    required SshHostKeyPrompt onVerifyHostKey,
  }) async {
    final host = session.host;
    final useProxy = effectiveSshViaProxy(host);
    final running = status == CoreStatus.running;
    final mixed = running ? (activeMixedPort ?? settings.mixedPort) : null;
    final bindAddr = (!useProxy &&
            running &&
            activeMode == ConnectionMode.tun &&
            Platform.isWindows)
        ? win32.defaultRouteAddress()
        : null;

    host.lastConnectedAt = DateTime.now();
    unawaited(_storeInstance.save());

    await session.connect(
      useProxy: useProxy,
      mixedPort: mixed,
      directBindAddress: bindAddr,
      password: sshSecrets.passwords[host.id],
      privateKeyPem:
          host.keyId != null ? sshSecrets.privateKeys[host.keyId!] : null,
      passphrase:
          host.keyId != null ? sshSecrets.passphrases[host.keyId!] : null,
      onVerifyHostKey: onVerifyHostKey,
      onFingerprintAccepted: (fp) {
        host.hostFingerprint = fp;
        unawaited(_storeInstance.save());
      },
    );
  }

  Future<void> closeSshSession(SshTabSession session) async {
    sshSessions.remove(session);
    session.dispose();
    notifyListeners();
  }

  void closeSshSessionsForHost(String hostId) {
    final matching = sshSessions.where((s) => s.host.id == hostId).toList();
    for (final s in matching) {
      sshSessions.remove(s);
      s.dispose();
    }
  }

  Future<void> closeAllSshSessions() async {
    final copy = List.of(sshSessions);
    sshSessions.clear();
    for (final s in copy) {
      s.dispose();
    }
    notifyListeners();
  }

  /// Accepts a CLI arg (`.heassh` path or `heanetwork://ssh-import?...` URI)
  /// or reads a handoff file left by a second Windows launch.
  Future<void> checkPendingSshHandoff({List<String> args = const []}) async {
    if (!isWindows) return;
    String? candidate;
    for (final a in args) {
      final t = a.trim();
      if (t.toLowerCase().startsWith(sshImportUriPrefix) ||
          t.toLowerCase().endsWith('.heassh')) {
        candidate = t;
        break;
      }
    }
    final handoff = _handoffFile();
    if (candidate == null && handoff != null && await handoff.exists()) {
      try {
        final text = (await handoff.readAsString()).trim();
        await handoff.delete();
        if (text.isNotEmpty) candidate = text;
      } on Object {
        // Ignore transient lock.
      }
    }
    if (candidate == null) return;
    String? bundleText;
    if (isSshBundleText(candidate)) {
      bundleText = candidate;
    } else if (candidate.toLowerCase().endsWith('.heassh')) {
      try {
        final f = File(candidate);
        if (await f.exists()) {
          final content = (await f.readAsString()).trim();
          if (isSshBundleText(content)) bundleText = content;
        }
      } on Object {
        // Unreadable file.
      }
    }
    if (bundleText != null) {
      pendingSshImport = bundleText;
      notifyListeners();
    }
  }

  String? takePendingSshImport() {
    final v = pendingSshImport;
    pendingSshImport = null;
    return v;
  }

  static File? _handoffFile() {
    final local = Platform.environment['LOCALAPPDATA'];
    if (local == null || local.isEmpty) return null;
    final sep = Platform.pathSeparator;
    return File('$local${sep}HeaNetwork${sep}pending_open.txt');
  }

  @override
  void disposeSsh() {
    for (final s in sshSessions) {
      s.dispose();
    }
    sshSessions.clear();
  }
}
