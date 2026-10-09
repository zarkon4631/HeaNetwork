import 'profile.dart';

enum ConnectionMode {
  /// Local mixed proxy plus the Windows system proxy setting.
  systemProxy,

  /// Virtual adapter capturing all traffic. Needs admin on Windows.
  tun;

  static ConnectionMode parse(String? v) =>
      values.firstWhere((e) => e.name == v, orElse: () => systemProxy);
}

enum RouteAction {
  proxy,
  direct,
  block;

  static RouteAction parse(String? v, [RouteAction fallback = proxy]) =>
      values.firstWhere((e) => e.name == v, orElse: () => fallback);
}

/// Anti-DPI (TSPU) hardening. [preset] drives the toggles unless it is
/// [custom], in which case the individual fields are used as stored.
class AntiDpiSettings {
  AntiDpiSettings({
    this.preset = AntiDpiPreset.balanced,
    this.tlsFragment = false,
    this.tlsRecordFragment = true,
    this.fragmentFallbackDelayMs = 500,
    this.utlsFingerprint = 'chrome',
    this.directFragment = false,
    this.spoofSni = '',
    this.spoofMethod = 'wrong-sequence',
  });

  AntiDpiPreset preset;

  /// Split the TLS ClientHello across TCP segments.
  bool tlsFragment;

  /// Split the TLS ClientHello across TLS records (cheaper, try first).
  bool tlsRecordFragment;
  int fragmentFallbackDelayMs;

  /// Browser fingerprint forced onto TLS profiles that do not set one.
  /// Empty keeps the profile untouched.
  String utlsFingerprint;

  /// Also fragment TLS of traffic routed directly, which helps with sites
  /// that are throttled rather than blocked.
  bool directFragment;

  /// Forged ClientHello with a whitelisted SNI. Needs admin (WinDivert).
  String spoofSni;
  String spoofMethod;

  /// The effective toggles after applying [preset].
  AntiDpiSettings get effective => switch (preset) {
        AntiDpiPreset.off => AntiDpiSettings(
            preset: preset,
            tlsFragment: false,
            tlsRecordFragment: false,
            utlsFingerprint: '',
          ),
        AntiDpiPreset.balanced => AntiDpiSettings(
            preset: preset,
            tlsFragment: false,
            tlsRecordFragment: true,
            utlsFingerprint: 'chrome',
          ),
        AntiDpiPreset.strong => AntiDpiSettings(
            preset: preset,
            tlsFragment: true,
            tlsRecordFragment: true,
            utlsFingerprint: 'chrome',
            directFragment: true,
          ),
        AntiDpiPreset.custom => this,
      };

  Map<String, dynamic> toJson() => {
        'preset': preset.name,
        'tlsFragment': tlsFragment,
        'tlsRecordFragment': tlsRecordFragment,
        'fragmentFallbackDelayMs': fragmentFallbackDelayMs,
        'utlsFingerprint': utlsFingerprint,
        'directFragment': directFragment,
        'spoofSni': spoofSni,
        'spoofMethod': spoofMethod,
      };

  factory AntiDpiSettings.fromJson(Map<String, dynamic> j) => AntiDpiSettings(
        preset: AntiDpiPreset.values.firstWhere(
          (e) => e.name == j['preset'],
          orElse: () => AntiDpiPreset.balanced,
        ),
        tlsFragment: j['tlsFragment'] as bool? ?? false,
        tlsRecordFragment: j['tlsRecordFragment'] as bool? ?? true,
        fragmentFallbackDelayMs:
            (j['fragmentFallbackDelayMs'] as num?)?.toInt() ?? 500,
        utlsFingerprint: j['utlsFingerprint'] as String? ?? 'chrome',
        directFragment: j['directFragment'] as bool? ?? false,
        spoofSni: j['spoofSni'] as String? ?? '',
        spoofMethod: j['spoofMethod'] as String? ?? 'wrong-sequence',
      );
}

enum AntiDpiPreset { off, balanced, strong, custom }

/// How the delay of a server is measured.
enum PingMode {
  /// Time to open a TCP connection to the server itself. Quick, and needs
  /// nothing to be running. UDP protocols have no TCP port to knock on, so
  /// they are measured as [url] where that is possible.
  tcp,

  /// Time of a real request sent through the server.
  url;

  static PingMode parse(String? v) =>
      values.firstWhere((e) => e.name == v, orElse: () => tcp);
}

/// A DNS server offered by name in the settings. [value] is what the
/// config builder's `dnsServer` parses; [note] tells the choices apart.
class DnsPreset {
  const DnsPreset(this.name, this.value, [this.note = DnsNote.none]);
  final String name;
  final String value;
  final DnsNote note;
}

