import 'dart:convert';

import '../models/profile.dart';
import 'link_utils.dart';
import 'misc_links.dart';
import 'v2ray_links.dart';
import 'wireguard_conf.dart';
import 'xray_json.dart';

export 'link_utils.dart' show LinkParseException;

class ImportResult {
  ImportResult({List<ProxyProfile>? profiles, List<String>? errors, this.subscriptionUrl})
      : profiles = profiles ?? [],
        errors = errors ?? [];

  final List<ProxyProfile> profiles;

  /// One message per entry that could not be imported.
  final List<String> errors;

  /// Set when the text was a single http(s) URL, i.e. a subscription.
  final String? subscriptionUrl;

  bool get isEmpty => profiles.isEmpty && subscriptionUrl == null;
}

/// Parses one share link. Throws [LinkParseException] when the scheme is
/// unknown or the link is malformed.
ProxyProfile parseLink(String link) {
  final l = link.trim();
  final end = l.indexOf('://');
  if (end <= 0) throw LinkParseException('not a link');
  switch (l.substring(0, end).toLowerCase()) {
    case 'vless':
      return parseVless(l);
    case 'vmess':
      return parseVmess(l);
    case 'trojan':
      return parseTrojan(l);
    case 'ss':
      return parseShadowsocks(l);
    case 'hysteria2':
    case 'hy2':
      return parseHysteria2(l);
    case 'hysteria':
      return parseHysteria(l);
    case 'tuic':
      return parseTuic(l);
    case 'wireguard':
    case 'wg':
    case 'awg':
      return parseWireGuardLink(l);
    case 'vpn':
      return parseAmneziaKey(l);
    case 'socks':
    case 'socks5':
    case 'socks4':
    case 'socks4a':
      return parseSocks(l);
  }
  throw LinkParseException(
      'unsupported link type: ${l.substring(0, end).toLowerCase()}');
}

const _importableTypes = {
  'vless': Protocol.vless,
  'vmess': Protocol.vmess,
  'trojan': Protocol.trojan,
  'shadowsocks': Protocol.shadowsocks,
  'hysteria': Protocol.hysteria,
  'hysteria2': Protocol.hysteria2,
  'tuic': Protocol.tuic,
  'http': Protocol.http,
  'socks': Protocol.socks,
  'wireguard': Protocol.wireguard,
};

/// Dial fields that reference other parts of the source config and would
/// dangle once the outbound is lifted out of it.
const _danglingKeys = ['tag', 'detour', 'domain_resolver', 'domain_strategy'];

ProxyProfile? _fromSingBoxOutbound(Map<String, dynamic> raw) {
  final type = raw['type'];
  final protocol = _importableTypes[type];
  if (protocol == null) return null;
  final name = '${raw['tag'] ?? ''}';
  var out = Map<String, dynamic>.from(raw);
  for (final k in _danglingKeys) {
    out.remove(k);
  }

  // Pre-1.11 WireGuard outbound: fold it into the endpoint shape.
  if (type == 'wireguard' && out['peers'] == null && out['server'] != null) {
    out = compact({
      'type': 'wireguard',
      'address': out['local_address'],
      'private_key': out['private_key'],
      'mtu': out['mtu'],
      'peers': [
        compact({
          'address': out['server'],
          'port': out['server_port'],
          'public_key': out['peer_public_key'],
          'pre_shared_key': out['pre_shared_key'],
          'allowed_ips': ['0.0.0.0/0', '::/0'],
        }),
      ],
    });
  }

  final profile = ProxyProfile(
    name: name,
    type: type == 'wireguard' && out['amnezia'] is Map
        ? Protocol.amneziawg
        : protocol,
    outbound: out,
  );
  if (profile.server.isEmpty) return null;
  if (profile.name.isEmpty) profile.name = '${profile.server}:${profile.port}';
  return profile;
}

ImportResult _fromJson(Object? json) {
  final result = ImportResult();
  void addAll(Object? list) {
    if (list is! List) return;
    for (final item in list) {
      if (item is! Map) continue;
      final p = _fromSingBoxOutbound(Map<String, dynamic>.from(item));
      if (p != null) result.profiles.add(p);
    }
  }

  // A 3x-ui JSON subscription: one full Xray config per server.
  final xrayConfigs = [
    if (looksLikeXrayConfig(json)) json,
    if (json is List) ...json.where(looksLikeXrayConfig),
  ];
  if (xrayConfigs.isNotEmpty) {
    for (final config in xrayConfigs) {
      final p = profileFromXrayConfig(Map<String, dynamic>.from(config as Map));
      if (p == null) {
        result.errors.add('unsupported Xray outbound');
      } else {
        result.profiles.add(p);
      }
    }
    return result;
  }

  if (json is List) {
    addAll(json);
  } else if (json is Map) {
    if (json['outbounds'] != null || json['endpoints'] != null) {
      addAll(json['outbounds']);
      addAll(json['endpoints']);
    } else {
      addAll([json]);
    }
  }
  if (result.profiles.isEmpty) {
    result.errors.add('JSON does not contain supported sing-box outbounds');
  }
  return result;
}

/// Parses clipboard text, a file or a subscription body: share links (one
/// per line, optionally base64-wrapped), a WireGuard/AmneziaWG `.conf`, a
/// sing-box JSON config, or a subscription URL.
ImportResult parseImportText(String input, {bool allowBase64 = true}) {
  final text = input.trim().replaceFirst('﻿', '');
  if (text.isEmpty) return ImportResult();

  if (looksLikeWireGuardConf(text)) {
    try {
      return ImportResult(profiles: [parseWireGuardConf(text)]);
    } on LinkParseException catch (e) {
      return ImportResult(errors: [e.message]);
    }
  }

  if (text.startsWith('{') || text.startsWith('[')) {
    try {
      return _fromJson(jsonDecode(text));
    } on FormatException {
      return ImportResult(errors: ['invalid JSON']);
    }
  }

  if (RegExp(r'^https?://\S+$', caseSensitive: false).hasMatch(text)) {
    return ImportResult(subscriptionUrl: text);
  }

  if (allowBase64 && !text.contains('://')) {
    final decoded = tryBase64(text);
    if (decoded != null) return parseImportText(decoded, allowBase64: false);
  }

  final result = ImportResult();
  for (final rawLine in const LineSplitter().convert(text)) {
    final line = rawLine.trim();
    if (line.isEmpty || !line.contains('://')) continue;
    if (RegExp(r'^https?://', caseSensitive: false).hasMatch(line)) continue;
    try {
      result.profiles.add(parseLink(line));
    } on LinkParseException catch (e) {
      result.errors.add(e.message);
    } on Object catch (e) {
      result.errors.add('$e');
    }
  }
  if (result.profiles.isEmpty && result.errors.isEmpty) {
    result.errors.add('nothing recognizable to import');
  }
  return result;
}
