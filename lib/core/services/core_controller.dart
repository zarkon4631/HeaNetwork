import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../platform/windows/win32.dart' as win32;
import 'clash_api.dart';

enum CoreStatus { stopped, starting, running, stopping }

class CoreException implements Exception {
  CoreException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The start was called off with [CoreController.stop] before it finished.
/// Not a failure: the user changed their mind.
class CoreCancelled extends CoreException {
  CoreCancelled() : super('cancelled');
}

/// The core kept running but never became ready.
class CoreStartTimeout extends CoreException {
  CoreStartTimeout(this.limit, String lastLine)
      : super('the core did not start within ${limit.inSeconds} seconds'
            '${lastLine.isEmpty ? '' : ' ($lastLine)'}');
  final Duration limit;
}

final _ansi = RegExp(r'\x1B\[[0-9;]*m');

/// Picks the most useful line out of core output for an error message.
String summarizeCoreFailure(Iterable<String> lines) {
  final list = lines.toList();
  for (final level in ['FATAL', 'ERROR']) {
    final hit = list.lastWhere((l) => l.contains(level), orElse: () => '');
    if (hit.isNotEmpty) {
      return hit.replaceFirst(RegExp('^.*?$level(\\[\\d+\\])?\\s*'), '').trim();
    }
  }
  return list.isEmpty ? 'the core exited without output' : list.last.trim();
}

/// Runs the proxy core and reports its state and log.
abstract class CoreController extends ChangeNotifier {
  CoreStatus _status = CoreStatus.stopped;
  CoreStatus get status => _status;

  /// Why the core stopped on its own, if it did.
  String? lastError;

  static const _maxLogLines = 2000;
  final List<String> logs = [];
  final _logStream = StreamController<String>.broadcast();
  Stream<String> get logStream => _logStream.stream;

  @protected
  void setStatus(CoreStatus s) {
    if (_status == s) return;
    _status = s;
    notifyListeners();
  }

  /// Records a line of core output; returns it cleaned up, or null when
  /// there was nothing in it.
  @protected
  String? addLog(String line) {
    final clean = line.replaceAll(_ansi, '').trimRight();
    if (clean.isEmpty) return null;
    logs.add(clean);
    if (logs.length > _maxLogLines) logs.removeRange(0, logs.length - _maxLogLines);
    _logStream.add(clean);
    return clean;
  }

  void clearLogs() {
    logs.clear();
    notifyListeners();
  }

  /// Starts the core with [config]. Completes once it is serving; throws
  /// [CoreException] with the core's own complaint if it cannot start, or
  /// [CoreCancelled] if [stop] was called meanwhile.
  Future<void> start(Map<String, dynamic> config);

  /// Stops the core. Called while it is still starting, calls the start off.
  Future<void> stop();
}

/// Windows: the core is a child process fed a config file.
class ProcessCoreController extends CoreController {
  ProcessCoreController({
    required this.corePath,
    required this.runDir,
    this.startTimeout = const Duration(seconds: 60),
  });

  final String corePath;
  final Directory runDir;

  /// How long the core may take to become ready. Generous, because the
  /// first VPN start installs a network driver, and because the wait can be
  /// called off with [stop] at any moment.
  final Duration startTimeout;
  Process? _process;
  bool _cancelled = false;

  File get _pidFile => File('${runDir.path}\\core.pid');

  /// What the core printed during this run, kept on disk so that a failure
  /// can still be looked into after the app was closed. The run before it
  /// is in [previousLogFile].
  File get logFile => File('${runDir.path}\\core.log');
  File get previousLogFile => File('${runDir.path}\\core.prev.log');

  static const _maxLogFileBytes = 4 * 1024 * 1024;
  IOSink? _logSink;
  int _logFileBytes = 0;

  /// Completes when the file of the previous run has been let go of; it
  /// cannot be renamed before that.
  Future<void> _logClosed = Future.value();

  void _openLogFile() {
    try {
      if (logFile.existsSync()) {
        if (previousLogFile.existsSync()) previousLogFile.deleteSync();
        logFile.renameSync(previousLogFile.path);
      }
      _logSink = logFile.openWrite();
      _logFileBytes = 0;
    } on FileSystemException {
      // The log file is a convenience; the core runs without it.
      _logSink = null;
    }
  }

  void _writeLogFile(String line) {
    final sink = _logSink;
    if (sink == null) return;
    sink.writeln(line);
    _logFileBytes += line.length + 2;
    if (_logFileBytes > _maxLogFileBytes) {
      // A long session at "debug" level: start a fresh file and keep the
      // full one as the previous, so the disk use stays bounded.
      _closeLogFile();
      unawaited(_logClosed.then((_) {
        if (_process != null && _logSink == null) _openLogFile();
      }));
    }
  }