enum DnsNote { none, noAds, encrypted }

/// The DNS used through the VPN unless the user picks another. A plain
/// address: the query already travels inside the encrypted tunnel, and of
/// everything tried it gets the quickest answers.
const defaultRemoteDns = '8.8.8.8';

const remoteDnsPresets = [
  DnsPreset('Google', defaultRemoteDns),
  DnsPreset('Cloudflare', '1.1.1.1'),
  DnsPreset('Quad9', '9.9.9.9'),
  DnsPreset('AdGuard', '94.140.14.14', DnsNote.noAds),
  DnsPreset('Google DoH', 'https://8.8.8.8/dns-query', DnsNote.encrypted),
  DnsPreset('Cloudflare DoH', 'https://1.1.1.1/dns-query', DnsNote.encrypted),
];

/// For connections that bypass the VPN. `local` is whatever the system uses.
const defaultDirectDns = 'local';

const directDnsPresets = [
  DnsPreset('', defaultDirectDns),
  DnsPreset('Яндекс', '77.88.8.8'),
  DnsPreset('Google', '8.8.8.8'),
  DnsPreset('Cloudflare', '1.1.1.1'),
];

/// What closing the main window does.
enum CloseAction {
  /// Ask every time: cancel, quit or hide to the tray.
  ask,
  tray,
  exit,
}

const utlsFingerprints = [
  'chrome', 'firefox', 'edge', 'safari', 'ios', 'android', 'random',
  'randomized',
];

const spoofMethods = [
  'wrong-sequence', 'wrong-checksum', 'wrong-ack', 'wrong-md5',
  'wrong-timestamp',
];

/// A local port forwarded to a fixed destination through the VPN
/// (the client-side counterpart of a 3x-ui "tunnel" inbound).
class PortForward {
  PortForward({
    String? id,
    required this.listenPort,
    required this.targetHost,
    required this.targetPort,
    this.viaProxy = true,
    this.enabled = true,
  }) : id = id ?? newId();

  final String id;
  int listenPort;
  String targetHost;
  int targetPort;
  bool viaProxy;
  bool enabled;

  Map<String, dynamic> toJson() => {
        'id': id,
        'listenPort': listenPort,
        'targetHost': targetHost,
        'targetPort': targetPort,
        'viaProxy': viaProxy,
        'enabled': enabled,
      };

  factory PortForward.fromJson(Map<String, dynamic> j) => PortForward(
        id: j['id'] as String?,
        listenPort: (j['listenPort'] as num?)?.toInt() ?? 0,
        targetHost: j['targetHost'] as String? ?? '',
        targetPort: (j['targetPort'] as num?)?.toInt() ?? 0,
        viaProxy: j['viaProxy'] as bool? ?? true,
        enabled: j['enabled'] as bool? ?? true,
      );
}

class AppSettings {
  AppSettings({
    this.locale = 'system',
    this.themeMode = 'system',
    this.mode = ConnectionMode.systemProxy,
    this.mixedPort = 2080,
    this.allowLan = false,
    this.tunStack = 'mixed',
    this.tunMtu = 0,
    this.strictRoute = true,
    this.ipv6 = false,
    this.remoteDns = defaultRemoteDns,
    this.directDns = defaultDirectDns,
    this.fakeIp = false,
    AntiDpiSettings? antiDpi,
    this.autoConnect = false,
    this.launchAtStartup = false,
    this.closeAction = CloseAction.ask,
    this.compactView = false,
    this.animations = true,
    this.sendHwid = true,
    String? installId,
    this.checkUpdates = true,
    this.logLevel = 'info',
    this.pingMode = PingMode.tcp,
    this.ownServersCollapsed = false,
    List<PortForward>? portForwards,
    this.selectedProfileId,
  })  : antiDpi = antiDpi ?? AntiDpiSettings(),
        portForwards = portForwards ?? [],
        installId = installId ?? newId() + newId();

  String locale;
  String themeMode;
  ConnectionMode mode;
  int mixedPort;
  bool allowLan;
  String tunStack;

  /// 0 keeps the core default.
  int tunMtu;

  /// Blocks traffic that would escape the tunnel (kill switch for TUN mode).
  bool strictRoute;
  bool ipv6;
  String remoteDns;
  String directDns;
  bool fakeIp;
  AntiDpiSettings antiDpi;
  bool autoConnect;
  bool launchAtStartup;

  /// What the window's close button does (Windows).
  CloseAction closeAction;

