// Servers only Xray-core can reach (MASQUE, the XDRIVE transport), as a
// 3x-ui 3.10 JSON subscription describes them: kept for Xray-core on
// Windows, where it ships next to the core, and named as left out where it
// does not. The traffic itself is tested in e2e_test.dart.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:heanetwork/core/config/config_builder.dart';
import 'package:heanetwork/core/models/profile.dart';
import 'package:heanetwork/core/models/settings.dart';
import 'package:heanetwork/core/parsers/import_parser.dart';
import 'package:heanetwork/core/services/latency_tester.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures.dart';
import 'support.dart';

Map<String, dynamic> panelConfig(String remark, Map<String, dynamic> proxy) => {
      'remarks': remark,
      'outbounds': [
        {'tag': 'proxy', ...proxy},
        {'tag': 'direct', 'protocol': 'freedom', 'settings': {}},
        {'tag': 'block', 'protocol': 'blackhole'},
      ],
    };

final masque = panelConfig('NL · MASQUE', {
  'protocol': 'masque',
  'settings': {'address': 'mq.example.test', 'port': 8443},
  'streamSettings': {
    'network': 'masque',
    'security': 'tls',
    'masqueSettings': {
      'path': '/.well-known/masque/ip/*/*/',
      'user': 'ivy@example.test',
      'pass': 'pw-ivy',
    },
    'tlsSettings': {
      'serverName': 'mq.example.test',
      'alpn': ['h3'],
      'fingerprint': 'chrome',
      // A panel host may still send it; Xray-core 26.10 refuses to start
      // with it at all.
      'allowInsecure': true,
    },
    'sockopt': {'dialerProxy': 'fragment', 'tcpFastOpen': true},
  },
});

final xdrive = panelConfig('DE · Drive', {
  'protocol': 'vless',
  'settings': {
    'address': '203.0.113.12',
    'port': 443,
    'id': uuid,
    'encryption': 'mlkem768x25519plus.native.0rtt.KEY',
  },
  'streamSettings': {
    'network': 'xdrive',
    'security': 'none',
    'xdriveSettings': {
      'service': 'google-drive',
      'remoteFolder': 'xray-tunnel',
      'secrets': ['id', 'secret', 'token'],
    },
  },
  'mux': {'enabled': true, 'concurrency': 8},
});

final trojan = panelConfig('Trojan', {
  'protocol': 'trojan',
  'settings': {'address': 'tr.example.com', 'port': 443, 'password': 'p'},
  'streamSettings': {
    'network': 'tcp',
    'security': 'tls',
    'tlsSettings': {'serverName': 'tr.example.com'},
  },
});

