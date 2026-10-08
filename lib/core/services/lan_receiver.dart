import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// Path prefix of pairing links, so a scanned QR can be told apart from a
/// subscription URL.
const pairingPath = '/hea/';

bool _isPrivate(InternetAddress a) {
  final b = a.rawAddress;
  if (b.length != 4) return false;
  return b[0] == 10 ||
      (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
      (b[0] == 192 && b[1] == 168);
}

/// Addresses of VPN tunnels (this app's and the sing-box default) look
/// private but are not reachable from other devices.
bool _isTunnel(String name, InternetAddress a) {
  final n = name.toLowerCase();
  final b = a.rawAddress;
  return n.startsWith('tun') ||
      n.contains('wintun') ||
      n.contains('sing') ||
      (b[0] == 172 && b[1] == 29 && b[2] == 117) ||
      (b[0] == 172 && b[1] == 19 && b[2] == 0);
}

/// Picks the address other devices on the local network can reach this one
/// at: a private IPv4 address of a real adapter, Wi-Fi or Ethernet first.
String? pickLanAddress(Iterable<(String name, InternetAddress address)> all) {
  final usable =
      all.where((e) => _isPrivate(e.$2) && !_isTunnel(e.$1, e.$2)).toList();
  if (usable.isEmpty) return null;
  int rank((String, InternetAddress) e) =>
      RegExp(r'wlan|wi-?fi|eth|беспровод', caseSensitive: false).hasMatch(e.$1) ? 0 : 1;
  usable.sort((a, b) => rank(a).compareTo(rank(b)));
  return usable.first.$2.address;
}

Future<String?> lanAddress() async {
  final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
  return pickLanAddress([
    for (final i in interfaces)
      for (final a in i.addresses) (i.name, a),
  ]);
}

/// True for a link produced by [LanReceiver], i.e. another device waiting
/// to be sent configurations.
bool isPairingUrl(String text) {
  final uri = Uri.tryParse(text.trim());
  return uri != null &&
      uri.scheme == 'http' &&
      uri.hasPort &&
      uri.path.startsWith(pairingPath) &&
      uri.path.length > pairingPath.length + 8;
}

/// Sends [text] (links, subscription URLs) to a device showing a pairing QR.
Future<void> sendToDevice(String pairingUrl, String text) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
  try {
    final request = await client.postUrl(Uri.parse(pairingUrl.trim()));
    request.headers.contentType =
        ContentType('application', 'x-www-form-urlencoded', charset: 'utf-8');
    request.write('text=${Uri.encodeQueryComponent(text)}');
    final response = await request.close().timeout(const Duration(seconds: 10));
    await response.drain<void>();
    if (response.statusCode != 200) {
      throw HttpException('device answered ${response.statusCode}');
    }
  } finally {
    client.close(force: true);
  }
}

/// A short-lived web page on the local network through which a phone can
/// hand this device a subscription: the device shows [url] as a QR code,
/// the phone opens it, pastes a link and submits.
///
/// The path carries a random token, so only someone who saw the QR can
/// submit, and the server exists only while the dialog is open.
class LanReceiver {
  LanReceiver._(this._server, this.url, this._token, this._russian) {
    _server.listen(_handle, onError: (_) {});
  }

  final HttpServer _server;
  final String url;
  final String _token;
  final bool _russian;
  final _received = StreamController<String>.broadcast();

  /// Text submitted from the phone.
  Stream<String> get received => _received.stream;

  static const _maxBody = 256 * 1024;

  /// Returns null when the device has no local network address.
  static Future<LanReceiver?> start({bool russian = true, String? address}) async {
    final host = address ?? await lanAddress();
    if (host == null) return null;
    final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    final random = Random.secure();
    final token =
        List.generate(20, (_) => random.nextInt(36).toRadixString(36)).join();
    return LanReceiver._(
        server, 'http://$host:${server.port}$pairingPath$token', token, russian);
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      if (request.uri.path != '$pairingPath$_token') {
        response.statusCode = HttpStatus.notFound;
        return;
      }
      response.headers.contentType = ContentType.html;
      response.headers.set('Cache-Control', 'no-store');
      if (request.method == 'GET') {
        response.write(_page(done: false));
        return;
      }
      if (request.method != 'POST') {
        response.statusCode = HttpStatus.methodNotAllowed;
        return;
      }
      final bytes = <int>[];
      var seen = 0;
      await for (final chunk in request) {
        seen += chunk.length;
        // Past the limit nothing is kept, but the rest is still read so the
        // sender gets a proper answer instead of a reset connection.
        if (seen <= _maxBody) bytes.addAll(chunk);
        if (seen > _maxBody * 32) break;
      }
      if (seen > _maxBody) {
        response.statusCode = HttpStatus.requestEntityTooLarge;
        return;
      }
      final body = utf8.decode(bytes, allowMalformed: true);
      final text = (Uri.splitQueryString(body)['text'] ?? body).trim();
      if (text.isNotEmpty) _received.add(text);
      response.write(_page(done: text.isNotEmpty));
    } on Object {
      response.statusCode = HttpStatus.badRequest;
    } finally {
      await response.close();
    }
  }

  String _page({required bool done}) {
    final t = _russian
        ? (
            title: 'HeaNetwork',
            lead: 'Вставьте ссылку подписки или сервера',
            hint: 'https://… , vless://… , vmess://… и другие',
            send: 'Отправить',
            done: 'Готово! Можно вернуться к телевизору.',
            more: 'Отправить ещё',
          )
        : (
            title: 'HeaNetwork',
            lead: 'Paste a subscription or server link',
            hint: 'https://… , vless://… , vmess://… and others',
            send: 'Send',
            done: 'Done! You can go back to the TV.',
            more: 'Send another',
          );
    final body = done
        ? '<p class="ok">${t.done}</p><p><a href="">${t.more}</a></p>'
        : '<form method="post"><p>${t.lead}</p>'
            '<textarea name="text" rows="7" placeholder="${t.hint}" required '
            'autofocus autocapitalize="off" autocorrect="off" spellcheck="false">'
            '</textarea><button type="submit">${t.send}</button></form>';
    return '<!doctype html><html lang="${_russian ? 'ru' : 'en'}"><head>'
        '<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
        '<title>${t.title}</title><style>'
        'body{margin:0;font:16px system-ui,sans-serif;background:#05060a;color:#e8ecf5;'
        'display:flex;min-height:100vh;align-items:center;justify-content:center}'
        'main{width:min(92vw,460px);padding:24px;border-radius:20px;background:#10131c;'
        'border:1px solid #232838}h1{margin:0 0 8px;font-size:22px}'
        'textarea{width:100%;box-sizing:border-box;margin:8px 0 14px;padding:12px;'
        'border-radius:12px;border:1px solid #2b3145;background:#090b11;color:inherit;font:inherit}'
        'button{width:100%;padding:14px;border:0;border-radius:12px;font:600 16px system-ui;'
        'color:#04122b;background:linear-gradient(135deg,#3b82f6,#22d3ee)}'
        '.ok{color:#2ee58f;font-weight:600}a{color:#6ea8ff}'
        '</style></head><body><main><h1>${t.title}</h1>$body</main></body></html>';
  }

  Future<void> close() async {
    await _server.close(force: true);
    await _received.close();
  }
}
