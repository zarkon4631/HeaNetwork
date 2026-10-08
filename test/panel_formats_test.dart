// What a 3x-ui panel (v3.9) actually emits, as read from its source:
// AmneziaWG as `vpn://<base64url of the .conf>`, fragmentation settings in
// the `fm` parameter, extra link parameters, and JSON subscriptions made of
// whole Xray configs. Each case is also fed to the real core when present.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:heanetwork/core/config/config_builder.dart';
import 'package:heanetwork/core/models/profile.dart';
import 'package:heanetwork/core/models/settings.dart';
import 'package:heanetwork/core/parsers/import_parser.dart';

import 'fixtures.dart';

final corePath = Platform.environment['HEA_CORE'] ??
    '${Directory.current.path}/.cache/core/sing-box.exe';

/// The exact text 3x-ui's amneziaWGConfigText produces.
const panelAwgConf = '''
[Interface]
PrivateKey = $wgPrivate
Address = 10.66.66.2/32, fd42:42:42::2/128
DNS = 1.1.1.1, 1.0.0.1
MTU = 1408
Jc = 4
Jmin = 40
Jmax = 70
S1 = 86
S2 = 122
S3 = 24
S4 = 12
H1 = 1033089720
H2 = 1336452505
H3 = 1858775673
H4 = 332219739
I1 = <b 0xc70000000108>
ContentPaddingAddition = 50-100
RekeyAfterTime = 100-140
RandomTrailers = on

# Амстердам AWG
[Peer]
PublicKey = $wgPublic
PresharedKey = $wgPrivate
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = 203.0.113.10:41234
PersistentKeepalive = 25''';

String panelVpnLink(String conf) =>
    'vpn://${base64Url.encode(utf8.encode(conf)).replaceAll('=', '')}';

final fragmentMask = jsonEncode({
  'tcp': [
    {
      'type': 'fragment',
      'settings': {'packets': 'tlshello', 'length': '100-200', 'delay': '10-25'},
    },
  ],
  'udp': [
    {
      'type': 'noise',
      'settings': {'type': 'rand', 'packet': '10-20'},
    },
  ],
});

/// One entry of a 3x-ui JSON subscription (trimmed to what matters).
Map<String, dynamic> xrayConfig(String remark, Map<String, dynamic> proxy) => {
      'remarks': remark,
      'dns': {
        'servers': ['8.8.8.8'],
      },
      'inbounds': [
        {'listen': '127.0.0.1', 'port': 10808, 'protocol': 'socks'},
      ],
      'outbounds': [
        {'tag': 'direct', 'protocol': 'freedom', 'settings': {}},
        {'tag': 'block', 'protocol': 'blackhole'},
        {'tag': 'proxy', ...proxy},
      ],
      'routing': {'rules': []},
    };

