// Drives the real core process through the same controller the app uses:
// start, failure reporting, crash detection, orphan cleanup, and latency
// measurement. Skipped when the core has not been fetched.
@TestOn('windows')
@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:heanetwork/core/models/profile.dart';
import 'package:heanetwork/core/models/settings.dart';
import 'package:heanetwork/core/parsers/import_parser.dart';
import 'package:heanetwork/core/services/core_controller.dart';
import 'package:heanetwork/core/services/latency_tester.dart';

final corePath = Platform.environment['HEA_CORE'] ??
    '${Directory.current.path}\\.cache\\core\\sing-box.exe';

Map<String, dynamic> minimalConfig(int port) => {
      'log': {'level': 'info'},
      'inbounds': [
        {'type': 'mixed', 'tag': 'in', 'listen': '127.0.0.1', 'listen_port': port},
      ],
      'outbounds': [
        {'type': 'direct', 'tag': 'direct'},
      ],
    };

Future<bool> portOpen(int port) async {
  try {
    final s = await Socket.connect('127.0.0.1', port,
        timeout: const Duration(milliseconds: 500));
    s.destroy();
    return true;
  } on Object {
    return false;
  }
}

Future<void> settle(bool Function() done) async {
  for (var i = 0; i < 100 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

void main() {
  if (!File(corePath).existsSync()) {
    test('core process', () {}, skip: 'core not found at $corePath');
    return;
  }

  late Directory tmp;
  late ProcessCoreController core;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('hea_proc_');
    core = ProcessCoreController(corePath: corePath, runDir: Directory('${tmp.path}\\run'));
  });

  tearDown(() async {
    await core.stop();
    for (var i = 0; i < 20; i++) {
      try {
        tmp.deleteSync(recursive: true);
        break;
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
  });

  test('starts, serves, logs and stops', () async {
    final port = await freeTcpPort();
    final seen = <CoreStatus>[];
    core.addListener(() => seen.add(core.status));

    await core.start(minimalConfig(port));
    expect(core.status, CoreStatus.running);
    expect(await portOpen(port), isTrue);
    expect(core.logs.join('\n'), contains('sing-box started'));
    expect(File('${tmp.path}\\run\\core.pid').existsSync(), isTrue);

    await core.stop();
    expect(core.status, CoreStatus.stopped);
    expect(core.lastError, isNull, reason: 'a requested stop is not an error');
    expect(await portOpen(port), isFalse);
    expect(seen, [
      CoreStatus.starting,
      CoreStatus.running,
      CoreStatus.stopping,
      CoreStatus.stopped,
    ]);
    await settle(() => !File('${tmp.path}\\run\\core.pid').existsSync());
    expect(File('${tmp.path}\\run\\core.pid').existsSync(), isFalse);
  });

  test('a config the core rejects is reported with its reason', () async {
    final bad = minimalConfig(await freeTcpPort());
    (bad['outbounds'] as List).add({'type': 'no-such-protocol', 'tag': 'x'});
    await expectLater(
      core.start(bad),
      throwsA(isA<CoreException>()
          .having((e) => e.message, 'message', contains('no-such-protocol'))),
    );
    expect(core.status, CoreStatus.stopped);
  });

  test('a busy port is reported instead of hanging', () async {
    final holder = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(holder.close);
    await expectLater(
      core.start(minimalConfig(holder.port)),
      throwsA(isA<CoreException>()
          .having((e) => e.message, 'message', contains('${holder.port}'))),
    );
    expect(core.status, CoreStatus.stopped);
  });

  test('a core that dies on its own is noticed', () async {
    await core.start(minimalConfig(await freeTcpPort()));
    final pid = int.parse(File('${tmp.path}\\run\\core.pid').readAsStringSync());
    Process.killPid(pid);
    await settle(() => core.status == CoreStatus.stopped);
    expect(core.status, CoreStatus.stopped);
    expect(core.lastError, isNotNull);
  });

  test('an orphan from a crashed app is killed, an unrelated pid is not', () async {
    final port = await freeTcpPort();
    final run = Directory('${tmp.path}\\run')..createSync();
    final config = File('${run.path}\\orphan.json')
      ..writeAsStringSync(jsonEncode(minimalConfig(port)));
    final orphan = await Process.start(corePath, ['run', '-c', config.path, '-D', run.path]);
    orphan.stdout.drain<void>();
    orphan.stderr.drain<void>();
    for (var i = 0; i < 100 && !await portOpen(port); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(await portOpen(port), isTrue);

    final pidFile = File('${run.path}\\core.pid')..writeAsStringSync('${orphan.pid}');
    core.killOrphan();
    await orphan.exitCode.timeout(const Duration(seconds: 5));
    expect(await portOpen(port), isFalse);
    expect(pidFile.existsSync(), isFalse);

    // A recycled pid now belonging to something else must be left alone.
    pidFile.writeAsStringSync('$pid');
    core.killOrphan();
    expect(pidFile.existsSync(), isFalse);
    // Still here to assert it: this test process was the "unrelated pid".
  });

  // Needs internet access: the core measures against its built-in HTTPS
  // probe target and ignores a caller-supplied plain-HTTP one.
  test('latency is measured through each server and bad ones are isolated', () async {
    // A local SOCKS server standing in for a remote one.
    final socksPort = await freeTcpPort();
    final serverDir = Directory('${tmp.path}\\server')..createSync();
    final serverConfig = File('${serverDir.path}\\server.json')
      ..writeAsStringSync(jsonEncode({
        'log': {'level': 'error'},
        'inbounds': [
          {'type': 'socks', 'listen': '127.0.0.1', 'listen_port': socksPort},
        ],
        'outbounds': [
          {'type': 'direct', 'tag': 'direct'},
        ],
      }));
    final server =
        await Process.start(corePath, ['run', '-c', serverConfig.path, '-D', serverDir.path]);
    server.stdout.drain<void>();
    server.stderr.drain<void>();
    addTearDown(() async {
      server.kill();
      await server.exitCode;
    });
    for (var i = 0; i < 100 && !await portOpen(socksPort); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }

    final good = parseLink('socks5://127.0.0.1:$socksPort#good');
    final dead = parseLink('socks5://127.0.0.1:${await freeTcpPort()}#dead');
    // Parses fine but the core refuses it, which makes the whole batch fail
    // to start and exercises the bisection.
    final invalid = ProxyProfile(
      name: 'invalid',
      type: Protocol.vless,
      outbound: {'type': 'vless', 'server': '127.0.0.1', 'server_port': 1, 'uuid': 'nope'},
    );

    final results = <String, int>{};
    await LatencyTester(corePath: corePath, workDir: Directory('${tmp.path}\\run')).test(
      [good, invalid, dead],
      antiDpi: AntiDpiSettings(),
      onResult: (p, ms) => results[p.name] = ms,
    );

    expect(results.keys, unorderedEquals(['good', 'invalid', 'dead']));
    expect(results['good'], greaterThanOrEqualTo(0));
    expect(results['dead'], -1);
    expect(results['invalid'], -1);
  });
}
