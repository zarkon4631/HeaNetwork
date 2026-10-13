import 'dart:convert';

import '../models/panel_routing.dart';
import '../models/profile.dart';
import '../models/settings.dart';
import 'rule_values.dart';

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

/// The tunnel's own IPv4 address. The subnet deliberately differs from
/// sing-box's default 172.19.0.1/30, which most other clients use.
const tunAddress4 = '172.29.117.1/30';

/// The address next to it, which the core keeps for itself: it answers DNS
/// there, and takes any TCP connection made to it. That makes it the place
/// to find out whether the tunnel takes connections at all.
const tunPeer4 = '172.29.117.2';

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
    } else {
      // Windows file names are case-insensitive; the core compares exactly.
      // A group rule covers every executable of its program.
      for (final name in a.processNames) {
        regexes.add('(?i)(^|[\\\\/])${RegExp.escape(name)}\$');
      }
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
    if (r.kind == DomainRuleKind.ipCidr) {
      // A range the core cannot read would keep it from starting at all.
      if (domainsOnly || !isCoreAddress(r.value)) continue;
    }
    out.putIfAbsent(r.kind.key, () => []).add(r.value.trim());
  }
  return out;
}

/// Builds the full core config for connecting through [profile].
///
/// [serverDomains] are the host names of all the user's servers, connected
/// or not; they matter only with FakeIP (see [_Plan.dns]).
Map<String, dynamic> buildConfig({
  required ProxyProfile profile,
  required AppSettings settings,
  required RoutingSettings routing,
  required BuildEnv env,
  Iterable<String> serverDomains = const [],
  PanelRouting? panel,
}) {
  final plan = _Plan(profile, settings, routing, env, panel);

  final proxy = hardenOutbound(profile, settings.antiDpi,
      elevated: env.elevated, platform: env.platform)
    ..['tag'] = tagProxy;
  final inbounds = plan.inbounds();
  // The rules before anything that lists the site lists: they name them.
  final rules = plan.routeRules();
  final dns = plan.dns(serverDomains);

  return {
    'log': {
      'level': settings.logLevel,
      'timestamp': true,
      'output': ?env.logFile,
    },
    'dns': {
      'servers': dns.servers,
      if (dns.rules.isNotEmpty) 'rules': dns.rules,
      // With "only selected apps through VPN" the bulk of traffic is direct,
      // so name resolution must not depend on the VPN server being up.
      'final': plan.proxyDefault ? tagDnsRemote : tagDnsDirect,
      'strategy': settings.ipv6 ? 'prefer_ipv4' : 'ipv4_only',
    },
    'inbounds': inbounds,
    // To the core a WireGuard server is an endpoint, the rest are outbounds.
    'outbounds': [
      if (!profile.isEndpoint) proxy,
      {'type': 'direct', 'tag': tagDirect},
    ],
    if (profile.isEndpoint) 'endpoints': [proxy],
    'route': {
      'rules': rules,
      if (plan.ruleSets.isNotEmpty) 'rule_set': plan.ruleSets,
      'final': plan.proxyDefault ? tagProxy : tagDirect,
      'auto_detect_interface': true,
      'default_domain_resolver': tagDnsDirect,
      if (plan.apps.isNotEmpty) 'find_process': true,
    },
    'experimental': {
      'cache_file': {
        'enabled': true,
        'path': env.cacheFile,
        if (plan.useFakeIp) 'store_fakeip': true,
      },
      'clash_api': {
        'external_controller': '127.0.0.1:${env.clashPort}',
        'secret': env.clashSecret,
      },
    },
  };
}

/// A config in the making: what its parts (the inbounds, the route rules,
/// the DNS) all go by, worked out once.
class _Plan {
  _Plan(this.profile, this.settings, this.routing, this.env, this.panel);

  final ProxyProfile profile;
  final AppSettings settings;
  final RoutingSettings routing;
  final BuildEnv env;
  final PanelRouting? panel;

  bool get isAndroid => env.platform == CorePlatform.android;
  late final bool tun = isAndroid || settings.mode == ConnectionMode.tun;
  late final bool useFakeIp = settings.fakeIp && tun;
  late final AntiDpiSettings antiDpi = settings.antiDpi.effective;

