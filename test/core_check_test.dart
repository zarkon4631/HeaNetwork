// Feeds generated configs to the real core (`sing-box check`), so a schema
// mismatch with the pinned core version fails here rather than on a user's
// machine. Skipped when the core has not been fetched
// (see tool/fetch_assets.ps1) or on non-Windows hosts.
@TestOn('windows')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:heanetwork/core/config/config_builder.dart';
import 'package:heanetwork/core/models/profile.dart';
import 'package:heanetwork/core/models/settings.dart';
import 'package:heanetwork/core/parsers/import_parser.dart';

import 'fixtures.dart';

final corePath = Platform.environment['HEA_CORE'] ??
    '${Directory.current.path}\\.cache\\core\\sing-box.exe';
final ruleSetDir = '${Directory.current.path}\\assets\\rulesets'.replaceAll('\\', '/');

late Directory tmp;

BuildEnv env(CorePlatform platform, {bool elevated = false}) => BuildEnv(
      platform: platform,
      ruleSetDir: ruleSetDir,
      cacheFile: '${tmp.path}\\cache.db'.replaceAll('\\', '/'),
      clashPort: 19090,
      clashSecret: 'secret',
      elevated: elevated,
      corePath: corePath,
    );

Future<void> check(Map<String, dynamic> config, String label) async {
  final file = File('${tmp.path}\\$label.json');
  await file.writeAsString(const JsonEncoder.withIndent('  ').convert(config));
  final r = await Process.run(corePath, ['check', '-c', file.path, '-D', tmp.path]);
  expect(r.exitCode, 0,
      reason: '$label rejected by core:\n${r.stderr}\n${r.stdout}');
}

List<ProxyProfile> allProfiles() => [
      for (final l in sampleLinks.values) parseLink(l),
      ...parseImportText(wireGuardConf).profiles,
      ...parseImportText(amneziaConf).profiles,
      ...parseImportText(amnezia2Conf).profiles,
    ];

RoutingSettings busyRouting() => RoutingSettings(
      defaultAction: RouteAction.proxy,
      ruDirect: true,
      blockAds: true,
      apps: [
        AppRule(name: 'Chrome', processName: 'chrome.exe', action: RouteAction.direct),
        AppRule(
            name: 'Game',
            processName: 'game.exe',
            processPath: r'C:\Games\My Game\game.exe',
            matchByPath: true,
            action: RouteAction.direct),
        AppRule(name: 'Telegram', processName: 'Telegram.exe', action: RouteAction.proxy),
        AppRule(name: 'Spy', processName: 'spy.exe', action: RouteAction.block),
        AppRule(name: 'Bank', packageName: 'ru.bank.app', action: RouteAction.direct),
        AppRule(name: 'TG', packageName: 'org.telegram.messenger', action: RouteAction.proxy),
        AppRule(name: 'Off', processName: 'off.exe', enabled: false),
      ],
      domains: [
        DomainRule.guess('example.org', RouteAction.direct),
        DomainRule.guess('10.10.0.0/16', RouteAction.direct),
        DomainRule.guess('tracker', RouteAction.block),
        DomainRule.guess('youtube.com', RouteAction.proxy),
      ],
    );