  void _closeLogFile() {
    final sink = _logSink;
    if (sink == null) return;
    _logSink = null;
    _logClosed = sink.close().then<void>((_) {}).catchError((Object _) {});
  }

  /// Client for the API the core was told to open in [config], if any.
  static ClashApi? _apiOf(Map<String, dynamic> config) {
    final experimental = config['experimental'];
    final api = experimental is Map ? experimental['clash_api'] : null;
    if (api is! Map) return null;
    final address = '${api['external_controller'] ?? ''}';
    final port = int.tryParse(address.substring(address.lastIndexOf(':') + 1));
    if (port == null || port <= 0) return null;
    return ClashApi(port, '${api['secret'] ?? ''}');
  }

  /// Kills a core left behind by a previous run of the app that crashed.
  /// The PID is only trusted if it still belongs to our core executable.
  void killOrphan() {
    try {
      if (!_pidFile.existsSync()) return;
      final pid = int.tryParse(_pidFile.readAsStringSync().trim());
      if (pid != null &&
          win32.processPath(pid)?.toLowerCase() == corePath.toLowerCase()) {
        Process.killPid(pid);
      }
      _pidFile.deleteSync();
    } on Object {
      // Nothing useful to do about a stale pid file we cannot read.
    }
  }

  @override
  Future<void> start(Map<String, dynamic> config) async {
    if (status != CoreStatus.stopped) {
      throw CoreException('the core is already running');
    }
    if (!File(corePath).existsSync()) {
      throw CoreException('core not found: $corePath');
    }
    lastError = null;
    _cancelled = false;
    setStatus(CoreStatus.starting);
    final api = _apiOf(config);
    try {
      await runDir.create(recursive: true);
      final configFile = File('${runDir.path}\\config.json');
      await configFile.writeAsString(jsonEncode(config), flush: true);
      await _logClosed;
      _openLogFile();

      final process = await Process.start(
        corePath,
        ['run', '-c', configFile.path, '-D', runDir.path, '--disable-color'],
        workingDirectory: runDir.path,
      );
      _process = process;
      await _pidFile.writeAsString('${process.pid}');

      final started = Completer<void>();
      final recent = <String>[];
      void onLine(String line) {
        final clean = addLog(line);
        if (clean == null) return;
        _writeLogFile(clean);
        recent.add(clean);
        if (recent.length > 40) recent.removeAt(0);
        if (!started.isCompleted && clean.contains('sing-box started')) {
          started.complete();
        }
      }

      // Whatever the core prints must not be able to break the reader.
      const lines = LineSplitter();
      const decoder = Utf8Decoder(allowMalformed: true);
      process.stdout.transform(decoder).transform(lines).listen(onLine, onError: (_) {});
      process.stderr.transform(decoder).transform(lines).listen(onLine, onError: (_) {});

      unawaited(process.exitCode.then((code) async {
        if (_process != process) return;
        _process = null;
        // Let the pipes drain so the reason for the exit is in `recent`.
        await Future<void>.delayed(const Duration(milliseconds: 150));
        final wanted = status == CoreStatus.stopping;
        if (!started.isCompleted) {
          started.completeError(
              _cancelled ? CoreCancelled() : CoreException(summarizeCoreFailure(recent)));
        } else if (!wanted) {
          lastError = summarizeCoreFailure(recent);
        }
        try {
          if (_pidFile.existsSync()) _pidFile.deleteSync();
        } on FileSystemException {
          // Harmless: killOrphan validates the pid before using it.
        }
        _closeLogFile();
        setStatus(CoreStatus.stopped);
      }));

      // "sing-box started" is only printed at the "info" log level and
      // above, so the line alone cannot be relied on: with "warn" a healthy
      // core would look as if it never started. The API answers once the
      // core has finished starting, whatever it logs.
      if (api != null) {
        unawaited(() async {
          while (!started.isCompleted && _process == process) {
            if (await api.ping()) {
              if (!started.isCompleted) started.complete();
              return;
            }
            await Future<void>.delayed(const Duration(milliseconds: 200));
          }
        }());
      }

      await started.future.timeout(startTimeout, onTimeout: () {
        throw CoreStartTimeout(
            startTimeout, recent.isEmpty ? '' : summarizeCoreFailure([recent.last]));
      });
      setStatus(CoreStatus.running);
    } on Object catch (e) {
      _process?.kill();
      _process = null;
      _closeLogFile();
      setStatus(CoreStatus.stopped);
      if (e is CoreException) rethrow;
      throw CoreException('$e');
    } finally {
      api?.close();
    }
  }

