import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

import '../models/ssh.dart';
import 'lan_receiver.dart';

const sshBundlePrefix = 'HEANETWORK-SSH-1:';
const sshImportUriPrefix = 'heanetwork://ssh-import?data=';
const sshLanDiscoveryPort = 45871;
const _sshLanMagic = 'HEANETWORK_SSH_LAN_V1';

const _iterations = 210000;
const _saltLength = 16;
const _nonceLength = 12;
const _macLength = 16;
final _aad = utf8.encode('HeaNetwork ssh transfer v1');

/// Generates a random 6-digit PIN for LAN or bundle transfer.
String generateTransferPin() {
  final r = Random.secure();
  return List.generate(6, (_) => r.nextInt(10)).join();
}

/// Checks whether [text] looks like a `heanetwork://ssh-import?...` link or
/// raw `HEANETWORK-SSH-1:...` bundle.
bool isSshBundleText(String text) {
  final t = text.trim();
  return t.startsWith(sshBundlePrefix) ||
      t.toLowerCase().startsWith(sshImportUriPrefix);
}

/// Extracts the raw `HEANETWORK-SSH-1:...` payload from either a URI link or
/// plain bundle text.
String? extractSshBundleText(String input) {
  final t = input.trim();
  if (t.startsWith(sshBundlePrefix)) return t;
  final uri = Uri.tryParse(t);
  if (uri != null &&
      uri.scheme.toLowerCase() == 'heanetwork' &&
      uri.host.toLowerCase() == 'ssh-import') {
    final data = uri.queryParameters['data'];
    if (data != null && data.startsWith(sshBundlePrefix)) return data;
  }
  return null;
}

/// Wraps an encoded bundle into a clickable `heanetwork://ssh-import?data=...` URI.
String toSshImportLink(String encodedBundle) =>
    '$sshImportUriPrefix${Uri.encodeQueryComponent(encodedBundle)}';

/// Subset of SSH data chosen by the user for app-to-app transfer.
class SshTransferPayload {
  SshTransferPayload({
    required this.hosts,
    required this.keys,
    required this.snippets,
    required this.secrets,
  });

  final List<SshHost> hosts;
  final List<SshKey> keys;
  final List<SshSnippet> snippets;
  final SshSecrets secrets;

  bool get isEmpty => hosts.isEmpty && keys.isEmpty && snippets.isEmpty;

  Map<String, dynamic> toJson() => {
        'app': 'heanetwork-ssh',
        'version': 1,
        'hosts': [for (final h in hosts) h.toJson()],
        'keys': [for (final k in keys) k.toJson()],
        'snippets': [for (final s in snippets) s.toJson()],
        'secrets': secrets.toJson(),
      };

  static SshTransferPayload? fromJson(Map<String, dynamic> j) {
    if (j['app'] != 'heanetwork-ssh' || j['version'] != 1) return null;
    final data = SshData.fromJson(j);
    final secrets = j['secrets'] is Map
        ? SshSecrets.fromJson(Map<String, dynamic>.from(j['secrets'] as Map))
        : SshSecrets();
    return SshTransferPayload(
      hosts: data.hosts,
      keys: data.keys,
      snippets: data.snippets,
      secrets: secrets,
    );
  }

  /// Counts how many items would actually be added (skipping existing IDs or
  /// matching host+port+user / snippet name+command).
  ({int hosts, int keys, int snippets}) previewMerge(SshData target) {
    final existingKeyIds = {for (final k in target.keys) k.id};
    final existingHostIds = {for (final h in target.hosts) h.id};
    final existingHostKeys = {
      for (final h in target.hosts)
        '${h.username}@${h.host.toLowerCase()}:${h.port}',
    };
    final existingSnippetIds = {for (final s in target.snippets) s.id};
    final existingSnippetSigs = {
      for (final s in target.snippets) '${s.name}\u0000${s.command}',
    };

    var newKeys = 0;
    for (final k in keys) {
      if (!existingKeyIds.contains(k.id)) newKeys++;
    }
    var newHosts = 0;
    for (final h in hosts) {
      final sig = '${h.username}@${h.host.toLowerCase()}:${h.port}';
      if (!existingHostIds.contains(h.id) && !existingHostKeys.contains(sig)) {
        newHosts++;
      }
    }
    var newSnippets = 0;
    for (final s in snippets) {
      final sig = '${s.name}\u0000${s.command}';
      if (!existingSnippetIds.contains(s.id) &&
          !existingSnippetSigs.contains(sig)) {
        newSnippets++;
      }
    }
    return (hosts: newHosts, keys: newKeys, snippets: newSnippets);
  }