final xraySubscription = [
  xrayConfig('NL · Reality', {
    'protocol': 'vless',
    'settings': {
      'address': '203.0.113.10',
      'port': 443,
      'id': uuid,
      'encryption': 'none',
      'flow': 'xtls-rprx-vision',
      'level': 8,
    },
    'streamSettings': {
      'network': 'tcp',
      'security': 'reality',
      'realitySettings': {
        'show': false,
        'publicKey': realityPbk,
        'fingerprint': 'firefox',
        'shortId': '0123abcd',
        'serverName': 'www.microsoft.com',
        'spiderX': '/',
      },
      'finalmask': jsonDecode(fragmentMask),
    },
  }),
  xrayConfig('DE · XHTTP', {
    'protocol': 'vless',
    'settings': {
      'vnext': [
        {
          'address': 'de.example.com',
          'port': 8443,
          'users': [
            {'id': uuid, 'encryption': 'none'},
          ],
        },
      ],
    },
    'streamSettings': {
      'network': 'xhttp',
      'security': 'tls',
      'tlsSettings': {
        'serverName': 'de.example.com',
        'alpn': ['h2'],
        'fingerprint': 'chrome',
      },
      'xhttpSettings': {
        'path': '/x',
        'host': 'de.example.com',
        'mode': 'packet-up',
        'xPaddingBytes': '200-900',
      },
    },
    'mux': {'enabled': true, 'concurrency': 8},
  }),
  xrayConfig('WS · VMess', {
    'protocol': 'vmess',
    'settings': {
      'address': 'ws.example.com',
      'port': 443,
      'id': uuid,
      'security': 'auto',
    },
    'streamSettings': {
      'network': 'ws',
      'security': 'tls',
      'tlsSettings': {'serverName': 'ws.example.com'},
      'wsSettings': {
        'path': '/vm',
        'headers': {'Host': 'cdn.example.com'},
      },
    },
  }),
  xrayConfig('Trojan gRPC', {
    'protocol': 'trojan',
    'settings': {
      'servers': [
        {'address': 'tr.example.com', 'port': 443, 'password': 'tr-pass', 'level': 8},
      ],
    },
    'streamSettings': {
      'network': 'grpc',
      'security': 'tls',
      'tlsSettings': {'serverName': 'tr.example.com', 'allowInsecure': true},
      'grpcSettings': {'serviceName': 'svc', 'authority': 'tr.example.com'},
    },
  }),
  xrayConfig('SS 2022', {
    'protocol': 'shadowsocks',
    'settings': {
      'servers': [
        {
          'address': '203.0.113.11',
          'port': 8388,
          'method': '2022-blake3-aes-128-gcm',
          'password': '8JCsPssfgS8tiRwiMlhARg==:VpKABcOpNP3ZrvdMS6nfhw==',
        },
      ],
    },
    'streamSettings': {'network': 'tcp', 'security': 'none'},
  }),
  xrayConfig('HY2', {
    'protocol': 'hysteria',
    'settings': {'version': 2, 'address': 'hy.example.com', 'port': 8443},
    'streamSettings': {
      'network': 'hysteria',
      'security': 'tls',
      'tlsSettings': {
        'serverName': 'hy.example.com',
        'alpn': ['h3'],
        'fingerprint': 'chrome',
      },
      'hysteriaSettings': {'version': 2, 'auth': 'hy-auth'},
      'finalmask': {
        'udp': [
          {
            'type': 'salamander',
            'settings': {'password': 'obfs-pw'},
          },
        ],
      },
    },
  }),
  xrayConfig('WG', {
    'protocol': 'wireguard',
    'settings': {
      'secretKey': wgPrivate,
      'address': ['10.0.0.2/32'],
      'mtu': 1380,
      'peers': [
        {
          'endpoint': 'wg.example.com:51820',
          'publicKey': wgPublic,
          'preSharedKey': wgPrivate,
          'keepAlive': 25,
          'allowedIPs': ['0.0.0.0/0', '::/0'],
        },
      ],
    },
  }),
];

Future<void> coreAccepts(ProxyProfile p, String label, {AntiDpiPreset? preset}) async {
  if (!File(corePath).existsSync()) return;
  final tmp = Directory.systemTemp.createTempSync('hea_panel_');
  try {
    final config = buildConfig(
      profiles: [p],
      settings: AppSettings(antiDpi: AntiDpiSettings(preset: preset ?? AntiDpiPreset.balanced)),
      routing: RoutingSettings(),
      env: BuildEnv(
        platform: CorePlatform.windows,
        ruleSetDir: '${Directory.current.path}/assets/rulesets',
        cacheFile: '${tmp.path}/cache.db'.replaceAll('\\', '/'),
        clashPort: 19095,
        clashSecret: 's',
      ),
    );
    final file = File('${tmp.path}/c.json')..writeAsStringSync(jsonEncode(config));
    final r = await Process.run(corePath, ['check', '-c', file.path, '-D', tmp.path]);
    expect(r.exitCode, 0, reason: '$label rejected by core:\n${r.stderr}');
  } finally {
    tmp.deleteSync(recursive: true);
  }
}

