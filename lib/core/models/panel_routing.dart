import 'dart:convert';

import '../parsers/link_utils.dart';
import 'settings.dart';

/// Routing rules handed out by the subscription server, in the format the
/// Happ client introduced and 3x-ui sends in the `Routing` response header:
/// `happ://routing/onadd/<base64 of a JSON profile>`.
///
/// The profile lists sites and addresses per destination (direct, proxy,
/// block) in Xray notation: `geosite:ru`, `geoip:ru`, `domain:example.com`,
/// `full:host`, `keyword:word`, `regexp:...`, a bare domain, or an IP range.
class PanelRouting {
  PanelRouting({
    this.name = '',
    this.globalProxy = true,
    List<String>? directSites,
    List<String>? directIp,
    List<String>? proxySites,
    List<String>? proxyIp,
    List<String>? blockSites,
    List<String>? blockIp,
    List<RouteAction>? order,
  })  : directSites = directSites ?? const [],
        directIp = directIp ?? const [],
        proxySites = proxySites ?? const [],
        proxyIp = proxyIp ?? const [],
        blockSites = blockSites ?? const [],
        blockIp = blockIp ?? const [],
        order = order ?? defaultOrder;

  final String name;

  /// Where traffic no rule matches goes: through the VPN, or directly.
  final bool globalProxy;
  final List<String> directSites;
  final List<String> directIp;
  final List<String> proxySites;
  final List<String> proxyIp;
  final List<String> blockSites;
  final List<String> blockIp;

  /// Which destination wins when several match; the first one does.
  final List<RouteAction> order;

  static const defaultOrder = [RouteAction.block, RouteAction.proxy, RouteAction.direct];
  static const _linkPrefixes = ['happ://routing/onadd/', 'happ://routing/add/'];

  /// True for anything that looks like a Happ routing link, valid or not.
  static bool isLink(String text) => text.trim().startsWith('happ://routing/');

  /// Parses a `happ://routing/...` link. Null for "off" and for anything
  /// that is not a routing profile.
  static PanelRouting? parseLink(String? text) {
    final link = text?.trim() ?? '';
    for (final prefix in _linkPrefixes) {
      if (!link.startsWith(prefix)) continue;
      final decoded = tryBase64(link.substring(prefix.length));
      if (decoded == null) return null;
      try {
        final json = jsonDecode(decoded);
        return json is Map ? PanelRouting.fromProfile(Map<String, dynamic>.from(json)) : null;
      } on FormatException {
        return null;
      }
    }
    return null;
  }

  static List<String> _list(Object? v) => v is List
      ? [
          for (final e in v)
            if ('$e'.trim().isNotEmpty) '$e'.trim(),
        ]
      : const [];

  static bool _flag(Object? v, bool fallback) {
    if (v is bool) return v;
    final text = '${v ?? ''}'.toLowerCase();
    return text == 'true' ? true : (text == 'false' ? false : fallback);
  }

  static List<RouteAction> _order(Object? v) {
    final out = <RouteAction>[];
    for (final part in '${v ?? ''}'.toLowerCase().split('-')) {
      final action = switch (part.trim()) {
        'block' => RouteAction.block,
        'proxy' => RouteAction.proxy,
        'direct' => RouteAction.direct,
        _ => null,
      };
      if (action != null && !out.contains(action)) out.add(action);
    }
    for (final action in defaultOrder) {
      if (!out.contains(action)) out.add(action);
    }
    return out;
  }

  /// From the JSON profile as Happ defines it (`DirectSites`, `GlobalProxy`…).
  factory PanelRouting.fromProfile(Map<String, dynamic> j) => PanelRouting(
        name: '${j['Name'] ?? ''}'.trim(),
        globalProxy: _flag(j['GlobalProxy'], true),
        directSites: _list(j['DirectSites']),
        directIp: _list(j['DirectIp']),
        proxySites: _list(j['ProxySites']),
        proxyIp: _list(j['ProxyIp']),
        blockSites: _list(j['BlockSites']),
        blockIp: _list(j['BlockIp']),
        order: _order(j['RouteOrder']),
      );

