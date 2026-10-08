import 'dart:convert';
import 'dart:io';

import '../models/profile.dart';
import 'link_utils.dart';

const _amneziaInts = ['jc', 'jmin', 'jmax', 's1', 's2', 's3', 's4'];
const _amneziaHeaders = ['h1', 'h2', 'h3', 'h4'];
const _amneziaStrings = ['i1', 'i2', 'i3', 'i4', 'i5'];

bool looksLikeWireGuardConf(String text) =>
    RegExp(r'^\s*\[Interface\]', multiLine: true, caseSensitive: false)
        .hasMatch(text) &&
    RegExp(r'^\s*\[Peer\]', multiLine: true, caseSensitive: false)
        .hasMatch(text);

String _withMask(String addr) {
  final a = addr.trim();
  if (a.contains('/')) return a;
  return a.contains(':') ? '$a/128' : '$a/32';
}

(String host, int port) _splitEndpoint(String endpoint) {
  final e = endpoint.trim();
  if (e.startsWith('[')) {
    final close = e.indexOf(']');
    return (
      e.substring(1, close),
      int.tryParse(e.substring(close + 1).replaceFirst(':', '')) ?? 0
    );
  }
  final colon = e.lastIndexOf(':');
  if (colon < 0) return (e, 0);
  return (e.substring(0, colon), int.tryParse(e.substring(colon + 1)) ?? 0);
}

/// Builds the `amnezia` block from lower-cased `[Interface]` keys. Returns
/// null for a plain WireGuard config.
Map<String, dynamic>? _amnezia(Map<String, String> iface) {
  final a = <String, dynamic>{};
  for (final k in _amneziaInts) {
    final v = int.tryParse(iface[k] ?? '');
    if (v != null) a[k] = v;
  }
  for (final k in _amneziaHeaders) {
    final raw = iface[k]?.trim();
    if (raw == null || raw.isEmpty) continue;
    // AmneziaWG 2.0 allows a range here; 1.x is a single number.
    a[k] = int.tryParse(raw) ?? raw;
  }
  for (final k in _amneziaStrings) {
    final v = iface[k]?.trim();
    if (v != null && v.isNotEmpty) a[k] = v;
  }
  return a.isEmpty ? null : a;
}

/// Parses a WireGuard / AmneziaWG `.conf` file.
ProxyProfile parseWireGuardConf(String text, {String? name}) {
  final sections = <String, List<Map<String, String>>>{};
  Map<String, String>? current;
  for (final rawLine in const LineSplitter().convert(text)) {
    final line = rawLine.split('#').first.trim();
    if (line.isEmpty) continue;
    final header = RegExp(r'^\[(\w+)\]$').firstMatch(line);
    if (header != null) {
      current = {};
      sections.putIfAbsent(header.group(1)!.toLowerCase(), () => []).add(current);
      continue;
    }
    final eq = line.indexOf('=');
    if (eq < 0 || current == null) continue;
    current[line.substring(0, eq).trim().toLowerCase()] =
        line.substring(eq + 1).trim();
  }

  final iface = sections['interface']?.first;
  final peers = sections['peer'];
  if (iface == null || peers == null || peers.isEmpty) {
    throw LinkParseException('WireGuard: missing [Interface] or [Peer]');
  }
  final privateKey = iface['privatekey'];
  if (privateKey == null || privateKey.isEmpty) {
    throw LinkParseException('WireGuard: missing PrivateKey');
  }
  final addresses = splitList(iface['address']).map(_withMask).toList();
  if (addresses.isEmpty) {
    throw LinkParseException('WireGuard: missing Address');
  }

  final outPeers = <Map<String, dynamic>>[];
  for (final p in peers) {
    final endpoint = p['endpoint'];
    if (endpoint == null) continue;
    final (host, port) = _splitEndpoint(endpoint);
    if (host.isEmpty || port == 0) continue;
    final allowed = splitList(p['allowedips']);
    outPeers.add(compact({
      'address': host,
      'port': port,
      'public_key': p['publickey'],
      'pre_shared_key': p['presharedkey'],
      'allowed_ips': allowed.isEmpty ? ['0.0.0.0/0', '::/0'] : allowed,
      'persistent_keepalive_interval':
          int.tryParse(p['persistentkeepalive'] ?? ''),
    }));
  }
  if (outPeers.isEmpty) {
    throw LinkParseException('WireGuard: no peer with an Endpoint');
  }

  final amnezia = _amnezia(iface);
  final out = compact({
    'type': 'wireguard',
    'address': addresses,
    'private_key': privateKey,
    'mtu': int.tryParse(iface['mtu'] ?? ''),
    'peers': outPeers,
    'amnezia': amnezia,
  });
  final first = outPeers.first;
  return ProxyProfile(
    name: name?.isNotEmpty == true
        ? name!
        : '${first['address']}:${first['port']}',
    type: amnezia == null ? Protocol.wireguard : Protocol.amneziawg,
    outbound: out,
    link: text,
  );
}

