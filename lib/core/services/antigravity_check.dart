import 'dart:async';
import 'dart:convert';
import 'dart:io';

class AntigravityCheckResult {
  const AntigravityCheckResult({
    required this.host,
    required this.elapsed,
    this.statusCode,
    this.regionBlocked = false,
    this.error,
  });

  final String host;
  final Duration elapsed;
  final int? statusCode;
  final bool regionBlocked;
  final String? error;

  bool get reachable => statusCode != null;
}

Future<AntigravityCheckResult> checkAntigravity(
  Uri uri, {
  int? proxyPort,
  Duration timeout = const Duration(seconds: 10),
}) async {
  final client = HttpClient()
    ..connectionTimeout = timeout
    ..findProxy = proxyPort == null
        ? (_) => 'DIRECT'
        : (_) => 'PROXY 127.0.0.1:$proxyPort';
  final watch = Stopwatch()..start();
  try {
    final request = await client.getUrl(uri).timeout(timeout);
    request.followRedirects = false;
    request.headers.set(HttpHeaders.userAgentHeader, 'HeaNetwork');
    request.headers.set(
      HttpHeaders.acceptHeader,
      'application/json, text/plain',
    );
    final response = await request.close().timeout(timeout);
    final bytes = <int>[];
    await for (final chunk in response.timeout(timeout)) {
      bytes.addAll(chunk.take(65536 - bytes.length));
      if (bytes.length >= 65536) break;
    }
    final body = utf8.decode(bytes, allowMalformed: true).toLowerCase();
    return AntigravityCheckResult(
      host: uri.host,
      elapsed: watch.elapsed,
      statusCode: response.statusCode,
      regionBlocked:
          response.statusCode == 400 &&
          body.contains('user location is not supported'),
    );
  } on Object catch (e) {
    return AntigravityCheckResult(
      host: uri.host,
      elapsed: watch.elapsed,
      error: '$e',
    );
  } finally {
    client.close(force: true);
  }
}
