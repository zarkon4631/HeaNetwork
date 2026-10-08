// End-to-end: a local sing-box server exposes one inbound per protocol, and
// for each of them a share link is parsed, turned into a client config by the
// real builder, run in a second core, and an HTTP request is pushed through.
// Hermetic: the probe target is a local HTTP server that the test server
// reaches by rewriting a TEST-NET address.
@TestOn('windows')
@Timeout(Duration(minutes: 10))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:heanetwork/core/config/config_builder.dart';
import 'package:heanetwork/core/models/profile.dart';
import 'package:heanetwork/core/models/settings.dart';
import 'package:heanetwork/core/parsers/import_parser.dart';
import 'package:heanetwork/core/parsers/misc_links.dart';

final corePath = Platform.environment['HEA_CORE'] ??
    '${Directory.current.path}\\.cache\\core\\sing-box.exe';

/// Not private, so the client routes it through the proxy; the test server
/// rewrites it to loopback.
const probeIp = '198.51.100.7';
const uuid = '775ddd8e-a994-4511-b059-e132efe15735';
const ss2022Server = '8JCsPssfgS8tiRwiMlhARg==';
const ss2022User = 'VpKABcOpNP3ZrvdMS6nfhw==';

Future<int> freeTcp() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final p = s.port;
  await s.close();
  return p;
}

Future<int> freeUdp() async {
  final s = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
  final p = s.port;
  s.close();
  return p;
}

Future<String> run(List<String> args) async {
  final r = await Process.run(corePath, args);
  if (r.exitCode != 0) throw StateError('core ${args.join(' ')}: ${r.stderr}');
  return r.stdout as String;
}

Future<(String priv, String pub)> keypair(String kind) async {
  final out = await run(['generate', kind]);
  String field(String name) =>
      RegExp('$name: (\\S+)').firstMatch(out)!.group(1)!;
  return (field('PrivateKey'), field('PublicKey'));
}

Future<void> waitForPort(int port, Process proc, StringBuffer log) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  var exited = false;
  proc.exitCode.then((_) => exited = true);
  while (DateTime.now().isBefore(deadline)) {
    if (exited) throw StateError('core exited early:\n$log');
    try {
      final s = await Socket.connect(InternetAddress.loopbackIPv4, port,
          timeout: const Duration(milliseconds: 300));
      s.destroy();
      return;
    } on Object {
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
  }
  throw StateError('port $port never opened:\n$log');
}

Future<Process> startCore(Map<String, dynamic> config, Directory dir, String name,
    StringBuffer log) async {
  final file = File('${dir.path}\\$name.json');
  await file.writeAsString(jsonEncode(config));
  final work = Directory('${dir.path}\\$name')..createSync();
  final p = await Process.start(corePath, ['run', '-c', file.path, '-D', work.path]);
  p.stdout.transform(utf8.decoder).listen(log.write);
  p.stderr.transform(utf8.decoder).listen(log.write);
  return p;
}

