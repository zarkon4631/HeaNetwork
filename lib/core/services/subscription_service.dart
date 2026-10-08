import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/profile.dart';
import '../parsers/import_parser.dart';
import '../parsers/link_utils.dart';

class SubscriptionException implements Exception {
  SubscriptionException(this.message);
  final String message;
  @override
  String toString() => message;
}

class SubscriptionResult {
  SubscriptionResult(this.profiles, {this.title, this.upload, this.download, this.total, this.expire});

  final List<ProxyProfile> profiles;

  /// From the `profile-title` header.
  final String? title;
  final int? upload;
  final int? download;
  final int? total;
  final DateTime? expire;
}

/// `upload=1; download=2; total=3; expire=1700000000`
Map<String, int> parseUserInfo(String? header) {
  final out = <String, int>{};
  if (header == null) return out;
  for (final part in header.split(';')) {
    final eq = part.indexOf('=');
    if (eq < 0) continue;
    final v = int.tryParse(part.substring(eq + 1).trim());
    if (v != null) out[part.substring(0, eq).trim().toLowerCase()] = v;
  }
  return out;
}

String? _decodeTitle(String? header) {
  if (header == null || header.isEmpty) return null;
  if (header.startsWith('base64:')) {
    return tryBase64(header.substring(7))?.trim();
  }
  return decodeComponent(header).trim();
}

Future<SubscriptionResult> fetchSubscription(
  String url, {
  http.Client? client,
  String userAgent = 'HeaNetwork',
}) async {
  final c = client ?? http.Client();
  try {
    final http.Response res;
    try {
      res = await c.get(Uri.parse(url), headers: {
        'User-Agent': userAgent,
        'Accept': '*/*',
      }).timeout(const Duration(seconds: 25));
    } on FormatException {
      throw SubscriptionException('invalid URL');
    }
    if (res.statusCode != 200) {
      throw SubscriptionException('server answered ${res.statusCode}');
    }
    final parsed = parseImportText(utf8.decode(res.bodyBytes, allowMalformed: true));
    if (parsed.profiles.isEmpty) {
      throw SubscriptionException(parsed.errors.isEmpty
          ? 'the subscription is empty'
          : parsed.errors.first);
    }
    final info = parseUserInfo(res.headers['subscription-userinfo']);
    final expire = info['expire'];
    return SubscriptionResult(
      parsed.profiles,
      title: _decodeTitle(res.headers['profile-title']),
      upload: info['upload'],
      download: info['download'],
      total: info['total'],
      expire: expire == null || expire == 0
          ? null
          : DateTime.fromMillisecondsSinceEpoch(expire * 1000),
    );
  } finally {
    if (client == null) c.close();
  }
}