  Map<String, dynamic> toJson() => {
        'Name': name,
        'GlobalProxy': '$globalProxy',
        'RouteOrder': order.map((a) => a.name).join('-'),
        'DirectSites': directSites,
        'DirectIp': directIp,
        'ProxySites': proxySites,
        'ProxyIp': proxyIp,
        'BlockSites': blockSites,
        'BlockIp': blockIp,
      };

  List<String> sitesOf(RouteAction a) => switch (a) {
        RouteAction.direct => directSites,
        RouteAction.proxy => proxySites,
        RouteAction.block => blockSites,
      };

  List<String> ipsOf(RouteAction a) => switch (a) {
        RouteAction.direct => directIp,
        RouteAction.proxy => proxyIp,
        RouteAction.block => blockIp,
      };

  int countOf(RouteAction a) => sitesOf(a).length + ipsOf(a).length;

  bool get isEmpty => RouteAction.values.every((a) => countOf(a) == 0);

  /// Rule-set tag of a `geosite:`/`geoip:` entry (`geosite-ru`, `geoip-ru`),
  /// or null when the entry is something else. `private` needs no list: the
  /// core knows private addresses itself.
  static String? ruleSetTag(String entry) {
    final m = RegExp(r'^(geosite|geoip):([A-Za-z0-9_.@!-]+)$').firstMatch(entry.trim());
    if (m == null) return null;
    final name = m.group(2)!.toLowerCase();
    if (name == 'private') return null;
    return '${m.group(1)}-$name';
  }

  /// Every rule-set this profile refers to.
  Set<String> get ruleSetTags => {
        for (final a in RouteAction.values)
          for (final e in [...sitesOf(a), ...ipsOf(a)])
            if (ruleSetTag(e) != null) ruleSetTag(e)!,
      };

  /// Where a rule-set is published in the core's binary format.
  static String ruleSetUrl(String tag) => tag.startsWith('geoip-')
      ? 'https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/$tag.srs'
      : 'https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/$tag.srs';

  static final _ip = RegExp(r'^(\d{1,3}(\.\d{1,3}){3}|[0-9a-fA-F:]*:[0-9a-fA-F:]*)(/\d{1,3})?$');

  /// Core route conditions for [action]. Rule-sets not in [available] are
  /// left out, so a list that could not be downloaded never stops the core.
  /// With [domainsOnly] address ranges are skipped (for DNS rules).
  Map<String, dynamic> conditions(RouteAction action,
      {required bool Function(String tag) available, bool domainsOnly = false}) {
    final out = <String, List<String>>{};
    void add(String key, String value) {
      final list = out.putIfAbsent(key, () => []);
      if (!list.contains(value)) list.add(value);
    }

    var private = false;
    for (final raw in [...sitesOf(action), if (!domainsOnly) ...ipsOf(action)]) {
      final entry = raw.trim();
      final tag = ruleSetTag(entry);
      if (tag != null) {
        if (domainsOnly && tag.startsWith('geoip-')) continue;
        if (available(tag)) add('rule_set', tag);
        continue;
      }
      final colon = entry.indexOf(':');
      final kind = colon > 0 ? entry.substring(0, colon).toLowerCase() : '';
      final value = colon > 0 ? entry.substring(colon + 1).trim() : entry;
      if (value.isEmpty) continue;
      if (kind == 'geosite' || kind == 'geoip') {
        // Only `private` gets here.
        if (!domainsOnly) private = true;
      } else if (kind == 'domain') {
        add('domain_suffix', value);
      } else if (kind == 'full') {
        add('domain', value);
      } else if (kind == 'keyword') {
        add('domain_keyword', value);
      } else if (kind == 'regexp') {
        add('domain_regex', value);
      } else if (kind.startsWith('ext')) {
        continue; // Refers to a file only the Xray core can read.
      } else if (_ip.hasMatch(entry)) {
        if (!domainsOnly) add('ip_cidr', entry);
      } else if (entry.contains('.') && !entry.contains(' ')) {
        add('domain_suffix', entry);
      } else {
        add('domain_keyword', entry);
      }
    }
    return {...out, if (private) 'ip_is_private': true};
  }
}
