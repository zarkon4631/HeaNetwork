import 'dart:math';

import 'panel_routing.dart';

/// Protocols the client can connect with. `amneziawg` is a WireGuard endpoint
/// carrying an `amnezia` block; it is kept separate so the UI can label it.
abstract final class Protocol {
  static const vless = 'vless';
  static const vmess = 'vmess';
  static const trojan = 'trojan';
  static const shadowsocks = 'shadowsocks';
  static const wireguard = 'wireguard';
  static const amneziawg = 'amneziawg';
  static const hysteria = 'hysteria';
  static const hysteria2 = 'hysteria2';
  static const tuic = 'tuic';
  static const http = 'http';
  static const socks = 'socks';

  static const all = [
    vless, vmess, trojan, shadowsocks, wireguard, amneziawg,
    hysteria, hysteria2, tuic, http, socks,
  ];

  static String label(String type) => switch (type) {
        vless => 'VLESS',
        vmess => 'VMess',
        trojan => 'Trojan',
        shadowsocks => 'Shadowsocks',
        wireguard => 'WireGuard',
        amneziawg => 'AmneziaWG',
        hysteria => 'Hysteria',
        hysteria2 => 'Hysteria 2',
        tuic => 'TUIC',
        http => 'HTTP',
        socks => 'SOCKS',
        _ => type,
      };
}

String newId() {
  final r = Random.secure();
  return List.generate(12, (_) => r.nextInt(36).toRadixString(36)).join();
}

/// One server. [outbound] is a sing-box outbound (or WireGuard endpoint)
/// object without a `tag`; the config builder assigns tags.
class ProxyProfile {
  ProxyProfile({
    String? id,
    required this.name,
    required this.type,
    required this.outbound,
    this.link,
    this.description,
    this.subscriptionId,
    this.latencyMs,
  }) : id = id ?? newId();

  final String id;
  String name;
  final String type;
  Map<String, dynamic> outbound;
  String? link;

  /// What the panel says about the server next to its name ("Wi-Fi", "for
  /// mobile networks"); shown under the name.
  String? description;
  String? subscriptionId;

  /// Last measured delay; null = never tested, -1 = failed.
  int? latencyMs;

  bool get isEndpoint => outbound['type'] == 'wireguard';

  String get server {
    if (isEndpoint) {
      final peers = outbound['peers'];
      if (peers is List && peers.isNotEmpty) {
        return '${(peers.first as Map)['address'] ?? ''}';
      }
      return '';
    }
    return '${outbound['server'] ?? ''}';
  }

  int get port {
    if (isEndpoint) {
      final peers = outbound['peers'];
      if (peers is List && peers.isNotEmpty) {
        return ((peers.first as Map)['port'] as num?)?.toInt() ?? 0;
      }
      return 0;
    }
    return (outbound['server_port'] as num?)?.toInt() ?? 0;
  }

  /// True when the handshake rides on UDP, where TLS fragmentation and a TCP
  /// connect probe do not apply.
  bool get isUdpBased =>
      isEndpoint ||
      type == Protocol.hysteria ||
      type == Protocol.hysteria2 ||
      type == Protocol.tuic ||
      transportType == 'quic' ||
      transportType == 'mkcp';

  String? get transportType {
    final t = outbound['transport'];
    return t is Map ? t['type'] as String? : null;
  }

  Map<String, dynamic>? get tls {
    final t = outbound['tls'];
    return t is Map<String, dynamic> && t['enabled'] == true ? t : null;
  }

  bool get isReality {
    final r = tls?['reality'];
    return r is Map && r['enabled'] == true;
  }

  /// Short human summary, e.g. "VLESS · Reality · XHTTP".
  String get summary {
    final parts = <String>[Protocol.label(type)];
    if (isReality) {
      parts.add('Reality');
    } else if (tls != null && !isUdpBased) {
      parts.add('TLS');
    }
    final t = transportType;
    if (t != null) {
      parts.add(switch (t) {
        'ws' => 'WebSocket',
        'grpc' => 'gRPC',
        'httpupgrade' => 'HTTPUpgrade',
        'xhttp' => 'XHTTP',
        'mkcp' => 'mKCP',
        'http' => 'HTTP',
        'quic' => 'QUIC',
        _ => t,
      });
    }
    if (outbound['flow'] == 'xtls-rprx-vision') parts.add('Vision');
    return parts.join(' · ');
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'type': type,
        'outbound': outbound,
        if (link != null) 'link': link,
        if (description != null) 'description': description,
        if (subscriptionId != null) 'subscriptionId': subscriptionId,
        if (latencyMs != null) 'latencyMs': latencyMs,
      };

