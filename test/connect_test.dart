// Connecting: calling it off, a start that never finishes, starting as
// administrator, and which DNS the connection uses.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:heanetwork/core/config/config_builder.dart';
import 'package:heanetwork/core/models/profile.dart';
import 'package:heanetwork/core/models/settings.dart';
import 'package:heanetwork/core/parsers/import_parser.dart';
import 'package:heanetwork/core/parsers/misc_links.dart';
import 'package:heanetwork/core/services/core_controller.dart';
import 'package:heanetwork/platform/windows/elevation.dart';
import 'package:heanetwork/state/app_state.dart';
import 'package:heanetwork/platform/windows/system_proxy.dart';

import 'fixtures.dart';
import 'support.dart';

Future<void> tick([int ms = 60]) => Future<void>.delayed(Duration(milliseconds: ms));

/// Counts how often it is started.
class CountingCore extends FakeCore {
  int starts = 0;

  @override
  Future<void> start(Map<String, dynamic> config) {
    starts++;
    return super.start(config);
  }
}

/// A system proxy setting that cannot be made, as when its backup cannot be
/// written.
class BrokenProxy extends SystemProxy {
  BrokenProxy() : super(File('nowhere'));

  @override
  void enable(int port) => throw const FileSystemException('cannot write the backup');

  @override
  void restore() {}
}

/// One that is made, and then cannot be put back.
class StubbornProxy extends SystemProxy {
  StubbornProxy() : super(File('nowhere'));

  @override
  void enable(int port) {}

  @override
  void restore() => throw const FileSystemException('cannot delete the backup');
}

