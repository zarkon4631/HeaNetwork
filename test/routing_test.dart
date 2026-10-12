// Routing that comes from the panel (Happ format), programs that run as
// several processes, real device names, and the log filter.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:heanetwork/core/config/config_builder.dart';
import 'package:heanetwork/core/config/rule_values.dart';
import 'package:heanetwork/core/models/panel_routing.dart';
import 'package:heanetwork/core/models/settings.dart';
import 'package:heanetwork/core/parsers/import_parser.dart';
import 'package:heanetwork/core/services/core_controller.dart';
import 'package:heanetwork/core/services/device_identity.dart';
import 'package:heanetwork/core/services/subscription_service.dart';
import 'package:heanetwork/ui/settings_page.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures.dart';
import 'support.dart';

/// What 3x-ui puts in the `Routing` header: a Happ profile, base64 in a
/// deep link.
String happLink(Map<String, dynamic> profile, {String verb = 'onadd'}) =>
    'happ://routing/$verb/${base64.encode(utf8.encode(jsonEncode(profile)))}';

final ruProfile = {
  'Name': 'RU напрямую',
  'GlobalProxy': 'true',
  'RouteOrder': 'block-proxy-direct',
  'DirectSites': ['geosite:private', 'geosite:category-ru', 'domain:yandex.net', 'full:vk.com'],
  'DirectIp': ['geoip:ru', 'geoip:private', '10.0.0.0/8'],
  'ProxySites': ['keyword:youtube', 'regexp:^.*\\.googlevideo\\.com\$', 'chatgpt.com'],
  'ProxyIp': ['1.1.1.1'],
  'BlockSites': ['geosite:category-ads-all', 'geosite:no-such-list'],
  'BlockIp': null,
  'DomainStrategy': 'IPIfNonMatch',
};

final corePath = Platform.environment['HEA_CORE'] ??
    '${Directory.current.path}\\.cache\\core\\sing-box.exe';
final ruleSetDir = '${Directory.current.path}\\assets\\rulesets'.replaceAll('\\', '/');
const bundled = {'geosite-category-ru', 'geoip-ru', 'geosite-category-ads-all'};

Map<String, dynamic> configWith(PanelRouting? panel,
        {RoutingSettings? routing, Set<String> ruleSets = bundled, String cache = 'x'}) =>
    buildConfig(
      profile: parseLink(sampleLinks['vless-reality-vision']!),
      settings: AppSettings(mode: ConnectionMode.systemProxy),
      routing: routing ?? RoutingSettings(),
      panel: panel,
      env: BuildEnv(
        platform: CorePlatform.windows,
        ruleSetDir: ruleSetDir,
        cacheFile: '$cache/cache.db',
        clashPort: 19191,
        clashSecret: 's',
        ruleSets: ruleSets,
      ),
    );

List<Map<String, dynamic>> routeRules(Map<String, dynamic> c) =>
    ((c['route'] as Map)['rules'] as List).cast<Map<String, dynamic>>();

bool has(Map<String, dynamic> rule, String key, String value) =>
    (rule[key] as List?)?.contains(value) ?? false;

/// A core that, like the real one, will not start on routing it cannot read.
class PickyCore extends FakeCore {
  int starts = 0;
  String complaint =
      'initialize router: parse rule[5]: ipcidr: parse [0]: prefix length out of range';
  bool Function(Map<String, dynamic> config)? refuses;

  @override
  Future<void> start(Map<String, dynamic> config) async {
    starts++;
    if (refuses?.call(config) ?? false) throw CoreException(complaint);
    return super.start(config);
  }
}

/// What an administrator can mistype in the panel, next to entries that
/// are fine.
final sloppyProfile = {
  'GlobalProxy': 'true',
  'ProxySites': [
    'regexp:(',
    'regexp:a(?=b)',
    r'regexp:(a)\1',
    r'regexp:^.*\.ok\.example$',
    'regexp:(?i)netflix',
    'fine.example',
  ],
  'DirectIp': ['999.1.1.1', '10.0.0.0/40', '::1/200', ':', '10.0.0.0/8', '1.1.1.1', 'fe80::/10'],
};

