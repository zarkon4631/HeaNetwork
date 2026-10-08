// The delay test: TCP probes, what falls back to a measurement through the
// server, and how the app applies the results.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:heanetwork/core/config/config_builder.dart';
import 'package:heanetwork/core/models/profile.dart';
import 'package:heanetwork/core/models/settings.dart';
import 'package:heanetwork/core/parsers/import_parser.dart';
import 'package:heanetwork/core/services/latency_tester.dart';
import 'package:heanetwork/platform/windows/win32.dart' as win32;

import 'fixtures.dart';
import 'support.dart';

const timeout = Duration(seconds: 2);

ProxyProfile tcpServer(String name, {String host = '198.51.100.7', int port = 443}) =>
    parseLink('socks5://$host:$port#$name');

ProxyProfile udpServer(String name) => parseLink(sampleLinks['hysteria2']!)..name = name;

void main() {
  group('tcp probe', () {
    late ServerSocket listener;

    setUp(() async {
      listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      listener.listen((s) => s.destroy());
    });
    tearDown(() => listener.close());

    test('times a connection to a listening port', () async {
      final ms = await dartTcpProbe('127.0.0.1', listener.port, timeout);
      expect(ms, inInclusiveRange(1, 500));
    });

    test('resolves a name before timing it', () async {
      final ms = await dartTcpProbe('localhost', listener.port, timeout);
      expect(ms, inInclusiveRange(1, 500));
    });

    test('a closed port and an unknown name are failures, not errors', () async {
      final closed = await freeTcpPort();
      expect(await dartTcpProbe('127.0.0.1', closed, timeout), -1);
      expect(await dartTcpProbe('no-such-host.invalid', 443, timeout), -1);
    });

    test('a FakeIP address is not measured at all', () async {
      // Nothing listens there; a null answer means no connection was tried.
      expect(await dartTcpProbe('198.18.0.5', 443, timeout), isNull);
      expect(await dartTcpProbe('198.19.255.1', 443, timeout), isNull);
      expect(await dartTcpProbe('fc00::1234', 443, timeout), isNull);
      expect(isFakeIp(InternetAddress('198.20.0.1')), isFalse);
      expect(isFakeIp(InternetAddress('fc00:4000::1')), isFalse);
    });

    test('an adapter address that is gone does not turn servers into dead ones',
        () async {
      // TEST-NET-3: certainly not an address of this machine.
      final ms = await dartTcpProbe('127.0.0.1', listener.port, timeout,
          sourceAddress: '203.0.113.9');
      expect(ms, inInclusiveRange(1, 500));
    });
  });

  group('windows adapter', () {
    test('the default-route adapter is a real one and can be bound to', () async {
      final address = win32.defaultRouteAddress();
      if (address == null) {
        markTestSkipped('this machine has no adapter with a default route');
        return;
      }
      final parsed = InternetAddress(address);
      expect(parsed.type, InternetAddressType.IPv4);
      expect(parsed.isLoopback, isFalse);
      // Never the tunnel of a VPN client (sing-box's default, or ours).
      expect(address, isNot(startsWith('172.19.0.')));
      expect(address, isNot(startsWith('172.29.117.')));
      final adapters = await NetworkInterface.list(type: InternetAddressType.IPv4);
      expect(adapters.expand((i) => i.addresses).map((a) => a.address), contains(address));

      final listener = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
      addTearDown(listener.close);
      listener.listen((s) => s.destroy());
      final ms = await dartTcpProbe(address, listener.port, timeout, sourceAddress: address);
      expect(ms, inInclusiveRange(1, 500));
    });
  }, skip: Platform.isWindows ? null : 'Windows only');

  group('batch', () {
    test('udp protocols are not knocked on, the rest are, a few at a time', () async {
      final profiles = [
        for (var i = 0; i < 40; i++) tcpServer('tcp$i', port: 1000 + i),
        udpServer('hy2'),
        ...parseImportText(wireGuardConf).profiles,
      ];
      var running = 0;
      var peak = 0;
      final asked = <int>[];
      Future<int?> probe(String host, int port, Duration t) async {
        asked.add(port);
        peak = ++running > peak ? running : peak;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        running--;
        if (port == 1003) throw const SocketException('boom');
        return port == 1001 ? -1 : port - 1000 + 10;
      }

      final results = <String, int?>{};
      await tcpPingAll(profiles,
          probe: probe, onResult: (p, ms) => results[p.name] = ms, concurrency: 8);

      expect(results.length, profiles.length);
      expect(asked.toSet(), {for (var i = 0; i < 40; i++) 1000 + i});
      expect(peak, 8);
      expect(results['tcp0'], 10);
      expect(results['tcp1'], -1);
      expect(results['tcp3'], -1, reason: 'a probe that throws is a failed server');
      expect(results['tcp39'], 49);
      expect(results['hy2'], isNull);
      expect(results[profiles.last.name], isNull);
    });

    test('tcp mode: what TCP cannot measure goes through the server', () async {
      final a = tcpServer('a', port: 1);
      final faked = tcpServer('behind-fakeip', port: 2);
      final dead = tcpServer('dead', port: 3);
      final hy2 = udpServer('hy2');
      final results = <String, int?>{};
      final sentThrough = <String>[];

      await measureLatency(
        [a, faked, dead, hy2],
        mode: PingMode.tcp,
        tcp: (host, port, t) async => switch (port) { 1 => 42, 2 => null, _ => -1 },
        urlTest: (list, onResult) async {
          for (final p in list) {
            sentThrough.add(p.name);
            onResult(p, 300);
          }
        },
        onResult: (p, ms) => results[p.name] = ms,
      );

      expect(sentThrough, unorderedEquals(['behind-fakeip', 'hy2']));
      expect(results, {'a': 42, 'dead': -1, 'behind-fakeip': 300, 'hy2': 300});
    });

    test('url mode measures everything through the server', () async {
      final profiles = [tcpServer('a'), udpServer('hy2')];
      final results = <String, int?>{};
      await measureLatency(
        profiles,
        mode: PingMode.url,
        tcp: (host, port, t) => fail('no TCP probe in url mode'),
        urlTest: (list, onResult) async {
          for (final p in list) {
            onResult(p, 120);
          }
        },
        onResult: (p, ms) => results[p.name] = ms,
      );
      expect(results, {'a': 120, 'hy2': 120});
    });

    test('without a spare core everything is TCP and udp stays unmeasured', () async {
      final results = <String, int?>{};
      await measureLatency(
        [tcpServer('a'), udpServer('hy2')],
        // Android has no second core, whatever the setting says.
        mode: PingMode.url,
        tcp: (host, port, t) async => 77,
        onResult: (p, ms) => results[p.name] = ms,
      );
      expect(results, {'a': 77, 'hy2': null});
    });
  });

  group('app state', () {
    test('ping fills in the delays through the injected probe and saves them', () async {
      final asked = <String>[];
      final state = makeState(
        platform: CorePlatform.android,
        populated: false,
        tcpProbe: (host, port, t) async {
          asked.add('$host:$port');
          return host == '203.0.113.5' ? -1 : 64;
        },
      );
      state
        ..addProfile(tcpServer('one', host: '198.51.100.7', port: 443))
        ..addProfile(tcpServer('two', host: '203.0.113.5', port: 8443))
        ..addProfile(udpServer('hy2'));
      state.profiles.last.latencyMs = 999;

      final seen = <bool>[];
      state.addListener(() => seen.add(state.testingLatency));
      await state.testLatency();

      expect(asked, unorderedEquals(['198.51.100.7:443', '203.0.113.5:8443']));
      expect(state.profiles.map((p) => p.latencyMs), [64, -1, null]);
      expect(seen.first, isTrue);
      expect(state.testingLatency, isFalse);
      expect(state.error, isNull);

      await state.store.flush();
      final saved = jsonDecode(
              File('${state.paths.data.path}/profiles.json').readAsStringSync())
          as List;
      expect(saved.map((p) => (p as Map)['latencyMs']), [64, -1, null]);
    });

    test('one server can be measured on its own', () async {
      final state = makeState(
          platform: CorePlatform.android, tcpProbe: (host, port, t) async => 5);
      final before = {for (final p in state.profiles) p.id: p.latencyMs};
      final target = state.profiles.first;
      await state.testLatency([target]);
      expect(target.latencyMs, 5);
      for (final p in state.profiles.skip(1)) {
        expect(p.latencyMs, before[p.id], reason: '${p.name} was not asked for');
      }
    });

    test('the new settings and the folded state survive a restart', () {
      final settings = AppSettings()
        ..pingMode = PingMode.url
        ..ownServersCollapsed = true;
      final back = AppSettings.fromJson(
          jsonDecode(jsonEncode(settings.toJson())) as Map<String, dynamic>);
      expect(back.pingMode, PingMode.url);
      expect(back.ownServersCollapsed, isTrue);
      // Files written by 1.0.1 have neither field.
      final old = AppSettings.fromJson({'mode': 'tun'});
      expect(old.pingMode, PingMode.tcp);
      expect(old.ownServersCollapsed, isFalse);

      final sub = Subscription(name: 's', url: 'https://x.example/sub')..collapsed = true;
      final subBack = Subscription.fromJson(
          jsonDecode(jsonEncode(sub.toJson())) as Map<String, dynamic>);
      expect(subBack.collapsed, isTrue);
      expect(Subscription.fromJson({'name': 's', 'url': 'u'}).collapsed, isFalse);
    });

    test('folding a group is remembered per group', () async {
      final state = makeState();
      final sub = state.subscriptions.single;
      var notified = 0;
      state.addListener(() => notified++);

      state.toggleCollapsed(sub);
      expect(sub.collapsed, isTrue);
      expect(state.settings.ownServersCollapsed, isFalse);
      state.toggleCollapsed(null);
      expect(state.settings.ownServersCollapsed, isTrue);
      expect(notified, 2);

      await state.store.flush();
      final dir = state.paths.data.path;
      expect(File('$dir/subscriptions.json').readAsStringSync(), contains('"collapsed":true'));
      expect(File('$dir/settings.json').readAsStringSync(),
          contains('"ownServersCollapsed":true'));

      state.toggleCollapsed(sub);
      expect(sub.collapsed, isFalse);
    });
  });
}
