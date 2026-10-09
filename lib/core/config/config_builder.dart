import 'dart:convert';

import '../models/profile.dart';
import '../models/settings.dart';

enum CorePlatform { windows, android }

/// Everything about the host the config depends on.
class BuildEnv {
  const BuildEnv({
    required this.platform,
    required this.ruleSetDir,
    required this.cacheFile,
    required this.clashPort,
    required this.clashSecret,
    this.elevated = false,
    this.corePath,
    this.mixedPort,
    this.ruleSets,
    this.logFile,
  });

  final CorePlatform platform;

  /// Directory holding the bundled `.srs` rule-sets.
  final String ruleSetDir;

  /// Tags of the rule-sets actually present in [ruleSetDir]; null means all.
  /// A config that names a missing file would not start.
  final Set<String>? ruleSets;
  final String cacheFile;
  final int clashPort;
  final String clashSecret;

  /// Running as administrator (Windows). Required for TUN and SNI spoofing.
  final bool elevated;

  /// Path of the core executable, used to keep helper core instances out of
  /// the tunnel.
  final String? corePath;

  /// Overrides the configured mixed port, e.g. when it is already taken.
  final int? mixedPort;

  /// Where the core writes its log when its output cannot be captured
  /// directly (Android, where it runs inside a service).
  final String? logFile;
}

const tagProxy = 'proxy';
const tagDirect = 'direct';
const tagDnsRemote = 'dns-remote';
const tagDnsDirect = 'dns-direct';
const tagDnsFake = 'dns-fake';

const ruleSetRuSite = 'geosite-category-ru';
const ruleSetRuIp = 'geoip-ru';
const ruleSetAds = 'geosite-category-ads-all';

/// Zones that are Russian by definition; the rule-sets cover the rest.
const ruDomainSuffixes = ['.ru', '.su', '.xn--p1ai', '.moscow', '.tatar'];

const urlTestTarget = 'https://www.gstatic.com/generate_204';

String profileTag(ProxyProfile p) => 'p-${p.id}';

/// Returns [profile]'s outbound with the anti-DPI options merged in.
/// TLS tricks only make sense for TLS over TCP, so UDP-based protocols and
/// plain connections come back unchanged.
Map<String, dynamic> hardenOutbound(
  ProxyProfile profile,
  AntiDpiSettings antiDpi, {
  bool elevated = false,
  CorePlatform platform = CorePlatform.windows,
}) {
  final out = jsonDecode(jsonEncode(profile.outbound)) as Map<String, dynamic>;
  final a = antiDpi.effective;

  // On Windows the core's default UDP bind zeroes bytes 1..3 of every
  // received datagram (WireGuard's "reserved" field). AmneziaWG stores its
  // custom H1-H4 headers there, so any header above 255 that is not shifted
  // by an S1-S4 padding is destroyed and the tunnel never passes data.
  // Dialing through the direct outbound selects the other bind, which
  // leaves the datagram alone.
  if (platform == CorePlatform.windows &&
      out['type'] == 'wireguard' &&
      out['amnezia'] is Map) {
    out['detour'] = tagDirect;
  }

  final tls = out['tls'];
  if (tls is! Map<String, dynamic> || tls['enabled'] != true) return out;
  if (profile.isUdpBased) return out;
  final alpn = tls['alpn'];
  if (alpn is List && alpn.length == 1 && alpn.first == 'h3') return out;

  if (a.tlsRecordFragment) tls['record_fragment'] = true;
  // The preset only ever adds: whatever the profile itself asked for (for
  // example fragmentation requested by the server's own settings) stays.
  if (a.tlsFragment) {
    tls['fragment'] = true;
    tls['fragment_fallback_delay'] ??= '${a.fragmentFallbackDelayMs}ms';
  }
  // uTLS cannot be combined with ECH in the core.
  if (a.utlsFingerprint.isNotEmpty && tls['utls'] == null && tls['ech'] == null) {
    tls['utls'] = {'enabled': true, 'fingerprint': a.utlsFingerprint};
  }
  if (a.spoofSni.isNotEmpty && elevated && platform == CorePlatform.windows) {
    tls['spoof'] = a.spoofSni;
    tls['spoof_method'] = a.spoofMethod;
  }
  return out;
}

