import 'dart:convert';

import '../models/profile.dart';
import 'link_utils.dart';

const _knownFingerprints = {
  'chrome', 'firefox', 'edge', 'safari', '360', 'qq', 'ios', 'android',
  'random', 'randomized', 'chrome_psk', 'chrome_psk_shuffle',
  'chrome_padding_psk_shuffle', 'chrome_pq', 'chrome_pq_psk',
};

const xhttpDefaultPadding = '100-1000';

/// Builds the sing-box `tls` object from Xray-style share-link parameters
/// (`security`, `sni`, `fp`, `alpn`, `pbk`, `sid`, ...). Returns null for
/// plain connections.
Map<String, dynamic>? tlsFromParams(
  Map<String, String> p, {
  required String host,
  bool forceTls = false,
}) {
  String? get(String k) => (p[k]?.isEmpty ?? true) ? null : p[k];
  bool flag(String k) => p[k] == '1' || p[k]?.toLowerCase() == 'true';

  final security = get('security') ?? (forceTls ? 'tls' : 'none');
  final reality = security == 'reality';
  if (!reality && security != 'tls' && security != 'xtls') return null;

  final sni = get('sni') ?? get('peer') ?? get('host');
  final tls = <String, dynamic>{
    'enabled': true,
    if (sni != null) 'server_name': sni.split(',').first,
    if (flag('allowInsecure') || flag('insecure') || flag('skip-cert-verify'))
      'insecure': true,
    'alpn': splitList(get('alpn')),
  };

  var fp = get('fp')?.toLowerCase();
  if (fp != null && !_knownFingerprints.contains(fp)) fp = 'chrome';
  // Reality is only implemented on top of uTLS.
  if (reality) fp ??= 'chrome';
  if (fp != null) tls['utls'] = {'enabled': true, 'fingerprint': fp};

  if (reality) {
    tls['reality'] = {
      'enabled': true,
      'public_key': get('pbk') ?? '',
      'short_id': get('sid') ?? '',
    };
  }

  final ech = get('ech');
  if (ech != null) {
    // Xray carries the ECHConfigList as bare base64; sing-box wants PEM.
    final looksLikeList = tryBase64(ech) != null && ech.length > 40;
    tls['ech'] = {
      'enabled': true,
      if (looksLikeList)
        'config': [
          '-----BEGIN ECH CONFIGS-----',
          ech,
          '-----END ECH CONFIGS-----',
        ],
    };
  }

  // Keep an explicitly empty host (IP-only servers) out of the config.
  if (tls['server_name'] == null && !_isIp(host)) tls['server_name'] = host;
  return compact(tls)..['enabled'] = true;
}

bool _isIp(String host) =>
    RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(host) || host.contains(':');

/// Builds the sing-box `transport` object from `type`/`net` and friends.
/// Returns null for raw TCP.
Map<String, dynamic>? transportFromParams(Map<String, String> p) {
  String? get(String k) => (p[k]?.isEmpty ?? true) ? null : p[k];

  final type = (get('type') ?? get('net') ?? 'tcp').toLowerCase();
  final host = get('host');
  final path = get('path');

  switch (type) {
    case 'tcp':
    case 'raw':
      if (get('headerType') != 'http') return null;
      return compact({
        'type': 'http',
        'host': splitList(host),
        'path': path,
      });
    case 'http':
    case 'h2':
      return compact({'type': 'http', 'host': splitList(host), 'path': path});
    case 'ws':
      final t = <String, dynamic>{'type': 'ws'};
      if (host != null) t['headers'] = {'Host': host};
      if (path != null) {
        // `?ed=2048` is Xray's inline early-data hint.
        final m = RegExp(r'^(.*?)(?:\?ed=(\d+))?$').firstMatch(path);
        t['path'] = m?.group(1) ?? path;
        final ed = int.tryParse(m?.group(2) ?? '');
        if (ed != null && ed > 0) {
          t['max_early_data'] = ed;
          t['early_data_header_name'] = 'Sec-WebSocket-Protocol';
        }
      }
      return compact(t);
    case 'grpc':
      return compact({
        'type': 'grpc',
        'service_name': get('serviceName') ?? path,
      });
    case 'httpupgrade':
      return compact({'type': 'httpupgrade', 'host': host, 'path': path});
    case 'xhttp':
    case 'splithttp':
      final t = <String, dynamic>{
        'type': 'xhttp',
        'mode': get('mode'),
        'host': host,
        'path': path,
      };
      final extra = _decodeExtra(get('extra'));
      if (extra != null) t.addAll(xhttpExtra(extra));
      // The core rejects XHTTP without padding; this is Xray's default.
      t['x_padding_bytes'] ??= xhttpDefaultPadding;
      return compact(t);
    case 'kcp':
    case 'mkcp':
      final header = get('headerType');
      return compact({
        'type': 'mkcp',
        'seed': get('seed'),
        'header_type': header == 'none' ? null : header,
      });
    case 'quic':
      return {'type': 'quic'};
  }
  throw LinkParseException('unsupported transport: $type');
}