void main() {
  group('reading', () {
    test('with Xray-core at hand the servers are kept, as the panel sent them', () {
      final r = parseImportText(jsonEncode([trojan, masque, xdrive]), xray: true);
      expect(r.errors, isEmpty);
      expect(r.skipped, isEmpty);
      final [plain, mq, drive] = r.profiles;
      expect(plain.viaXray, isFalse, reason: 'what the core can do stays with the core');
      expect(mq.viaXray, isTrue);
      expect(mq.name, 'NL · MASQUE');
      expect(mq.server, 'mq.example.test');
      expect(mq.port, 8443);
      expect(mq.summary, 'MASQUE · Xray');
      expect(mq.isUdpBased, isTrue, reason: 'MASQUE over HTTP/3');

      final out = mq.xrayOutbound!;
      expect(out.containsKey('tag'), isFalse);
      final stream = out['streamSettings'] as Map;
      expect((stream['masqueSettings'] as Map)['user'], 'ivy@example.test');
      expect((stream['tlsSettings'] as Map).containsKey('allowInsecure'), isFalse);
      // Points at an outbound of the panel's config that is not here.
      expect(stream['sockopt'], {'tcpFastOpen': true});

      expect(drive.summary, 'VLESS · XDRIVE · Xray');
      expect(drive.xrayNetwork, 'xdrive');
      expect(drive.xrayOutbound!['mux'], {'enabled': true, 'concurrency': 8},
          reason: 'XDRIVE does not run without it');
      expect(ProxyProfile.fromJson(jsonDecode(jsonEncode(drive.toJson())) as Map<String, dynamic>)
          .xrayOutbound, drive.xrayOutbound);
    });

    test('without it they are left out by name, as before', () {
      final r = parseImportText(jsonEncode([trojan, masque, xdrive]));
      expect(r.profiles.map((p) => p.name), ['Trojan']);
      expect([for (final e in r.skipped) e.reason], ['protocol:masque', 'transport:xdrive']);
    });
  });

  group('config', () {
    final mq = parseImportText(jsonEncode(masque), xray: true).profiles.single;
    BuildEnv env({String? xrayPath = r'C:\app\core\xray.exe'}) => BuildEnv(
          platform: CorePlatform.windows,
          ruleSetDir: 'x',
          cacheFile: 'x/cache.db',
          clashPort: 1,
          clashSecret: 's',
          corePath: r'C:\app\core\sing-box.exe',
          xrayPath: xrayPath,
          xrayPort: 23456,
        );

    test('the core hands the traffic to Xray-core over loopback SOCKS', () {
      final config = buildConfig(
        profile: mq,
        settings: AppSettings(mode: ConnectionMode.tun),
        routing: RoutingSettings(),
        env: env(),
      );
      final proxy = (config['outbounds'] as List).first as Map;
      expect(proxy, {
        'type': 'socks',
        'tag': tagProxy,
        'server': '127.0.0.1',
        'server_port': 23456,
        'version': '5',
      });
      // Xray-core's own traffic, DNS first of all, must not come back into
      // the tunnel: the rule goes before DNS is taken over.
      final rules = ((config['route'] as Map)['rules'] as List).cast<Map>();
      expect(rules.first, {
        'process_path': [r'C:\app\core\xray.exe'],
        'action': 'route',
        'outbound': tagDirect,
      });
      final xray = config[xrayConfigKey] as Map;
      final inbound = (xray['inbounds'] as List).single as Map;
      expect(inbound['listen'], '127.0.0.1');
      expect(inbound['port'], 23456);
      expect(inbound['protocol'], 'socks');
      final out = (xray['outbounds'] as List).single as Map;
      expect(out['tag'], 'proxy');
      expect(out['protocol'], 'masque');
    });

    test('the core accepts its part, and Xray-core its own', () async {
      final config = buildConfig(
        profile: mq,
        settings: AppSettings(mode: ConnectionMode.systemProxy),
        routing: RoutingSettings(),
        env: env(),
      );
      final xray = config.remove(xrayConfigKey) as Map<String, dynamic>;
      final core = '${Directory.current.path}/.cache/core/sing-box.exe';
      final xrayExe = '${Directory.current.path}/.cache/core/xray.exe';
      if (!File(core).existsSync() || !File(xrayExe).existsSync()) {
        markTestSkipped('core or Xray-core not fetched');
        return;
      }
      final tmp = Directory.systemTemp.createTempSync('hea_xray_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final c = File('${tmp.path}/c.json')..writeAsStringSync(jsonEncode(config));
      final x = File('${tmp.path}/x.json')..writeAsStringSync(jsonEncode(xray));
      final rc = await Process.run(core, ['check', '-c', c.path, '-D', tmp.path]);
      expect(rc.exitCode, 0, reason: '${rc.stderr}');
      final rx = await Process.run(xrayExe, ['run', '-test', '-c', x.path]);
      expect(rx.exitCode, 0, reason: '${rx.stdout}');
    });

    test('a latency test does not try to reach it through the spare core', () async {
      final sent = <String>[];
      final results = <String, int?>{};
      await measureLatency(
        [mq],
        mode: PingMode.url,
        tcp: (host, port, t) async => 10,
        urlTest: (list, onResult) async => sent.addAll(list.map((p) => p.name)),
        onResult: (p, ms) => results[p.name] = ms,
      );
      expect(sent, isEmpty);
      expect(results, {'NL · MASQUE': null});
    });
  });

  group('app', () {
    http.Client panel(List<Map<String, dynamic>> configs) => MockClient(
        (_) async => http.Response.bytes(utf8.encode(jsonEncode(configs)), 200));

    test('on Windows with Xray-core a MASQUE server is in the list and connects', () async {
      final state = makeState(
          populated: false,
          xrayPath: r'C:\app\core\xray.exe',
          subscriptionClient: panel([trojan, masque]));
      final sub = await state.addSubscription('https://panel.example/json/abc');
      expect(state.profilesOf(sub.id).map((p) => p.name), ['Trojan', 'NL · MASQUE']);
      expect(sub.unsupported, isEmpty);

      final mq = state.profilesOf(sub.id).last;
      state.selectProfile(mq.id);
      await state.connect();
      expect(state.isConnected, isTrue);
      final started = (state.core as FakeCore).lastConfig!;
      expect(started[xrayConfigKey], isA<Map>());
      await state.disconnect();
    });

    test('where Xray-core is not, the server is named as left out', () async {
      final state = makeState(populated: false, subscriptionClient: panel([trojan, masque]));
      final sub = await state.addSubscription('https://panel.example/json/abc');
      expect(state.profilesOf(sub.id).map((p) => p.name), ['Trojan']);
      expect(sub.unsupported.single.reason, 'protocol:masque');
    });
  });
}
