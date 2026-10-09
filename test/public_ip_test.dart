// The device's public address: reading an address service's answer,
// asking several at once, and not asking more often than needed.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:heanetwork/core/services/public_ip.dart';

void main() {
  test('an address service answer', () {
    expect(parseAddress('203.0.113.7\n'), '203.0.113.7');
    expect(parseAddress('  203.0.113.7  '), '203.0.113.7');
    expect(parseAddress('2001:db8::1'), '2001:db8::1');
    // Chunked transfer framing around the body.
    expect(parseAddress('d\r\n203.0.113.7\r\n0\r\n'), '203.0.113.7');

    expect(parseAddress(''), isNull);
    expect(parseAddress('<html>access denied</html>'), isNull);
    expect(parseAddress('127.0.0.1'), isNull);
    expect(parseAddress('198.18.0.5'), isNull, reason: 'a FakeIP stands for a name');
  });

  test('the headers a reverse proxy would set', () {
    expect(addressHeaders(null), isEmpty);
    expect(addressHeaders('203.0.113.7'),
        {'X-Real-IP': '203.0.113.7', 'X-Forwarded-For': '203.0.113.7'});
  });

  test('the first usable answer wins', () async {
    expect(
        await firstAnswer<String>([
          Future.value(null),
          Future.delayed(const Duration(milliseconds: 30), () => 'slow'),
          Future.delayed(const Duration(milliseconds: 5), () => 'fast'),
          Future.error(StateError('unreachable')),
        ]),
        'fast');
    expect(
        await firstAnswer<String>(
            [Future.value(null), Future.error(StateError('unreachable'))]),
        isNull);
    expect(await firstAnswer<String>(const []), isNull);
  });

  test('an answer is reused; a failure is neither fatal nor final', () async {
    var calls = 0;
    final ip = PublicIp(() async {
      calls++;
      return '203.0.113.7';
    }, retryAfter: Duration.zero);
    expect(await ip.current(), '203.0.113.7');
    expect(await ip.current(), '203.0.113.7');
    expect(calls, 1, reason: 'several subscriptions in a row ask once');

    var attempts = 0;
    final flaky = PublicIp(() async {
      if (attempts++ == 0) throw StateError('offline');
      return '203.0.113.9';
    }, retryAfter: Duration.zero);
    expect(await flaky.current(), isNull);
    expect(await flaky.current(), '203.0.113.9');

    final stuck = PublicIp(() => Completer<String?>().future,
        limit: const Duration(milliseconds: 20));
    expect(await stuck.current(), isNull, reason: 'a request never waits for long');
  });
}
