import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/profile.dart';
import '../parsers/import_parser.dart';
import '../parsers/link_utils.dart';

/// Why a subscription could not be loaded. [code] is stable and meant for
/// the UI to translate; [message] is the technical detail.
class SubscriptionException implements Exception {
  SubscriptionException(this.message, {this.code = SubscriptionError.other});
  final String message;
  final SubscriptionError code;
  @override
  String toString() => message;
}

enum SubscriptionError {
  other,

  /// The panel limits devices per subscription and this one does not fit.
  deviceLimit,

  /// The panel requires a device id and none was sent.
  deviceIdRequired,
}

class SubscriptionResult {
  SubscriptionResult(
    this.profiles, {
    this.title,
    this.upload,
    this.download,
    this.total,
    this.expire,
    this.updateIntervalHours,
    this.supportUrl,
    this.webPageUrl,
    this.announce,
    this.skipped = 0,
  });

  final List<ProxyProfile> profiles;

  /// From the `profile-title` header.
  final String? title;
  final int? upload;
  final int? download;
  final int? total;
  final DateTime? expire;

  /// `profile-update-interval`, in hours.
  final int? updateIntervalHours;
  final String? supportUrl;
  final String? webPageUrl;
  final String? announce;

  /// Entries of the body that were not usable.
  final int skipped;
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

/// Header text that panels send either plain, percent-encoded or as
/// `base64:<utf-8>`.
String? decodeHeaderText(String? header) {
  if (header == null || header.trim().isEmpty) return null;
  final h = header.trim();
  final text =
      h.startsWith('base64:') ? tryBase64(h.substring(7)) : decodeComponent(h);
  final clean = text?.trim();
  return clean == null || clean.isEmpty ? null : clean;
}

String? _url(String? header) {
  final v = header?.trim();
  if (v == null || !RegExp(r'^https?://', caseSensitive: false).hasMatch(v)) {
    return null;
  }
  return v;
}

/// Downloads and parses a subscription.
///
/// [deviceHeaders] identify this device to the panel (see `DeviceIdentity`);
/// a panel with a device limit refuses requests that lack them.
Future<SubscriptionResult> fetchSubscription(
  String url, {
  http.Client? client,
  String userAgent = 'HeaNetwork',
  Map<String, String> deviceHeaders = const {},
}) async {
  final c = client ?? http.Client();
  try {
    final http.Response res;
    try {
      res = await c.get(Uri.parse(url), headers: {
        'User-Agent': userAgent,
        'Accept': '*/*',
        ...deviceHeaders,
      }).timeout(const Duration(seconds: 25));
    } on FormatException {
      throw SubscriptionException('invalid URL');
    }

    // 3x-ui answers a refused device with 404 plus one of these markers.
    final h = res.headers;
    if (h['x-hwid-max-devices-reached'] == 'true' || h['x-hwid-limit'] == 'true') {
      throw SubscriptionException('device limit reached',
          code: SubscriptionError.deviceLimit);
    }
    if (h['x-hwid-not-supported'] == 'true') {
      throw SubscriptionException('the server requires a device id',
          code: SubscriptionError.deviceIdRequired);
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
    final info = parseUserInfo(h['subscription-userinfo']);
    final expire = info['expire'];
    final interval = int.tryParse(h['profile-update-interval']?.trim() ?? '');
    return SubscriptionResult(
      parsed.profiles,
      title: decodeHeaderText(h['profile-title']),
      upload: info['upload'],
      download: info['download'],
      total: info['total'],
      expire: expire == null || expire == 0
          ? null
          : DateTime.fromMillisecondsSinceEpoch(expire * 1000),
      updateIntervalHours: interval != null && interval > 0 ? interval : null,
      supportUrl: _url(h['support-url']),
      webPageUrl: _url(h['profile-web-page-url']),
      announce: decodeHeaderText(h['announce']),
      skipped: parsed.errors.length,
    );
  } finally {
    if (client == null) c.close();
  }
}
