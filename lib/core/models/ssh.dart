import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'profile.dart';

/// How an SSH host routes its TCP connection relative to the VPN tunnel.
enum SshRouteMode {
  /// Follow the global SSH routing toggle.
  inherit,
  direct,
  proxy;

  static SshRouteMode parse(String? v) =>
      values.firstWhere((e) => e.name == v, orElse: () => inherit);
}

enum SshAuthType {
  password,
  key;

  static SshAuthType parse(String? v) =>
      values.firstWhere((e) => e.name == v, orElse: () => password);
}

class SshHost {
  SshHost({
    String? id,
    required this.name,
    required this.host,
    this.port = 22,
    this.username = 'root',
    this.authType = SshAuthType.password,
    this.keyId,
    this.linkedProfileId,
    this.routeMode = SshRouteMode.inherit,
    this.hostFingerprint,
    this.lastConnectedAt,
  }) : id = id ?? newId();

  final String id;
  String name;
  String host;
  int port;
  String username;
  SshAuthType authType;
  String? keyId;

  /// Optional link to a VPN [ProxyProfile.id] so subscription updates do not
  /// erase SSH credentials attached to that server.
  String? linkedProfileId;
  SshRouteMode routeMode;

  /// TOFU host key fingerprint (`<type>:<hex>`), saved after user confirms.
  String? hostFingerprint;
  DateTime? lastConnectedAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'host': host,
        'port': port,
        'username': username,
        'authType': authType.name,
        if (keyId != null) 'keyId': keyId,
        if (linkedProfileId != null) 'linkedProfileId': linkedProfileId,
        'routeMode': routeMode.name,
        if (hostFingerprint != null) 'hostFingerprint': hostFingerprint,
        if (lastConnectedAt != null)
          'lastConnectedAt': lastConnectedAt!.toIso8601String(),
      };

  factory SshHost.fromJson(Map<String, dynamic> j) => SshHost(
        id: j['id'] as String?,
        name: j['name'] as String? ?? '',
        host: j['host'] as String? ?? '',
        port: (j['port'] as num?)?.toInt() ?? 22,
        username: j['username'] as String? ?? 'root',
        authType: SshAuthType.parse(j['authType'] as String?),
        keyId: j['keyId'] as String?,
        linkedProfileId: j['linkedProfileId'] as String?,
        routeMode: SshRouteMode.parse(j['routeMode'] as String?),
        hostFingerprint: j['hostFingerprint'] as String?,
        lastConnectedAt:
            DateTime.tryParse(j['lastConnectedAt'] as String? ?? ''),
      );
}

/// Public metadata of an SSH key pair. The private key and passphrase live
/// exclusively in [SshSecrets].
class SshKey {
  SshKey({
    String? id,
    required this.name,
    this.publicKey = '',
    DateTime? createdAt,
  })  : id = id ?? newId(),
        createdAt = createdAt ?? DateTime.now();

  final String id;
  String name;
  String publicKey;
  DateTime createdAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        if (publicKey.isNotEmpty) 'publicKey': publicKey,
        'createdAt': createdAt.toIso8601String(),
      };

  factory SshKey.fromJson(Map<String, dynamic> j) => SshKey(
        id: j['id'] as String?,
        name: j['name'] as String? ?? '',
        publicKey: j['publicKey'] as String? ?? '',
        createdAt: DateTime.tryParse(j['createdAt'] as String? ?? ''),
      );
}

class SshSnippet {
  SshSnippet({
    String? id,
    required this.name,
    required this.command,
    this.autoRun = true,
  }) : id = id ?? newId();

  final String id;
  String name;
  String command;

  /// When true, sends a trailing newline to execute immediately.
  bool autoRun;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'command': command,
        'autoRun': autoRun,
      };

  factory SshSnippet.fromJson(Map<String, dynamic> j) => SshSnippet(
        id: j['id'] as String?,
        name: j['name'] as String? ?? '',
        command: j['command'] as String? ?? '',
        autoRun: j['autoRun'] as bool? ?? true,
      );
}

class SshData {
  SshData({
    List<SshHost>? hosts,
    List<SshKey>? keys,
    List<SshSnippet>? snippets,
  })  : hosts = hosts ?? [],
        keys = keys ?? [],
        snippets = snippets ?? [];

  List<SshHost> hosts;
  List<SshKey> keys;
  List<SshSnippet> snippets;

  Map<String, dynamic> toJson() => {
        'hosts': [for (final h in hosts) h.toJson()],
        'keys': [for (final k in keys) k.toJson()],
        'snippets': [for (final s in snippets) s.toJson()],
      };

