import '../models/profile.dart';
import 'link_utils.dart';

String _nameOr(String name, String host, int port) =>
    name.isNotEmpty ? name : '$host:$port';

void _requireServer(RawLink l, String proto) {
  if (l.host.isEmpty || l.port == 0) {
    throw LinkParseException('$proto: missing server address');
  }
}

/// SIP002 (`ss://base64(method:pass)@host:port`) and the legacy form where
/// the whole `method:pass@host:port` is base64.
ProxyProfile parseShadowsocks(String link) {
  var l = RawLink.parse(link);
  if (l.userInfo.isEmpty) {
    final body = link.substring(5).split('#').first.split('?').first;
    final decoded = tryBase64(body);
    if (decoded == null) throw LinkParseException('Shadowsocks: bad link');
    final suffix = link.contains('#') ? link.substring(link.indexOf('#')) : '';
    l = RawLink.parse('ss://$decoded$suffix');
    if (l.userInfo.isEmpty) throw LinkParseException('Shadowsocks: bad link');
  }
  _requireServer(l, 'Shadowsocks');

  var creds = l.userInfo;
  if (!creds.contains(':')) {
    creds = tryBase64(creds) ?? creds;
  }
  final sep = creds.indexOf(':');
  if (sep <= 0) throw LinkParseException('Shadowsocks: missing method');

  final out = <String, dynamic>{
    'type': 'shadowsocks',
    'server': l.host,
    'server_port': l.port,
    'method': creds.substring(0, sep),
    // 2022 multi-user keys are `server:user`; keep everything after the method.
    'password': creds.substring(sep + 1),
  };
  final plugin = l.q('plugin');
  if (plugin != null) {
    final semi = plugin.indexOf(';');
    var name = semi < 0 ? plugin : plugin.substring(0, semi);
    if (name == 'simple-obfs') name = 'obfs-local';
    out['plugin'] = name;
    if (semi >= 0) out['plugin_opts'] = plugin.substring(semi + 1);
  }
  return ProxyProfile(
    name: _nameOr(l.name, l.host, l.port),
    type: Protocol.shadowsocks,
    outbound: out,
    link: link,
  );
}

ProxyProfile parseHysteria2(String link) {
  final l = RawLink.parse(link);
  _requireServer(l, 'Hysteria2');

  // `pinSHA256` pins the leaf certificate; the core can only pin the public
  // key, so the pin is not carried over.
  final tls = <String, dynamic>{
    'enabled': true,
    'server_name': l.q('sni') ?? l.q('peer'),
    if (l.flag('insecure') || l.flag('allowInsecure')) 'insecure': true,
    'alpn': splitList(l.q('alpn')),
  };

  final out = <String, dynamic>{
    'type': 'hysteria2',
    'server': l.host,
    'server_port': l.port,
    'password': l.userInfo,
    'tls': compact(tls)..['enabled'] = true,
  };

  // Port hopping: `host:443,20000-30000` or `?mport=20000-30000`.
  final hop = <String>[
    ...l.portSpec.split(',').skip(1),
    ...splitList(l.q('mport')),
  ].where((e) => e.isNotEmpty).map((e) {
    final r = e.replaceAll('-', ':');
    return r.contains(':') ? r : '$r:$r';
  }).toList();
  if (hop.isNotEmpty) out['server_ports'] = hop;

  final obfs = l.q('obfs');
  if (obfs != null && obfs != 'none') {
    out['obfs'] = {
      'type': obfs,
      'password': l.q('obfs-password') ?? l.q('obfsParam') ?? '',
    };
  }
  final up = int.tryParse(l.q('up') ?? l.q('upmbps') ?? '');
  final down = int.tryParse(l.q('down') ?? l.q('downmbps') ?? '');
  if (up != null && up > 0) out['up_mbps'] = up;
  if (down != null && down > 0) out['down_mbps'] = down;

  return ProxyProfile(
    name: _nameOr(l.name, l.host, l.port),
    type: Protocol.hysteria2,
    outbound: out,
    link: link,
  );
}