  factory ProxyProfile.fromJson(Map<String, dynamic> j) => ProxyProfile(
        id: j['id'] as String?,
        name: j['name'] as String? ?? '',
        type: j['type'] as String? ?? '',
        outbound: Map<String, dynamic>.from(j['outbound'] as Map? ?? const {}),
        link: j['link'] as String?,
        description: j['description'] as String?,
        subscriptionId: j['subscriptionId'] as String?,
        latencyMs: (j['latencyMs'] as num?)?.toInt(),
      );
}

/// A server that was read correctly but left out, because the core has no
/// such protocol or transport. [reason] is `protocol:masque`,
/// `transport:xdrive` and the like.
class SkippedServer {
  const SkippedServer(this.name, this.reason);

  final String name;
  final String reason;

  Map<String, dynamic> toJson() => {'name': name, 'reason': reason};

  factory SkippedServer.fromJson(Map<String, dynamic> j) =>
      SkippedServer('${j['name'] ?? ''}', '${j['reason'] ?? ''}');
}

class Subscription {
  Subscription({
    String? id,
    required this.name,
    required this.url,
    this.updatedAt,
    this.uploadBytes,
    this.downloadBytes,
    this.totalBytes,
    this.expireAt,
    this.updateIntervalHours,
    this.supportUrl,
    this.webPageUrl,
    this.announce,
    this.collapsed = false,
    this.routing,
    List<SkippedServer>? unsupported,
  })  : id = id ?? newId(),
        unsupported = unsupported ?? [];

  final String id;
  String name;
  String url;
  DateTime? updatedAt;

  /// Routing rules the panel sends with the subscription (`Routing` header).
  PanelRouting? routing;

  /// Servers of the last update that are not in the list, because the core
  /// has no such protocol or transport.
  List<SkippedServer> unsupported;

  /// Folded in the list: only the header shows, the servers are hidden.
  bool collapsed;

  // From the `subscription-userinfo` response header, when the panel sends it.
  int? uploadBytes;
  int? downloadBytes;
  int? totalBytes;
  DateTime? expireAt;

  // What the panel asks of the client, from the response headers.
  /// `profile-update-interval`: refresh at least this often.
  int? updateIntervalHours;
  String? supportUrl;
  String? webPageUrl;

  /// A message from the provider to show next to the subscription.
  String? announce;

  /// True when the panel's refresh interval has elapsed.
  bool isDue(DateTime now) {
    final hours = updateIntervalHours;
    final last = updatedAt;
    if (hours == null || hours <= 0 || last == null) return false;
    return now.difference(last) >= Duration(hours: hours);
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': url,
        if (updatedAt != null) 'updatedAt': updatedAt!.toIso8601String(),
        if (uploadBytes != null) 'uploadBytes': uploadBytes,
        if (downloadBytes != null) 'downloadBytes': downloadBytes,
        if (totalBytes != null) 'totalBytes': totalBytes,
        if (expireAt != null) 'expireAt': expireAt!.toIso8601String(),
        if (updateIntervalHours != null) 'updateIntervalHours': updateIntervalHours,
        if (supportUrl != null) 'supportUrl': supportUrl,
        if (webPageUrl != null) 'webPageUrl': webPageUrl,
        if (announce != null) 'announce': announce,
        if (collapsed) 'collapsed': true,
        if (routing != null) 'routing': routing!.toJson(),
        if (unsupported.isNotEmpty)
          'unsupported': [for (final e in unsupported) e.toJson()],
      };

  factory Subscription.fromJson(Map<String, dynamic> j) => Subscription(
        id: j['id'] as String?,
        name: j['name'] as String? ?? '',
        url: j['url'] as String? ?? '',
        updatedAt: DateTime.tryParse(j['updatedAt'] as String? ?? ''),
        uploadBytes: (j['uploadBytes'] as num?)?.toInt(),
        downloadBytes: (j['downloadBytes'] as num?)?.toInt(),
        totalBytes: (j['totalBytes'] as num?)?.toInt(),
        expireAt: DateTime.tryParse(j['expireAt'] as String? ?? ''),
        updateIntervalHours: (j['updateIntervalHours'] as num?)?.toInt(),
        supportUrl: j['supportUrl'] as String?,
        webPageUrl: j['webPageUrl'] as String?,
        announce: j['announce'] as String?,
        collapsed: j['collapsed'] as bool? ?? false,
        routing: j['routing'] is Map
            ? PanelRouting.fromProfile(Map<String, dynamic>.from(j['routing'] as Map))
            : null,
        unsupported: [
          for (final e in j['unsupported'] as List? ?? const [])
            if (e is Map) SkippedServer.fromJson(Map<String, dynamic>.from(e)),
        ],
      );
}
