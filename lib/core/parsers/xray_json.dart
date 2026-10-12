import 'dart:convert';

import '../models/profile.dart';
import 'link_utils.dart';
import 'v2ray_links.dart';

/// True for an Xray-core config: its outbounds name a `protocol`, where
/// sing-box ones name a `type`.
bool looksLikeXrayConfig(Object? json) {
  if (json is! Map) return false;
  final outbounds = json['outbounds'];
  return outbounds is List &&
      outbounds.any((o) => o is Map && o['protocol'] is String);
}

Map<String, dynamic>? _map(Object? v) =>
    v is Map ? Map<String, dynamic>.from(v) : null;

Map<String, dynamic>? _first(Object? list) =>
    list is List && list.isNotEmpty ? _map(list.first) : null;

String _str(Object? v) => v == null ? '' : '$v';

int _int(Object? v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}') ?? 0;

/// Flattens Xray `streamSettings` into the parameter names share links use,
/// so both paths go through the same TLS/transport builder.
Map<String, String> _streamParams(Map<String, dynamic> stream) {
  final p = <String, String>{};
  var network = _str(stream['network']);
  if (network.isEmpty || network == 'raw') network = 'tcp';
  p['type'] = network;
  p['security'] = _str(stream['security']).isEmpty ? 'none' : _str(stream['security']);

  final tls = _map(stream['tlsSettings']);
  if (tls != null) {
    p['sni'] = _str(tls['serverName']);
    p['fp'] = _str(tls['fingerprint']);
    final alpn = tls['alpn'];
    if (alpn is List) p['alpn'] = alpn.join(',');
    if (tls['allowInsecure'] == true) p['allowInsecure'] = '1';
    p['ech'] = _str(tls['echConfigList']);
  }
  final reality = _map(stream['realitySettings']);
  if (reality != null) {
    p['sni'] = _str(reality['serverName']);
    p['fp'] = _str(reality['fingerprint']);
    p['pbk'] = _str(reality['publicKey']);
    p['sid'] = _str(reality['shortId']);
  }

  switch (network) {
    case 'ws':
      final ws = _map(stream['wsSettings']) ?? const {};
      p['path'] = _str(ws['path']);
      p['host'] = _str(ws['host']).isNotEmpty
          ? _str(ws['host'])
          : _str(_map(ws['headers'])?['Host']);
    case 'grpc':
      p['serviceName'] = _str(_map(stream['grpcSettings'])?['serviceName']);
    case 'httpupgrade':
      final hu = _map(stream['httpupgradeSettings']) ?? const {};
      p['path'] = _str(hu['path']);
      p['host'] = _str(hu['host']);
    case 'xhttp' || 'splithttp':
      final x = _map(stream['xhttpSettings'] ?? stream['splithttpSettings']) ?? const {};
      p['path'] = _str(x['path']);
      p['host'] = _str(x['host']);
      p['mode'] = _str(x['mode']);
      // The tuning knobs sit either under `extra` or next to path/host.
      final extra = _map(x['extra']) ??
          (Map<String, dynamic>.from(x)
            ..remove('path')
            ..remove('host')
            ..remove('mode'));
      if (extra.isNotEmpty) p['extra'] = jsonEncode(extra);
    case 'kcp' || 'mkcp':
      final kcp = _map(stream['kcpSettings']) ?? const {};
      p['seed'] = _str(kcp['seed']);
      p['headerType'] = _str(_map(kcp['header'])?['type']);
    case 'tcp':
      final header = _map(_map(stream['tcpSettings'] ?? stream['rawSettings'])?['header']);
      if (header?['type'] == 'http') {
        p['headerType'] = 'http';
        final request = _map(header!['request']) ?? const {};
        final host = _map(request['headers'])?['Host'];
        p['host'] = host is List ? host.join(',') : _str(host);
        final path = request['path'];
        p['path'] = path is List && path.isNotEmpty ? _str(path.first) : _str(path);
      }
  }

  final finalMask = stream['finalmask'];
  if (finalMask is Map && finalMask.isNotEmpty) p['fm'] = jsonEncode(finalMask);
  p.removeWhere((_, v) => v.isEmpty);
  return p;
}

