import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../config/config_builder.dart';
import '../models/profile.dart';
import '../models/settings.dart';
import 'clash_api.dart';

/// Returns [preferred] if it is free on loopback, otherwise an OS-chosen port.
Future<int> freeTcpPort([int? preferred]) async {
  if (preferred != null && preferred > 0) {
    try {
      final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, preferred);
      await s.close();
      return preferred;
    } on SocketException {
      // Taken; fall through to an ephemeral port.
    }
  }
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = s.port;
  await s.close();
  return port;
}

/// Time to open a TCP connection to the server, in ms; -1 on failure and
/// null for UDP-based protocols, where a TCP probe says nothing.
Future<int?> tcpPing(ProxyProfile p,
    {Duration timeout = const Duration(seconds: 3)}) async {
  if (p.isUdpBased || p.server.isEmpty || p.port == 0) return null;
  final sw = Stopwatch()..start();
  try {
    final s = await Socket.connect(p.server, p.port, timeout: timeout);
    s.destroy();
    return sw.elapsedMilliseconds;
  } on Object {
    return -1;
  }
}

/// Measures real request latency through each profile by running a
/// throw-away core instance that exposes them over the Clash API.
class LatencyTester {
  LatencyTester({required this.corePath, required this.workDir});

  final String corePath;
  final Directory workDir;

  static const _concurrency = 6;

  Future<void> test(
    List<ProxyProfile> profiles, {
    required AntiDpiSettings antiDpi,
    required void Function(ProxyProfile profile, int ms) onResult,
    bool elevated = false,
  }) async {
    if (profiles.isEmpty) return;
    if (await _runBatch(profiles, antiDpi, onResult, elevated)) return;
    // The core refused the batch, so some profile is invalid. Bisect to
    // find it instead of failing every server.
    if (profiles.length == 1) {
      onResult(profiles.single, -1);
      return;
    }
    final mid = profiles.length ~/ 2;
    await test(profiles.sublist(0, mid),
        antiDpi: antiDpi, onResult: onResult, elevated: elevated);
    await test(profiles.sublist(mid),
        antiDpi: antiDpi, onResult: onResult, elevated: elevated);
  }

  Future<bool> _runBatch(
    List<ProxyProfile> profiles,
    AntiDpiSettings antiDpi,
    void Function(ProxyProfile, int) onResult,
    bool elevated,
  ) async {
    final port = await freeTcpPort();
    const secret = 'latency';
    await workDir.create(recursive: true);
    final file = File('${workDir.path}${Platform.pathSeparator}latency-$port.json');
    await file.writeAsString(jsonEncode(buildLatencyTestConfig(
      profiles: profiles,
      antiDpi: antiDpi,
      clashPort: port,
      clashSecret: secret,
      elevated: elevated,
    )));

    final process = await Process.start(
        corePath, ['run', '-c', file.path, '-D', workDir.path, '--disable-color']);
    var exited = false;
    unawaited(process.exitCode.then((_) => exited = true));
    unawaited(process.stdout.drain<void>());
    unawaited(process.stderr.drain<void>());

    final api = ClashApi(port, secret);
    try {
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      var ready = false;
      while (!exited && DateTime.now().isBefore(deadline)) {
        if (await api.ping()) {
          ready = true;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
      if (!ready) return false;

      final queue = List.of(profiles);
      Future<void> worker() async {
        while (queue.isNotEmpty) {
          final p = queue.removeLast();
          onResult(p, await api.delay(profileTag(p), url: urlTestTarget));
        }
      }

      await Future.wait(List.generate(_concurrency, (_) => worker()));
      return true;
    } finally {
      api.close();
      process.kill();
      await process.exitCode
          .timeout(const Duration(seconds: 3), onTimeout: () => -1);
      try {
        await file.delete();
      } on FileSystemException {
        // Left for the next run to overwrite.
      }
    }
  }
}