void main() {
  group('amneziawg from the panel', () {
    test('vpn:// carrying the plain .conf', () async {
      final p = parseLink(panelVpnLink(panelAwgConf));
      expect(p.type, Protocol.amneziawg);
      // The remark travels as a comment above [Peer].
      expect(p.name, 'Амстердам AWG');
      expect(p.server, '203.0.113.10');
      expect(p.port, 41234);
      expect(p.outbound['address'], ['10.66.66.2/32', 'fd42:42:42::2/128']);
      expect(p.outbound['mtu'], 1408);
      final a = p.outbound['amnezia'] as Map;
      expect(a['jc'], 4);
      expect(a['s3'], 24);
      expect(a['s4'], 12);
      expect(a['h4'], 332219739);
      expect(a['i1'], '<b 0xc70000000108>');
      // AmneziaWG 3.x extras map onto the core's option names.
      expect(a['content_padding_addition'], '50-100');
      expect(a['rekey_after_time'], '100-140');
      // Not expressible in the core: must be ignored, not break the import.
      expect(a.keys, isNot(contains('randomtrailers')));
      final peer = (p.outbound['peers'] as List).single as Map;
      expect(peer['pre_shared_key'], wgPrivate);
      expect(peer['persistent_keepalive_interval'], 25);
      await coreAccepts(p, 'panel awg');
    });

    test('header protection key is carried', () {
      final conf = panelAwgConf.replaceFirst(
          'RandomTrailers = on', 'HeaderProtectionKey = $wgPublic');
      final a = parseLink(panelVpnLink(conf)).outbound['amnezia'] as Map;
      expect(a['header_protection_key'], wgPublic);
    });

    test('several links in one subscription body', () {
      final body = base64.encode(utf8.encode([
        panelVpnLink(panelAwgConf),
        sampleLinks['vless-reality-vision'],
        panelVpnLink(panelAwgConf.replaceFirst('Амстердам AWG', 'Запасной')),
      ].join('\n')));
      final r = parseImportText(body);
      expect(r.errors, isEmpty);
      expect(r.profiles.map((p) => p.name), ['Амстердам AWG', 'VLESS Reality', 'Запасной']);
    });
  });

  group('link parameters', () {
    test('fm fragment mask turns on fragmentation for that profile', () async {
      final link = '${sampleLinks['vless-ws-tls']!.split('#').first}'
          '&fm=${Uri.encodeComponent(fragmentMask)}#fm';
      final p = parseLink(link);
      final tls = p.outbound['tls'] as Map;
      expect(tls['fragment'], true);
      // The upper bound of the server's own delay range.
      expect(tls['fragment_fallback_delay'], '25ms');
      await coreAccepts(p, 'fm');
    });

    test('the profile keeps its own settings under every preset', () {
      final link = '${sampleLinks['vless-ws-tls']!.split('#').first}'
          '&fm=${Uri.encodeComponent(fragmentMask)}#fm';
      final p = parseLink(link);
      for (final preset in AntiDpiPreset.values) {
        final out = hardenOutbound(p, AntiDpiSettings(preset: preset));
        final tls = out['tls'] as Map;
        // Asked for by the server: stays on even with the preset "off".
        expect(tls['fragment'], true, reason: preset.name);
        expect(tls['fragment_fallback_delay'], '25ms', reason: preset.name);
        // The link says firefox; a preset must not swap the fingerprint.
        expect(tls['utls'], {'enabled': true, 'fingerprint': 'firefox'},
            reason: preset.name);
      }
      // And the stored profile itself is never modified by hardening.
      expect((p.outbound['tls'] as Map).containsKey('record_fragment'), isFalse);
    });

    test('a profile without anti-DPI settings is only added to', () {
      final p = parseLink(sampleLinks['trojan-tls']!);
      final off = hardenOutbound(p, AntiDpiSettings(preset: AntiDpiPreset.off));
      expect(off, p.outbound, reason: 'preset off leaves the profile as imported');
      final auto = hardenOutbound(p, AntiDpiSettings())['tls'] as Map;
      expect(auto['record_fragment'], true);
      expect(auto['server_name'], 'example.com');
    });

    test('x_padding_bytes and post-quantum reality', () async {
      final p = parseLink(
          'vless://$uuid@203.0.113.10:443?type=xhttp&path=%2Fx&mode=auto&x_padding_bytes=300-700'
          '&security=reality&pbk=$realityPbk&sid=ab&sni=example.com&fp=chrome'
          '&support-x25519mlkem768=true&authority=ignored#pq');
      expect((p.outbound['transport'] as Map)['x_padding_bytes'], '300-700');
      expect(((p.outbound['tls'] as Map)['reality'] as Map)['support_x25519mlkem768'], true);
      await coreAccepts(p, 'x_padding + pq');
    });

    test('hysteria2 as the panel writes it', () async {
      final p = parseLink(
          'hysteria2://hy-auth@hy.example.com:8443?security=tls&alpn=h3&sni=hy.example.com'
          '&fp=chrome&obfs=salamander&obfs-password=pw&mport=20000-20100&pinSHA256=AA%3ABB#hy2');
      expect(p.type, Protocol.hysteria2);
      expect(p.outbound['obfs'], {'type': 'salamander', 'password': 'pw'});
      expect(p.outbound['server_ports'], ['20000:20100']);
      // QUIC: a browser fingerprint has no meaning and must not be forced.
      expect((p.outbound['tls'] as Map).containsKey('utls'), isFalse);
      await coreAccepts(p, 'panel hysteria2');
    });
  });

  group('json subscription', () {
    late List<ProxyProfile> profiles;
    setUpAll(() => profiles = parseImportText(jsonEncode(xraySubscription)).profiles);

    test('every server of the array is imported under its remark', () {
      expect(profiles.map((p) => p.name),
          ['NL · Reality', 'DE · XHTTP', 'WS · VMess', 'Trojan gRPC', 'SS 2022', 'HY2', 'WG']);
      expect(profiles.map((p) => p.type), [
        Protocol.vless, Protocol.vless, Protocol.vmess, Protocol.trojan,
        Protocol.shadowsocks, Protocol.hysteria2, Protocol.wireguard,
      ]);
    });

    test('reality with the config\'s own fingerprint and fragmentation', () {
      final p = profiles[0];
      expect(p.outbound['flow'], 'xtls-rprx-vision');
      final tls = p.outbound['tls'] as Map;
      expect(tls['server_name'], 'www.microsoft.com');
      expect(tls['utls'], {'enabled': true, 'fingerprint': 'firefox'});
      expect((tls['reality'] as Map)['public_key'], realityPbk);
      expect(tls['fragment'], true);
    });

    test('legacy vnext shape, xhttp settings next to the path', () {
      final p = profiles[1];
      expect(p.server, 'de.example.com');
      expect(p.port, 8443);
      expect(p.outbound['transport'], {
        'type': 'xhttp',
        'mode': 'packet-up',
        'host': 'de.example.com',
        'path': '/x',
        'x_padding_bytes': '200-900',
      });
      expect((p.outbound['tls'] as Map)['alpn'], ['h2']);
      // Xray's mux.cool has no counterpart in the core and is dropped.
      expect(p.outbound.containsKey('mux'), isFalse);
      expect(p.outbound.containsKey('multiplex'), isFalse);
    });

    test('ws host header, trojan servers array, shadowsocks 2022', () {
      expect(profiles[2].outbound['transport'], {
        'type': 'ws',
        'headers': {'Host': 'cdn.example.com'},
        'path': '/vm',
      });
      expect(profiles[3].outbound['password'], 'tr-pass');
      expect(profiles[3].outbound['transport'], {'type': 'grpc', 'service_name': 'svc'});
      expect((profiles[3].outbound['tls'] as Map)['insecure'], true);
      expect(profiles[4].outbound['method'], '2022-blake3-aes-128-gcm');
    });

    test('hysteria 2 with salamander, wireguard', () {
      expect(profiles[5].outbound['password'], 'hy-auth');
      expect(profiles[5].outbound['obfs'], {'type': 'salamander', 'password': 'obfs-pw'});
      expect((profiles[5].outbound['tls'] as Map).containsKey('utls'), isFalse);
      final wg = profiles[6];
      expect(wg.server, 'wg.example.com');
      expect(wg.port, 51820);
      expect(wg.outbound['mtu'], 1380);
    });

    test('a single config object works too, and the core accepts all of them', () async {
      final one = parseImportText(jsonEncode(xraySubscription.first));
      expect(one.profiles.single.name, 'NL · Reality');
      for (final p in profiles) {
        await coreAccepts(p, 'json ${p.name}', preset: AntiDpiPreset.strong);
      }
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('a config with nothing usable is reported, not imported', () {
      final r = parseImportText(jsonEncode([
        xrayConfig('only freedom', {'protocol': 'freedom', 'settings': {}}),
      ]));
      expect(r.profiles, isEmpty);
      expect(r.errors, isNotEmpty);
    });
  });
}
