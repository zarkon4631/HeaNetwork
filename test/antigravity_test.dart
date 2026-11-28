import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heanetwork/app.dart';
import 'package:heanetwork/core/config/config_builder.dart';
import 'package:heanetwork/core/models/settings.dart';
import 'package:heanetwork/core/parsers/import_parser.dart';
import 'package:heanetwork/core/services/antigravity_check.dart';
import 'package:heanetwork/core/services/core_controller.dart';
import 'package:heanetwork/platform/windows/elevation.dart';
import 'package:heanetwork/platform/windows/system_proxy.dart';
import 'package:heanetwork/state/app_state.dart';
import 'package:heanetwork/ui/shell.dart';

import 'fixtures.dart';
import 'support.dart';

Map<String, dynamic> antigravityConfig({
  bool enabled = true,
  CorePlatform platform = CorePlatform.windows,
  RoutingSettings? routing,
}) {
  final cache = Directory.systemTemp.createTempSync('hea_ag_config_');
  addTearDown(() => cache.deleteSync(recursive: true));
  return buildConfig(
    profile: parseLink(sampleLinks['vless-reality-vision']!),
    settings: AppSettings(
      antigravityEnabled: enabled,
      mode: ConnectionMode.tun,
      fakeIp: true,
    ),
    routing: routing ?? RoutingSettings(defaultAction: RouteAction.direct),
    env: BuildEnv(
      platform: platform,
      ruleSetDir: cache.path,
      cacheFile: '${cache.path}/cache.db',
      clashPort: 19191,
      clashSecret: 's',
      elevated: true,
      ruleSets: const {},
    ),
  );
}

List<Map<String, dynamic>> rulesOf(
  Map<String, dynamic> config,
  String section,
) => ((config[section] as Map)['rules'] as List).cast<Map<String, dynamic>>();

bool hasDomain(Map<String, dynamic> rule) =>
    (rule['domain'] as List?)?.contains(antigravityDomains.first) ?? false;

class _RealHttpOverrides extends HttpOverrides {}

Future<AntigravityCheckResult> check(
  Uri uri, {
  int? proxyPort,
  AntigravityProxy? httpProxy,
}) =>
    HttpOverrides.runWithHttpOverrides(
      () => checkAntigravity(uri, proxyPort: proxyPort, httpProxy: httpProxy),
      _RealHttpOverrides(),
    );