  /// Merges non-duplicate items into [targetData] and [targetSecrets] without
  /// overwriting existing entries. Returns counts of added items.
  ({int hosts, int keys, int snippets}) mergeInto(
    SshData targetData,
    SshSecrets targetSecrets,
  ) {
    final existingKeyIds = {for (final k in targetData.keys) k.id};
    final existingHostIds = {for (final h in targetData.hosts) h.id};
    final existingHostKeys = {
      for (final h in targetData.hosts)
        '${h.username}@${h.host.toLowerCase()}:${h.port}',
    };
    final existingSnippetIds = {for (final s in targetData.snippets) s.id};
    final existingSnippetSigs = {
      for (final s in targetData.snippets) '${s.name}\u0000${s.command}',
    };

    var addedKeys = 0;
    for (final k in keys) {
      if (existingKeyIds.add(k.id)) {
        targetData.keys.add(SshKey.fromJson(k.toJson()));
        final priv = secrets.privateKeys[k.id];
        if (priv != null) targetSecrets.privateKeys[k.id] = priv;
        final pass = secrets.passphrases[k.id];
        if (pass != null) targetSecrets.passphrases[k.id] = pass;
        addedKeys++;
      }
    }

    var addedHosts = 0;
    for (final h in hosts) {
      final sig = '${h.username}@${h.host.toLowerCase()}:${h.port}';
      if (!existingHostIds.contains(h.id) && existingHostKeys.add(sig)) {
        existingHostIds.add(h.id);
        // Clear linkedProfileId: VPN profile IDs differ across installs.
        final copy = SshHost.fromJson(h.toJson())..linkedProfileId = null;
        targetData.hosts.add(copy);
        final pw = secrets.passwords[h.id];
        if (pw != null) targetSecrets.passwords[h.id] = pw;
        addedHosts++;
      }
    }

    var addedSnippets = 0;
    for (final s in snippets) {
      final sig = '${s.name}\u0000${s.command}';
      if (!existingSnippetIds.contains(s.id) && existingSnippetSigs.add(sig)) {
        existingSnippetIds.add(s.id);
        targetData.snippets.add(SshSnippet.fromJson(s.toJson()));
        addedSnippets++;
      }
    }
    return (hosts: addedHosts, keys: addedKeys, snippets: addedSnippets);
  }
}

/// Builds a [SshTransferPayload] from selected IDs and secret inclusion flag.
SshTransferPayload buildTransferPayload({
  required SshData data,
  required SshSecrets secrets,
  required Set<String> hostIds,
  required Set<String> keyIds,
  required Set<String> snippetIds,
  required bool includeSecrets,
}) {
  final hosts = [for (final h in data.hosts) if (hostIds.contains(h.id)) h];
  // Automatically include keys referenced by selected hosts.
  final effectiveKeyIds = {
    ...keyIds,
    for (final h in hosts)
      if (h.authType == SshAuthType.key && h.keyId != null) h.keyId!,
  };
  final keys = [for (final k in data.keys) if (effectiveKeyIds.contains(k.id)) k];
  final snippets = [
    for (final s in data.snippets) if (snippetIds.contains(s.id)) s,
  ];
  final outSecrets = SshSecrets();
  if (includeSecrets) {
    for (final h in hosts) {
      final pw = secrets.passwords[h.id];
      if (pw != null) outSecrets.passwords[h.id] = pw;
    }
    for (final k in keys) {
      final priv = secrets.privateKeys[k.id];
      if (priv != null) outSecrets.privateKeys[k.id] = priv;
      final pass = secrets.passphrases[k.id];
      if (pass != null) outSecrets.passphrases[k.id] = pass;
    }
  }
  return SshTransferPayload(
    hosts: hosts,
    keys: keys,
    snippets: snippets,
    secrets: outSecrets,
  );
}

Future<SecretKey> _deriveKey(String pin, List<int> salt) {
  final pwKey = SecretKeyData(utf8.encode(pin), overwriteWhenDestroyed: true);
  return Pbkdf2.hmacSha256(iterations: _iterations, bits: 256)
      .deriveKey(secretKey: pwKey, nonce: salt)
      .whenComplete(pwKey.destroy);
}