void main() {
  final haveCore = File(corePath).existsSync();
  final skip = haveCore ? null : 'core not found at $corePath';

  setUpAll(() => tmp = Directory.systemTemp.createTempSync('hea_check_'));
  tearDownAll(() => tmp.deleteSync(recursive: true));

  test('every protocol, system proxy mode, default settings', () async {
    for (final p in allProfiles()) {
      final c = buildConfig(
        profile: p,
        settings: AppSettings(),
        routing: RoutingSettings(),
        env: env(CorePlatform.windows),
      );
      await check(c, 'proxy-${p.type}-${p.id}');
    }
  }, skip: skip, timeout: const Timeout(Duration(minutes: 5)));

  test('every protocol, TUN + strong anti-DPI + full routing', () async {
    final settings = AppSettings(
      mode: ConnectionMode.tun,
      fakeIp: true,
      ipv6: false,
      antiDpi: AntiDpiSettings(preset: AntiDpiPreset.strong),
      portForwards: [
        PortForward(listenPort: 13389, targetHost: '10.0.0.5', targetPort: 3389),
        PortForward(
            listenPort: 18080,
            targetHost: 'intranet.example',
            targetPort: 80,
            viaProxy: false),
      ],
    );
    for (final p in allProfiles()) {
      final c = buildConfig(
        profile: p,
        settings: settings,
        routing: busyRouting(),
        env: env(CorePlatform.windows, elevated: true),
        serverDomains: const ['nl.example.com', 'de.example.com', 'nl.example.com'],
      );
      await check(c, 'tun-${p.type}-${p.id}');

      // With FakeIP on, the user's own servers still resolve for real, and
      // that rule comes before the one that fakes everything else.
      final rules = ((c['dns'] as Map)['rules'] as List).cast<Map<String, dynamic>>();
      final own = rules.indexWhere((r) => r['domain'] is List);
      final fake = rules.indexWhere((r) => r['server'] == tagDnsFake);
      expect(rules[own]['domain'], ['de.example.com', 'nl.example.com']);
      expect(rules[own]['server'], tagDnsDirect);
      expect(own, lessThan(fake));
    }
  }, skip: skip, timeout: const Timeout(Duration(minutes: 5)));

  test('custom anti-DPI with SNI spoofing and direct fragmentation', () async {
    final settings = AppSettings(
      mode: ConnectionMode.tun,
      antiDpi: AntiDpiSettings(
        preset: AntiDpiPreset.custom,
        tlsFragment: true,
        tlsRecordFragment: true,
        directFragment: true,
        utlsFingerprint: 'firefox',
        spoofSni: 'ya.ru',
        spoofMethod: 'wrong-checksum',
      ),
    );
    final c = buildConfig(
      profile: parseLink(sampleLinks['vless-ws-tls']!),
      settings: settings,
      routing: RoutingSettings(defaultAction: RouteAction.direct, apps: [
        AppRule(name: 'TG', processName: 'Telegram.exe', action: RouteAction.proxy),
      ]),
      env: env(CorePlatform.windows, elevated: true),
    );
    final tls = (c['outbounds'] as List).first['tls'] as Map;
    expect(tls['spoof'], 'ya.ru');
    expect(tls['fragment'], true);
    expect(tls['utls'], {'enabled': true, 'fingerprint': 'firefox'},
        reason: 'the fingerprint from the link wins over the setting');
    expect((c['route'] as Map)['final'], tagDirect);
    await check(c, 'custom-antidpi');
  }, skip: skip);

  test('android: per-app split via include/exclude package', () async {
    final vless = parseLink(sampleLinks['vless-reality-vision']!);
    final proxyAll = buildConfig(
      profile: vless,
      settings: AppSettings(),
      routing: busyRouting(),
      env: env(CorePlatform.android),
    );
    final tun = (proxyAll['inbounds'] as List).firstWhere((i) => i['type'] == 'tun');
    expect(tun['exclude_package'], ['ru.bank.app']);
    expect(tun.containsKey('include_package'), isFalse);
    await check(proxyAll, 'android-proxy-default');

    final onlySelected = buildConfig(
      profile: vless,
      settings: AppSettings(),
      routing: busyRouting()..defaultAction = RouteAction.direct,
      env: env(CorePlatform.android),
    );
    final tun2 =
        (onlySelected['inbounds'] as List).firstWhere((i) => i['type'] == 'tun');
    expect(tun2['include_package'], ['org.telegram.messenger']);
    await check(onlySelected, 'android-direct-default');
  }, skip: skip);

  test('latency test config', () async {
    await check(
      buildLatencyTestConfig(
        profiles: allProfiles(),
        antiDpi: AntiDpiSettings(),
        clashPort: 19091,
        clashSecret: 's',
      ),
      'latency',
    );
  }, skip: skip);

  test('dns server specs', () {
    expect(dnsServer('local', 't'), {'tag': 't', 'type': 'local'});
    expect(dnsServer('8.8.8.8', 't'), {'tag': 't', 'type': 'udp', 'server': '8.8.8.8'});
    expect(dnsServer('https://dns.google/dns-query', 't', detour: 'proxy'),
        {'tag': 't', 'type': 'https', 'server': 'dns.google', 'detour': 'proxy'});
    expect(dnsServer('https://1.1.1.1:8443/custom', 't'), {
      'tag': 't', 'type': 'https', 'server': '1.1.1.1', 'server_port': 8443,
      'path': '/custom',
    });
    expect(dnsServer('tls://[2606:4700::1111]:853', 't'), {
      'tag': 't', 'type': 'tls', 'server': '2606:4700::1111', 'server_port': 853,
    });
  });

  test('windows app rules match case-insensitively by exe name', () {
    final cond = appConditions([
      AppRule(name: 'C', processName: 'Chrome.exe'),
      AppRule(name: 'G', processName: 'g.exe', processPath: r'C:\g.exe', matchByPath: true),
    ], CorePlatform.windows);
    expect(cond['process_path'], [r'C:\g.exe']);
    // The core uses Go regexp, where `(?i)` is the case-insensitive flag;
    // Dart spells it as a constructor argument.
    final pattern = (cond['process_path_regex'] as List).single as String;
    expect(pattern, startsWith('(?i)'));
    final re = RegExp(pattern.substring(4), caseSensitive: false);
    expect(re.hasMatch(r'C:\Program Files\Google\Chrome\Application\chrome.exe'), isTrue);
    expect(re.hasMatch(r'C:\x\notchrome.exe'), isFalse);
    expect(re.hasMatch(r'C:\x\chrome.exe.bak'), isFalse);
  });
}