/// The settings of every UDP mask of one [type] in the stream's finalmask.
Iterable<Map<String, dynamic>> _udpMasks(Map<String, dynamic> stream, String type) sync* {
  final udp = _map(stream['finalmask'])?['udp'];
  if (udp is! List) return;
  for (final mask in udp) {
    if (mask is Map && mask['type'] == type) {
      yield _map(mask['settings']) ?? const {};
    }
  }
}

/// Hysteria 2 obfuscation, which Xray writes as a `salamander` mask. With a
/// `packetSize` range it is the gecko variant: packets padded to that size.
Map<String, dynamic>? _hysteriaObfs(Map<String, dynamic> stream) {
  for (final settings in _udpMasks(stream, 'salamander')) {
    final password = _str(settings['password']);
    if (password.isEmpty) continue;
    final size =
        RegExp(r'^(\d+)-(\d+)$').firstMatch(_str(settings['packetSize']).trim());
    return {
      'type': size == null ? 'salamander' : 'gecko',
      'password': password,
      if (size != null) 'min_packet_size': int.parse(size.group(1)!),
      if (size != null) 'max_packet_size': int.parse(size.group(2)!),
    };
  }
  return null;
}

/// Port hopping: a `udphop` mask since Xray 26.9.9, `quicParams.udpHop`
/// before it. The interval is in seconds, a number or a range.
void _applyPortHopping(Map<String, dynamic> out, Map<String, dynamic> stream) {
  final mask = _udpMasks(stream, 'udphop').lastOrNull;
  final legacy = _map(_map(_map(stream['finalmask'])?['quicParams'])?['udpHop']);
  final ports = hopPortRanges([_str(mask?['remotePorts'] ?? legacy?['ports'])]);
  if (ports.isEmpty) return;
  out['server_ports'] = ports;
  final interval = RegExp(r'^(\d+)(?:-(\d+))?$')
      .firstMatch(_str(mask?['interval'] ?? legacy?['interval']).trim());
  if (interval == null) return;
  out['hop_interval'] = '${interval.group(1)}s';
  final upper = interval.group(2);
  if (upper != null && upper != interval.group(1)) out['hop_interval_max'] = '${upper}s';
}

/// Outbounds every Xray config has next to the server itself.
const _plumbing = {'freedom', 'blackhole', 'dns', 'loopback'};