  factory SshData.fromJson(Map<String, dynamic> j) {
    List<T> parseList<T>(Object? raw, T Function(Map<String, dynamic>) fn) {
      if (raw is! List) return [];
      final out = <T>[];
      for (final e in raw) {
        if (e is! Map) continue;
        try {
          out.add(fn(Map<String, dynamic>.from(e)));
        } on Object {
          // Skip malformed record.
        }
      }
      return out;
    }

    return SshData(
      hosts: parseList(j['hosts'], SshHost.fromJson),
      keys: parseList(j['keys'], SshKey.fromJson),
      snippets: parseList(j['snippets'], SshSnippet.fromJson),
    );
  }
}

/// Sensitive SSH credentials, persisted separately under OS-level protection
/// (Windows DPAPI).
class SshSecrets {
  SshSecrets({
    Map<String, String>? passwords,
    Map<String, String>? privateKeys,
    Map<String, String>? passphrases,
  })  : passwords = passwords ?? {},
        privateKeys = privateKeys ?? {},
        passphrases = passphrases ?? {};

  /// hostId -> password
  final Map<String, String> passwords;

  /// keyId -> PEM / OpenSSH private key text
  final Map<String, String> privateKeys;

  /// keyId -> key passphrase
  final Map<String, String> passphrases;

  Map<String, dynamic> toJson() => {
        'passwords': passwords,
        'privateKeys': privateKeys,
        'passphrases': passphrases,
      };

  factory SshSecrets.fromJson(Map<String, dynamic> j) {
    Map<String, String> strMap(Object? raw) {
      if (raw is! Map) return {};
      return {
        for (final e in raw.entries)
          if (e.key is String && e.value is String) e.key as String: e.value as String,
      };
    }

    return SshSecrets(
      passwords: strMap(j['passwords']),
      privateKeys: strMap(j['privateKeys']),
      passphrases: strMap(j['passphrases']),
    );
  }
}

/// Encrypts/decrypts [SshSecrets] at rest. On Windows this wraps DPAPI;
/// tests can inject an in-memory codec without Win32 calls.
class SshSecretCodec {
  const SshSecretCodec({required this.protect, required this.unprotect});

  final Uint8List? Function(Uint8List plain) protect;
  final Uint8List? Function(Uint8List cipher) unprotect;

  static final passthrough = SshSecretCodec(
    protect: (b) => b,
    unprotect: (b) => b,
  );
}

/// Persists SSH metadata (`ssh.json`) and encrypted credentials
/// (`ssh_secrets.bin`) inside the app's data directory.
class SshStore {
  SshStore(this.dir, {required this.codec});

  final Directory dir;
  final SshSecretCodec codec;

  SshData data = SshData();
  SshSecrets secrets = SshSecrets();
  bool _loaded = false;

  bool get isLoaded => _loaded;

  File _file(String name) => File('${dir.path}${Platform.pathSeparator}$name');

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final metaFile = _file('ssh.json');
      if (await metaFile.exists()) {
        final raw = jsonDecode(await metaFile.readAsString());
        if (raw is Map) {
          data = SshData.fromJson(Map<String, dynamic>.from(raw));
        }
      }
    } on Object {
      data = SshData();
    }
    try {
      final secFile = _file('ssh_secrets.bin');
      if (await secFile.exists()) {
        final cipher = await secFile.readAsBytes();
        final plain = codec.unprotect(cipher);
        if (plain != null) {
          final raw = jsonDecode(utf8.decode(plain));
          if (raw is Map) {
            secrets = SshSecrets.fromJson(Map<String, dynamic>.from(raw));
          }
        }
      }
    } on Object {
      secrets = SshSecrets();
    }
  }

  Future<void> _writeQueue = Future<void>.value();

  Future<void> save() {
    _writeQueue = _writeQueue.then((_) async {
      try {
        await dir.create(recursive: true);
        final metaTmp = _file('ssh.json.tmp');
        await metaTmp.writeAsString(jsonEncode(data.toJson()), flush: true);
        await metaTmp.rename(_file('ssh.json').path);

        final plain = Uint8List.fromList(utf8.encode(jsonEncode(secrets.toJson())));
        final protected = codec.protect(plain);
        if (protected != null) {
          final secTmp = _file('ssh_secrets.bin.tmp');
          await secTmp.writeAsBytes(protected, flush: true);
          await secTmp.rename(_file('ssh_secrets.bin').path);
        }
      } on Object {
        // Queue stays usable for subsequent saves.
      }
    });
    return _writeQueue;
  }

  Future<void> flush() => _writeQueue;
}