Map<String, dynamic> tunOf(Map<String, dynamic> config) =>
    (config['inbounds'] as List).cast<Map<String, dynamic>>().firstWhere((i) => i['type'] == 'tun');

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

  group('a tunnel that takes no connections', () {
    // VPN mode on Windows, with a check of the tunnel that answers by the
    // network stack the running core was given. A firewall that blocks
    // incoming connections lets nothing through the system's stack.
    AppState vpn(CountingCore core, bool Function(String stack) accepts,
        {List<String>? asked, CorePlatform platform = CorePlatform.windows}) {
      final state = makeState(
          core: core,
          elevated: true,
          platform: platform,
          tunnelCheck: () async {
            final stack = tunOf(core.lastConfig!)['stack'] as String;
            asked?.add(stack);
            return accepts(stack);
          });
      state.settings.mode = ConnectionMode.tun;
      return state;
    }

    test('is started again on the stack that needs nothing from the system', () async {
      final core = CountingCore();
      final asked = <String>[];
      final state = vpn(core, (stack) => stack == 'gvisor', asked: asked);
      expect(state.settings.tunStack, 'mixed');

      await state.connect();
      expect(state.isConnected, isTrue);
      expect(core.starts, 2);
      expect(asked, ['mixed', 'gvisor']);
      expect(tunOf(core.lastConfig!)['stack'], 'gvisor');
      expect(state.settings.tunStack, 'gvisor', reason: 'remembered for the next time');
      expect(state.stackSwitched, isTrue);
      expect(state.error, isNull);
      expect(state.pendingRestart, isFalse);

      // The next connection starts right and has nothing to find out.
      await state.disconnect();
      expect(state.stackSwitched, isFalse);
      asked.clear();
      await state.connect();
      expect(core.starts, 3);
      expect(asked, isEmpty);
      expect(state.stackSwitched, isFalse);
      await state.disconnect();
    });

    test('one that works is left as it is', () async {
      final core = CountingCore();
      final asked = <String>[];
      final state = vpn(core, (_) => true, asked: asked);
      await state.connect();
      expect(core.starts, 1);
      expect(asked, ['mixed']);
      expect(state.settings.tunStack, 'mixed');
      expect(state.stackSwitched, isFalse);
      await state.disconnect();
    });

    test('when the other stack is no better, the setting stays the user\'s', () async {
      final core = CountingCore();
      final asked = <String>[];
      final state = vpn(core, (_) => false, asked: asked);
      await state.connect();
      expect(state.isConnected, isTrue, reason: 'still better connected than not');
      expect(core.starts, 2);
      expect(asked, ['mixed', 'gvisor']);
      expect(state.settings.tunStack, 'mixed');
      expect(state.stackSwitched, isFalse);
      expect(state.pendingRestart, isFalse);
      await state.disconnect();
    });

    test('nothing is checked without a tunnel of that kind', () async {
      final asked = <String>[];

      // System proxy mode has no tunnel.
      var core = CountingCore();
      var state = vpn(core, (_) => false, asked: asked);
      state.settings.mode = ConnectionMode.systemProxy;
      await state.connect();
      expect(core.starts, 1);
      await state.disconnect();

      // A stack the user already set to gVisor has nothing to fall back to.
      core = CountingCore();
      state = vpn(core, (_) => false, asked: asked);
      state.settings.tunStack = 'gvisor';
      await state.connect();
      expect(core.starts, 1);
      await state.disconnect();

      // On Android the tunnel is the system's own.
      core = CountingCore();
      state = vpn(core, (_) => false, asked: asked, platform: CorePlatform.android);
      await state.connect();
      expect(core.starts, 1);
      await state.disconnect();

      expect(asked, isEmpty);
    });
  });

  group('asking to reconnect', () {
    test('only a setting that really changed asks for it', () async {
      final state = makeState();
      await state.connect();
      expect(state.pendingRestart, isFalse);

      // Choosing what is already chosen changes nothing.
      state.updateSettings((s) => s.remoteDns = s.remoteDns);
      state.updateRouting((r) => r.ruDirect = r.ruDirect);
      state.selectProfile(state.selectedProfile!.id);
      state.updateSettings((s) => s.mode = s.mode);
      expect(state.pendingRestart, isFalse);

      // A real change does, and taking it back withdraws the request.
      final dns = state.settings.remoteDns;
      state.updateSettings((s) => s.remoteDns = '9.9.9.9');
      expect(state.pendingRestart, isTrue);
      state.updateSettings((s) => s.remoteDns = dns);
      expect(state.pendingRestart, isFalse);

      state.updateRouting((r) => r.ruDirect = !r.ruDirect);
      expect(state.pendingRestart, isTrue);
      await state.reconnect();
      expect(state.pendingRestart, isFalse);

      // Things the core never sees do not ask either.
      state.updateSettings((s) => s.themeMode = 'light', affectsCore: false);
      state.updateSettings((s) => s.pingMode = PingMode.url);
      expect(state.pendingRestart, isFalse);
      await state.disconnect();
    });

    test('a reconnect that needs administrator rights leaves the connection up',
        () async {
      // Connected through the system proxy, then switched to VPN mode, which
      // this copy of the app has no rights for.
      final state = makeState();
      await state.connect();
      state.updateSettings((s) => s.mode = ConnectionMode.tun);
      expect(state.pendingRestart, isTrue);

      await expectLater(state.reconnect(), throwsA(isA<ElevationRequired>()));
      expect(state.isConnected, isTrue,
          reason: 'nothing is torn down for a connection that cannot be made');
      await state.disconnect();
    });

    test('deleting the server in use asks for it, deleting another does not', () async {
      final state = makeState();
      await state.connect();
      final inUse = state.selectedProfile!;
      state.deleteProfile(state.profiles.last);
      expect(state.pendingRestart, isFalse);

      state.deleteProfile(inUse);
      expect(state.selectedProfile, isNotNull);
      expect(state.pendingRestart, isTrue,
          reason: 'the connection still runs through a server that is gone');
      await state.disconnect();
    });

    test('so does deleting the subscription the server in use came with', () async {
      final state = makeState();
      await state.connect();
      state.deleteSubscription(state.subscriptions.single);
      expect(state.pendingRestart, isTrue);
      await state.disconnect();
    });
  });

  group('a connection that is only half made', () {
    test('does not leave the core running behind the error', () async {
      final state = makeState(systemProxy: BrokenProxy());
      await state.connect();
      expect(state.error, contains('cannot write the backup'));
      expect(state.status, CoreStatus.stopped);
      expect(state.activeMode, isNull);
    });

    test('a proxy setting that cannot be put back does not keep the core up', () async {
      final state = makeState(systemProxy: StubbornProxy());
      await state.connect();
      expect(state.isConnected, isTrue);
      await state.disconnect();
      expect(state.status, CoreStatus.stopped);
    });
  });

  test('traffic is counted by where it went', () {
    final seen = <String, (int, int)>{};
    var t = const RouteTraffic().add([
      (id: 'a', chains: ['proxy'], up: 100, down: 1000),
      (id: 'b', chains: ['direct'], up: 10, down: 50),
    ], seen);
    expect([t.vpnUp, t.vpnDown, t.directUp, t.directDown, t.open], [100, 1000, 10, 50, 2]);

    // Totals per connection keep growing; only the growth is added. A
    // connection that closed keeps what it carried.
    t = t.add([
      (id: 'a', chains: ['proxy'], up: 150, down: 4000),
      (id: 'c', chains: ['direct'], up: 5, down: 5),
    ], seen);
    expect([t.vpnUp, t.vpnDown, t.directUp, t.directDown, t.open], [150, 4000, 15, 55, 2]);
    expect(t.vpn, 4150);
    expect(t.direct, 70);
    expect(seen.keys, unorderedEquals(['a', 'c']));
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