  @override
  Future<void> stop() async {
    final process = _process;
    if (process == null) {
      setStatus(CoreStatus.stopped);
      return;
    }
    if (status == CoreStatus.starting) _cancelled = true;
    setStatus(CoreStatus.stopping);
    process.kill();
    await process.exitCode.timeout(const Duration(seconds: 5), onTimeout: () {
      process.kill(ProcessSignal.sigkill);
      return -1;
    });
    // The exit handler above flips the status; wait for it to settle.
    for (var i = 0; i < 20 && status != CoreStatus.stopped; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    setStatus(CoreStatus.stopped);
  }
}

/// Android: the core runs inside the app's VpnService; this talks to it over
/// a method channel and mirrors its state from an event channel.
class AndroidCoreController extends CoreController {
  AndroidCoreController({required this.logFile}) {
    _events.receiveBroadcastStream().listen(_onEvent);
  }

  /// The file the core is configured to log to; tailed while it runs.
  final File logFile;

  static const _channel = MethodChannel('hea/core');
  static const _events = EventChannel('hea/core/events');

  Completer<void>? _starting;
  bool _cancelled = false;
  Timer? _tail;
  int _logOffset = 0;
  String _partialLine = '';

  void _startTail({bool fromStart = true}) {
    _tail?.cancel();
    _partialLine = '';
    _logOffset = fromStart || !logFile.existsSync() ? 0 : logFile.lengthSync();
    _tail = Timer.periodic(const Duration(milliseconds: 700), (_) => _readLog());
  }

  Future<void> _readLog() async {
    try {
      if (!await logFile.exists()) return;
      final length = await logFile.length();
      if (length < _logOffset) _logOffset = 0; // truncated by a restart
      if (length == _logOffset) return;
      final chunk = await logFile
          .openRead(_logOffset, length)
          .transform(const Utf8Decoder(allowMalformed: true))
          .join();
      _logOffset = length;
      final lines = (_partialLine + chunk).split('\n');
      _partialLine = lines.removeLast();
      lines.forEach(addLog);
    } on FileSystemException {
      // The file is being rotated or removed; the next tick retries.
    }
  }

  void _stopTail() {
    _tail?.cancel();
    _tail = null;
    // Pick up what the core wrote on its way out.
    unawaited(_readLog());
  }

  void _onEvent(Object? event) {
    if (event is! Map) return;
    switch (event['type']) {
      case 'log':
        addLog('${event['message']}');
      case 'status':
        final s = switch (event['status']) {
          'starting' => CoreStatus.starting,
          'running' => CoreStatus.running,
          'stopping' => CoreStatus.stopping,
          _ => CoreStatus.stopped,
        };
        final error = event['error'] as String?;
        final starting = _starting;
        if (s == CoreStatus.running) {
          if (starting != null && !starting.isCompleted) starting.complete();
        } else if (s == CoreStatus.stopped) {
          _stopTail();
          if (starting != null && !starting.isCompleted) {
            starting.completeError(_cancelled
                ? CoreCancelled()
                : CoreException(error ?? 'the VPN service stopped'));
          } else if (error != null) {
            lastError = error;
          }
        }
        setStatus(s);
    }
  }

  /// Asks for the system VPN permission. False if the user refused.
  Future<bool> prepare() async =>
      await _channel.invokeMethod<bool>('prepare') ?? false;

  /// Syncs with a service that may already be running (app was restarted).
  Future<void> sync() async {
    final s = await _channel.invokeMethod<String>('status');
    if (s == 'running') _startTail(fromStart: false);
    setStatus(s == 'running' ? CoreStatus.running : CoreStatus.stopped);
  }

  @override
  Future<void> start(Map<String, dynamic> config) async {
    if (status != CoreStatus.stopped) {
      throw CoreException('the VPN is already running');
    }
    lastError = null;
    _cancelled = false;
    if (!await prepare()) throw CoreException('VPN permission was not granted');
    final starting = _starting = Completer<void>();
    setStatus(CoreStatus.starting);
    try {
      await logFile.parent.create(recursive: true);
      await logFile.writeAsString('');
      _startTail();
      await _channel.invokeMethod<void>('start', {'config': jsonEncode(config)});
      const limit = Duration(seconds: 30);
      await starting.future.timeout(limit, onTimeout: () {
        throw CoreStartTimeout(limit, '');
      });
    } on PlatformException catch (e) {
      setStatus(CoreStatus.stopped);
      throw CoreException(e.message ?? e.code);
    } on CoreException {
      setStatus(CoreStatus.stopped);
      rethrow;
    } finally {
      _starting = null;
    }
  }

  @override
  Future<void> stop() async {
    if (status == CoreStatus.stopped) return;
    if (status == CoreStatus.starting) _cancelled = true;
    setStatus(CoreStatus.stopping);
    await _channel.invokeMethod<void>('stop');
    for (var i = 0; i < 100 && status != CoreStatus.stopped; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    setStatus(CoreStatus.stopped);
  }
}