  /// Shrinks the window to just the connect button and speeds (Windows).
  bool compactView;

  /// Moving background and transitions. Off saves power on weak devices.
  bool animations;

  /// Identify this device to the subscription server (3x-ui device limit).
  bool sendHwid;

  /// Random per-install id; the device id of last resort when the OS does
  /// not provide one.
  final String installId;
  bool checkUpdates;
  String logLevel;
  PingMode pingMode;

  /// The "my servers" group is folded in the list.
  bool ownServersCollapsed;
  List<PortForward> portForwards;

  /// The server to connect to.
  String? selectedProfileId;

  Map<String, dynamic> toJson() => {
        'locale': locale,
        'themeMode': themeMode,
        'mode': mode.name,
        'mixedPort': mixedPort,
        'allowLan': allowLan,
        'tunStack': tunStack,
        'tunMtu': tunMtu,
        'strictRoute': strictRoute,
        'ipv6': ipv6,
        'remoteDns': remoteDns,
        'directDns': directDns,
        'fakeIp': fakeIp,
        'antiDpi': antiDpi.toJson(),
        'autoConnect': autoConnect,
        'launchAtStartup': launchAtStartup,
        'closeAction': closeAction.name,
        'compactView': compactView,
        'animations': animations,
        'sendHwid': sendHwid,
        'installId': installId,
        'checkUpdates': checkUpdates,
        'logLevel': logLevel,
        'pingMode': pingMode.name,
        'ownServersCollapsed': ownServersCollapsed,
        'portForwards': portForwards.map((e) => e.toJson()).toList(),
        'selectedProfileId': selectedProfileId,
      };

  factory AppSettings.fromJson(Map<String, dynamic> j) => AppSettings(
        locale: j['locale'] as String? ?? 'system',
        themeMode: j['themeMode'] as String? ?? 'system',
        mode: ConnectionMode.parse(j['mode'] as String?),
        mixedPort: (j['mixedPort'] as num?)?.toInt() ?? 2080,
        allowLan: j['allowLan'] as bool? ?? false,
        tunStack: j['tunStack'] as String? ?? 'mixed',
        tunMtu: (j['tunMtu'] as num?)?.toInt() ?? 0,
        strictRoute: j['strictRoute'] as bool? ?? true,
        ipv6: j['ipv6'] as bool? ?? false,
        remoteDns: j['remoteDns'] as String? ?? defaultRemoteDns,
        directDns: j['directDns'] as String? ?? defaultDirectDns,
        fakeIp: j['fakeIp'] as bool? ?? false,
        antiDpi: j['antiDpi'] is Map
            ? AntiDpiSettings.fromJson(
                Map<String, dynamic>.from(j['antiDpi'] as Map))
            : null,
        autoConnect: j['autoConnect'] as bool? ?? false,
        launchAtStartup: j['launchAtStartup'] as bool? ?? false,
        closeAction: CloseAction.values.firstWhere(
          (e) => e.name == j['closeAction'],
          orElse: () => CloseAction.ask,
        ),
        compactView: j['compactView'] as bool? ?? false,
        animations: j['animations'] as bool? ?? true,
        sendHwid: j['sendHwid'] as bool? ?? true,
        installId: j['installId'] as String?,
        checkUpdates: j['checkUpdates'] as bool? ?? true,
        logLevel: j['logLevel'] as String? ?? 'info',
        pingMode: PingMode.parse(j['pingMode'] as String?),
        ownServersCollapsed: j['ownServersCollapsed'] as bool? ?? false,
        portForwards: (j['portForwards'] as List? ?? const [])
            .map((e) => PortForward.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
        selectedProfileId: j['selectedProfileId'] as String?,
      );
}

/// A per-application routing rule. On Windows the app is matched by
/// executable name (or full path); on Android by package name.
class AppRule {
  AppRule({
    String? id,
    required this.name,
    this.processName,
    this.processPath,
    this.matchByPath = false,
    this.packageName,
    this.action = RouteAction.direct,
    this.enabled = true,
  }) : id = id ?? newId();

  final String id;
  String name;

  /// Executable file name, e.g. `chrome.exe`. Matched case-insensitively.
  String? processName;

  /// Full path of the executable; kept for the icon and for [matchByPath].
  String? processPath;

  /// Match only this exact [processPath] instead of any exe named
  /// [processName]. Off by default because paths change on app updates.
  bool matchByPath;
  String? packageName;
  RouteAction action;
  bool enabled;