/// `wireguard://<private key>@host:port?publickey=...&address=...` as emitted
/// by v2rayN-style clients. AmneziaWG parameters ride along as query keys.
ProxyProfile parseWireGuardLink(String link) {
  final l = RawLink.parse(link);
  if (l.userInfo.isEmpty) throw LinkParseException('WireGuard: missing key');
  if (l.host.isEmpty || l.port == 0) {
    throw LinkParseException('WireGuard: missing server address');
  }
  final q = l.query.map((k, v) => MapEntry(k.toLowerCase(), v));
  final publicKey = q['publickey'] ?? q['public_key'] ?? q['peer_public_key'];
  if (publicKey == null || publicKey.isEmpty) {
    throw LinkParseException('WireGuard: missing public key');
  }
  final addresses = splitList(q['address'] ?? q['ip']).map(_withMask).toList();
  final amnezia = _amnezia(q);
  final out = compact({
    'type': 'wireguard',
    'address': addresses.isEmpty ? ['10.0.0.2/32'] : addresses,
    'private_key': l.userInfo,
    'mtu': int.tryParse(q['mtu'] ?? ''),
    'peers': [
      compact({
        'address': l.host,
        'port': l.port,
        'public_key': publicKey,
        'pre_shared_key': q['presharedkey'] ?? q['pre_shared_key'],
        'allowed_ips': ['0.0.0.0/0', '::/0'],
        'persistent_keepalive_interval': int.tryParse(q['keepalive'] ?? ''),
      }),
    ],
    'amnezia': amnezia,
  });
  return ProxyProfile(
    name: l.name.isNotEmpty ? l.name : '${l.host}:${l.port}',
    type: amnezia == null ? Protocol.wireguard : Protocol.amneziawg,
    outbound: out,
    link: link,
  );
}

/// An AmneziaVPN share key: `vpn://` + base64url of a Qt `qCompress` blob
/// (4-byte big-endian length, then zlib) holding the app's JSON config.
ProxyProfile parseAmneziaKey(String link) {
  var b64 = link.substring(link.indexOf('://') + 3).trim();
  b64 = b64.replaceAll('-', '+').replaceAll('_', '/');
  b64 = b64.padRight(b64.length + (4 - b64.length % 4) % 4, '=');

  Map<String, dynamic> root;
  try {
    final bytes = base64.decode(b64);
    final json = utf8.decode(zlib.decode(bytes.sublist(4)));
    root = Map<String, dynamic>.from(jsonDecode(json) as Map);
  } on Object {
    throw LinkParseException('Amnezia: cannot decode key');
  }

  final containers = (root['containers'] as List? ?? const []).cast<Map>();
  final preferred = root['defaultContainer'];
  containers.sort((a, b) =>
      (b['container'] == preferred ? 1 : 0) -
      (a['container'] == preferred ? 1 : 0));

  for (final c in containers) {
    final proto = c['awg'] ?? c['wireguard'];
    if (proto is! Map) continue;
    final last = proto['last_config'];
    if (last is! String) continue;
    final Map inner;
    try {
      inner = jsonDecode(last) as Map;
    } on Object {
      continue;
    }
    var conf = inner['config'];
    if (conf is! String) continue;
    conf = conf
        .replaceAll(r'$PRIMARY_DNS', '${root['dns1'] ?? '1.1.1.1'}')
        .replaceAll(r'$SECONDARY_DNS', '${root['dns2'] ?? '1.0.0.1'}');
    final name = '${root['description'] ?? root['hostName'] ?? ''}';
    return parseWireGuardConf(conf, name: name)..link = link;
  }
  throw LinkParseException(
      'Amnezia: this key has no WireGuard or AmneziaWG configuration');
}