/// `extra` is URL-encoded JSON in Xray links; some tools base64 it instead.
Map<String, dynamic>? _decodeExtra(String? raw) {
  if (raw == null) return null;
  for (final candidate in [raw, tryBase64(raw)]) {
    if (candidate == null) continue;
    try {
      final v = jsonDecode(candidate);
      if (v is Map) return Map<String, dynamic>.from(v);
    } on FormatException {
      continue;
    }
  }
  return null;
}

/// Xray accepts a range as a number, an `"a-b"` string or `{from,to}`.
Object? _range(Object? v) {
  if (v is num) return v.toInt();
  if (v is String) return v.trim().isEmpty ? null : v.trim();
  if (v is Map && v['from'] != null && v['to'] != null) {
    return '${v['from']}-${v['to']}';
  }
  return null;
}

/// Maps Xray's camelCase XHTTP `extra` object onto the core's option names.
Map<String, dynamic> xhttpExtra(Map<String, dynamic> e) {
  final out = <String, dynamic>{};

  void range(String from, String to) {
    final r = _range(e[from]);
    if (r != null) out[to] = r;
  }

  void plain(String from, String to) {
    final v = e[from];
    if (v is String && v.isNotEmpty || v is bool && v) out[to] = v;
  }

  final headers = e['headers'];
  if (headers is Map && headers.isNotEmpty) {
    out['headers'] = headers.map((k, v) => MapEntry('$k', '$v'));
  }
  range('xPaddingBytes', 'x_padding_bytes');
  range('scMaxEachPostBytes', 'sc_max_each_post_bytes');
  range('scMinPostsIntervalMs', 'sc_min_posts_interval_ms');
  range('uplinkChunkSize', 'uplink_chunk_size');
  plain('noGRPCHeader', 'no_grpc_header');
  plain('xPaddingObfsMode', 'x_padding_obfs_mode');
  plain('xPaddingKey', 'x_padding_key');
  plain('xPaddingHeader', 'x_padding_header');
  plain('xPaddingPlacement', 'x_padding_placement');
  plain('xPaddingMethod', 'x_padding_method');
  plain('uplinkHTTPMethod', 'uplink_http_method');
  plain('sessionPlacement', 'session_placement');
  plain('sessionKey', 'session_key');
  plain('seqPlacement', 'seq_placement');
  plain('seqKey', 'seq_key');
  plain('uplinkDataPlacement', 'uplink_data_placement');
  plain('uplinkDataKey', 'uplink_data_key');

  final xmux = e['xmux'];
  if (xmux is Map) {
    final x = <String, dynamic>{};
    void xr(String from, String to) {
      final r = _range(xmux[from]);
      if (r != null) x[to] = r;
    }

    xr('maxConcurrency', 'max_concurrency');
    xr('maxConnections', 'max_connections');
    xr('cMaxReuseTimes', 'c_max_reuse_times');
    xr('hMaxRequestTimes', 'h_max_request_times');
    xr('hMaxReusableSecs', 'h_max_reusable_secs');
    final keepAlive = xmux['hKeepAlivePeriod'];
    if (keepAlive is num) x['h_keep_alive_period'] = keepAlive.toInt();
    if (x.isNotEmpty) out['xmux'] = x;
  }

  final dl = e['downloadSettings'];
  if (dl is Map) {
    final d = <String, dynamic>{
      'server': dl['address'],
      'server_port': (dl['port'] as num?)?.toInt(),
    };
    final xs = dl['xhttpSettings'];
    if (xs is Map) {
      d['host'] = xs['host'];
      d['path'] = xs['path'];
      final nested = xs['extra'];
      if (nested is Map) d.addAll(xhttpExtra(Map<String, dynamic>.from(nested)));
    }
    final security = dl['security'];
    final ts = dl['tlsSettings'];
    final rs = dl['realitySettings'];
    if (security == 'tls' && ts is Map) {
      d['tls'] = tlsFromParams({
        'security': 'tls',
        'sni': '${ts['serverName'] ?? ''}',
        'fp': '${ts['fingerprint'] ?? ''}',
        'alpn': (ts['alpn'] as List?)?.join(',') ?? '',
        if (ts['allowInsecure'] == true) 'allowInsecure': '1',
      }, host: '${dl['address'] ?? ''}');
    } else if (security == 'reality' && rs is Map) {
      d['tls'] = tlsFromParams({
        'security': 'reality',
        'sni': '${rs['serverName'] ?? ''}',
        'fp': '${rs['fingerprint'] ?? ''}',
        'pbk': '${rs['publicKey'] ?? ''}',
        'sid': '${rs['shortId'] ?? ''}',
      }, host: '${dl['address'] ?? ''}');
    }
    final c = compact(d);
    if (c.isNotEmpty) {
      c['x_padding_bytes'] ??= xhttpDefaultPadding;
      out['download'] = c;
    }
  }
  return out;
}