void main() {
  group('happ routing profile', () {
    test('is read from the link 3x-ui sends', () {
      final p = PanelRouting.parseLink(happLink(ruProfile))!;
      expect(p.name, 'RU напрямую');
      expect(p.globalProxy, isTrue);
      expect(p.order, [RouteAction.block, RouteAction.proxy, RouteAction.direct]);
      expect(p.directSites, hasLength(4));
      expect(p.blockIp, isEmpty, reason: 'a null list is an empty one');
      expect(p.countOf(RouteAction.direct), 7);
      expect(PanelRouting.parseLink(happLink(ruProfile, verb: 'add'))!.name, 'RU напрямую');
    });

    test('"off", junk and other links are not a profile', () {
      expect(PanelRouting.parseLink('happ://routing/off'), isNull);
      expect(PanelRouting.parseLink('happ://routing/onadd/@@@'), isNull);
      expect(
          PanelRouting.parseLink('happ://routing/onadd/${base64.encode(utf8.encode('[1]'))}'),
          isNull);
      expect(PanelRouting.parseLink(null), isNull);
      expect(PanelRouting.isLink(' happ://routing/off'), isTrue);
      expect(PanelRouting.isLink('vless://x'), isFalse);
    });

    test('survives being stored', () {
      final p = PanelRouting.parseLink(happLink(
          {...ruProfile, 'GlobalProxy': 'false', 'RouteOrder': 'direct-proxy-block'}))!;
      final back = PanelRouting.fromProfile(
          jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>);
      expect(back.globalProxy, isFalse);
      expect(back.order, [RouteAction.direct, RouteAction.proxy, RouteAction.block]);
      expect(back.proxySites, p.proxySites);
      expect(back.directIp, p.directIp);
    });

    test('entries turn into the conditions the core understands', () {
      final p = PanelRouting.parseLink(happLink(ruProfile))!;
      bool have(String tag) => bundled.contains(tag);
      expect(p.conditions(RouteAction.direct, available: have), {
        'rule_set': ['geosite-category-ru', 'geoip-ru'],
        'domain_suffix': ['yandex.net'],
        'domain': ['vk.com'],
        'ip_cidr': ['10.0.0.0/8'],
        'ip_is_private': true,
      });
      expect(p.conditions(RouteAction.proxy, available: have), {
        'domain_keyword': ['youtube'],
        'domain_regex': [r'^.*\.googlevideo\.com$'],
        'domain_suffix': ['chatgpt.com'],
        'ip_cidr': ['1.1.1.1'],
      });
      // A list this device does not have is left out, not sent to the core.
      expect(p.conditions(RouteAction.block, available: have), {
        'rule_set': ['geosite-category-ads-all'],
      });
      expect(p.ruleSetTags, {
        'geosite-category-ru',
        'geoip-ru',
        'geosite-category-ads-all',
        'geosite-no-such-list',
      });
      // For DNS only names matter.
      expect(p.conditions(RouteAction.direct, available: have, domainsOnly: true), {
        'rule_set': ['geosite-category-ru'],
        'domain_suffix': ['yandex.net'],
        'domain': ['vk.com'],
      });
      expect(PanelRouting.ruleSetUrl('geoip-ru'), contains('sing-geoip/rule-set/geoip-ru.srs'));
      expect(PanelRouting.ruleSetUrl('geosite-cn'),
          contains('sing-geosite/rule-set/geosite-cn.srs'));
    });
  });

  group('config', () {
    test('panel rules follow the user\'s own, in the order the profile asks for', () {
      final routing =
          RoutingSettings(domains: [DomainRule.guess('example.org', RouteAction.block)]);
      final rules = routeRules(
          configWith(PanelRouting.parseLink(happLink(ruProfile)), routing: routing));
      final own = rules.indexWhere((r) => has(r, 'domain_suffix', 'example.org'));
      final block = rules.indexWhere(
          (r) => r['action'] == 'reject' && has(r, 'rule_set', 'geosite-category-ads-all'));
      final proxy = rules.indexWhere((r) => has(r, 'domain_keyword', 'youtube'));
      final direct = rules.indexWhere((r) => has(r, 'domain', 'vk.com'));
      expect(own, greaterThan(0));
      expect(own < block && block < proxy && proxy < direct, isTrue,
          reason: 'own $own, block $block, proxy $proxy, direct $direct');
      expect(rules[proxy]['outbound'], tagProxy);
      expect(rules[direct]['outbound'], tagDirect);
    });

    test('GlobalProxy decides where everything else goes', () {
      final off = PanelRouting.parseLink(happLink({...ruProfile, 'GlobalProxy': 'false'}));
      expect((configWith(off)['route'] as Map)['final'], tagDirect);
      expect(
          (configWith(PanelRouting.parseLink(happLink(ruProfile)))['route'] as Map)['final'],
          tagProxy);
      // Without a profile the user's own default stands.
      final own = configWith(null, routing: RoutingSettings(defaultAction: RouteAction.direct));
      expect((own['route'] as Map)['final'], tagDirect);
    });

    test('names that go out directly are resolved directly, blocked ones not at all', () {
      final config = configWith(PanelRouting.parseLink(happLink(ruProfile)));
      final dns = ((config['dns'] as Map)['rules'] as List).cast<Map<String, dynamic>>();
      expect(
          dns.any((r) =>
              r['action'] == 'reject' && has(r, 'rule_set', 'geosite-category-ads-all')),
          isTrue);
      final direct = dns.firstWhere((r) => has(r, 'domain', 'vk.com'));
      expect(direct['server'], tagDnsDirect);
      expect(direct.containsKey('ip_cidr'), isFalse);
    });

    test('the real core accepts a config with a panel profile', () async {
      // Needs the core and the bundled lists; tool/fetch_assets.ps1 gets both.
      if (!File(corePath).existsSync() ||
          !File('$ruleSetDir/geoip-ru.srs').existsSync()) {
        markTestSkipped('core or rule-sets not found');
        return;
      }
      final tmp = Directory.systemTemp.createTempSync('hea_route_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final config = configWith(PanelRouting.parseLink(happLink(ruProfile)),
          cache: tmp.path.replaceAll('\\', '/'));
      final file = File('${tmp.path}\\c.json')..writeAsStringSync(jsonEncode(config));
      final r = await Process.run(corePath, ['check', '-c', file.path, '-D', tmp.path]);
      expect(r.exitCode, 0, reason: '${r.stderr}');
    }, testOn: 'windows');
  });

  group('subscription', () {
    http.Client panelClient(Map<String, String> headers) => MockClient((_) async =>
        http.Response(sampleLinks['vless-reality-vision']!, 200, headers: headers));

    test('the Routing header is read with the subscription', () async {
      final r = await fetchSubscription('https://p.example/sub/x',
          client: panelClient({'routing': happLink(ruProfile), 'routing-enable': 'true'}));
      expect(r.routing!.name, 'RU напрямую');
      final none = await fetchSubscription('https://p.example/sub/x', client: panelClient({}));
      expect(none.routing, isNull);
      final off = await fetchSubscription('https://p.example/sub/x',
          client: panelClient({'routing': 'happ://routing/off'}));
      expect(off.routing, isNull);
    });

    test('the app applies it, and lets it be switched off', () async {
      var headers = {'routing': happLink(ruProfile)};
      final state = makeState(
          populated: false,
          subscriptionClient: MockClient((req) async => req.url.host == 'p.example'
              ? http.Response(sampleLinks['vless-reality-vision']!, 200, headers: headers)
              : http.Response('no', 404)));
      final sub = await state.addSubscription('https://p.example/sub/x');
      expect(sub.routing!.name, 'RU напрямую');
      expect(state.panelRouting, isNotNull);
      expect(state.panelRoutingFromSubscription, isTrue);
      expect(state.missingPanelRuleSets, isNotEmpty, reason: 'nothing was downloaded here');

      await state.connect();
      var rules = routeRules((state.core as FakeCore).lastConfig!);
      expect(rules.any((r) => has(r, 'domain', 'vk.com')), isTrue);

      state.setUsePanelRouting(false);
      expect(state.pendingRestart, isTrue);
      await state.reconnect();
      rules = routeRules((state.core as FakeCore).lastConfig!);
      expect(rules.any((r) => has(r, 'domain', 'vk.com')), isFalse);

      // The administrator removes the rules: the next refresh drops them.
      state.setUsePanelRouting(true);
      headers = {};
      await state.refreshSubscription(sub);
      expect(sub.routing, isNull);
      expect(state.panelRouting, isNull);
      await state.disconnect();

      await state.store.flush();
      expect(File('${state.paths.data.path}/subscriptions.json').readAsStringSync(),
          isNot(contains('DirectSites')));
    });

    test('a routing link can be added by hand and removed again', () async {
      final state = makeState(populated: false);
      final added = await state.importText(happLink(ruProfile));
      expect(added.routing!.name, 'RU напрямую');
      expect(state.panelRouting!.name, 'RU напрямую');
      expect(state.panelRoutingFromSubscription, isFalse);
      expect(state.profiles, isEmpty, reason: 'a routing link is not a server');

      final bad = await state.importText('happ://routing/onadd/@@@');
      expect(bad.routing, isNull);
      expect(state.panelRouting, isNotNull, reason: 'a broken link changes nothing');

      final off = await state.importText('happ://routing/off');
      expect(off.routing!.isEmpty, isTrue);
      expect(state.panelRouting, isNull);
    });
  });

  group('programs with several processes', () {
    test('a group rule matches every executable of the program', () {
      final rule =
          AppRule(name: 'Steam', processName: 'steam.exe', processes: ['steamwebhelper.exe']);
      final cond = appConditions([rule], CorePlatform.windows);
      final patterns = (cond['process_path_regex'] as List).cast<String>();
      expect(patterns, hasLength(2));
      bool hit(String path) => patterns.any(
          (p) => RegExp(p.replaceFirst('(?i)', ''), caseSensitive: false).hasMatch(path));
      expect(hit(r'C:\Program Files (x86)\Steam\steam.exe'), isTrue);
      expect(hit(r'D:\Steam\bin\cef\cef.win64\SteamWebHelper.exe'), isTrue);
      expect(hit(r'C:\Games\notsteam.exe'), isFalse);
    });

    test('picking any process of Steam gives the whole group, once', () {
      final routing = RoutingSettings(apps: [
        AppRule(
            name: 'Steam Client WebHelper',
            processName: 'steamwebhelper.exe',
            processPath: r'C:\Steam\bin\steamwebhelper.exe',
            action: RouteAction.direct),
        AppRule(name: 'Other', processName: 'other.exe'),
      ]);
      final picked = AppRule(
          name: 'Steam',
          processName: 'Steam.exe',
          processPath: r'C:\Steam\steam.exe',
          action: RouteAction.proxy);
      routing.apps.add(picked);
      routing.adoptGroup(picked);
      expect(routing.apps.map((a) => a.name), ['Other', 'Steam']);
      expect(picked.isGroup, isTrue);
      expect(picked.processNames.first, 'steam.exe');
      expect(picked.processNames, contains('steamwebhelper.exe'));
      expect(picked.processPath, r'C:\Steam\steam.exe', reason: 'keeps its icon');
      expect(appGroupOf('GAMEOVERLAYUI.EXE'), steamGroup);
      expect(appGroupOf('notepad.exe'), isNull);
    });

    test('a new install starts with Steam going directly; a deleted rule stays deleted', () {
      final fresh = RoutingSettings();
      expect(fresh.seedDefaults(windows: true, exists: (_) => true), isTrue);
      final steam = fresh.apps.single;
      expect(steam.name, 'Steam');
      expect(steam.action, RouteAction.direct);
      expect(steam.isGroup, isTrue);
      expect(steam.processPath, steamGroup.defaultPath);

      fresh.apps.clear();
      expect(fresh.seedDefaults(windows: true), isFalse);
      expect(fresh.apps, isEmpty);
      final back = RoutingSettings.fromJson(
          jsonDecode(jsonEncode(fresh.toJson())) as Map<String, dynamic>);
      expect(back.seed, RoutingSettings.currentSeed);

      // Android has no Steam client to route.
      final phone = RoutingSettings()..seedDefaults(windows: false);
      expect(phone.apps, isEmpty);
    });

    test('rules made before groups existed are folded into one, keeping their choice', () {
      final old = RoutingSettings.fromJson({
        'apps': [
          {
            'name': 'Steam',
            'processName': 'steam.exe',
            'processPath': r'C:\S\steam.exe',
            'action': 'proxy',
          },
          {'name': 'Steam Client WebHelper', 'processName': 'steamwebhelper.exe', 'action': 'direct'},
          {'name': 'Discord', 'processName': 'Discord.exe', 'action': 'proxy'},
        ],
      });
      expect(old.seedDefaults(windows: true), isTrue);
      expect(old.apps.map((a) => a.name), ['Steam', 'Discord']);
      expect(old.apps.first.action, RouteAction.proxy, reason: 'the user chose that');
      expect(old.apps.first.processNames.length, steamGroup.all.length);
      final back = RoutingSettings.fromJson(
          jsonDecode(jsonEncode(old.toJson())) as Map<String, dynamic>);
      expect(back.apps.first.processes, steamGroup.others);
    });
  });

  group('device names', () {
    test('a desktop is named after its motherboard, not a part number', () {
      expect(
          DeviceIdentity.windowsModel(
            manufacturer: 'Micro-Star International Co., Ltd.',
            product: 'MS-7D22',
            version: '1.0',
            boardManufacturer: 'Micro-Star International Co., Ltd.',
            boardProduct: 'H510M-A PRO (MS-7D22)',
            hostname: 'DESKTOP-ABC',
          ),
          'MSI H510M-A PRO');
      expect(
          DeviceIdentity.windowsModel(
            manufacturer: 'System manufacturer',
            product: 'System Product Name',
            boardManufacturer: 'ASUSTeK COMPUTER INC.',
            boardProduct: 'ROG STRIX B550-F GAMING',
            hostname: 'PC',
          ),
          'ASUS ROG STRIX B550-F GAMING');
    });

    test('a laptop is named as it is sold', () {
      expect(
          DeviceIdentity.windowsModel(
            manufacturer: 'LENOVO',
            product: '20XW00A1RT',
            version: 'ThinkPad X1 Carbon Gen 9',
            boardProduct: '20XW00A1RT',
            hostname: 'L',
          ),
          'Lenovo ThinkPad X1 Carbon Gen 9');
      expect(
          DeviceIdentity.windowsModel(
            manufacturer: 'ASUSTeK COMPUTER INC.',
            product: 'ASUS TUF Gaming F15 FX506HM',
            boardProduct: 'FX506HM',
            hostname: 'L',
          ),
          'ASUS TUF Gaming F15 FX506HM');
      expect(
          DeviceIdentity.windowsModel(
              manufacturer: 'Dell Inc.', product: 'XPS 15 9520', hostname: 'L'),
          'Dell XPS 15 9520');
    });

    test('with nothing usable the computer name is all there is', () {
      expect(
          DeviceIdentity.windowsModel(
              manufacturer: 'To Be Filled By O.E.M.',
              product: 'To Be Filled By O.E.M.',
              boardProduct: 'Default string',
              hostname: 'HOME-PC'),
          'HOME-PC');
    });

    test('Windows is named by its release, not its kernel version', () {
      expect(DeviceIdentity.windowsRelease('"Windows 11 Pro" 10.0 (Build 26100)', '24H2'),
          '11 24H2');
      expect(DeviceIdentity.windowsRelease('"Windows 10 Home" 10.0 (Build 19045)', '22H2'),
          '10 22H2');
      expect(DeviceIdentity.windowsRelease('"Windows 11" 10.0 (Build 22631)', null),
          '11 (build 22631)');
    });
  });

  group('routing never stands in the way of connecting', () {
    test('addresses and expressions the core would refuse are recognised', () {
      for (final ok in ['10.0.0.0/8', '1.1.1.1', '0.0.0.0/0', 'fe80::/10', '::1', '2001:db8::/32']) {
        expect(isCoreAddress(ok), isTrue, reason: ok);
      }
      for (final bad in [
        '999.1.1.1', '300.1.1.1/32', '10.0.0.0/40', '10.0.0.0/', '01.2.3.4',
        '::1/200', ':', '(', '', '1.2.3', 'example.com',
      ]) {
        expect(isCoreAddress(bad), isFalse, reason: bad);
      }
      for (final ok in [r'^.*\.example\.com$', '(?i)netflix', '(?P<n>a)b', '(?i:a)b', 'a|b']) {
        expect(isCoreRegex(ok), isTrue, reason: ok);
      }
      for (final bad in ['(', 'a(?=b)', 'a(?!b)', '(?<=a)b', r'(a)\1', 'a++', '']) {
        expect(isCoreRegex(bad), isFalse, reason: bad);
      }
    });

    test('a profile with mistakes keeps its sound entries and loses the rest', () {
      final panel = PanelRouting.fromProfile(sloppyProfile);
      final proxy = panel.conditions(RouteAction.proxy, available: (_) => true);
      expect(proxy['domain_regex'], [r'^.*\.ok\.example$', '(?i)netflix']);
      expect(proxy['domain_suffix'], ['fine.example']);
      final direct = panel.conditions(RouteAction.direct, available: (_) => true);
      expect(direct['ip_cidr'], ['10.0.0.0/8', '1.1.1.1', 'fe80::/10']);
    });

    test('what the user types as an address is one, or is taken as a name', () {
      expect(DomainRule.guess('10.0.0.0/8', RouteAction.direct).kind, DomainRuleKind.ipCidr);
      expect(DomainRule.guess('2001:db8::1', RouteAction.direct).value, '2001:db8::1/128');
      expect(DomainRule.guess('300.1.1.1', RouteAction.direct).kind,
          isNot(DomainRuleKind.ipCidr));
      expect(DomainRule.guess('10.0.0.0/99', RouteAction.direct).kind,
          isNot(DomainRuleKind.ipCidr));

      // A rule an earlier version saved is left out rather than passed on.
      final config = configWith(null,
          ruleSets: const {},
          routing: RoutingSettings(domains: [
            DomainRule(kind: DomainRuleKind.ipCidr, value: '10.0.0.0/99', action: RouteAction.block),
            DomainRule(kind: DomainRuleKind.ipCidr, value: '10.1.0.0/16', action: RouteAction.block),
          ]));
      expect([for (final r in routeRules(config)) ...?(r['ip_cidr'] as List?)], ['10.1.0.0/16']);
    });

    test('the real core starts on what is left of them', () async {
      if (!File(corePath).existsSync()) {
        markTestSkipped('core not found');
        return;
      }
      final tmp = Directory.systemTemp.createTempSync('hea_route_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final config = configWith(PanelRouting.fromProfile(sloppyProfile),
          ruleSets: const {},
          cache: tmp.path.replaceAll('\\', '/'),
          routing: RoutingSettings(domains: [
            DomainRule(kind: DomainRuleKind.ipCidr, value: '300.1.1.1/32', action: RouteAction.block),
          ]));
      final file = File('${tmp.path}\\c.json')..writeAsStringSync(jsonEncode(config));
      final r = await Process.run(corePath, ['check', '-c', file.path, '-D', tmp.path]);
      expect(r.exitCode, 0, reason: '${r.stderr}');
    }, testOn: 'windows');

    test('a start the core refuses over its routing is repeated without it', () async {
      final core = PickyCore();
      final state = makeState(core: core);
      bool carriesSiteRules(Map<String, dynamic> c) =>
          routeRules(c).any((r) => has(r, 'domain_suffix', 'youtube.com')) ||
          (c['route'] as Map).containsKey('rule_set');
      // Whatever it is about the rules, the core will have none of them.
      core.refuses = carriesSiteRules;

      await state.connect();
      expect(state.isConnected, isTrue, reason: 'the rules must not cost the connection');
      expect(core.starts, 2);
      expect(carriesSiteRules(core.lastConfig!), isFalse);
      expect(state.error, isNull);
      expect(state.routingProblem, contains('parse rule'));
      // Per-program rules are the user's own and cannot be malformed: kept.
      expect(routeRules(core.lastConfig!).any((r) => r.containsKey('process_path_regex')),
          isTrue);

      // Once the rules are sound again the next connection carries them.
      await state.disconnect();
      core.refuses = null;
      await state.connect();
      expect(state.routingProblem, isNull);
      expect(carriesSiteRules(core.lastConfig!), isTrue);
      await state.disconnect();
    });

    test('a failure that has nothing to do with routing is not tried twice', () async {
      final core = PickyCore()
        ..complaint = 'listen tcp 127.0.0.1:2080: bind: address already in use'
        ..refuses = (_) => true;
      final state = makeState(core: core);
      await state.connect();
      expect(core.starts, 1);
      expect(state.isConnected, isFalse);
      expect(state.error, contains('address already in use'));
      expect(state.routingProblem, isNull);
    });

    test('which complaints of the core are about routing', () {
      expect(isRoutingComplaint('initialize router: parse rule[3]: ipcidr: parse [0]'), isTrue);
      expect(isRoutingComplaint('initialize router: parse rule-set[0]: unsupported version: 9'),
          isTrue);
      expect(isRoutingComplaint('initialize dns router: parse dns rule[1]: bad'), isTrue);
      expect(isRoutingComplaint('listen tcp 127.0.0.1:2080: bind: address already in use'),
          isFalse);
      expect(isRoutingComplaint('start inbound/tun[tun-in]: configure tun interface: Access is denied.'),
          isFalse);
    });
  });

  test('the log shows only what the chosen detail asks for', () {
    const debug = '+0700 2026-10-11 10:00:00 DEBUG dns: lookup';
    const info = '+0700 2026-10-11 10:00:00 INFO inbound: connection';
    const notice = '+0700 2026-10-11 10:00:00 NOTICE sing-box started';
    const warn = '+0700 2026-10-11 10:00:00 WARN router: slow';
    const error = '+0700 2026-10-11 10:00:00 ERROR outbound: timeout';
    const plain = 'a line without a level';
    List<String> shown(String level) => [
          for (final l in [debug, info, notice, warn, error, plain])
            if (logLineVisible(l, level)) l,
        ];
    expect(shown('debug'), hasLength(6));
    expect(shown('info'), [info, notice, warn, error, plain]);
    expect(shown('warn'), [warn, error, plain]);
  });
}
