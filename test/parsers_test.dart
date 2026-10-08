import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:heanetwork/core/models/profile.dart';
import 'package:heanetwork/core/models/settings.dart';
import 'package:heanetwork/core/parsers/import_parser.dart';

import 'fixtures.dart';

void main() {
  group('share links', () {
    test('every sample parses', () {
      for (final e in sampleLinks.entries) {
        final p = parseLink(e.value);
        expect(p.server, isNotEmpty, reason: e.key);
        expect(p.port, greaterThan(0), reason: e.key);
        expect(p.name, isNotEmpty, reason: e.key);
      }
    });

    test('vless reality vision', () {
      final p = parseLink(sampleLinks['vless-reality-vision']!);
      expect(p.type, Protocol.vless);
      expect(p.name, 'VLESS Reality');
      expect(p.outbound['uuid'], uuid);
      expect(p.outbound['flow'], 'xtls-rprx-vision');
      final tls = p.outbound['tls'] as Map;
      expect(tls['server_name'], 'www.microsoft.com');
      expect(tls['reality'], {
        'enabled': true,
        'public_key': realityPbk,
        'short_id': '0123abcd',
      });
      expect(tls['utls'], {'enabled': true, 'fingerprint': 'chrome'});
      expect(p.outbound.containsKey('transport'), isFalse);
      expect(p.summary, 'VLESS · Reality · Vision');
    });

    test('ws path carries early data', () {
      final p = parseLink(sampleLinks['vless-ws-tls']!);
      expect(p.outbound['transport'], {
        'type': 'ws',
        'headers': {'Host': 'cdn.example.com'},
        'path': '/ws',
        'max_early_data': 2048,
        'early_data_header_name': 'Sec-WebSocket-Protocol',
      });
      expect((p.outbound['tls'] as Map)['alpn'], ['http/1.1']);
    });

    test('xhttp maps mode and extra', () {
      final t = parseLink(sampleLinks['vless-xhttp-reality']!)
          .outbound['transport'] as Map;
      expect(t['type'], 'xhttp');
      expect(t['mode'], 'packet-up');
      expect(t['path'], '/x');
      expect(t['x_padding_bytes'], '100-1000');
      expect(t['no_grpc_header'], true);
      expect(t['sc_max_each_post_bytes'], 1000000);
      expect(t['xmux'], {
        'max_concurrency': '16-32',
        'h_max_request_times': '600-900',
      });
      expect(t['headers'], {'X-Test': '1'});
    });

    test('xhttp over plain TLS gets Xray default ALPN', () {
      final tls = parseLink(sampleLinks['vless-xhttp-tls']!).outbound['tls'] as Map;
      expect(tls['alpn'], ['h2', 'http/1.1']);
    });

    test('vless encryption and mkcp', () {
      final enc = parseLink(
          'vless://$uuid@1.2.3.4:443?encryption=mlkem768x25519plus.native.0rtt.KEY&type=tcp#e');
      expect(enc.outbound['encryption'], 'mlkem768x25519plus.native.0rtt.KEY');
      final kcp = parseLink(sampleLinks['vless-mkcp']!);
      expect(kcp.outbound['transport'],
          {'type': 'mkcp', 'seed': 'secret', 'header_type': 'wechat-video'});
      expect(kcp.isUdpBased, isTrue);
    });

    test('ipv6 host', () {
      final p = parseLink(sampleLinks['vless-ipv6']!);
      expect(p.server, '2001:db8::1');
      expect(p.port, 443);
    });

    test('vmess', () {
      final p = parseLink(sampleLinks['vmess-ws-tls']!);
      expect(p.type, Protocol.vmess);
      expect(p.name, 'VMess WS');
      expect(p.outbound['alter_id'], 0);
      expect((p.outbound['transport'] as Map)['path'], '/vm');
      expect(parseLink(sampleLinks['vmess-tcp']!).port, 10086);
    });

    test('trojan password is percent-decoded and TLS is implied', () {
      expect(parseLink(sampleLinks['trojan-tls']!).outbound['password'],
          'p@ss:word');
      final bare = parseLink(sampleLinks['trojan-default-tls']!);
      expect((bare.outbound['tls'] as Map)['enabled'], true);
      expect((bare.outbound['tls'] as Map)['server_name'], 'example.com');
    });

    test('shadowsocks forms', () {
      final a = parseLink(sampleLinks['ss-sip002']!);
      expect(a.outbound['method'], 'aes-256-gcm');
      expect(a.outbound['password'], 'pass:with:colons');
      final b = parseLink(sampleLinks['ss-2022']!);
      expect(b.outbound['method'], '2022-blake3-aes-128-gcm');
      expect(b.outbound['password'],
          '8JCsPssfgS8tiRwiMlhARg==:VpKABcOpNP3ZrvdMS6nfhw==');
      final c = parseLink(sampleLinks['ss-legacy']!);
      expect(c.outbound['method'], 'chacha20-ietf-poly1305');
      expect(c.port, 8389);
      expect(c.name, 'SS-legacy');
    });

    test('hysteria2 obfs and port hopping', () {
      final p = parseLink(sampleLinks['hysteria2']!);
      expect(p.outbound['password'], 'hy2-pass');
      expect(p.port, 443);
      expect(p.outbound['server_ports'], ['20000:30000']);
      expect(p.outbound['obfs'], {'type': 'salamander', 'password': 'obfs-pass'});
      expect((p.outbound['tls'] as Map)['insecure'], true);
      expect(parseLink(sampleLinks['hy2-short']!).outbound['password'],
          'user:pass');
    });

    test('tuic and socks', () {
      final t = parseLink(sampleLinks['tuic']!);
      expect(t.outbound['uuid'], uuid);
      expect(t.outbound['password'], 'tuic-pass');
      expect(t.outbound['congestion_control'], 'bbr');
      final s = parseLink(sampleLinks['socks']!);
      expect(s.outbound['username'], 'user');
      expect(s.outbound['password'], 'pass');
      expect(parseLink(sampleLinks['socks5-plain']!).outbound.containsKey('username'),
          isFalse);
    });

    test('unknown scheme is rejected', () {
      expect(() => parseLink('foo://bar'), throwsA(isA<LinkParseException>()));
      expect(() => parseLink('vless://@:0'), throwsA(isA<LinkParseException>()));
    });
  });

  group('wireguard', () {
    test('plain conf', () {
      final p = parseImportText(wireGuardConf).profiles.single;
      expect(p.type, Protocol.wireguard);
      expect(p.outbound['address'], ['10.8.0.2/24', 'fd00::2/128']);
      expect(p.outbound['mtu'], 1420);
      final peer = (p.outbound['peers'] as List).single as Map;
      expect(peer['address'], 'vpn.example.com');
      expect(peer['port'], 51820);
      expect(peer['persistent_keepalive_interval'], 25);
      expect(p.outbound.containsKey('amnezia'), isFalse);
    });

    test('amneziawg conf', () {
      final p = parseImportText(amneziaConf).profiles.single;
      expect(p.type, Protocol.amneziawg);
      expect(p.outbound['amnezia'], {
        'jc': 4, 'jmin': 40, 'jmax': 70, 's1': 86, 's2': 122,
        'h1': 1033089720, 'h2': 1336452505, 'h3': 1858775673, 'h4': 332219739,
      });
    });

    test('amneziawg 2.0 ranges and ipv6 endpoint', () {
      final p = parseImportText(amnezia2Conf).profiles.single;
      final a = p.outbound['amnezia'] as Map;
      expect(a['h1'], '100000-200000');
      expect(a['s4'], 8);
      expect(a['i1'], '<b 0xc70000000108>');
      expect(p.server, '2001:db8::5');
      expect(p.port, 41235);
    });

    test('wireguard:// link', () {
      final p = parseLink(sampleLinks['wireguard-link']!);
      expect(p.outbound['private_key'], wgPrivate);
      expect(((p.outbound['peers'] as List).single as Map)['public_key'], wgPublic);
      expect(p.outbound['mtu'], 1380);
    });

    test('amnezia vpn:// key', () {
      final inner = jsonEncode({'config': amneziaConf});
      final root = jsonEncode({
        'containers': [
          {'container': 'amnezia-awg', 'awg': {'last_config': inner}},
        ],
        'defaultContainer': 'amnezia-awg',
        'description': 'My Amnezia',
      });
      final raw = utf8.encode(root);
      final blob = [
        (raw.length >> 24) & 0xff, (raw.length >> 16) & 0xff,
        (raw.length >> 8) & 0xff, raw.length & 0xff,
        ...zlib.encode(raw),
      ];
      final key = 'vpn://${base64Url.encode(blob).replaceAll('=', '')}';
      final p = parseLink(key);
      expect(p.type, Protocol.amneziawg);
      expect(p.name, 'My Amnezia');
      expect((p.outbound['amnezia'] as Map)['jc'], 4);
    });
  });

  group('import text', () {
    test('base64 subscription body', () {
      final body = base64.encode(utf8.encode(
          '${sampleLinks['vless-reality-vision']}\n${sampleLinks['trojan-tls']}\n'
          'bogus://x\n'));
      final r = parseImportText(body);
      expect(r.profiles, hasLength(2));
      expect(r.errors, hasLength(1));
    });

    test('plain list and subscription url', () {
      expect(
          parseImportText(
                  '${sampleLinks['tuic']}\r\n\r\n${sampleLinks['hysteria2']}')
              .profiles,
          hasLength(2));
      final sub = parseImportText(' https://panel.example.com/sub/abc123 ');
      expect(sub.subscriptionUrl, 'https://panel.example.com/sub/abc123');
      expect(sub.profiles, isEmpty);
    });

    test('sing-box json', () {
      final r = parseImportText(jsonEncode({
        'outbounds': [
          {'type': 'direct', 'tag': 'direct'},
          {
            'type': 'vless', 'tag': 'my-vless', 'server': 'a.com',
            'server_port': 443, 'uuid': uuid, 'detour': 'x',
          },
        ],
        'endpoints': [
          {
            'type': 'wireguard', 'tag': 'awg', 'address': ['10.0.0.2/32'],
            'private_key': wgPrivate, 'amnezia': {'jc': 3},
            'peers': [
              {'address': '1.2.3.4', 'port': 51820, 'public_key': wgPublic},
            ],
          },
        ],
      }));
      expect(r.profiles.map((p) => p.name), ['my-vless', 'awg']);
      expect(r.profiles.first.outbound.containsKey('tag'), isFalse);
      expect(r.profiles.first.outbound.containsKey('detour'), isFalse);
      expect(r.profiles.last.type, Protocol.amneziawg);
    });

    test('garbage reports an error instead of throwing', () {
      final r = parseImportText('hello world');
      expect(r.profiles, isEmpty);
      expect(r.errors, isNotEmpty);
    });
  });

  group('domain rule guess', () {
    test('kinds', () {
      expect(DomainRule.guess('https://www.Example.com/path', RouteAction.direct).value,
          'www.example.com');
      expect(DomainRule.guess('*.example.com', RouteAction.direct).kind,
          DomainRuleKind.domainSuffix);
      expect(DomainRule.guess('10.0.0.0/8', RouteAction.direct).kind,
          DomainRuleKind.ipCidr);
      expect(DomainRule.guess('8.8.8.8', RouteAction.direct).value, '8.8.8.8/32');
      expect(DomainRule.guess('2001:db8::1', RouteAction.direct).value,
          '2001:db8::1/128');
      expect(DomainRule.guess('youtube', RouteAction.proxy).kind,
          DomainRuleKind.domainKeyword);
    });
  });
}
