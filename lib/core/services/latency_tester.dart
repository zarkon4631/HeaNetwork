import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

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

/// Opens a TCP connection to [host]:[port] and reports how long that took in
/// ms, -1 when the server did not answer, or null when a TCP connection
/// cannot tell anything about it.
typedef TcpProbe = Future<int?> Function(String host, int port, Duration timeout);

/// Measures [profiles] through their servers, as [LatencyTester.test] does.
typedef UrlTest = Future<void> Function(
    List<ProxyProfile> profiles, void Function(ProxyProfile profile, int ms) onResult);

/// True for an address handed out by a FakeIP DNS (the ranges this app and
/// most other clients use): it stands for a name, not for a real server.
bool isFakeIp(InternetAddress address) {
  final b = address.rawAddress;
  if (b.length == 4) return b[0] == 198 && (b[1] == 18 || b[1] == 19);
  return b[0] == 0xfc && b[1] == 0 && b[2] < 0x40;
}

// WSAEADDRNOTAVAIL and its POSIX counterpart: the address to bind to is gone.
bool _cannotBind(SocketException e) =>
    e.osError?.errorCode == 10049 || e.osError?.errorCode == 99;

/// The [TcpProbe] for plain sockets. The name is resolved first so that only
/// the handshake is timed, and the better of two connections is reported so
/// one delayed packet does not misrepresent the server.
///
/// [sourceAddress], an IPv4 address of the real network adapter, keeps the
/// probe out of a VPN tunnel that has taken over the routing table: inside
/// a tunnel the handshake is answered locally in under a millisecond no
/// matter how far away the server is.
Future<int?> dartTcpProbe(String host, int port, Duration timeout,
    {String? sourceAddress}) async {
  var address = InternetAddress.tryParse(host);
  if (address == null) {
    try {
      final found = await InternetAddress.lookup(host).timeout(timeout);
      address = found.where((a) => a.type == InternetAddressType.IPv4).firstOrNull ??
          found.firstOrNull;
    } on Object {
      return -1;
    }
    if (address == null) return -1;
  }
  if (isFakeIp(address)) return null;

  final target = address;
  Future<int> connect(String? from) async {
    final watch = Stopwatch()..start();
    final socket =
        await Socket.connect(target, port, sourceAddress: from, timeout: timeout);
    final ms = (watch.elapsedMicroseconds / 1000).round();
    socket.destroy();
    return ms < 1 ? 1 : ms;
  }

  Future<int> measure(String? from) async {
    final first = await connect(from);
    try {
      final second = await connect(from);
      return second < first ? second : first;
    } on Object {
      return first;
    }
  }

  final source = target.type == InternetAddressType.IPv4 ? sourceAddress : null;
  try {
    return await measure(source);
  } on SocketException catch (e) {
    if (source == null || !_cannotBind(e)) return -1;
    // The adapter changed under us (cable out, Wi-Fi switched): measure the
    // ordinary way rather than report a working server as dead.
    try {
      return await measure(null);
    } on Object {
      return -1;
    }
  } on Object {
    return -1;
  }
}

const _androidChannel = MethodChannel('hea/core');

/// The [TcpProbe] for Android, where it runs natively on the device's real
/// network: while the VPN is up, this app's own sockets go into the tunnel.
Future<int?> androidTcpProbe(String host, int port, Duration timeout) async {
  try {
    return await _androidChannel.invokeMethod<int>('tcpPing', {
          'host': host,
          'port': port,
          'timeout': timeout.inMilliseconds,
        }) ??
        -1;
  } on MissingPluginException {
    return dartTcpProbe(host, port, timeout);
  } on PlatformException {
    return -1;
  }
}

/// TCP-probes [profiles], a few at a time. [onResult] gets null for a
/// profile a TCP connection says nothing about: a UDP-based protocol, or a
/// server whose address cannot be learnt right now.
Future<void> tcpPingAll(
  List<ProxyProfile> profiles, {
  required TcpProbe probe,
  required void Function(ProxyProfile profile, int? ms) onResult,
  Duration timeout = const Duration(seconds: 3),
  int concurrency = 16,
}) async {
  final queue = List.of(profiles.reversed);
  Future<void> worker() async {
    while (queue.isNotEmpty) {
      final p = queue.removeLast();
      if (p.isUdpBased || p.server.isEmpty || p.port == 0) {
        onResult(p, null);
        continue;
      }
      int? ms;
      try {
        ms = await probe(p.server, p.port, timeout);
      } on Object {
        ms = -1;
      }
      onResult(p, ms);
    }
  }

  await Future.wait(List.generate(concurrency, (_) => worker()));
}

/// Measures [profiles] the way [mode] asks for. In TCP mode whatever a TCP
/// connection cannot measure is sent through [urlTest] instead; without a
/// [urlTest] (no spare core on this platform) everything is TCP-probed and
/// the rest is reported as null, i.e. not measured.
Future<void> measureLatency(
  List<ProxyProfile> profiles, {
  required PingMode mode,
  required TcpProbe tcp,
  required void Function(ProxyProfile profile, int? ms) onResult,
  UrlTest? urlTest,
}) async {
  var throughServer = profiles;
  if (mode == PingMode.tcp || urlTest == null) {
    throughServer = [];
    await tcpPingAll(profiles, probe: tcp, onResult: (p, ms) {
      if (ms == null && urlTest != null) {
        throughServer.add(p);
      } else {
        onResult(p, ms);
      }
    });
  }
  if (throughServer.isNotEmpty && urlTest != null) {
    await urlTest(throughServer, onResult);
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