/// Parses a DNS server spec (`local`, `1.1.1.1`, `https://host/path`,
/// `tls://host`, `quic://host`, `h3://host/path`, `tcp://host`).
/// With [preferTcp] a bare address is asked over TCP instead of UDP.
Map<String, dynamic> dnsServer(String spec, String tag,
    {String? detour, bool preferTcp = false}) {
  final s = spec.trim();
  final base = <String, dynamic>{'tag': tag};
  if (s.isEmpty || s == 'local' || s == 'system') {
    return {...base, 'type': 'local'};
  }
  final m = RegExp(r'^([a-z0-9]+)://(.+)$', caseSensitive: false).firstMatch(s);
  var type = 'udp';
  var rest = s;
  if (m != null) {
    type = m.group(1)!.toLowerCase();
    rest = m.group(2)!;
  }
  var path = '';
  final slash = rest.indexOf('/');
  if (slash >= 0) {
    path = rest.substring(slash);
    rest = rest.substring(0, slash);
  }
  String host = rest;
  int? port;
  final bracket = RegExp(r'^\[(.+)\](?::(\d+))?$').firstMatch(rest);
  if (bracket != null) {
    host = bracket.group(1)!;
    port = int.tryParse(bracket.group(2) ?? '');
  } else if (':'.allMatches(rest).length == 1) {
    host = rest.substring(0, rest.indexOf(':'));
    port = int.tryParse(rest.substring(rest.indexOf(':') + 1));
  }
  if (!const {'udp', 'tcp', 'tls', 'https', 'quic', 'h3'}.contains(type)) {
    type = 'udp';
  }
  if (preferTcp && type == 'udp') type = 'tcp';
  return {
    ...base,
    'type': type,
    'server': host,
    'server_port': ?port,
    if ((type == 'https' || type == 'h3') && path.isNotEmpty && path != '/dns-query')
      'path': path,
    'detour': ?detour,
  };
}

/// Builds sing-box route conditions matching [apps] on [platform].
Map<String, dynamic> appConditions(List<AppRule> apps, CorePlatform platform) {
  if (platform == CorePlatform.android) {
    final packages = [
      for (final a in apps)
        if (a.packageName?.isNotEmpty ?? false) a.packageName!,
    ];
    return packages.isEmpty ? {} : {'package_name': packages};
  }
  final paths = <String>[];
  final regexes = <String>[];
  for (final a in apps) {
    if (a.matchByPath && (a.processPath?.isNotEmpty ?? false)) {
      paths.add(a.processPath!);
    } else if (a.processName?.isNotEmpty ?? false) {
      // Windows file names are case-insensitive; the core compares exactly.
      regexes.add('(?i)(^|[\\\\/])${RegExp.escape(a.processName!)}\$');
    }
  }
  return {
    if (paths.isNotEmpty) 'process_path': paths,
    if (regexes.isNotEmpty) 'process_path_regex': regexes,
  };
}

Map<String, dynamic> _domainConditions(Iterable<DomainRule> rules,
    {bool domainsOnly = false}) {
  final out = <String, List<String>>{};
  for (final r in rules) {
    if (r.value.trim().isEmpty) continue;
    if (domainsOnly && r.kind == DomainRuleKind.ipCidr) continue;
    out.putIfAbsent(r.kind.key, () => []).add(r.value.trim());
  }
  return out;
}

