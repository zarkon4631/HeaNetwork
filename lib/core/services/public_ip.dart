import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../../platform/windows/win32.dart' as win32;
import 'latency_tester.dart' show isFakeIp;

/// Services that answer a plain GET with the caller's address as text.
/// Several are asked at once: any one of them may be unreachable.
const addressServices = [
  'https://api.ipify.org/',
  'https://ipv4.icanhazip.com/',
  'https://checkip.amazonaws.com/',
  'https://ifconfig.me/ip',
];

/// The headers that carry this device's address to a subscription server.
/// They are the ones a reverse proxy sets, so a server reads them the way
/// it reads any forwarded request, and takes the first address listed.
Map<String, String> addressHeaders(String? ip) =>
    ip == null ? const {} : {'X-Real-IP': ip, 'X-Forwarded-For': ip};

/// The address an address service answered with, or null when [body] is
/// something else (an error page, a captive portal).
String? parseAddress(String body) {
  for (final line in const LineSplitter().convert(body)) {
    final text = line.trim();
    if (!text.contains('.') && !text.contains(':')) continue;
    final address = InternetAddress.tryParse(text);
    if (address != null && !address.isLoopback && !isFakeIp(address)) {
      return address.address;
    }
  }
  return null;
}

/// Completes with the first answer that is not null, or with null once
/// every attempt has come back empty or failed.
Future<T?> firstAnswer<T extends Object>(Iterable<Future<T?>> attempts) {
  final done = Completer<T?>();
  var pending = 0;
  void settle(T? value) {
    pending--;
    if (done.isCompleted) return;
    if (value != null || pending == 0) done.complete(value);
  }

  for (final attempt in attempts.toList()) {
    pending++;
    unawaited(attempt.then(settle, onError: (Object _) => settle(null)));
  }
  if (pending == 0) done.complete(null);
  return done.future;
}

/// Asks one address [service] over a socket of its own, so that it can be
/// bound to [sourceAddress]: the real network adapter, which keeps the
/// request out of a VPN tunnel that has taken over the routing table.
/// Through the tunnel the answer would be the VPN server's address.
Future<String?> askAddressService(
  Uri service, {
  String? sourceAddress,
  Duration timeout = const Duration(seconds: 4),
}) async {
  // Whichever socket is open, for closing it however this ends.
  Socket? open;
  try {
    final found = await InternetAddress.lookup(service.host,
        type: InternetAddressType.IPv4);
    final target = found.where((a) => !isFakeIp(a)).firstOrNull;
    if (target == null) return null;
    final plain = await Socket.connect(target, 443,
        sourceAddress: sourceAddress, timeout: timeout);
    open = plain;
    final secure =
        await SecureSocket.secure(plain, host: service.host).timeout(timeout);
    open = secure;
    secure.write('GET ${service.path.isEmpty ? '/' : service.path} HTTP/1.1\r\n'
        'Host: ${service.host}\r\n'
        'User-Agent: HeaNetwork\r\n'
        'Accept: text/plain\r\n'
        'Connection: close\r\n\r\n');
    await secure.flush();
    final answer = await const Utf8Decoder(allowMalformed: true)
        .bind(secure)
        .join()
        .timeout(timeout);
    final split = answer.indexOf('\r\n\r\n');
    if (split < 0 || !answer.startsWith(RegExp(r'HTTP/1\.[01] 200'))) return null;
    return parseAddress(answer.substring(split + 4));
  } on Object {
    return null;
  } finally {
    open?.destroy();
  }
}

Future<String?> _socketLookup() {
  final source = Platform.isWindows ? win32.defaultRouteAddress() : null;
  return firstAnswer([
    for (final service in addressServices)
      askAddressService(Uri.parse(service), sourceAddress: source),
  ]);
}

/// On Android the request runs natively on the device's real network:
/// while the VPN is up, this app's own sockets go into the tunnel.
Future<String?> _androidLookup() async {
  try {
    final answer = await const MethodChannel('hea/core')
        .invokeMethod<String>('publicIp', {'urls': addressServices});
    return answer == null ? null : parseAddress(answer);
  } on MissingPluginException {
    return _socketLookup();
  } on PlatformException {
    return null;
  }
}

/// The address this device reaches the internet from, as the outside world
/// sees it. A subscription server normally reads it off the connection, but
/// cannot when it sits behind a proxy that hides it, or when the request
/// arrives through the VPN; so the app finds it out and sends it along.
class PublicIp {
  PublicIp(
    this._lookup, {
    this.maxAge = const Duration(minutes: 5),
    this.retryAfter = const Duration(minutes: 1),
    this.limit = const Duration(seconds: 5),
  });

  /// Asks the [addressServices], past any VPN tunnel.
  factory PublicIp.platform() =>
      PublicIp(Platform.isAndroid ? _androidLookup : _socketLookup);

  final Future<String?> Function() _lookup;

  /// How long an answer is reused: refreshing several subscriptions in a
  /// row asks once.
  final Duration maxAge;

  /// How long a failed lookup stands before the next try.
  final Duration retryAfter;

  /// The longest a lookup may hold up the request that waits for it.
  final Duration limit;

  String? _last;
  DateTime? _lastAt;
  Future<String?>? _running;

  /// The address, or null when it cannot be learnt right now. Never throws.
  Future<String?> current() {
    final at = _lastAt;
    if (at != null &&
        DateTime.now().difference(at) < (_last == null ? retryAfter : maxAge)) {
      return Future.value(_last);
    }
    return _running ??= _refresh();
  }

  Future<String?> _refresh() async {
    try {
      _last = await _lookup().timeout(limit);
    } on Object {
      _last = null;
    }
    _lastAt = DateTime.now();
    _running = null;
    return _last;
  }
}