  /// Where traffic that no rule matches goes. A profile from the panel
  /// says that as well.
  late final bool proxyDefault =
      panel?.globalProxy ?? (routing.defaultAction == RouteAction.proxy);

  late final List<AppRule> apps = routing.apps.where((a) => a.enabled).toList();
  late final List<DomainRule> domains = routing.domains.where((d) => d.enabled).toList();
  late final List<PortForward> forwards = settings.portForwards
      .where((f) => f.enabled && f.listenPort > 0 && f.targetHost.isNotEmpty)
      .toList();

  List<AppRule> appsWith(RouteAction action) =>
      apps.where((a) => a.action == action).toList();

  Iterable<DomainRule> domainsWith(RouteAction action) =>
      domains.where((d) => d.action == action);

  // ---- lists of sites ---------------------------------------------------

  /// The lists the route rules refer to, in the order they first did. Each
  /// has to be declared: a config naming a list it does not have would not
  /// start.
  final ruleSets = <Map<String, dynamic>>[];
  final _declared = <String>{};

  /// Whether the list is on this device.
  bool have(String tag) => env.ruleSets?.contains(tag) ?? true;

  void useRuleSet(String tag) {
    if (!_declared.add(tag)) return;
    ruleSets.add({
      'type': 'local',
      'tag': tag,
      'format': 'binary',
      'path': '${env.ruleSetDir}/$tag.srs',
    });
  }

  late final bool blockAds = routing.blockAds && have(ruleSetAds);

  // ---- where a rule sends traffic ---------------------------------------