/// Encrypts [payload] with [pin] using AES-256-GCM + PBKDF2-HMAC-SHA256.
Future<String> encodeSshBundle(SshTransferPayload payload, String pin) async {
  if (pin.trim().isEmpty) {
    throw ArgumentError('PIN/password must not be empty');
  }
  final salt = SecretKeyData.random(length: _saltLength).bytes;
  final key = await _deriveKey(pin.trim(), salt);
  try {
    final plainBytes = gzip.encode(utf8.encode(jsonEncode(payload.toJson())));
    final box = await AesGcm.with256bits().encrypt(
      plainBytes,
      secretKey: key,
      aad: _aad,
    );
    final envelope = {
      'v': 1,
      's': base64Url.encode(salt),
      'n': base64Url.encode(box.nonce),
      'c': base64Url.encode(box.cipherText),
      'm': base64Url.encode(box.mac.bytes),
    };
    return '$sshBundlePrefix${base64Url.encode(utf8.encode(jsonEncode(envelope)))}';
  } finally {
    key.destroy();
  }
}

/// Decrypts a bundle (raw or `heanetwork://ssh-import?...` link) using [pin].
/// Returns null if the format is invalid or the PIN is wrong.
Future<SshTransferPayload?> decodeSshBundle(String input, String pin) async {
  final raw = extractSshBundleText(input);
  if (raw == null || pin.trim().isEmpty) return null;
  SecretKey? key;
  try {
    final b64 = raw.substring(sshBundlePrefix.length);
    final envelope = jsonDecode(utf8.decode(base64Url.decode(b64)));
    if (envelope is! Map || envelope['v'] != 1) return null;
    final salt = base64Url.decode(envelope['s'] as String);
    final nonce = base64Url.decode(envelope['n'] as String);
    final cipher = base64Url.decode(envelope['c'] as String);
    final mac = base64Url.decode(envelope['m'] as String);
    if (salt.length != _saltLength ||
        nonce.length != _nonceLength ||
        mac.length != _macLength) {
      return null;
    }
    key = await _deriveKey(pin.trim(), salt);
    final compressed = await AesGcm.with256bits().decrypt(
      SecretBox(cipher, nonce: nonce, mac: Mac(mac)),
      secretKey: key,
      aad: _aad,
    );
    final decoded = jsonDecode(utf8.decode(gzip.decode(compressed)));
    if (decoded is! Map) return null;
    return SshTransferPayload.fromJson(Map<String, dynamic>.from(decoded));
  } on Object {
    return null;
  } finally {
    key?.destroy();
  }
}

// ---- LAN discovery & transfer (no external server) -----------------------

class SshLanPeer {
  const SshLanPeer({
    required this.name,
    required this.host,
    required this.port,
    required this.seenAt,
  });

  final String name;
  final String host;
  final int port;
  final DateTime seenAt;

  String get address => '$host:$port';
}

/// Serves an already-encrypted SSH bundle on the local network and announces
/// itself via UDP broadcast while active.
class SshLanSender {
  SshLanSender._(
    this._server,
    this.host,
    this.port,
    this.pin,
    this._bundle,
    this._udp,
    this._beaconTimer,
  ) {
    _server.listen(_handle, onError: (_) {});
  }

  final HttpServer _server;
  final String host;
  final int port;
  final String pin;
  final String _bundle;
  final RawDatagramSocket? _udp;
  final Timer? _beaconTimer;
  final _delivered = StreamController<void>.broadcast();

  Stream<void> get delivered => _delivered.stream;
  String get address => '$host:$port';

  static Future<SshLanSender?> start({
    required SshTransferPayload payload,
    String? pin,
    String? address,
    bool broadcast = true,
  }) async {
    final host = address ?? await lanAddress();
    if (host == null) return null;
    final code = (pin != null && pin.trim().isNotEmpty)
        ? pin.trim()
        : generateTransferPin();
    final bundle = await encodeSshBundle(payload, code);
    final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);

    RawDatagramSocket? udp;
    Timer? timer;
    if (broadcast) {
      try {
        udp = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
        udp.broadcastEnabled = true;
        final packet = utf8.encode(jsonEncode({
          'magic': _sshLanMagic,
          'name': Platform.localHostname,
          'host': host,
          'port': server.port,
        }));
        void sendBeacon() {
          try {
            udp?.send(packet, InternetAddress('255.255.255.255'),
                sshLanDiscoveryPort);
          } on Object {
            // Best-effort; manual IP:port still works.
          }
        }

        sendBeacon();
        timer = Timer.periodic(const Duration(seconds: 1), (_) => sendBeacon());
      } on Object {
        udp?.close();
        udp = null;
      }
    }