void main() {
  if (!File(corePath).existsSync()) {
    test('e2e', () {}, skip: 'core not found at $corePath');
    return;
  }

  late Directory tmp;
  late HttpServer probe;
  late Process server;
  final serverLog = StringBuffer();
  final links = <String, String>{};
  final extraProfiles = <String, ProxyProfile>{};
  const awgUnpaddedReply = 'amneziawg-unpadded-reply';
  ProxyProfile? unpaddedReplyProfile;

  setUpAll(() async {
    tmp = Directory.systemTemp.createTempSync('hea_e2e_');
    probe = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    probe.listen((req) {
      req.response
        ..write('hea-ok')
        ..close();
    });

    final pem = await run(['generate', 'tls-keypair', 'localhost']);
    final blocks = RegExp(r'-----BEGIN ([A-Z ]+)-----[\s\S]+?-----END \1-----')
        .allMatches(pem)
        .map((m) => m.group(0)!)
        .toList();
    final key = blocks.firstWhere((b) => b.contains('PRIVATE KEY')).split('\n');
    final cert = blocks.firstWhere((b) => b.contains('CERTIFICATE')).split('\n');
    Map<String, dynamic> tls({List<String>? alpn}) => {
          'enabled': true,
          'server_name': 'localhost',
          'certificate': cert,
          'key': key,
          'alpn': ?alpn,
        };

    final (realityPriv, realityPub) = await keypair('reality-keypair');
    final (wgSrvPriv, wgSrvPub) = await keypair('wg-keypair');
    final (wgCliPriv, wgCliPub) = await keypair('wg-keypair');

    final inbounds = <Map<String, dynamic>>[];
    final endpoints = <Map<String, dynamic>>[];
    Future<int> tcpIn(Map<String, dynamic> inbound) async {
      final port = await freeTcp();
      inbounds.add({...inbound, 'listen': '127.0.0.1', 'listen_port': port});
      return port;
    }

    Future<int> udpIn(Map<String, dynamic> inbound) async {
      final port = await freeUdp();
      inbounds.add({...inbound, 'listen': '127.0.0.1', 'listen_port': port});
      return port;
    }

    const insecureTls = 'security=tls&sni=localhost&allowInsecure=1';
    final vlessUsers = [
      {'uuid': uuid},
    ];

    var p = await tcpIn({
      'type': 'trojan',
      'users': [
        {'password': 'tr-pass'},
      ],
      'tls': tls(),
    });
    final trojanPort = p;
    links['trojan'] = 'trojan://tr-pass@127.0.0.1:$p?$insecureTls#trojan';

    p = await tcpIn({
      'type': 'vless',
      'users': [
        {'uuid': uuid, 'flow': 'xtls-rprx-vision'},
      ],
      'tls': tls(),
    });
    links['vless-tls-vision'] =
        'vless://$uuid@127.0.0.1:$p?type=tcp&$insecureTls&flow=xtls-rprx-vision&fp=chrome#v';

    p = await tcpIn({
      'type': 'vless',
      'users': [
        {'uuid': uuid, 'flow': 'xtls-rprx-vision'},
      ],
      'tls': {
        'enabled': true,
        'server_name': 'localhost',
        'reality': {
          'enabled': true,
          'handshake': {'server': '127.0.0.1', 'server_port': trojanPort},
          'private_key': realityPriv,
          'short_id': ['0123abcd'],
        },
      },
    });
    links['vless-reality-vision'] =
        'vless://$uuid@127.0.0.1:$p?type=tcp&security=reality&pbk=$realityPub'
        '&sid=0123abcd&sni=localhost&fp=chrome&flow=xtls-rprx-vision#r';

    p = await tcpIn({
      'type': 'vless',
      'users': vlessUsers,
      'tls': tls(),
      'transport': {'type': 'ws', 'path': '/ws'},
    });
    links['vless-ws-tls'] =
        'vless://$uuid@127.0.0.1:$p?type=ws&path=%2Fws&host=localhost&$insecureTls#w';

    p = await tcpIn({
      'type': 'vless',
      'users': vlessUsers,
      'tls': tls(),
      'transport': {'type': 'grpc', 'service_name': 'svc'},
    });
    links['vless-grpc-tls'] =
        'vless://$uuid@127.0.0.1:$p?type=grpc&serviceName=svc&$insecureTls#g';

    p = await tcpIn({
      'type': 'vless',
      'users': vlessUsers,
      'transport': {'type': 'httpupgrade', 'path': '/hu'},
    });
    links['vless-httpupgrade'] =
        'vless://$uuid@127.0.0.1:$p?type=httpupgrade&path=%2Fhu&security=none#h';

    for (final mode in ['auto', 'packet-up', 'stream-one']) {
      p = await tcpIn({
        'type': 'vless',
        'users': vlessUsers,
        'tls': tls(alpn: ['h2', 'http/1.1']),
        'transport': {
          'type': 'xhttp',
          'mode': mode,
          'path': '/xh',
          'x_padding_bytes': '100-1000',
        },
      });
      links['vless-xhttp-$mode'] =
          'vless://$uuid@127.0.0.1:$p?type=xhttp&path=%2Fxh&mode=$mode&$insecureTls#x';
    }

    p = await tcpIn({
      'type': 'vless',
      'users': vlessUsers,
      'tls': {
        'enabled': true,
        'server_name': 'localhost',
        'reality': {
          'enabled': true,
          'handshake': {'server': '127.0.0.1', 'server_port': trojanPort},
          'private_key': realityPriv,
          'short_id': ['ab'],
        },
      },
      'transport': {
        'type': 'xhttp',
        'mode': 'auto',
        'path': '/xr',
        'x_padding_bytes': '100-1000',
      },
    });
    links['vless-xhttp-reality'] =
        'vless://$uuid@127.0.0.1:$p?type=xhttp&path=%2Fxr&security=reality'
        '&pbk=$realityPub&sid=ab&sni=localhost&fp=chrome#xr';

    p = await udpIn({
      'type': 'vless',
      'users': vlessUsers,
      'transport': {'type': 'mkcp', 'seed': 'kcp-seed'},
    });
    links['vless-mkcp'] =
        'vless://$uuid@127.0.0.1:$p?type=kcp&seed=kcp-seed&headerType=none&security=none#k';

    p = await tcpIn({
      'type': 'vmess',
      'users': [
        {'uuid': uuid, 'alterId': 0},
      ],
      'tls': tls(),
      'transport': {'type': 'ws', 'path': '/vm'},
    });
    links['vmess-ws-tls'] = 'vmess://${base64.encode(utf8.encode(jsonEncode({
          'v': '2', 'ps': 'vm', 'add': '127.0.0.1', 'port': '$p', 'id': uuid,
          'aid': '0', 'scy': 'auto', 'net': 'ws', 'type': 'none',
          'host': 'localhost', 'path': '/vm', 'tls': 'tls', 'sni': 'localhost',
          'allowInsecure': '1',
        })))}';

    p = await tcpIn({
      'type': 'shadowsocks',
      'method': 'aes-128-gcm',
      'password': 'ss-pass',
    });
    links['shadowsocks'] =
        'ss://${base64.encode(utf8.encode('aes-128-gcm:ss-pass'))}@127.0.0.1:$p#s';

    p = await tcpIn({
      'type': 'shadowsocks',
      'method': '2022-blake3-aes-128-gcm',
      'password': ss2022Server,
      'users': [
        {'name': 'u', 'password': ss2022User},
      ],
    });
    links['shadowsocks-2022'] = 'ss://2022-blake3-aes-128-gcm:'
        '${Uri.encodeComponent('$ss2022Server:$ss2022User')}@127.0.0.1:$p#s22';

    p = await udpIn({
      'type': 'hysteria2',
      'users': [
        {'password': 'hy2-pass'},
      ],
      'obfs': {'type': 'salamander', 'password': 'obfs-pass'},
      'tls': tls(alpn: ['h3']),
    });
    links['hysteria2'] = 'hysteria2://hy2-pass@127.0.0.1:$p?sni=localhost'
        '&insecure=1&obfs=salamander&obfs-password=obfs-pass#hy2';

    p = await udpIn({
      'type': 'hysteria',
      'up_mbps': 100,
      'down_mbps': 100,
      'users': [
        {'auth_str': 'hy-token'},
      ],
      'obfs': 'hy-obfs',
      'tls': tls(alpn: ['hysteria']),
    });
    links['hysteria'] = 'hysteria://127.0.0.1:$p?protocol=udp&auth=hy-token'
        '&peer=localhost&insecure=1&upmbps=50&downmbps=50&alpn=hysteria'
        '&obfs=xplus&obfsParam=hy-obfs#hy';

    p = await udpIn({
      'type': 'tuic',
      'users': [
        {'uuid': uuid, 'password': 'tuic-pass'},
      ],
      'congestion_control': 'bbr',
      'tls': tls(alpn: ['h3']),
    });
    links['tuic'] = 'tuic://$uuid:tuic-pass@127.0.0.1:$p?congestion_control=bbr'
        '&udp_relay_mode=native&alpn=h3&sni=localhost&allow_insecure=1#tuic';

    p = await tcpIn({
      'type': 'socks',
      'users': [
        {'username': 'u', 'password': 'p'},
      ],
    });
    links['socks'] = 'socks://${base64.encode(utf8.encode('u:p'))}@127.0.0.1:$p#socks';

    p = await tcpIn({
      'type': 'http',
      'users': [
        {'username': 'u', 'password': 'p'},
      ],
    });
    extraProfiles['http'] = parseHttpProxy('http://u:p@127.0.0.1:$p#http');

    // WireGuard and AmneziaWG: the server side is an endpoint with one peer.
    // Every packet type is padded (S1-S4) because this *server* runs on the
    // Windows bind that zeroes header bytes at offset 0; the client side of
    // that problem is covered by its own test below.
    const amnezia = {
      'jc': 4, 'jmin': 40, 'jmax': 70, 's1': 86, 's2': 122, 's3': 24, 's4': 12,
      'h1': 1033089720, 'h2': 1336452505, 'h3': 1858775673, 'h4': 332219739,
    };
    // The client binds its WireGuard socket to the default network interface
    // (auto_detect_interface), from which loopback is unreachable, so the
    // peer is addressed by this machine's LAN address instead. The adapter
    // is picked by its default gateway, which skips virtual adapters of any
    // VPN that happens to be running.
    final ps = await Process.run('powershell', [
      '-NoProfile',
      '-Command',
      r"(Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway -and "
          r"$_.NetAdapter.Status -eq 'Up' } | Select-Object -First 1)"
          r".IPv4Address.IPAddress",
    ]);
    final lanText = (ps.stdout as String).trim().split(RegExp(r'\s+')).first;
    final lan = InternetAddress.tryParse(lanText)?.address;
    // AmneziaWG 1.x shape: only the handshake initiation is padded, so the
    // server's reply carries its custom header at offset 0.
    const amneziaUnpaddedReply = {
      's1': 86,
      'h1': 1033089720, 'h2': 1336452505, 'h3': 1858775673, 'h4': 332219739,
    };
    final wgVariants = <String, Map<String, int>?>{
      'wireguard': null,
      'amneziawg': amnezia,
      awgUnpaddedReply: amneziaUnpaddedReply,
    };
    for (final (i, variant) in wgVariants.entries.indexed) {
      if (lan == null) break;
      final params = variant.value;
      final port = await freeUdp();
      endpoints.add({
        'type': 'wireguard',
        'tag': 'wg-srv-$i',
        'address': ['10.9.$i.1/24'],
        'private_key': wgSrvPriv,
        'listen_port': port,
        'peers': [
          {
            'public_key': wgCliPub,
            'allowed_ips': ['10.9.$i.2/32'],
          },
        ],
        'amnezia': ?params,
      });
      final conf = StringBuffer()
        ..writeln('[Interface]')
        ..writeln('PrivateKey = $wgCliPriv')
        ..writeln('Address = 10.9.$i.2/32')
        ..writeln('MTU = 1280');
      params?.forEach((k, v) =>
          conf.writeln('${k[0].toUpperCase()}${k.substring(1)} = $v'));
      conf
        ..writeln('[Peer]')
        ..writeln('PublicKey = $wgSrvPub')
        ..writeln('AllowedIPs = 0.0.0.0/0')
        ..writeln('Endpoint = $lan:$port');
      final profile = parseImportText(conf.toString()).profiles.single;
      if (variant.key == awgUnpaddedReply) {
        unpaddedReplyProfile = profile;
      } else {
        extraProfiles[variant.key] = profile;
      }
    }

    server = await startCore({
      'log': {'level': 'warn'},
      'inbounds': inbounds,
      'endpoints': endpoints,
      'outbounds': [
        {'type': 'direct', 'tag': 'direct'},
      ],
      'route': {
        'rules': [
          {
            'ip_cidr': ['$probeIp/32'],
            'action': 'route-options',
            'override_address': '127.0.0.1',
          },
        ],
        'final': 'direct',
      },
    }, tmp, 'server', serverLog);
    await waitForPort(trojanPort, server, serverLog);
  });

  tearDownAll(() async {
    server.kill();
    await server.exitCode;
    await probe.close(force: true);
    // The core may hold its cache file open for a moment after exit.
    for (var i = 0; i < 10; i++) {
      try {
        tmp.deleteSync(recursive: true);
        break;
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    }
  });

  Future<void> roundTrip(String name, ProxyProfile profile,
      {AntiDpiPreset preset = AntiDpiPreset.balanced}) async {
    final mixedPort = await freeTcp();
    final config = buildConfig(
      profiles: [profile],
      settings: AppSettings(
        mixedPort: mixedPort,
        antiDpi: AntiDpiSettings(preset: preset),
        logLevel: 'debug',
      ),
      routing: RoutingSettings(),
      env: BuildEnv(
        platform: CorePlatform.windows,
        ruleSetDir: '${Directory.current.path}/assets/rulesets',
        cacheFile: '${tmp.path}/$name-${preset.name}-cache.db'.replaceAll('\\', '/'),
        clashPort: await freeTcp(),
        clashSecret: 'x',
        corePath: corePath,
      ),
    );
    final log = StringBuffer();
    final client = await startCore(config, tmp, '$name-${preset.name}', log);
    try {
      await waitForPort(mixedPort, client, log);
      final http = HttpClient()
        ..findProxy = ((_) => 'PROXY 127.0.0.1:$mixedPort')
        ..connectionTimeout = const Duration(seconds: 10);
      try {
        final req = await http
            .getUrl(Uri.parse('http://$probeIp:${probe.port}/probe'))
            .timeout(const Duration(seconds: 20));
        final res = await req.close().timeout(const Duration(seconds: 20));
        final body = await res.transform(utf8.decoder).join();
        expect('${res.statusCode} $body', '200 hea-ok',
            reason: 'client log:\n$log\nserver log:\n$serverLog');
      } on Object catch (e) {
        fail('$name (${preset.name}): $e\nclient log:\n$log\nserver log:\n$serverLog');
      } finally {
        http.close(force: true);
      }
    } finally {
      client.kill();
      await client.exitCode;
    }
  }

  test('every protocol carries traffic (balanced anti-DPI)', () async {
    final failures = <String>[];
    final all = <String, ProxyProfile>{
      for (final e in links.entries) e.key: parseLink(e.value),
      ...extraProfiles,
    };
    for (final e in all.entries) {
      try {
        await roundTrip(e.key, e.value);
        // ignore: avoid_print
        print('  ok   ${e.key}');
      } on TestFailure catch (f) {
        // ignore: avoid_print
        print('  FAIL ${e.key}');
        failures.add('${e.key}: ${f.message}');
      }
    }
    expect(failures, isEmpty, reason: failures.join('\n\n'));
  });

  // Regression test for the workaround in hardenOutbound: with the core's
  // default Windows bind the reply below is dropped as "unknown type".
  test('AmneziaWG headers at offset 0 survive on the client', () async {
    final profile = unpaddedReplyProfile;
    if (profile == null) {
      markTestSkipped('no LAN address to reach the WireGuard test server');
      return;
    }
    final mixedPort = await freeTcp();
    final config = buildConfig(
      profiles: [profile],
      settings: AppSettings(mixedPort: mixedPort, logLevel: 'debug'),
      routing: RoutingSettings(),
      env: BuildEnv(
        platform: CorePlatform.windows,
        ruleSetDir: '${Directory.current.path}/assets/rulesets',
        cacheFile: '${tmp.path}/awg-reply-cache.db'.replaceAll('\\', '/'),
        clashPort: await freeTcp(),
        clashSecret: 'x',
        corePath: corePath,
      ),
    );
    expect((config['endpoints'] as List).single['detour'], tagDirect);

    final log = StringBuffer();
    final client = await startCore(config, tmp, 'awg-reply', log);
    try {
      await waitForPort(mixedPort, client, log);
      // Any proxied connection makes the endpoint start its handshake.
      final probeSocket = Socket.connect('127.0.0.1', mixedPort).then((s) {
        s.write('GET http://$probeIp:${probe.port}/ HTTP/1.1\r\n'
            'Host: $probeIp\r\n\r\n');
        return s;
      });
      final deadline = DateTime.now().add(const Duration(seconds: 8));
      while (DateTime.now().isBefore(deadline) &&
          !'$log'.contains('received handshake response')) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      (await probeSocket).destroy();
      expect('$log', contains('received handshake response'),
          reason: 'client log:\n$log');
      expect('$log', isNot(contains('unknown type')));
    } finally {
      client.kill();
      await client.exitCode;
    }
  });

  test('TLS protocols still work with strong anti-DPI (fragmentation)', () async {
    for (final name in [
      'trojan', 'vless-tls-vision', 'vless-reality-vision', 'vless-ws-tls',
      'vless-xhttp-auto', 'vless-xhttp-reality', 'vmess-ws-tls',
    ]) {
      await roundTrip(name, parseLink(links[name]!), preset: AntiDpiPreset.strong);
      // ignore: avoid_print
      print('  ok   $name');
    }
  });
}