void _applyStream(Map<String, dynamic> out, Map<String, String> p, String host,
    {bool forceTls = false}) {
  final transport = transportFromParams(p);
  final tls = tlsFromParams(p, host: host, forceTls: forceTls);
  if (tls != null) {
    // The core picks the HTTP version of XHTTP from ALPN; default like Xray.
    if (transport?['type'] == 'xhttp' &&
        tls['alpn'] == null &&
        tls['reality'] == null) {
      tls['alpn'] = ['h2', 'http/1.1'];
    }
    out['tls'] = tls;
  }
  if (transport != null) out['transport'] = transport;
}

String _nameOr(String name, String host, int port) =>
    name.isNotEmpty ? name : '$host:$port';

ProxyProfile parseVless(String link) {
  final l = RawLink.parse(link);
  if (l.userInfo.isEmpty) throw LinkParseException('VLESS: missing UUID');
  if (l.host.isEmpty || l.port == 0) {
    throw LinkParseException('VLESS: missing server address');
  }
  final out = <String, dynamic>{
    'type': 'vless',
    'server': l.host,
    'server_port': l.port,
    'uuid': l.userInfo,
  };
  final flow = l.q('flow');
  if (flow != null && flow != 'none') {
    // Xray's `-udp443` suffix is a client-side toggle, not a distinct flow.
    out['flow'] = flow.replaceFirst('-udp443', '');
  }
  final encryption = l.q('encryption');
  if (encryption != null && encryption != 'none') out['encryption'] = encryption;
  final pe = l.q('packetEncoding');
  if (pe != null) out['packet_encoding'] = pe == 'none' ? '' : pe;
  _applyStream(out, l.query, l.host);
  return ProxyProfile(
    name: _nameOr(l.name, l.host, l.port),
    type: Protocol.vless,
    outbound: out,
    link: link,
  );
}

ProxyProfile parseTrojan(String link) {
  final l = RawLink.parse(link);
  if (l.userInfo.isEmpty) throw LinkParseException('Trojan: missing password');
  if (l.host.isEmpty || l.port == 0) {
    throw LinkParseException('Trojan: missing server address');
  }
  final out = <String, dynamic>{
    'type': 'trojan',
    'server': l.host,
    'server_port': l.port,
    'password': l.userInfo,
  };
  // Trojan is TLS unless the link explicitly says otherwise.
  _applyStream(out, l.query, l.host, forceTls: l.q('security') == null);
  return ProxyProfile(
    name: _nameOr(l.name, l.host, l.port),
    type: Protocol.trojan,
    outbound: out,
    link: link,
  );
}

ProxyProfile parseVmess(String link) {
  final body = link.substring(link.indexOf('://') + 3).trim();
  final decoded = tryBase64(body.split('#').first.split('?').first);
  Map<String, dynamic>? j;
  if (decoded != null) {
    try {
      final v = jsonDecode(decoded);
      if (v is Map) j = Map<String, dynamic>.from(v);
    } on FormatException {
      j = null;
    }
  }
  if (j == null) throw LinkParseException('VMess: unsupported link format');

  String s(String k) => '${j![k] ?? ''}'.trim();
  final host = s('add');
  final port = int.tryParse(s('port')) ?? 0;
  if (host.isEmpty || port == 0 || s('id').isEmpty) {
    throw LinkParseException('VMess: missing server address or id');
  }

  final out = <String, dynamic>{
    'type': 'vmess',
    'server': host,
    'server_port': port,
    'uuid': s('id'),
    'security': s('scy').isEmpty ? 'auto' : s('scy'),
    'alter_id': int.tryParse(s('aid')) ?? 0,
  };
  final p = <String, String>{
    'type': s('net').isEmpty ? 'tcp' : s('net'),
    'headerType': s('type'),
    'host': s('host'),
    'path': s('path'),
    'security': s('tls').isEmpty ? 'none' : s('tls'),
    'sni': s('sni'),
    'alpn': s('alpn'),
    'fp': s('fp'),
    if (s('allowInsecure') == 'true' || s('allowInsecure') == '1' ||
        s('insecure') == '1')
      'allowInsecure': '1',
  };
  if (p['type'] == 'grpc') p['serviceName'] = s('path');
  if (p['type'] == 'kcp') p['seed'] = s('path');
  _applyStream(out, p, host);
  return ProxyProfile(
    name: _nameOr(s('ps'), host, port),
    type: Protocol.vmess,
    outbound: out,
    link: link,
  );
}