    return SshLanSender._(
      server,
      host,
      server.port,
      code,
      bundle,
      udp,
      timer,
    );
  }

  Future<void> _handle(HttpRequest request) async {
    final res = request.response;
    try {
      if (request.method != 'GET' || request.uri.path != '/ssh-bundle') {
        res.statusCode = HttpStatus.notFound;
        return;
      }
      res.headers.contentType = ContentType.text;
      res.headers.set('Cache-Control', 'no-store');
      res.write(_bundle);
      if (!_delivered.isClosed) _delivered.add(null);
    } finally {
      try {
        await res.close();
      } on Object {
        // Peer disconnected.
      }
    }
  }

  Future<void> close() async {
    _beaconTimer?.cancel();
    _udp?.close();
    await _server.close(force: true);
    await _delivered.close();
  }
}

/// Listens for [SshLanSender] UDP beacons on the local network.
class SshLanDiscoverer {
  SshLanDiscoverer._(this._udp, this._controller);

  final RawDatagramSocket _udp;
  final StreamController<List<SshLanPeer>> _controller;
  final _peers = <String, SshLanPeer>{};
  Timer? _pruneTimer;

  Stream<List<SshLanPeer>> get peers => _controller.stream;

  static Future<SshLanDiscoverer?> start() async {
    try {
      final udp = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        sshLanDiscoveryPort,
        reuseAddress: true,
      );
      final ctrl = StreamController<List<SshLanPeer>>.broadcast();
      final d = SshLanDiscoverer._(udp, ctrl);
      udp.listen((event) {
        if (event != RawSocketEvent.read) return;
        final dg = udp.receive();
        if (dg == null) return;
        d._onDatagram(dg);
      }, onError: (_) {});
      d._pruneTimer = Timer.periodic(const Duration(seconds: 2), (_) {
        final cutoff = DateTime.now().subtract(const Duration(seconds: 5));
        final before = d._peers.length;
        d._peers.removeWhere((_, p) => p.seenAt.isBefore(cutoff));
        if (d._peers.length != before && !ctrl.isClosed) {
          ctrl.add(d._peers.values.toList());
        }
      });
      return d;
    } on Object {
      return null;
    }
  }

  void _onDatagram(Datagram dg) {
    try {
      final msg = jsonDecode(utf8.decode(dg.data));
      if (msg is! Map || msg['magic'] != _sshLanMagic) return;
      final port = (msg['port'] as num?)?.toInt() ?? 0;
      if (port <= 0 || port > 65535) return;
      final host = (msg['host'] as String?)?.trim().isNotEmpty == true
          ? (msg['host'] as String).trim()
          : dg.address.address;
      final name = (msg['name'] as String?)?.trim().isNotEmpty == true
          ? (msg['name'] as String).trim()
          : host;
      final peer = SshLanPeer(
        name: name,
        host: host,
        port: port,
        seenAt: DateTime.now(),
      );
      _peers[peer.address] = peer;
      if (!_controller.isClosed) _controller.add(_peers.values.toList());
    } on Object {
      // Ignore unrelated LAN traffic.
    }
  }

  Future<void> close() async {
    _pruneTimer?.cancel();
    _udp.close();
    await _controller.close();
  }
}

/// Downloads an encrypted SSH bundle from a [SshLanSender] at `host:port`.
Future<String> fetchSshBundleFromLan(String address) async {
  final trimmed = address.trim();
  final uri = trimmed.startsWith('http://')
      ? Uri.parse(trimmed)
      : Uri.parse('http://$trimmed/ssh-bundle');
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  try {
    final req = await client.getUrl(uri);
    final res = await req.close().timeout(const Duration(seconds: 8));
    if (res.statusCode != HttpStatus.ok) {
      throw HttpException('Peer answered ${res.statusCode}');
    }
    final body = await utf8.decoder.bind(res).join();
    if (!body.trim().startsWith(sshBundlePrefix)) {
      throw const FormatException('Unexpected response');
    }
    return body.trim();
  } finally {
    client.close(force: true);
  }
}