ProxyProfile parseHysteria(String link) {
  final l = RawLink.parse(link);
  _requireServer(l, 'Hysteria');

  final out = <String, dynamic>{
    'type': 'hysteria',
    'server': l.host,
    'server_port': l.port,
    // The protocol needs both rates; fall back to modest defaults.
    'up_mbps': int.tryParse(l.q('upmbps') ?? l.q('up') ?? '') ?? 20,
    'down_mbps': int.tryParse(l.q('downmbps') ?? l.q('down') ?? '') ?? 100,
    'tls': compact({
      'enabled': true,
      'server_name': l.q('peer') ?? l.q('sni'),
      if (l.flag('insecure')) 'insecure': true,
      'alpn': splitList(l.q('alpn')),
    })
      ..['enabled'] = true,
  };
  final auth = l.q('auth') ?? (l.userInfo.isEmpty ? null : l.userInfo);
  if (auth != null) out['auth_str'] = auth;
  final obfs = l.q('obfsParam');
  if (obfs != null) out['obfs'] = obfs;

  return ProxyProfile(
    name: _nameOr(l.name, l.host, l.port),
    type: Protocol.hysteria,
    outbound: out,
    link: link,
  );
}

ProxyProfile parseTuic(String link) {
  final l = RawLink.parse(link);
  _requireServer(l, 'TUIC');
  final sep = l.userInfo.indexOf(':');
  if (l.userInfo.isEmpty) throw LinkParseException('TUIC: missing UUID');

  final out = <String, dynamic>{
    'type': 'tuic',
    'server': l.host,
    'server_port': l.port,
    'uuid': sep < 0 ? l.userInfo : l.userInfo.substring(0, sep),
    if (sep >= 0) 'password': l.userInfo.substring(sep + 1),
    'tls': compact({
      'enabled': true,
      'server_name': l.q('sni'),
      if (l.flag('allow_insecure') || l.flag('allowInsecure') || l.flag('insecure'))
        'insecure': true,
      if (l.flag('disable_sni')) 'disable_sni': true,
      'alpn': splitList(l.q('alpn')),
    })
      ..['enabled'] = true,
  };
  final cc = l.q('congestion_control') ?? l.q('congestion-control');
  if (cc != null) out['congestion_control'] = cc;
  final relay = l.q('udp_relay_mode') ?? l.q('udp-relay-mode');
  if (relay != null) out['udp_relay_mode'] = relay;

  return ProxyProfile(
    name: _nameOr(l.name, l.host, l.port),
    type: Protocol.tuic,
    outbound: out,
    link: link,
  );
}

/// `socks://base64(user:pass)@host:port` and `socks5://user:pass@host:port`.
ProxyProfile parseSocks(String link) {
  final l = RawLink.parse(link);
  _requireServer(l, 'SOCKS');
  var creds = l.userInfo;
  if (creds.isNotEmpty && !creds.contains(':')) creds = tryBase64(creds) ?? creds;
  final sep = creds.indexOf(':');
  return ProxyProfile(
    name: _nameOr(l.name, l.host, l.port),
    type: Protocol.socks,
    outbound: compact({
      'type': 'socks',
      'version': l.scheme == 'socks4' ? '4' : (l.scheme == 'socks4a' ? '4a' : '5'),
      'server': l.host,
      'server_port': l.port,
      'username': sep < 0 ? creds : creds.substring(0, sep),
      'password': sep < 0 ? '' : creds.substring(sep + 1),
    }),
    link: link,
  );
}

/// An HTTP(S) proxy. Only used when the user explicitly adds one, because a
/// bare `https://` URL is otherwise treated as a subscription.
ProxyProfile parseHttpProxy(String link) {
  final l = RawLink.parse(link);
  final port = l.port != 0 ? l.port : (l.scheme == 'https' ? 443 : 80);
  if (l.host.isEmpty) throw LinkParseException('HTTP: missing server address');
  final sep = l.userInfo.indexOf(':');
  return ProxyProfile(
    name: _nameOr(l.name, l.host, port),
    type: Protocol.http,
    outbound: compact({
      'type': 'http',
      'server': l.host,
      'server_port': port,
      'username': sep < 0 ? l.userInfo : l.userInfo.substring(0, sep),
      'password': sep < 0 ? '' : l.userInfo.substring(sep + 1),
      if (l.scheme == 'https') 'tls': {'enabled': true, 'server_name': l.host},
    }),
    link: link,
  );
}
