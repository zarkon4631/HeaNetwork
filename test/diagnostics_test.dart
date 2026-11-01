// The diagnostics bundle for support: what the report says about the app,
// and that nothing pastable carries a credential.
import 'package:flutter_test/flutter_test.dart';
import 'package:heanetwork/core/services/diagnostics.dart';

void main() {
  test('the header tells the app, platform, mode and status', () {
    final r = diagnosticsReport(
      appVersion: '1.0.15',
      platformLabel: 'Windows',
      modeLabel: 'tun',
      statusLabel: 'running',
      log: const ['INFO inbound/tcp started'],
    );
    final lines = r.split('\n');
    expect(lines[0], 'HeaNetwork 1.0.15');
    expect(lines[1], 'Windows · tun · running');
    expect(r, contains('INFO inbound/tcp started'));
  });

  test('without a log the report is just the header', () {
    expect(
        diagnosticsReport(
            appVersion: '1',
            platformLabel: 'Android',
            modeLabel: 'systemProxy',
            statusLabel: 'stopped'),
        'HeaNetwork 1\nAndroid · systemProxy · stopped');
  });

  test('only the end of a long log goes in', () {
    final r = diagnosticsReport(
      appVersion: '1',
      platformLabel: 'Windows',
      modeLabel: 'tun',
      statusLabel: 'stopped',
      log: List.generate(400, (i) => 'line $i'),
      maxLogLines: 50,
    );
    expect(r, contains('line 399'));
    expect(r, isNot(contains('line 100')));
  });

  group('scrubLogLine', () {
    test('server and client UUIDs go, the rest of the line stays', () {
      const id = '123e4567-e89b-42d3-a456-426614174000';
      final out = scrubLogLine('INFO outbound/vmess[$id] dial tcp 203.0.113.5:443');
      expect(out, 'INFO outbound/vmess[[uuid]] dial tcp 203.0.113.5:443');
      expect(out, contains('203.0.113.5:443'),
          reason: 'addresses are what support asks about next');
    });

    test('the credentials in a share link go', () {
      expect(
          scrubLogLine(
              'failed: vless://d76f-a-uuid-like-secret@example.com:443?type=xhttp'),
          isNot(contains('d76f-a-uuid-like-secret')));
      expect(
          scrubLogLine('failed: vless://abc123def456@example.com:443'),
          contains('vless://[…]@example.com:443'));
    });

    test('a subscription URL keeps the host, loses the token', () {
      const url =
          'https://panel.example.com/sub/9f8e7d6c5b4a3210f9e8d7c6b5a43210?token=secretvalue123456';
      final out = scrubLogLine('ERROR fetch $url: timeout');
      expect(out, contains('https://panel.example.com/'));
      expect(out, isNot(contains('9f8e7d6c5b4a3210f9e8d7c6b5a43210')));
      expect(out, isNot(contains('secretvalue123456')));
    });

    test('short harmless paths and known URLs stay readable', () {
      expect(scrubLogLine('GET https://www.gstatic.com/generate_204 done'),
          contains('https://www.gstatic.com/generate_204'));
    });

    test('userinfo in an http URL goes', () {
      expect(scrubLogLine('open https://user:pa55w0rd@example.com/x'),
          contains('https://[…]@example.com/x'));
    });

    test('password fields go, whatever shape they take', () {
      expect(scrubLogLine('config password: hunter2 end'),
          isNot(contains('hunter2')));
      expect(scrubLogLine('password=hunter2'), isNot(contains('hunter2')));
      expect(scrubLogLine('private-key: 8N7rTkeymaterialishere000000000000000000000='),
          isNot(contains('8N7rTkeymaterialishere')));
    });

    test('a plain line comes back untouched', () {
      const line = 'INFO [2856] outbound/direct: outbound connection to 91.198.174.192:80';
      expect(scrubLogLine(line), line);
    });
  });
}
