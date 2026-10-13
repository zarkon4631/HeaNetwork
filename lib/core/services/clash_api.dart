import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// A fresh secret for the core's API. Without it the API answers nobody, so
/// no other program on the machine can steer the connection.
String newApiSecret() {
  final random = Random.secure();
  return List.generate(24, (_) => random.nextInt(16).toRadixString(16)).join();
}

class TrafficSample {
  const TrafficSample(this.up, this.down);

  /// Bytes per second.
  final int up;
  final int down;
}

/// Client for the core's Clash-compatible REST API on loopback.
class ClashApi {
  ClashApi(this.port, this.secret);

  final int port;
  final String secret;
  final _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 3)
    // The API lives on loopback; a system proxy must never be in the way.
    ..findProxy = (_) => 'DIRECT';

  Uri _uri(String path, [Map<String, String>? query]) => Uri(
      scheme: 'http', host: '127.0.0.1', port: port, path: path, queryParameters: query);

  Future<HttpClientResponse> _send(String method, Uri uri) async {
    final req = await _http.openUrl(method, uri);
    req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $secret');
    return req.close();
  }

  Future<bool> ping() async {
    try {
      final res = await _send('GET', _uri('/version'))
          .timeout(const Duration(seconds: 2));
      await res.drain<void>();
      return res.statusCode == 200;
    } on Object {
      return false;
    }
  }

  /// One sample per second until the listener cancels or the core stops.
  /// Simply ends, without an error, when the core or this client goes away:
  /// a disconnect right after connecting can close the client before the
  /// request is even sent.
  Stream<TrafficSample> traffic() async* {
    try {
      final res = await _send('GET', _uri('/traffic'));
      await for (final line
          in res.transform(utf8.decoder).transform(const LineSplitter())) {
        if (line.isEmpty) continue;
        final Object? j;
        try {
          j = jsonDecode(line);
        } on FormatException {
          continue;
        }
        if (j is! Map) continue;
        yield TrafficSample(
            (j['up'] as num?)?.toInt() ?? 0, (j['down'] as num?)?.toInt() ?? 0);
      }
    } on StateError {
      return;
    } on IOException {
      return;
    }
  }

  /// The connections open right now: id, the outbounds each one goes
  /// through, and the bytes it has carried so far. Null when the core does
  /// not answer.
  Future<List<({String id, List<String> chains, int up, int down})>?>
      connections() async {
    try {
      final res =
          await _send('GET', _uri('/connections')).timeout(const Duration(seconds: 3));
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode != 200) return null;
      final list = (jsonDecode(body) as Map)['connections'] as List? ?? const [];
      return [
        for (final c in list.whereType<Map>())
          (
            id: '${c['id']}',
            chains: [for (final x in c['chains'] as List? ?? const []) '$x'],
            up: (c['upload'] as num?)?.toInt() ?? 0,
            down: (c['download'] as num?)?.toInt() ?? 0,
          ),
      ];
    } on Object {
      return null;
    }
  }

  /// Round-trip time of an HTTP request through outbound [tag], in ms.
  /// Returns -1 when the outbound cannot reach [url].
  Future<int> delay(String tag,
      {required String url, int timeoutMs = 5000}) async {
    try {
      final res = await _send(
        'GET',
        _uri('/proxies/${Uri.encodeComponent(tag)}/delay',
            {'url': url, 'timeout': '$timeoutMs'}),
      ).timeout(Duration(milliseconds: timeoutMs + 2000));
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode != 200) return -1;
      return ((jsonDecode(body) as Map)['delay'] as num?)?.toInt() ?? -1;
    } on Object {
      return -1;
    }
  }

  Future<void> closeAllConnections() async {
    try {
      final res = await _send('DELETE', _uri('/connections'))
          .timeout(const Duration(seconds: 3));
      await res.drain<void>();
    } on Object {
      // Best effort.
    }
  }

  void close() => _http.close(force: true);
}