/// Converts one Xray-core config, as served by a 3x-ui JSON subscription,
/// into a profile. Only the proxy outbound is taken: routing, DNS and
/// inbounds of the source config belong to that client, not to this one.
///
/// Returns null when the config names no server at all, and throws
/// [UnsupportedException] when it names one the core cannot connect to
/// (MASQUE, the XDRIVE transport): that server is skipped, and no other
/// outbound of the config is taken in its place.
ProxyProfile? profileFromXrayConfig(Map<String, dynamic> config) {
  final outbounds = (config['outbounds'] as List? ?? const [])
      .whereType<Map>()
      .map(Map<String, dynamic>.from)
      .toList();
  const supported = {
    'vless', 'vmess', 'trojan', 'shadowsocks', 'socks', 'http', 'hysteria',
    'wireguard',
  };
  bool usable(Map<String, dynamic> o) => supported.contains(o['protocol']);
  final o = outbounds.where((o) => o['tag'] == 'proxy').firstOrNull ??
      outbounds.where(usable).firstOrNull ??
      outbounds
          .where((o) => o['protocol'] is String && !_plumbing.contains(o['protocol']))
          .firstOrNull;
  if (o == null) return null;
  if (!usable(o)) {
    if (o['protocol'] is! String || _plumbing.contains(o['protocol'])) return null;
    throw UnsupportedException('protocol:${o['protocol']}');
  }

  final protocol = o['protocol'] as String;
  final settings = _map(o['settings']) ?? const {};
  final stream = _map(o['streamSettings']) ?? const {};
  final remark = _str(config['remarks']).trim();

  if (protocol == 'wireguard') {
    final peer = _first(settings['peers']);
    final endpoint = _str(peer?['endpoint']);
    final colon = endpoint.lastIndexOf(':');
    if (peer == null || colon <= 0) return null;
    final host = endpoint.substring(0, colon).replaceAll(RegExp(r'[\[\]]'), '');
    final port = int.tryParse(endpoint.substring(colon + 1)) ?? 0;
    final addresses = (settings['address'] as List? ?? const [])
        .map((a) => '$a'.contains('/') ? '$a' : ('$a'.contains(':') ? '$a/128' : '$a/32'))
        .toList();
    return ProxyProfile(
      name: remark.isNotEmpty ? remark : '$host:$port',
      type: Protocol.wireguard,
      outbound: compact({
        'type': 'wireguard',
        'address': addresses,
        'private_key': _str(settings['secretKey']),
        'mtu': _int(settings['mtu']) > 0 ? _int(settings['mtu']) : null,
        'peers': [
          compact({
            'address': host,
            'port': port,
            'public_key': _str(peer['publicKey']),
            'pre_shared_key': _str(peer['preSharedKey']),
            'allowed_ips': ['0.0.0.0/0', '::/0'],
            'persistent_keepalive_interval':
                _int(peer['keepAlive']) > 0 ? _int(peer['keepAlive']) : null,
          }),
        ],
      }),
    );
  }

  // Newer configs put the endpoint straight into `settings`; older ones wrap
  // it in `vnext` (VLESS/VMess) or `servers` (the rest).
  final vnext = _first(settings['vnext']);
  final server = _first(settings['servers']);
  final endpoint = vnext ?? server ?? settings;
  final user = _first(endpoint['users']) ?? endpoint;
  final host = _str(endpoint['address']);
  final port = _int(endpoint['port']);
  final params = _streamParams(stream);
  // A transport the core does not have is named before anything else is
  // asked of the config: XDRIVE, for one, needs no address at all.
  if (protocol != 'hysteria') transportFromParams(params);
  if (host.isEmpty || port == 0) return null;

  final out = <String, dynamic>{'server': host, 'server_port': port};
  String type;

  switch (protocol) {
    case 'vless':
      type = Protocol.vless;
      out['type'] = 'vless';
      out['uuid'] = _str(user['id']);
      final flow = _str(user['flow']);
      if (flow.isNotEmpty) out['flow'] = flow.replaceFirst('-udp443', '');
      final encryption = _str(user['encryption']);
      if (encryption.isNotEmpty && encryption != 'none') out['encryption'] = encryption;
    case 'vmess':
      type = Protocol.vmess;
      out['type'] = 'vmess';
      out['uuid'] = _str(user['id']);
      out['security'] = _str(user['security']).isEmpty ? 'auto' : _str(user['security']);
      out['alter_id'] = _int(user['alterId']);
    case 'trojan':
      type = Protocol.trojan;
      out['type'] = 'trojan';
      out['password'] = _str(endpoint['password']);
    case 'shadowsocks':
      type = Protocol.shadowsocks;
      out['type'] = 'shadowsocks';
      out['method'] = _str(endpoint['method']);
      out['password'] = _str(endpoint['password']);
    case 'socks' || 'http':
      type = protocol == 'socks' ? Protocol.socks : Protocol.http;
      out['type'] = protocol;
      if (protocol == 'socks') out['version'] = '5';
      final account = _first(endpoint['users']);
      if (account != null) {
        out['username'] = _str(account['user']);
        out['password'] = _str(account['pass']);
      }
    case 'hysteria':
      final hy = _map(stream['hysteriaSettings']) ?? const {};
      final version = _int(settings['version']) == 1 || _int(hy['version']) == 1 ? 1 : 2;
      final auth = _str(hy['auth']);
      params['security'] = 'tls';
      params.remove('type');
      if (version == 2) {
        type = Protocol.hysteria2;
        out['type'] = 'hysteria2';
        out['password'] = auth;
        final obfs = _hysteriaObfs(stream);
        if (obfs != null) out['obfs'] = obfs;
        _applyPortHopping(out, stream);
      } else {
        type = Protocol.hysteria;
        out['type'] = 'hysteria';
        out['auth_str'] = auth;
        out['up_mbps'] = 20;
        out['down_mbps'] = 100;
      }
    default:
      return null;
  }

  if (protocol == 'hysteria') {
    // QUIC: no stream transport, and a browser fingerprint does not apply.
    params.remove('fp');
    final tls = tlsFromParams(params, host: host, forceTls: true);
    if (tls != null) out['tls'] = tls;
  } else {
    applyStream(out, params, host, forceTls: protocol == 'trojan' && params['security'] == null);
  }

  return ProxyProfile(
    name: remark.isNotEmpty ? remark : '$host:$port',
    type: type,
    outbound: compact(out),
  );
}