  /// Stable identity used to avoid adding the same app twice.
  String get matchKey =>
      packageName ??
      (matchByPath ? processPath : processName)?.toLowerCase() ??
      processPath?.toLowerCase() ??
      id;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        if (processName != null) 'processName': processName,
        if (processPath != null) 'processPath': processPath,
        if (matchByPath) 'matchByPath': true,
        if (packageName != null) 'packageName': packageName,
        'action': action.name,
        'enabled': enabled,
      };

  factory AppRule.fromJson(Map<String, dynamic> j) => AppRule(
        id: j['id'] as String?,
        name: j['name'] as String? ?? '',
        processName: j['processName'] as String?,
        processPath: j['processPath'] as String?,
        matchByPath: j['matchByPath'] as bool? ?? false,
        packageName: j['packageName'] as String?,
        action: RouteAction.parse(j['action'] as String?, RouteAction.direct),
        enabled: j['enabled'] as bool? ?? true,
      );
}

enum DomainRuleKind {
  domainSuffix('domain_suffix'),
  domain('domain'),
  domainKeyword('domain_keyword'),
  ipCidr('ip_cidr');

  const DomainRuleKind(this.key);
  final String key;

  static DomainRuleKind parse(String? v) =>
      values.firstWhere((e) => e.name == v, orElse: () => domainSuffix);
}

class DomainRule {
  DomainRule({
    String? id,
    required this.kind,
    required this.value,
    this.action = RouteAction.direct,
    this.enabled = true,
  }) : id = id ?? newId();

  final String id;
  DomainRuleKind kind;
  String value;
  RouteAction action;
  bool enabled;

  /// Guesses the rule kind from what the user typed: a CIDR/IP, a full
  /// domain, or a bare keyword.
  factory DomainRule.guess(String input, RouteAction action) {
    final v = input.trim().toLowerCase();
    final isIp = RegExp(r'^\d{1,3}(\.\d{1,3}){3}(/\d{1,2})?$').hasMatch(v) ||
        (v.contains(':') && RegExp(r'^[0-9a-f:]+(/\d{1,3})?$').hasMatch(v));
    if (isIp) {
      final cidr = v.contains('/') ? v : (v.contains(':') ? '$v/128' : '$v/32');
      return DomainRule(kind: DomainRuleKind.ipCidr, value: cidr, action: action);
    }
    final host = v
        .replaceFirst(RegExp(r'^[a-z]+://'), '')
        .replaceFirst(RegExp(r'[/:?#].*$'), '')
        .replaceFirst(RegExp(r'^\*?\.'), '');
    if (host.contains('.')) {
      return DomainRule(
          kind: DomainRuleKind.domainSuffix, value: host, action: action);
    }
    return DomainRule(
        kind: DomainRuleKind.domainKeyword, value: host, action: action);
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind.name,
        'value': value,
        'action': action.name,
        'enabled': enabled,
      };

  factory DomainRule.fromJson(Map<String, dynamic> j) => DomainRule(
        id: j['id'] as String?,
        kind: DomainRuleKind.parse(j['kind'] as String?),
        value: j['value'] as String? ?? '',
        action: RouteAction.parse(j['action'] as String?, RouteAction.direct),
        enabled: j['enabled'] as bool? ?? true,
      );
}

class RoutingSettings {
  RoutingSettings({
    this.defaultAction = RouteAction.proxy,
    List<AppRule>? apps,
    List<DomainRule>? domains,
    this.ruDirect = false,
    this.blockAds = false,
  })  : apps = apps ?? [],
        domains = domains ?? [];

  /// Where traffic goes when no rule matches: [RouteAction.proxy] sends
  /// everything through the VPN, [RouteAction.direct] only what rules select.
  RouteAction defaultAction;
  List<AppRule> apps;
  List<DomainRule> domains;

  /// Russian sites and addresses bypass the VPN.
  bool ruDirect;
  bool blockAds;

  Map<String, dynamic> toJson() => {
        'defaultAction': defaultAction.name,
        'apps': apps.map((e) => e.toJson()).toList(),
        'domains': domains.map((e) => e.toJson()).toList(),
        'ruDirect': ruDirect,
        'blockAds': blockAds,
      };

  factory RoutingSettings.fromJson(Map<String, dynamic> j) => RoutingSettings(
        defaultAction: RouteAction.parse(j['defaultAction'] as String?),
        apps: (j['apps'] as List? ?? const [])
            .map((e) => AppRule.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
        domains: (j['domains'] as List? ?? const [])
            .map((e) => DomainRule.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
        ruDirect: j['ruDirect'] as bool? ?? false,
        blockAds: j['blockAds'] as bool? ?? false,
      );
}
