import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heanetwork/app.dart';
import 'package:heanetwork/core/config/config_builder.dart';
import 'package:heanetwork/core/models/settings.dart';
import 'package:heanetwork/core/parsers/import_parser.dart';
import 'package:heanetwork/core/services/antigravity_check.dart';
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

Future<AntigravityCheckResult> check(Uri uri, {int? proxyPort}) =>
    HttpOverrides.runWithHttpOverrides(
      () => checkAntigravity(uri, proxyPort: proxyPort),
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
  });
}
