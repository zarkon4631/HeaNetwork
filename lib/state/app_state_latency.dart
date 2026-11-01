import 'dart:async';
import 'dart:io';

import '../core/models/profile.dart';
import '../core/services/latency_tester.dart';
import '../platform/windows/win32.dart' as win32;
import 'app_state_base.dart';

/// Measuring the delay to each server, through a side run of the core on
/// Windows or a plain TCP probe elsewhere.
mixin AppStateLatency on AppStateBase {
  bool testingLatency = false;

  TcpProbe _platformTcpProbe() {
    if (isAndroid) return androidTcpProbe;
    // Looked up once per run: the adapter does not change within seconds.
    final source = isWindows && Platform.isWindows ? win32.defaultRouteAddress() : null;
    return (host, port, timeout) =>
        dartTcpProbe(host, port, timeout, sourceAddress: source);
  }

  Future<void> testLatency([List<ProxyProfile>? only]) async {
    if (testingLatency) return;
    final targets = List.of(only ?? profiles);
    if (targets.isEmpty) return;
    testingLatency = true;
    for (final p in targets) {
      p.latencyMs = null;
    }
    notifyListeners();
    try {
      // Only Windows ships a core that can be run a second time on the side.
      final corePath = paths.corePath;
      final UrlTest? urlTest = isWindows && corePath != null
          ? (list, onResult) => LatencyTester(corePath: corePath, workDir: paths.run)
              .test(list, antiDpi: settings.antiDpi, elevated: elevated, onResult: onResult)
          : null;
      await measureLatency(
        targets,
        mode: settings.pingMode,
        tcp: tcpProbe ?? _platformTcpProbe(),
        urlTest: urlTest,
        onResult: (p, ms) {
          p.latencyMs = ms;
          notifyListeners();
        },
      );
    } on Object catch (e) {
      error = '$e';
    } finally {
      testingLatency = false;
      unawaited(store.saveProfiles());
      notifyListeners();
    }
  }
}