void main() {
  group('Antigravity routing', () {
    test('is off by default and the opt-in survives storage', () {
      final settings = AppSettings();
      expect(settings.antigravityEnabled, isFalse);
      expect(settings.toJson().containsKey('antigravityEnabled'), isFalse);
      settings.antigravityEnabled = true;
      expect(
        AppSettings.fromJson(settings.toJson()).antigravityEnabled,
        isTrue,
      );
    });

    test('adds process, domain and remote DNS rules only when enabled', () {
      final enabled = antigravityConfig();
      final routes = rulesOf(enabled, 'route');
      final domains = routes.singleWhere(hasDomain);
      expect(domains['domain'], antigravityDomains);
      expect(domains['outbound'], tagProxy);
      final process = routes.singleWhere(
        (r) =>
            (r['process_path_regex'] as List?)?.contains(
              antigravityProcessPattern,
            ) ??
            false,
      );
      expect(process['outbound'], tagProxy);
      expect((enabled['route'] as Map)['find_process'], isTrue);
      expect((enabled['route'] as Map)['final'], tagDirect);

      final dns = rulesOf(enabled, 'dns');
      final remote = dns.singleWhere(hasDomain);
      expect(remote['server'], tagDnsRemote);
      final fake = dns.indexWhere((r) => r['server'] == tagDnsFake);
      expect(
        dns.indexOf(remote),
        lessThan(fake),
        reason: 'FakeIP must not replace remote DNS',
      );

      final pattern = RegExp(
        antigravityProcessPattern.replaceFirst('(?i)', ''),
        caseSensitive: false,
      );
      for (final path in [
        r'C:\Users\u\AppData\Local\Programs\Antigravity\Antigravity.exe',
        r'C:\Tools\agy.exe',
        r'C:\Antigravity\resources\bin\language_server.exe',
        r'C:\Antigravity\language_server_windows_x64.exe',
      ]) {
        expect(pattern.hasMatch(path), isTrue, reason: path);
      }
      expect(pattern.hasMatch(r'C:\Other\editor.exe'), isFalse);

      final disabled = antigravityConfig(enabled: false);
      expect(rulesOf(disabled, 'route').any(hasDomain), isFalse);
      expect((disabled['route'] as Map).containsKey('find_process'), isFalse);
    });

    test('does not add hidden Windows rules on Android', () {
      final config = antigravityConfig(platform: CorePlatform.android);
      expect(rulesOf(config, 'route').any(hasDomain), isFalse);
      expect(
        rulesOf(
          config,
          'route',
        ).any((r) => r.containsKey('process_path_regex')),
        isFalse,
      );
    });

    test('the user’s own direct and DNS rules keep priority', () {
      final config = antigravityConfig(
        routing: RoutingSettings(
          defaultAction: RouteAction.direct,
          domains: [
            DomainRule(
              kind: DomainRuleKind.domain,
              value: antigravityDomains.first,
              action: RouteAction.direct,
            ),
          ],
        ),
      );
      final routes = rulesOf(config, 'route').where(hasDomain).toList();
      expect(routes, hasLength(2));
      expect(routes.first['outbound'], tagDirect);
      expect(routes.last['outbound'], tagProxy);
      final dns = rulesOf(config, 'dns').where(hasDomain).toList();
      expect(dns.first['server'], tagDnsDirect);
      expect(dns.last['server'], tagDnsRemote);
    });

    test('the real core accepts the enabled configuration', () async {
      final core = File(
        Platform.environment['HEA_CORE'] ??
            '${Directory.current.path}\\.cache\\core\\sing-box.exe',
      );
      if (!core.existsSync()) {
        markTestSkipped('core not found');
        return;
      }
      final dir = Directory.systemTemp.createTempSync('hea_ag_core_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/config.json')
        ..writeAsStringSync(jsonEncode(antigravityConfig()));
      final result = await Process.run(core.path, [
        'check',
        '-c',
        file.path,
        '-D',
        dir.path,
      ]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
    }, testOn: 'windows');
  });

  group('Antigravity checks', () {
    test('reads HTTP and recognises the location refusal', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) {
        if (request.uri.path == '/blocked') {
          request.response.statusCode = 400;
          request.response.write('{"error":"User location is not supported"}');
        } else {
          request.response.statusCode = 404;
        }
        request.response.close();
      });
      final base = 'http://127.0.0.1:${server.port}';
      final reachable = await check(Uri.parse('$base/ok'));
      expect(reachable.reachable, isTrue);
      expect(reachable.statusCode, 404);
      expect(reachable.regionBlocked, isFalse);

      final blocked = await check(Uri.parse('$base/blocked'));
      expect(blocked.statusCode, 400);
      expect(blocked.regionBlocked, isTrue);
    });

    test(
      'uses the supplied local proxy instead of the target network',
      () async {
        final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => proxy.close(force: true));
        var requestedHost = '';
        proxy.listen((request) {
          requestedHost = request.uri.host;
          request.response.statusCode = 200;
          request.response.close();
        });
        final result = await check(
          Uri.parse('http://antigravity.invalid/'),
          proxyPort: proxy.port,
        );
        expect(result.statusCode, 200);
        expect(requestedHost, 'antigravity.invalid');
      },
    );
  });

  group('Antigravity interface', () {
    testWidgets('the opt-in shows the tab and opens its page', (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final state = makeState();
      state.settings.locale = 'ru';
      await tester.pumpWidget(HeaApp(state: state, home: const Shell()));
      await tester.pump();
      expect(find.text('Antigravity'), findsNothing);

      state.updateSettings((s) => s.antigravityEnabled = true);
      await tester.pump();
      expect(find.text('Antigravity'), findsOneWidget);
      await tester.tap(find.text('Antigravity'));
      await tester.pump();
      expect(find.text('Доступ к Antigravity'), findsOneWidget);
      expect(find.text('VPN не подключён'), findsOneWidget);
      expect(find.text(antigravityDomains.first), findsOneWidget);
      expect(find.text('Проверить'), findsOneWidget);

      state.updateSettings((s) => s.antigravityEnabled = false);
      await tester.pump();
      expect(find.text('Antigravity'), findsNothing);
      expect(find.text('Главная'), findsWidgets);
    });

    testWidgets('the setting is next to SSH and persists', (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final state = makeState();
      state.settings
        ..locale = 'ru'
        ..sshClientEnabled = true;
      await tester.pumpWidget(
        HeaApp(
          state: state,
          home: const Shell(initialTab: ShellTab.settings),
        ),
      );
      await tester.pump();
      final setting = find.widgetWithText(SwitchListTile, 'Antigravity');
      await tester.ensureVisible(setting);
      await tester.pump();
      final ssh = find.text('SSH-клиент (Терминал и SFTP)');
      expect(
        tester.getTopLeft(ssh).dy,
        lessThan(tester.getTopLeft(setting).dy),
      );
      expect(state.settings.antigravityEnabled, isFalse);
      await tester.runAsync(() async {
        await tester.tap(setting);
        await tester.pump();
        expect(state.settings.antigravityEnabled, isTrue);
        await state.store.flush();
      });
      final saved = jsonDecode(
        File('${state.paths.data.path}/settings.json').readAsStringSync(),
      );
      expect(saved['antigravityEnabled'], isTrue);
    });

    testWidgets(
      'dedicated HTTP proxy input is obscured by default and connects without VPN',
      (tester) async {
        tester.view.physicalSize = const Size(1200, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final core = FakeCore();
        final state = makeState(core: core, elevated: true);
        state.settings
          ..locale = 'ru'
          ..mode = ConnectionMode.tun
          ..antigravityEnabled = true;

        await tester.pumpWidget(
          HeaApp(
            state: state,
            home: const Shell(initialTab: ShellTab.antigravity),
          ),
        );
        await tester.pump();

        final fieldFinder = find.byType(TextField);
        expect(tester.widget<TextField>(fieldFinder).obscureText, isTrue);

        // Toggle visibility on and back off.
        await tester.tap(find.byIcon(Icons.visibility_outlined));
        await tester.pump();
        expect(tester.widget<TextField>(fieldFinder).obscureText, isFalse);
        await tester.tap(find.byIcon(Icons.visibility_off_outlined));
        await tester.pump();
        expect(tester.widget<TextField>(fieldFinder).obscureText, isTrue);

        const sample = 'u_9mhu5cgofh:qnpyoqw53h78yp36@111.11.123.11:2443';
        await tester.enterText(fieldFinder, sample);
        await tester.pump();
        final connectBtn = find.text('Подключить');
        await tester.ensureVisible(connectBtn);
        await tester.pump();
        await tester.tap(connectBtn);
        await tester.pump();
        for (var i = 0; i < 40 && !state.antigravityProxyRunning; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 15)),
          );
          await tester.pump();
        }
        await tester.runAsync(() => state.store.flush());
        await tester.pump();

        expect(state.antigravityProxyRunning, isTrue,
            reason: 'error=${state.antigravityError}, role=${state.coreRole}, core=${core.status}');
        expect(state.isConnected, isFalse);
        expect(find.text('HTTP-прокси подключён'), findsOneWidget);
        expect(find.text('111.11.123.11:2443 · без VPN'), findsOneWidget);
        // Credentials must never appear in any status tile.
        expect(
          find.descendant(
            of: find.byType(ListTile),
            matching: find.textContaining('qnpyoqw53h78yp36'),
          ),
          findsNothing,
        );

        final disconnectBtn = find.text('Отключить');
        await tester.ensureVisible(disconnectBtn);
        await tester.pump();
        await tester.tap(disconnectBtn);
        await tester.pump();
        for (var i = 0; i < 40 && core.status != CoreStatus.stopped; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 15)),
          );
          await tester.pump();
        }
        await tester.runAsync(() => state.store.flush());
        await tester.pump();
        expect(state.antigravityProxyRunning, isFalse);
        expect(core.status, CoreStatus.stopped);
        expect(find.text('VPN не подключён'), findsOneWidget);
      },
    );
  });

  group('Antigravity dedicated HTTP proxy', () {
    const sample = 'u_9mhu5cgofh:qnpyoqw53h78yp36@111.11.123.11:2443';

    test('parses supported HTTP(S) proxy formats and rejects invalid input', () {
      final bare = AntigravityProxy.tryParse(sample)!;
      expect(bare.host, '111.11.123.11');
      expect(bare.port, 2443);
      expect(bare.username, 'u_9mhu5cgofh');
      expect(bare.password, 'qnpyoqw53h78yp36');
      expect(bare.tls, isFalse);
      expect(bare.endpoint, '111.11.123.11:2443');
      expect(bare.raw, sample);
      expect(bare.toOutbound(tag: tagAntigravityProxy), {
        'type': 'http',
        'tag': tagAntigravityProxy,
        'server': '111.11.123.11',
        'server_port': 2443,
        'username': 'u_9mhu5cgofh',
        'password': 'qnpyoqw53h78yp36',
      });

      final https = AntigravityProxy.tryParse(
        'https://user:p%40ss:word@proxy.example.com/',
      )!;
      expect(https.host, 'proxy.example.com');
      expect(https.port, 443);
      expect(https.username, 'user');
      expect(https.password, 'p@ss:word');
      expect(https.tls, isTrue);
      expect(https.endpoint, 'https://proxy.example.com:443');
      expect(https.toOutbound(tag: tagAntigravityProxy)['tls'], {
        'enabled': true,
        'server_name': 'proxy.example.com',
      });

      final noAuth = AntigravityProxy.tryParse('10.0.0.5:8080')!;
      expect(noAuth.username, isEmpty);
      expect(noAuth.password, isEmpty);
      expect(noAuth.endpoint, '10.0.0.5:8080');

      final ipv6 = AntigravityProxy.tryParse('u:p@[2001:db8::1]:3128')!;
      expect(ipv6.host, '2001:db8::1');
      expect(ipv6.port, 3128);
      expect(ipv6.endpoint, '[2001:db8::1]:3128');

      for (final bad in [
        '',
        '   ',
        '111.11.123.11',
        'socks5://u:p@111.11.123.11:1080',
        '111.11.123.11:0',
        '111.11.123.11:70000',
        '111.11.123.11:abc',
        'user:pass@:2443',
      ]) {
        expect(AntigravityProxy.tryParse(bad), isNull, reason: bad);
      }
    });

    test('settings persist antigravityProxy and antigravityProxyEnabled', () {
      final settings = AppSettings();
      expect(settings.toJson().containsKey('antigravityProxy'), isFalse);
      expect(settings.toJson().containsKey('antigravityProxyEnabled'), isFalse);
      settings
        ..antigravityEnabled = true
        ..antigravityProxy = sample
        ..antigravityProxyEnabled = true;
      final restored = AppSettings.fromJson(settings.toJson());
      expect(restored.antigravityProxy, sample);
      expect(restored.antigravityProxyEnabled, isTrue);
      expect(restored.hasActiveAntigravityProxy, isTrue);
    });

    test('standalone and hybrid configs are accepted by the real core', () async {
      final core = File(
        Platform.environment['HEA_CORE'] ??
            '${Directory.current.path}\\.cache\\core\\sing-box.exe',
      );
      if (!core.existsSync()) {
        markTestSkipped('core not found');
        return;
      }
      final dir = Directory.systemTemp.createTempSync('hea_ag_proxy_core_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final env = BuildEnv(
        platform: CorePlatform.windows,
        ruleSetDir: dir.path,
        cacheFile: '${dir.path}/cache.db',
        clashPort: 19192,
        clashSecret: 's',
        elevated: true,
        corePath: core.path,
        ruleSets: const {},
      );
      final proxy = AntigravityProxy.tryParse(sample)!;
      final settings = AppSettings(
        antigravityEnabled: true,
        antigravityProxy: sample,
        antigravityProxyEnabled: true,
        mode: ConnectionMode.tun,
        fakeIp: true,
      );

      Future<void> checkWithCore(String name, Map<String, dynamic> cfg) async {
        final file = File('${dir.path}/$name.json')
          ..writeAsStringSync(jsonEncode(cfg));
        final result = await Process.run(core.path, [
          'check',
          '-c',
          file.path,
          '-D',
          dir.path,
        ]);
        expect(result.exitCode, 0, reason: '$name: ${result.stderr}');
      }

      // 1. Standalone Antigravity-only TUN config (main VPN off).
      final standalone = buildAntigravityProxyConfig(
        proxy: proxy,
        settings: settings,
        env: env,
      );
      expect((standalone['route'] as Map)['final'], tagDirect);
      expect(
        ((standalone['inbounds'] as List).first as Map)['strict_route'],
        isFalse,
      );
      expect(
        rulesOf(standalone, 'route').any(
          (r) => r['outbound'] == tagAntigravityProxy && hasDomain(r),
        ),
        isTrue,
      );
      expect(
        rulesOf(standalone, 'dns').singleWhere(hasDomain)['server'],
        tagDnsAntigravity,
      );
      await checkWithCore('standalone', standalone);

      // 2. Hybrid TUN VPN + dedicated Antigravity HTTP proxy.
      final hybridTun = buildConfig(
        profile: parseLink(sampleLinks['vless-reality-vision']!),
        settings: settings,
        routing: RoutingSettings(),
        env: env,
      );
      final outTags = (hybridTun['outbounds'] as List)
          .cast<Map<String, dynamic>>()
          .map((o) => o['tag'])
          .toList();
      expect(outTags, containsAll([tagProxy, tagAntigravityProxy, tagDirect]));
      expect(
        rulesOf(hybridTun, 'route').singleWhere(
          (r) => hasDomain(r) && r['action'] == 'route',
        )['outbound'],
        tagAntigravityProxy,
      );
      await checkWithCore('hybrid_tun', hybridTun);

      // 3. Hybrid System Proxy VPN + Antigravity-only TUN (elevated).
      final sysSettings = AppSettings.fromJson(settings.toJson())
        ..mode = ConnectionMode.systemProxy;
      final hybridSys = buildConfig(
        profile: parseLink(sampleLinks['vless-reality-vision']!),
        settings: sysSettings,
        routing: RoutingSettings(),
        env: env,
      );
      final inbounds = (hybridSys['inbounds'] as List).cast<Map<String, dynamic>>();
      expect(inbounds.any((i) => i['type'] == 'mixed'), isTrue);
      expect(inbounds.any((i) => i['type'] == 'tun' && i['strict_route'] == false), isTrue);
      expect(
        rulesOf(hybridSys, 'route').any(
          (r) => r['inbound'] == 'tun-in' && r['outbound'] == tagDirect,
        ),
        isTrue,
      );
      await checkWithCore('hybrid_sys', hybridSys);
    }, testOn: 'windows');

    test('authenticates HTTP proxy and detects 407 auth failure', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final expectedAuth = 'Basic ${base64Encode(utf8.encode('u1:p1'))}';
      server.listen((request) {
        final auth = request.headers.value(HttpHeaders.proxyAuthorizationHeader);
        if (auth != expectedAuth) {
          request.response
            ..statusCode = HttpStatus.proxyAuthenticationRequired
            ..headers.set(
              HttpHeaders.proxyAuthenticateHeader,
              'Basic realm="Proxy"',
            );
          request.response.close();
          return;
        }
        request.response
          ..statusCode = 200
          ..close();
      });

      final good = await check(
        Uri.parse('http://antigravity.invalid/'),
        httpProxy: AntigravityProxy(
          host: '127.0.0.1',
          port: server.port,
          username: 'u1',
          password: 'p1',
        ),
      );
      expect(good.reachable, isTrue);
      expect(good.statusCode, 200);
      expect(good.proxyAuthFailed, isFalse);

      final bad = await check(
        Uri.parse('http://antigravity.invalid/'),
        httpProxy: AntigravityProxy(
          host: '127.0.0.1',
          port: server.port,
          username: 'u1',
          password: 'wrong',
        ),
      );
      expect(bad.reachable, isFalse);
      expect(bad.proxyAuthFailed, isTrue);
    });

    test('auto-starts on init without VPN and stays independent of VPN toggle', () async {
      final core = FakeCore();
      final state = makeState(core: core, elevated: true);
      state.settings
        ..mode = ConnectionMode.tun
        ..antigravityEnabled = true
        ..antigravityProxy = sample
        ..antigravityProxyEnabled = true;

      // Launch: standalone Antigravity starts immediately while main VPN stays OFF.
      await state.init();
      expect(state.antigravityProxyRunning, isTrue);
      expect(state.antigravityStandaloneRunning, isTrue);
      expect(state.isConnected, isFalse);
      expect(state.status, CoreStatus.stopped);
      expect((core.lastConfig!['route'] as Map)['final'], tagDirect);

      // Connect main VPN: upgrades cleanly to hybrid config carrying both outbounds.
      await state.connect();
      expect(state.isConnected, isTrue);
      expect(state.status, CoreStatus.running);
      expect(state.antigravityProxyRunning, isTrue);
      expect(state.antigravityStandaloneRunning, isFalse);
      final outTags = (core.lastConfig!['outbounds'] as List)
          .cast<Map<String, dynamic>>()
          .map((o) => o['tag'])
          .toList();
      expect(outTags, containsAll([tagProxy, tagAntigravityProxy]));

      // Disconnect main VPN: automatically returns to standalone Antigravity.
      await state.disconnect();
      expect(state.isConnected, isFalse);
      expect(state.status, CoreStatus.stopped);
      expect(state.antigravityProxyRunning, isTrue);
      expect(state.antigravityStandaloneRunning, isTrue);
      expect((core.lastConfig!['route'] as Map)['final'], tagDirect);

      // App exit (keepAntigravity: false): tears down core completely.
      await state.disconnect(keepAntigravity: false);
      expect(state.antigravityProxyRunning, isFalse);
      expect(core.status, CoreStatus.stopped);
    });

    test('elevation policy requests admin rights when Antigravity proxy is active', () {
      final settings = AppSettings(
        mode: ConnectionMode.systemProxy,
        antigravityEnabled: true,
        antigravityProxy: sample,
        antigravityProxyEnabled: true,
      );
      expect(
        shouldElevateOnLaunch(
          settings: settings,
          elevated: false,
          args: const [],
        ),
        isTrue,
      );
      expect(
        shouldElevateOnLaunch(
          settings: settings,
          elevated: false,
          args: const [Autostart.flag],
        ),
        isTrue,
      );
      expect(
        shouldElevateOnLaunch(
          settings: settings,
          elevated: true,
          args: const [],
        ),
        isFalse,
      );
    });

    test('without elevation saves proxy and throws ElevationRequired', () async {
      final state = makeState(elevated: false);
      state.settings.antigravityEnabled = true;
      await expectLater(
        state.applyAntigravityProxy(sample, enabled: true),
        throwsA(isA<ElevationRequired>()),
      );
      expect(state.settings.antigravityProxy, sample);
      expect(state.settings.antigravityProxyEnabled, isTrue);
    });
  });
}