/// Builds the full core config for connecting through [profiles]. With one
/// profile it is used directly; with several they are wrapped in a urltest
/// group that keeps the fastest one selected.
///
/// [serverDomains] are the host names of all the user's servers, connected
/// or not; they matter only with FakeIP (see below).
Map<String, dynamic> buildConfig({
  required List<ProxyProfile> profiles,
  required AppSettings settings,
  required RoutingSettings routing,
  required BuildEnv env,
  Iterable<String> serverDomains = const [],
}) {
  if (profiles.isEmpty) throw ArgumentError('no profile to connect with');

  final isAndroid = env.platform == CorePlatform.android;
  final tun = isAndroid || settings.mode == ConnectionMode.tun;
  final antiDpi = settings.antiDpi.effective;
  final proxyDefault = routing.defaultAction == RouteAction.proxy;

  // ---- outbounds / endpoints -------------------------------------------
  final outbounds = <Map<String, dynamic>>[];
  final endpoints = <Map<String, dynamic>>[];
  void addProfile(ProxyProfile p, String tag) {
    final o = hardenOutbound(p, settings.antiDpi,
        elevated: env.elevated, platform: env.platform)
      ..['tag'] = tag;
    (p.isEndpoint ? endpoints : outbounds).add(o);
  }

  if (profiles.length == 1) {
    addProfile(profiles.single, tagProxy);
  } else {
    for (final p in profiles) {
      addProfile(p, profileTag(p));
    }
    outbounds.add({
      'type': 'urltest',
      'tag': tagProxy,
      'outbounds': profiles.map(profileTag).toList(),
      'url': urlTestTarget,
      'interval': '3m',
      'tolerance': 50,
    });
  }
  outbounds.add({'type': 'direct', 'tag': tagDirect});

  // ---- inbounds ---------------------------------------------------------
  final inbounds = <Map<String, dynamic>>[
    {
      'type': 'mixed',
      'tag': 'mixed-in',
      'listen': settings.allowLan ? '0.0.0.0' : '127.0.0.1',
      'listen_port': env.mixedPort ?? settings.mixedPort,
    },
  ];

  final apps = routing.apps.where((a) => a.enabled).toList();
  List<AppRule> appsWith(RouteAction action) =>
      apps.where((a) => a.action == action).toList();

  if (tun) {
    final t = <String, dynamic>{
      'type': 'tun',
      'tag': 'tun-in',
      // IPv6 is always captured so it cannot leak; it is rejected by a
      // route rule when disabled. The subnet deliberately differs from
      // sing-box's default 172.19.0.1/30 that most other clients use.
      'address': ['172.29.117.1/30', 'fdfe:dcba:9877::1/126'],
      'auto_route': true,
      'strict_route': settings.strictRoute,
      'stack': settings.tunStack,
      if (settings.tunMtu > 0) 'mtu': settings.tunMtu,
    };
    if (isAndroid) {
      // Let the OS keep apps out of (or pull them into) the tunnel. Apps
      // excluded this way do not see a VPN at all, which matters for
      // banking apps that refuse to work behind one.
      if (proxyDefault) {
        final direct = appConditions(appsWith(RouteAction.direct), env.platform);
        if (direct.isNotEmpty) t['exclude_package'] = direct['package_name'];
      } else {
        final included = appConditions(
          apps.where((a) => a.action != RouteAction.direct).toList(),
          env.platform,
        );
        if (included.isNotEmpty) t['include_package'] = included['package_name'];
      }
    }
    inbounds.add(t);
  }

  final forwards = settings.portForwards
      .where((f) => f.enabled && f.listenPort > 0 && f.targetHost.isNotEmpty)
      .toList();
  for (final f in forwards) {
    inbounds.add({
      'type': 'direct',
      'tag': 'fwd-${f.id}',
      'listen': '127.0.0.1',
      'listen_port': f.listenPort,
      'override_address': f.targetHost,
      'override_port': f.targetPort,
    });
  }

  // ---- route rules ------------------------------------------------------
  // Options merged into rules that send TLS traffic out directly.
  final directExtras = <String, dynamic>{
    if (antiDpi.directFragment && antiDpi.tlsRecordFragment)
      'tls_record_fragment': true,
    if (antiDpi.directFragment && antiDpi.tlsFragment) ...{
      'tls_fragment': true,
      'tls_fragment_fallback_delay': '${antiDpi.fragmentFallbackDelayMs}ms',
    },
  };
  Map<String, dynamic> routeTo(RouteAction action) => switch (action) {
        RouteAction.block => {'action': 'reject'},
        RouteAction.direct => {
            'action': 'route',
            'outbound': tagDirect,
            ...directExtras,
          },
        RouteAction.proxy => {'action': 'route', 'outbound': tagProxy},
      };

  final rules = <Map<String, dynamic>>[
    {'action': 'sniff'},
    {
      'type': 'logical',
      'mode': 'or',
      'rules': [
        {'protocol': 'dns'},
        {'port': 53},
      ],
      'action': 'hijack-dns',
    },
    {'ip_is_private': true, 'action': 'route', 'outbound': tagDirect},
  ];

  if (!settings.ipv6 && tun) {
    rules.add({'ip_version': 6, 'action': 'reject'});
  }

  for (final f in forwards) {
    rules.add({
      'inbound': 'fwd-${f.id}',
      'action': 'route',
      'outbound': f.viaProxy ? tagProxy : tagDirect,
    });
  }

  if (env.platform == CorePlatform.windows && env.corePath != null) {
    // A second core instance (latency tests) must measure the real network,
    // not a path through this tunnel.
    rules.add({
      'process_path': [env.corePath],
      'action': 'route',
      'outbound': tagDirect,
    });
  }

  for (final action in [RouteAction.block, RouteAction.direct, RouteAction.proxy]) {
    final cond = appConditions(appsWith(action), env.platform);
    if (cond.isNotEmpty) rules.add({...cond, ...routeTo(action)});
  }

  final domains = routing.domains.where((d) => d.enabled).toList();
  for (final action in [RouteAction.block, RouteAction.direct, RouteAction.proxy]) {
    final cond = _domainConditions(domains.where((d) => d.action == action));
    if (cond.isNotEmpty) rules.add({...cond, ...routeTo(action)});
  }

  final ruleSets = <Map<String, dynamic>>[];
  bool have(String tag) => env.ruleSets?.contains(tag) ?? true;
  void useRuleSet(String tag) => ruleSets.add({
        'type': 'local',
        'tag': tag,
        'format': 'binary',
        'path': '${env.ruleSetDir}/$tag.srs',
      });

  final blockAds = routing.blockAds && have(ruleSetAds);
  if (blockAds) {
    useRuleSet(ruleSetAds);
    rules.add({'rule_set': [ruleSetAds], 'action': 'reject'});
  }
  final ruSets = [ruleSetRuSite, ruleSetRuIp].where(have).toList();
  if (routing.ruDirect) {
    ruSets.forEach(useRuleSet);
    rules.add({
      'domain_suffix': ruDomainSuffixes,
      if (ruSets.isNotEmpty) 'rule_set': ruSets,
      ...routeTo(RouteAction.direct),
    });
  }
  if (!proxyDefault && directExtras.isNotEmpty) {
    // `final` cannot carry options, so catch the remaining TCP explicitly.
    rules.add({'network': 'tcp', ...routeTo(RouteAction.direct)});
  }

  // ---- dns --------------------------------------------------------------
  // An HTTP proxy cannot carry UDP and a SOCKS one often will not, which
  // is what a bare DNS address would need; TCP gets through both.
  final proxyCarriesUdp = profiles
      .every((p) => p.type != Protocol.http && p.type != Protocol.socks);
  final dnsServers = <Map<String, dynamic>>[
    dnsServer(settings.remoteDns, tagDnsRemote,
        detour: tagProxy, preferTcp: !proxyCarriesUdp),
    dnsServer(settings.directDns, tagDnsDirect),
  ];
  final dnsRules = <Map<String, dynamic>>[];
  final blockedDomains = _domainConditions(
      domains.where((d) => d.action == RouteAction.block),
      domainsOnly: true);
  if (blockedDomains.isNotEmpty) {
    dnsRules.add({...blockedDomains, 'action': 'reject'});
  }
  if (blockAds) {
    dnsRules.add({'rule_set': [ruleSetAds], 'action': 'reject'});
  }
  final directDomains = _domainConditions(
      domains.where((d) => d.action == RouteAction.direct),
      domainsOnly: true);
  if (directDomains.isNotEmpty) {
    dnsRules.add({...directDomains, 'action': 'route', 'server': tagDnsDirect});
  }
  if (routing.ruDirect) {
    dnsRules.add({
      'domain_suffix': ruDomainSuffixes,
      if (have(ruleSetRuSite)) 'rule_set': [ruleSetRuSite],
      'action': 'route',
      'server': tagDnsDirect,
    });
  }
  final useFakeIp = settings.fakeIp && tun;
  if (useFakeIp) {
    dnsServers.add({
      'type': 'fakeip',
      'tag': tagDnsFake,
      'inet4_range': '198.18.0.0/15',
      'inet6_range': 'fc00::/18',
    });
    // The user's own servers keep their real addresses, so the delay test
    // can still reach them directly while the tunnel is up.
    final own = serverDomains.where((d) => d.isNotEmpty).toSet().toList()..sort();
    if (own.isNotEmpty) {
      dnsRules.add({'domain': own, 'action': 'route', 'server': tagDnsDirect});
    }
    dnsRules.add({
      'query_type': ['A', 'AAAA'],
      'action': 'route',
      'server': tagDnsFake,
    });
  }

  return {
    'log': {
      'level': settings.logLevel,
      'timestamp': true,
      'output': ?env.logFile,
    },
    'dns': {
      'servers': dnsServers,
      if (dnsRules.isNotEmpty) 'rules': dnsRules,
      // With "only selected apps through VPN" the bulk of traffic is direct,
      // so name resolution must not depend on the VPN server being up.
      'final': proxyDefault ? tagDnsRemote : tagDnsDirect,
      'strategy': settings.ipv6 ? 'prefer_ipv4' : 'ipv4_only',
    },
    'inbounds': inbounds,
    'outbounds': outbounds,
    if (endpoints.isNotEmpty) 'endpoints': endpoints,
    'route': {
      'rules': rules,
      if (ruleSets.isNotEmpty) 'rule_set': ruleSets,
      'final': proxyDefault ? tagProxy : tagDirect,
      'auto_detect_interface': true,
      'default_domain_resolver': tagDnsDirect,
      if (apps.isNotEmpty) 'find_process': true,
    },
    'experimental': {
      'cache_file': {
        'enabled': true,
        'path': env.cacheFile,
        if (useFakeIp) 'store_fakeip': true,
      },
      'clash_api': {
        'external_controller': '127.0.0.1:${env.clashPort}',
        'secret': env.clashSecret,
      },
    },
  };
}

