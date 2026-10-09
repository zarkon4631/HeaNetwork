// Drives the real core process through the same controller the app uses:
// start, failure reporting, crash detection, orphan cleanup, and latency
// measurement. Skipped when the core has not been fetched.
@TestOn('windows')
@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
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

  // What the app's configs look like to the controller: a log level and the
  // API the core is told to open.
  Map<String, dynamic> appLikeConfig(int port, String level, {int? apiPort}) => {
        ...minimalConfig(port),
        'log': {'level': level, 'timestamp': true},
        if (apiPort != null)
          'experimental': {
            'clash_api': {'external_controller': '127.0.0.1:$apiPort', 'secret': 's3cret'},
          },
      };

  test('a quiet log level does not make a healthy core look dead', () async {
    // At "warn" the core prints nothing on a clean start, least of all the
    // "sing-box started" line; its API answering is what counts.
    final port = await freeTcpPort();
    final watch = Stopwatch()..start();
    await core.start(appLikeConfig(port, 'warn', apiPort: await freeTcpPort()));
    expect(core.status, CoreStatus.running);
    expect(watch.elapsed, lessThan(const Duration(seconds: 15)));
    expect(core.logs.join('\n'), isNot(contains('sing-box started')));
    expect(await portOpen(port), isTrue);
    await core.stop();
    expect(core.lastError, isNull);
  });

  test('a start can be called off while it is still waiting', () async {
    // No API and a silent log level: this core never reports ready.
    final port = await freeTcpPort();
    final starting = core.start(appLikeConfig(port, 'warn'));
    Object? outcome;
    unawaited(starting.then((_) => outcome = 'started', onError: (Object e) => outcome = e));
    for (var i = 0; i < 100 && !await portOpen(port); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(core.status, CoreStatus.starting);

    final watch = Stopwatch()..start();
    await core.stop();
    await settle(() => outcome != null);
    expect(outcome, isA<CoreCancelled>());
    expect(watch.elapsed, lessThan(const Duration(seconds: 6)));
    expect(core.status, CoreStatus.stopped);
    expect(core.lastError, isNull, reason: 'calling it off is not a failure');
    expect(await portOpen(port), isFalse, reason: 'the core is gone');

    // The controller is usable again straight away.
    await core.start(minimalConfig(port));
    expect(core.status, CoreStatus.running);
  });

  test('a core that never becomes ready is stopped after the limit', () async {
    final impatient = ProcessCoreController(
      corePath: corePath,
      runDir: Directory('${tmp.path}\\run2'),
      startTimeout: const Duration(seconds: 2),
    );
    addTearDown(impatient.stop);
    final port = await freeTcpPort();
    await expectLater(
      impatient.start(appLikeConfig(port, 'warn')),
      throwsA(isA<CoreStartTimeout>()
          .having((e) => e.limit.inSeconds, 'limit', 2)
          .having((e) => e.message, 'message', contains('2 seconds'))),
    );
    expect(impatient.status, CoreStatus.stopped);
    for (var i = 0; i < 30 && await portOpen(port); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(await portOpen(port), isFalse, reason: 'it must not be left running');
  });

  test('the log of a run is kept on disk, and the run before it too', () async {
    await core.start(minimalConfig(await freeTcpPort()));
    await core.stop();
    await settle(() => core.logFile.existsSync() && core.logFile.lengthSync() > 0);
    final first = core.logFile.readAsStringSync();
    expect(first, contains('sing-box started'));

    final port = await freeTcpPort();
    await core.start(minimalConfig(port));
    await core.stop();
    await settle(() => core.logFile.existsSync() && core.logFile.lengthSync() > 0);
    expect(core.previousLogFile.readAsStringSync(), first);
    expect(core.logFile.readAsStringSync(), contains('127.0.0.1:$port'));
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

    // The probe leaves this machine, so the outcome for the good server
    // depends on the network: no internet means nothing to assert about it,
    // and one slow answer under load deserves a second try.
    Future<bool> online() async {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
      try {
        final request = await client.getUrl(Uri.parse('https://www.gstatic.com/generate_204'));
        final response = await request.close().timeout(const Duration(seconds: 5));
        await response.drain<void>();
        return true;
      } on Object {
        return false;
      } finally {
        client.close(force: true);
      }
    }

    var results = <String, int>{};
    for (var attempt = 0; attempt < 3; attempt++) {
      results = {};
      await LatencyTester(corePath: corePath, workDir: Directory('${tmp.path}\\run')).test(
        [good, invalid, dead],
        antiDpi: AntiDpiSettings(),
        onResult: (p, ms) => results[p.name] = ms,
      );
      if ((results['good'] ?? -1) >= 0) break;
    }

    // These hold with or without a network.
    expect(results.keys, unorderedEquals(['good', 'invalid', 'dead']));
    expect(results['dead'], -1);
    expect(results['invalid'], -1);
    if (results['good']! < 0 && !await online()) {
      markTestSkipped('no internet access to measure a real delay');
      return;
    }
    expect(results['good'], greaterThanOrEqualTo(0));
  });
}
