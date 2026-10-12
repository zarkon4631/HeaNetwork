import 'dart:convert';

class LinkParseException implements Exception {
  LinkParseException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// A server that is described correctly but needs something the core does
/// not have. [what] names it as `protocol:masque` or `transport:xdrive`.
class UnsupportedException extends LinkParseException {
  UnsupportedException(this.what) : super('unsupported ${what.replaceFirst(':', ': ')}');
  final String what;
}

/// Decodes standard or URL-safe base64, with or without padding.
/// Returns null when [input] is not base64.
String? tryBase64(String input) {
  var s = input.trim().replaceAll(RegExp(r'\s'), '');
  if (s.isEmpty || !RegExp(r'^[A-Za-z0-9+/_=-]+$').hasMatch(s)) return null;
  s = s.replaceAll('-', '+').replaceAll('_', '/').replaceAll('=', '');
  if (s.length % 4 == 1) return null;
  s = s.padRight(s.length + (4 - s.length % 4) % 4, '=');
  try {
    return utf8.decode(base64.decode(s), allowMalformed: true);
  } on FormatException {
    return null;
  }
}

String decodeComponent(String s) {
  try {
    return Uri.decodeComponent(s);
  } on ArgumentError {
    return s;
  }
}

const _descriptionMark = '?serverDescription=';

/// A share link split by hand. `Uri.parse` is avoided because it rejects
/// port ranges, lowercases case-sensitive parts and treats `+` as a space.
class RawLink {
  RawLink._(this.scheme, this.userInfo, this.host, this.portSpec, this.path,
      this.query, this.name, this.description);

  final String scheme;

  /// Percent-decoded text before the last `@`, or empty.
  final String userInfo;
  final String host;

  /// Raw port text, which hysteria2 may extend to `443,20000-30000`.
  final String portSpec;
  final String path;
  final Map<String, String> query;
  final String name;

  /// What the panel says about the server next to its name, if anything.
  final String? description;

  int get port {
    final m = RegExp(r'^\d+').firstMatch(portSpec);
    return m == null ? 0 : int.parse(m.group(0)!);
  }

  String? q(String key) {
    final v = query[key];
    return v == null || v.isEmpty ? null : v;
  }

  bool flag(String key) {
    final v = query[key]?.toLowerCase();
    return v == '1' || v == 'true';
  }

  static RawLink parse(String link) {
    final schemeEnd = link.indexOf('://');
    if (schemeEnd <= 0) throw LinkParseException('not a link');
    final scheme = link.substring(0, schemeEnd).toLowerCase();
    var rest = link.substring(schemeEnd + 3);

    var name = '';
    String? description;
    final hash = rest.indexOf('#');
    if (hash >= 0) {
      var fragment = rest.substring(hash + 1);
      // 3x-ui appends a host's description to the name, unescaped, as
      // `?serverDescription=<base64>`; a name that merely contains those
      // words arrives escaped and is left alone.
      final mark = fragment.lastIndexOf(_descriptionMark);
      if (mark >= 0) {
        final text = tryBase64(fragment.substring(mark + _descriptionMark.length))?.trim();
        if (text != null && text.isNotEmpty) {
          description = text;
          fragment = fragment.substring(0, mark);
        }
      }
      name = decodeComponent(fragment).trim();
      rest = rest.substring(0, hash);
    }

    var queryText = '';
    final qm = rest.indexOf('?');
    if (qm >= 0) {
      queryText = rest.substring(qm + 1);
      rest = rest.substring(0, qm);
    }

    var path = '';
    final at = rest.lastIndexOf('@');
    final slash = rest.indexOf('/', at < 0 ? 0 : at);
    if (slash >= 0) {
      path = rest.substring(slash);
      rest = rest.substring(0, slash);
    }

    final userInfo = at >= 0 ? decodeComponent(rest.substring(0, at)) : '';
    final authority = at >= 0 ? rest.substring(at + 1) : rest;

    String host;
    var portSpec = '';
    if (authority.startsWith('[')) {
      final close = authority.indexOf(']');
      if (close < 0) throw LinkParseException('bad IPv6 host');
      host = authority.substring(1, close);
      if (close + 1 < authority.length && authority[close + 1] == ':') {
        portSpec = authority.substring(close + 2);
      }
    } else {
      final colon = authority.lastIndexOf(':');
      if (colon >= 0) {
        host = authority.substring(0, colon);
        portSpec = authority.substring(colon + 1);
      } else {
        host = authority;
      }
    }

    return RawLink._(scheme, userInfo, host, portSpec, path,
        parseQuery(queryText), name, description);
  }
}

Map<String, String> parseQuery(String text) {
  final out = <String, String>{};
  for (final part in text.split('&')) {
    if (part.isEmpty) continue;
    final eq = part.indexOf('=');
    final key = decodeComponent(eq < 0 ? part : part.substring(0, eq));
    out[key] = eq < 0 ? '' : decodeComponent(part.substring(eq + 1));
  }
  return out;
}

/// Ports a QUIC client hops between, the way panels write them
/// (`20000-30000,40000`), as the core's ranges: `20000:30000`, `40000:40000`.
List<String> hopPortRanges(Iterable<String> specs) => [
      for (final spec in specs)
        for (final part in splitList(spec))
          part.contains(RegExp('[-:]')) ? part.replaceAll('-', ':') : '$part:$part',
    ];

List<String> splitList(String? v) => v == null
    ? const []
    : v.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

/// Drops nulls, empty strings, empty lists and empty maps, recursively,
/// so generated configs stay minimal.
Map<String, dynamic> compact(Map<String, dynamic> m) {
  final out = <String, dynamic>{};
  m.forEach((k, v) {
    if (v == null) return;
    if (v is String && v.isEmpty) return;
    if (v is List && v.isEmpty) return;
    if (v is Map) {
      final c = compact(Map<String, dynamic>.from(v));
      if (c.isEmpty) return;
      out[k] = c;
      return;
    }
    out[k] = v;
  });
  return out;
}