  /// Options merged into rules that send TLS traffic out directly.
  late final Map<String, dynamic> directExtras = {
    if (antiDpi.directFragment && antiDpi.tlsRecordFragment) 'tls_record_fragment': true,
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

  /// The order the user's rules of one kind are written in: what is blocked
  /// is not let through by a rule that comes after it.
  static const _byPrecedence = [RouteAction.block, RouteAction.direct, RouteAction.proxy];

  // ---- inbounds ---------------------------------------------------------

  List<Map<String, dynamic>> inbounds() => [
        {
          'type': 'mixed',
          'tag': 'mixed-in',
          'listen': settings.allowLan ? '0.0.0.0' : '127.0.0.1',
          'listen_port': env.mixedPort ?? settings.mixedPort,
        },
        if (tun) _tunInbound(),
        for (final f in forwards)
          {
            'type': 'direct',
            'tag': 'fwd-${f.id}',
            'listen': '127.0.0.1',
            'listen_port': f.listenPort,
            'override_address': f.targetHost,
            'override_port': f.targetPort,
          },
      ];

  Map<String, dynamic> _tunInbound() {
    final t = <String, dynamic>{
      'type': 'tun',
      'tag': 'tun-in',
      // IPv6 is always captured so it cannot leak; it is rejected by a
      // route rule when disabled.
      'address': [tunAddress4, 'fdfe:dcba:9877::1/126'],
      'auto_route': true,
      'strict_route': settings.strictRoute,
      'stack': settings.tunStack,
      if (settings.tunMtu > 0) 'mtu': settings.tunMtu,
    };
    if (!isAndroid) return t;
    // Let the OS keep apps out of (or pull them into) the tunnel. Apps
    // excluded this way do not see a VPN at all, which matters for
    // banking apps that refuse to work behind one.
    if (proxyDefault) {
      final direct = appConditions(appsWith(RouteAction.direct), env.platform);
      if (direct.isNotEmpty) t['exclude_package'] = direct['package_name'];
    } else {
      final included = appConditions(
          apps.where((a) => a.action != RouteAction.direct).toList(), env.platform);
      if (included.isNotEmpty) t['include_package'] = included['package_name'];
    }
    return t;
  }

  // ---- route rules ------------------------------------------------------

  List<Map<String, dynamic>> routeRules() {
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
      if (!settings.ipv6 && tun) {'ip_version': 6, 'action': 'reject'},
      for (final f in forwards)
        {
          'inbound': 'fwd-${f.id}',
          'action': 'route',
          'outbound': f.viaProxy ? tagProxy : tagDirect,
        },
      // A second core instance (latency tests) must measure the real
      // network, not a path through this tunnel.
      if (env.platform == CorePlatform.windows && env.corePath != null)
        {
          'process_path': [env.corePath],
          'action': 'route',
          'outbound': tagDirect,
        },
    ];

    // The user's own rules: programs, then sites.
    for (final action in _byPrecedence) {
      final cond = appConditions(appsWith(action), env.platform);
      if (cond.isNotEmpty) rules.add({...cond, ...routeTo(action)});
    }
    for (final action in _byPrecedence) {
      final cond = _domainConditions(domainsWith(action));
      if (cond.isNotEmpty) rules.add({...cond, ...routeTo(action)});
    }

    // The panel's rules come after the user's own, which therefore win.
    final panel = this.panel;
    if (panel != null) {
      for (final action in panel.order) {
        final cond = panel.conditions(action, available: have);
        if (cond.isEmpty) continue;
        (cond['rule_set'] as List<String>? ?? const []).forEach(useRuleSet);
        rules.add({...cond, ...routeTo(action)});
      }
    }

    if (blockAds) {
      useRuleSet(ruleSetAds);
      rules.add({'rule_set': [ruleSetAds], 'action': 'reject'});
    }
    if (routing.ruDirect) {
      final ruSets = [ruleSetRuSite, ruleSetRuIp].where(have).toList();
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
    return rules;
  }

  // ---- dns --------------------------------------------------------------

  /// The DNS servers and the rules that pick one. Called after
  /// [routeRules], which declares the lists these rules also go by.
  ///
  /// [serverDomains] keep their real addresses under FakeIP, so the delay
  /// test can still reach the user's servers while the tunnel is up.
  ({List<Map<String, dynamic>> servers, List<Map<String, dynamic>> rules}) dns(
      Iterable<String> serverDomains) {
    // An HTTP proxy cannot carry UDP and a SOCKS one often will not, which
    // is what a bare DNS address would need; TCP gets through both.
    final proxyCarriesUdp =
        profile.type != Protocol.http && profile.type != Protocol.socks;
    final servers = <Map<String, dynamic>>[
      dnsServer(settings.remoteDns, tagDnsRemote,
          detour: tagProxy, preferTcp: !proxyCarriesUdp),
      dnsServer(settings.directDns, tagDnsDirect),
    ];
    final rules = <Map<String, dynamic>>[];

    final blocked = _domainConditions(domainsWith(RouteAction.block), domainsOnly: true);
    if (blocked.isNotEmpty) rules.add({...blocked, 'action': 'reject'});
    if (blockAds) {
      rules.add({'rule_set': [ruleSetAds], 'action': 'reject'});
    }
    final direct = _domainConditions(domainsWith(RouteAction.direct), domainsOnly: true);
    if (direct.isNotEmpty) {
      rules.add({...direct, 'action': 'route', 'server': tagDnsDirect});
    }

    final panel = this.panel;
    if (panel != null) {
      final panelBlocked =
          panel.conditions(RouteAction.block, available: have, domainsOnly: true);
      if (panelBlocked.isNotEmpty) rules.add({...panelBlocked, 'action': 'reject'});
      // Names that go out directly are also resolved directly, so a local
      // service gets the address meant for local visitors.
      final panelDirect =
          panel.conditions(RouteAction.direct, available: have, domainsOnly: true);
      if (panelDirect.isNotEmpty) {
        rules.add({...panelDirect, 'action': 'route', 'server': tagDnsDirect});
      }
    }
    if (routing.ruDirect) {
      rules.add({
        'domain_suffix': ruDomainSuffixes,
        if (have(ruleSetRuSite)) 'rule_set': [ruleSetRuSite],
        'action': 'route',
        'server': tagDnsDirect,
      });
    }

    if (useFakeIp) {
      servers.add({
        'type': 'fakeip',
        'tag': tagDnsFake,
        'inet4_range': '198.18.0.0/15',
        'inet6_range': 'fc00::/18',
      });
      final own = serverDomains.where((d) => d.isNotEmpty).toSet().toList()..sort();
      if (own.isNotEmpty) {
        rules.add({'domain': own, 'action': 'route', 'server': tagDnsDirect});
      }
      rules.add({
        'query_type': ['A', 'AAAA'],
        'action': 'route',
        'server': tagDnsFake,
      });
    }
    return (servers: servers, rules: rules);
  }
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
