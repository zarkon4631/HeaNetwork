// Connecting: calling it off, a start that never finishes, starting as
// administrator, and which DNS the connection uses.
import 'package:flutter_test/flutter_test.dart';
import 'package:heanetwork/core/config/config_builder.dart';
import 'package:heanetwork/core/models/profile.dart';
import 'package:heanetwork/core/models/settings.dart';
import 'package:heanetwork/core/parsers/import_parser.dart';
import 'package:heanetwork/core/parsers/misc_links.dart';
import 'package:heanetwork/core/services/core_controller.dart';
import 'package:heanetwork/platform/windows/elevation.dart';
import 'package:heanetwork/platform/windows/system_proxy.dart';

import 'fixtures.dart';
import 'support.dart';

Future<void> tick([int ms = 60]) => Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  group('cancelling', () {
    test('a connection being set up can be called off, and that is no error', () async {
      final core = SlowCore();
      final state = makeState(core: core);
      final connecting = state.connect();
      await tick();
      expect(state.status, CoreStatus.starting);
      expect(state.canCancel, isTrue);

      await state.disconnect();
      await connecting;
      expect(state.status, CoreStatus.stopped);
      expect(state.error, isNull, reason: 'the user changed their mind; nothing failed');
      expect(state.activeMode, isNull);
      expect(state.canCancel, isFalse);

      // And the next attempt goes through as usual.
      final again = state.connect();
      await tick();
      core.finish();
      await again;
      expect(state.isConnected, isTrue);
      await state.disconnect();
    });

    test('the button does not cancel on the second click of a double click', () async {
      final core = SlowCore();
      final state = makeState(core: core);
      final connecting = state.toggle();
      await tick();
      await state.toggle(); // the same double click
      expect(state.status, CoreStatus.starting);
      expect(core.starts, 1);

      await tick(800);
      await state.toggle(); // a deliberate one
      await connecting;
      expect(state.status, CoreStatus.stopped);
      expect(state.error, isNull);
    });

    test('two connects at once start the core once', () async {
      final core = SlowCore();
      final state = makeState(core: core);
      final first = state.connect();
      final second = state.connect();
      await tick();
      expect(core.starts, 1);
      core.finish();
      await Future.wait([first, second]);
      expect(state.isConnected, isTrue);
      expect(state.error, isNull);
      await state.disconnect();
    });

    test('a start that never finishes is reported as such, a failure as itself',
        () async {
      final core = SlowCore();
      final state = makeState(core: core);
      var connecting = state.connect();
      await tick();
      core.fail(CoreStartTimeout(const Duration(seconds: 60), 'last line'));
      await connecting;
      expect(state.error, 'start-timeout:60');
      expect(state.status, CoreStatus.stopped);

      connecting = state.connect();
      await tick();
      expect(state.error, isNull, reason: 'a new attempt clears the old error');
      core.fail(CoreException('dial tcp: connection refused'));
      await connecting;
      expect(state.error, 'dial tcp: connection refused');
    });
  });

  group('starting as administrator', () {
    AppSettings settings({ConnectionMode mode = ConnectionMode.tun, bool autoConnect = false}) =>
        AppSettings(mode: mode, autoConnect: autoConnect);

    bool elevate(AppSettings s, {bool elevated = false, List<String> args = const []}) =>
        shouldElevateOnLaunch(settings: s, elevated: elevated, args: args);

    test('VPN mode asks for the rights at launch, system proxy mode never', () {
      expect(elevate(settings()), isTrue);
      expect(elevate(settings(mode: ConnectionMode.systemProxy)), isFalse);
      expect(elevate(settings(), elevated: true), isFalse, reason: 'already has them');
    });

    test('it never asks twice in a row', () {
      expect(elevate(settings(), args: [elevatedFlag]), isFalse);
      expect(elevate(settings(), args: [elevatedFlag, connectFlag]), isFalse);
    });

    test('a start with Windows asks only when it is also going to connect', () {
      expect(elevate(settings(), args: [Autostart.flag]), isFalse);
      expect(elevate(settings(autoConnect: true), args: [Autostart.flag]), isTrue);
    });

    test('the elevated copy gets the same arguments plus the marker', () {
      expect(elevatedArguments(const []), '--elevated');
      expect(elevatedArguments(const [], connect: true), '--elevated --connect');
      expect(elevatedArguments([Autostart.flag]), '--autostart --elevated');
      expect(elevatedArguments([connectFlag], connect: true), '--connect --elevated');
      expect(elevatedArguments([elevatedFlag]), '--elevated');
    });
  });

  group('dns', () {
    Map<String, dynamic> remoteServer(ProxyProfile p, [AppSettings? settings]) {
      final config = buildConfig(
        profile: p,
        settings: settings ?? AppSettings(),
        routing: RoutingSettings(),
        env: const BuildEnv(
          platform: CorePlatform.windows,
          ruleSetDir: 'x',
          cacheFile: 'x/cache.db',
          clashPort: 1,
          clashSecret: 's',
        ),
      );
      final servers = ((config['dns'] as Map)['servers'] as List).cast<Map<String, dynamic>>();
      return servers.firstWhere((s) => s['tag'] == tagDnsRemote);
    }

    test('8.8.8.8 through the VPN is the default', () {
      expect(AppSettings().remoteDns, '8.8.8.8');
      expect(AppSettings.fromJson(const {}).remoteDns, '8.8.8.8');
      expect(remoteServer(parseLink(sampleLinks['vless-reality-vision']!)), {
        'tag': tagDnsRemote,
        'type': 'udp',
        'server': '8.8.8.8',
        'detour': tagProxy,
      });
    });

    test('a choice made before the default changed is kept', () {
      final old = AppSettings.fromJson(const {'remoteDns': 'https://1.1.1.1/dns-query'});
      expect(old.remoteDns, 'https://1.1.1.1/dns-query');
      expect(remoteServer(parseLink(sampleLinks['trojan-ws']!), old)['type'], 'https');
    });

    test('proxies that cannot carry UDP are asked over TCP', () {
      for (final proxy in [
        parseHttpProxy('http://proxy.example:8080#h'),
        parseSocks('socks5://127.0.0.1:1080#s'),
      ]) {
        final server = remoteServer(proxy);
        expect(server['type'], 'tcp', reason: proxy.type);
        expect(server['server'], '8.8.8.8');
      }
      // An explicit choice of protocol is left alone.
      final doh = AppSettings(remoteDns: 'https://1.1.1.1/dns-query');
      expect(remoteServer(parseHttpProxy('http://proxy.example:8080#h'), doh)['type'], 'https');
    });

    test('every offered server is one the config builder understands', () {
      expect(remoteDnsPresets.first.value, defaultRemoteDns);
      expect(directDnsPresets.first.value, defaultDirectDns);
      for (final p in [...remoteDnsPresets, ...directDnsPresets]) {
        final server = dnsServer(p.value, 't');
        if (p.value == defaultDirectDns) {
          expect(server['type'], 'local');
        } else {
          expect(server['server'], isNotEmpty, reason: p.name);
          expect(server['type'], p.value.startsWith('https') ? 'https' : 'udp',
              reason: p.name);
        }
      }
      expect({for (final p in remoteDnsPresets) p.value}.length, remoteDnsPresets.length,
          reason: 'no duplicates');
    });
  });
}