/// A config with no inbounds whose only job is to expose [profiles] to the
/// Clash API so their delay can be measured without connecting.
Map<String, dynamic> buildLatencyTestConfig({
  required List<ProxyProfile> profiles,
  required AntiDpiSettings antiDpi,
  required int clashPort,
  required String clashSecret,
  bool elevated = false,
  CorePlatform platform = CorePlatform.windows,
}) {
  final outbounds = <Map<String, dynamic>>[
    {'type': 'direct', 'tag': tagDirect},
  ];
  final endpoints = <Map<String, dynamic>>[];
  for (final p in profiles) {
    final o = hardenOutbound(p, antiDpi, elevated: elevated, platform: platform)
      ..['tag'] = profileTag(p);
    (p.isEndpoint ? endpoints : outbounds).add(o);
  }
  return {
    'log': {'level': 'error'},
    'dns': {
      'servers': [
        {'type': 'local', 'tag': tagDnsDirect},
      ],
    },
    'outbounds': outbounds,
    if (endpoints.isNotEmpty) 'endpoints': endpoints,
    'route': {
      'final': tagDirect,
      'auto_detect_interface': true,
      'default_domain_resolver': tagDnsDirect,
    },
    'experimental': {
      'clash_api': {
        'external_controller': '127.0.0.1:$clashPort',
        'secret': clashSecret,
      },
    },
  };
}
