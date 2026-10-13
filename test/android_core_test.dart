// The Android side of running the core, with the VPN service played by the
// test: what the app does when the service fails or never reports back.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heanetwork/core/services/core_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('hea/core');
  const events = EventChannel('hea/core/events');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late Directory dir;
  late List<String> calls;
  MockStreamHandlerEventSink? service;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('hea_android_');
    calls = [];
    service = null;
    messenger.setMockStreamHandler(
        events, MockStreamHandler.inline(onListen: (_, sink) => service = sink));
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'prepare') return true;
      // The service answers a stop the way the real one does.
      if (call.method == 'stop') {
        service?.success({'type': 'status', 'status': 'stopped'});
      }
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockStreamHandler(events, null);
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // The log is still being read; the OS temp cleaner will get it.
    }
  });

  test('a start that fails before the service is asked is a failure, not a hang',
      () async {
    // The log file cannot be made: its folder is a file.
    final inTheWay = File('${dir.path}/taken')..writeAsStringSync('x');
    final core = AndroidCoreController(logFile: File('${inTheWay.path}/run/core.log'));

    await expectLater(core.start(const {}), throwsA(isA<CoreException>()));
    expect(core.status, CoreStatus.stopped, reason: 'not left "connecting" for good');
    expect(calls, isNot(contains('start')));
  });

  test('a service that never reports back is told to stop', () async {
    final core = AndroidCoreController(
        logFile: File('${dir.path}/run/core.log'),
        startTimeout: const Duration(milliseconds: 200));

    await expectLater(
        core.start(const {}),
        throwsA(isA<CoreStartTimeout>()
            .having((e) => e.limit.inMilliseconds, 'limit', 200)));
    expect(core.status, CoreStatus.stopped);
    expect(calls, containsAllInOrder(['prepare', 'start', 'stop']),
        reason: 'or the core would come up later, behind the app\'s back');
  });
}
