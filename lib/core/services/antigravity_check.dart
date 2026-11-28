import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/settings.dart';

class AntigravityCheckResult {
  const AntigravityCheckResult({
    required this.host,
    required this.elapsed,
    this.statusCode,
    this.regionBlocked = false,
    this.proxyAuthFailed = false,
    this.error,
  });

  final String host;
  final Duration elapsed;
  final int? statusCode;
  final bool regionBlocked;
  final bool proxyAuthFailed;
  final String? error;

  bool get reachable => statusCode != null && !proxyAuthFailed;
}

Future<AntigravityCheckResult> checkAntigravity(
  Uri uri, {
  int? proxyPort,
  AntigravityProxy? httpProxy,
  Duration timeout = const Duration(seconds: 10),
}) async {
  if (httpProxy != null) {
    return _checkViaHttpProxy(uri, httpProxy, timeout: timeout);
  }
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

/// Probes [uri] directly through [proxy] using explicit HTTP/HTTPS CONNECT
/// with preemptive Basic auth. Avoids `HttpClient`'s infinite 407 retry loop
/// on bad proxy credentials and supports `https://` proxies as well.
Future<AntigravityCheckResult> _checkViaHttpProxy(
  Uri uri,
  AntigravityProxy proxy, {
  required Duration timeout,
}) async {
  final watch = Stopwatch()..start();
  final deadline = DateTime.now().add(timeout);
  Duration remaining() {
    final left = deadline.difference(DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }

  RawSocket? raw;
  RawSecureSocket? tunnel;
  StreamSubscription<RawSocketEvent>? sub;
  try {
    raw = proxy.tls
        ? await RawSecureSocket.connect(
            proxy.host,
            proxy.port,
            timeout: remaining(),
          )
        : await RawSocket.connect(
            proxy.host,
            proxy.port,
            timeout: remaining(),
          );

    final authHeader =
        proxy.username.isEmpty && proxy.password.isEmpty
            ? ''
            : 'Proxy-Authorization: Basic '
                '${base64Encode(utf8.encode('${proxy.username}:${proxy.password}'))}\r\n';
    final targetPort = uri.hasPort
        ? uri.port
        : (uri.scheme == 'https' ? 443 : 80);
    final path = uri.path.isEmpty ? '/' : uri.path;
    final pathWithQuery = uri.hasQuery ? '$path?${uri.query}' : path;

    if (uri.scheme == 'https') {
      final connectReq =
          'CONNECT ${uri.host}:$targetPort HTTP/1.1\r\n'
          'Host: ${uri.host}:$targetPort\r\n'
          '$authHeader'
          'User-Agent: HeaNetwork\r\n\r\n';
      _writeAll(raw, utf8.encode(connectReq));

      final headerEnd = Completer<String>();
      final buf = <int>[];
      sub = raw.listen(
        (event) {
          if (event == RawSocketEvent.read) {
            final chunk = raw!.read();
            if (chunk != null) buf.addAll(chunk);
            final end = _indexOfHeaderEnd(buf);
            if (end >= 0 && !headerEnd.isCompleted) {
              headerEnd.complete(latin1.decode(buf.sublist(0, end)));
            }
          } else if ((event == RawSocketEvent.readClosed ||
                  event == RawSocketEvent.closed) &&
              !headerEnd.isCompleted) {
            headerEnd.completeError(
              const SocketException('proxy closed connection during CONNECT'),
            );
          }
        },
        onError: (Object e) {
          if (!headerEnd.isCompleted) headerEnd.completeError(e);
        },
      );

      final head = await headerEnd.future.timeout(remaining());
      final proxyStatus = _parseStatusCode(head);
      if (proxyStatus == HttpStatus.proxyAuthenticationRequired) {
        return AntigravityCheckResult(
          host: uri.host,
          elapsed: watch.elapsed,
          statusCode: proxyStatus,
          proxyAuthFailed: true,
        );
      }
      if (proxyStatus != HttpStatus.ok) {
        return AntigravityCheckResult(
          host: uri.host,
          elapsed: watch.elapsed,
          error: 'Proxy CONNECT returned HTTP ${proxyStatus ?? head.split('\r\n').first}',
        );
      }

      tunnel = await RawSecureSocket.secure(
        raw,
        subscription: sub,
        host: uri.host,
      ).timeout(remaining());
      sub = null; // Owned by [tunnel] now.

      final getReq =
          'GET $pathWithQuery HTTP/1.1\r\n'
          'Host: ${uri.host}\r\n'
          'User-Agent: HeaNetwork\r\n'
          'Accept: application/json, text/plain\r\n'
          'Connection: close\r\n\r\n';
      _writeAll(tunnel, utf8.encode(getReq));
      final responseBytes = await _readHttpResponse(tunnel, remaining());
      return _resultFromBytes(uri.host, watch.elapsed, responseBytes);
    }

    final getReq =
        'GET $uri HTTP/1.1\r\n'
        'Host: ${uri.host}\r\n'
        '$authHeader'
        'User-Agent: HeaNetwork\r\n'
        'Accept: application/json, text/plain\r\n'
        'Proxy-Connection: close\r\n'
        'Connection: close\r\n\r\n';
    _writeAll(raw, utf8.encode(getReq));
    final responseBytes = await _readHttpResponse(raw, remaining());
    return _resultFromBytes(uri.host, watch.elapsed, responseBytes);
  } on Object catch (e) {
    return AntigravityCheckResult(
      host: uri.host,
      elapsed: watch.elapsed,
      error: '$e',
    );
  } finally {
    await sub?.cancel();
    tunnel?.close();
    raw?.close();
  }
}

void _writeAll(RawSocket socket, List<int> bytes) {
  var offset = 0;
  while (offset < bytes.length) {
    final written = socket.write(bytes, offset);
    if (written <= 0) break;
    offset += written;
  }
}

Future<List<int>> _readHttpResponse(RawSocket socket, Duration timeout) {
  final done = Completer<List<int>>();
  final buf = <int>[];
  late StreamSubscription<RawSocketEvent> sub;
  sub = socket.listen(
    (event) {
      if (event == RawSocketEvent.read) {
        final chunk = socket.read();
        if (chunk != null) {
          final room = 65536 - buf.length;
          if (room > 0) buf.addAll(chunk.take(room));
          if (buf.length >= 65536 && !done.isCompleted) {
            sub.cancel();
            done.complete(buf);
          }
        }
      } else if (event == RawSocketEvent.readClosed ||
          event == RawSocketEvent.closed) {
        if (!done.isCompleted) {
          sub.cancel();
          done.complete(buf);
        }
      }
    },
    onError: (Object e) {
      if (!done.isCompleted) {
        sub.cancel();
        done.completeError(e);
      }
    },
  );
  return done.future.timeout(
    timeout,
    onTimeout: () {
      sub.cancel();
      if (_indexOfHeaderEnd(buf) >= 0) return buf;
      throw TimeoutException('HTTP response timed out', timeout);
    },
  );
}

int _indexOfHeaderEnd(List<int> buf) {
  for (var i = 0; i <= buf.length - 4; i++) {
    if (buf[i] == 13 &&
        buf[i + 1] == 10 &&
        buf[i + 2] == 13 &&
        buf[i + 3] == 10) {
      return i;
    }
  }
  return -1;
}

int? _parseStatusCode(String headers) {
  final firstLine = headers.split('\r\n').first;
  final parts = firstLine.split(' ');
  return parts.length >= 2 ? int.tryParse(parts[1]) : null;
}

AntigravityCheckResult _resultFromBytes(
  String host,
  Duration elapsed,
  List<int> bytes,
) {
  final end = _indexOfHeaderEnd(bytes);
  if (end < 0) {
    return AntigravityCheckResult(
      host: host,
      elapsed: elapsed,
      error: 'Incomplete HTTP response',
    );
  }
  final head = latin1.decode(bytes.sublist(0, end));
  final status = _parseStatusCode(head);
  final body =
      utf8.decode(bytes.sublist(end + 4), allowMalformed: true).toLowerCase();
  return AntigravityCheckResult(
    host: host,
    elapsed: elapsed,
    statusCode: status,
    proxyAuthFailed: status == HttpStatus.proxyAuthenticationRequired,
    regionBlocked:
        status == 400 && body.contains('user location is not supported'),
  );
}
