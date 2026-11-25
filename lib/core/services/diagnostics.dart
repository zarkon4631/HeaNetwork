/// What a user pastes into a support conversation: a short header plus the
/// recent log. Everything that could carry a credential is taken out of the
/// log first: UUIDs, keys and passwords, and the credentials in links and
/// subscription URLs. Hosts and addresses stay — they are what the answer
/// usually turns on.
library;

/// UUIDs of servers and clients appear in core output.
final _uuid = RegExp(
    r'\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b');

/// The credentials before `@` in a share link (`vless://…@host`).
final _linkCredentials =
    RegExp(r'\b(vless|vmess|trojan|ss|ssr|hy2|tuic)://[^\s@/]+@', caseSensitive: false);

/// `password: …` and its synonyms, also as `password=…`.
final _secretField = RegExp(
    r'\b(password|passwd|pwd|secret|private[-_ ]?key)(\s*[:=]\s*)(\S+)',
    caseSensitive: false);

/// An http(s) URL: scheme, authority, then path and query, scrubbed by
/// [_scrubUrl] down to what cannot identify or authenticate anyone.
final _url = RegExp(r'(https?://)([^\s/?#]+)([^\s]*)');

/// A path or query segment long enough to be a token rather than a page.
final _tokenSegment = RegExp(r'/[A-Za-z0-9_\-]{20,}');

String _scrubUrl(Match m) {
  var authority = m.group(2)!;
  var rest = m.group(3) ?? '';
  // userinfo: https://user:password@host
  final at = authority.lastIndexOf('@');
  if (at >= 0) authority = '[…]@${authority.substring(at + 1)}';
  // The query often holds tokens outright.
  final q = rest.indexOf('?');
  if (q >= 0) rest = '${rest.substring(0, q)}?[…]';
  // Subscription links put the token in the path.
  rest = rest.replaceAll(_tokenSegment, '/[…]');
  return '${m.group(1)}$authority$rest';
}

/// One log line, safe to show someone else.
String scrubLogLine(String line) {
  var out = line.replaceAllMapped(_linkCredentials, (m) => '${m.group(1)}://[…]@');
  out = out.replaceAllMapped(_url, _scrubUrl);
  out = out.replaceAll(_uuid, '[uuid]');
  out = out.replaceAll(_secretField, '${1}${2}[…]');
  return out;
}

/// What a line of the core's output means for the person reading it, where
/// the core's own words say too little.
enum LogHint {
  /// The reply did not prove to come from the Reality server: someone else
  /// answered. The core drops such a connection itself.
  reality,

  /// The server's address is this device itself, and nothing answered there.
  thisDevice,
}

final _realityFailure = RegExp('reality verification failed');

/// `dial tcp 127.0.0.1:443: …`, the address being any of the loopback ones.
final _dialLoopback =
    RegExp(r'dial tcp (?:127\.\d{1,3}\.\d{1,3}\.\d{1,3}|\[::1\]):\d+');

/// The [LogHint] for [line], or null when its words are enough as they are.
LogHint? logHintOf(String line) {
  if (_realityFailure.hasMatch(line)) return LogHint.reality;
  // "connection refused" on Linux and Android, "No connection could be
  // made" on Windows: nothing listens on that port.
  if (_dialLoopback.hasMatch(line) &&
      (line.contains('refused') || line.contains('No connection could be made'))) {
    return LogHint.thisDevice;
  }
  return null;
}

/// The report the diagnostics button copies: who the app is, how it runs,
/// and the end of the log with secrets scrubbed.
String diagnosticsReport({
  required String appVersion,
  required String platformLabel,
  required String modeLabel,
  required String statusLabel,
  List<String> log = const [],
  int maxLogLines = 300,
}) {
  final b = StringBuffer('HeaNetwork $appVersion')
    ..writeln()
    ..writeln('$platformLabel · $modeLabel · $statusLabel');
  if (log.isEmpty) return b.toString().trimRight();
  final lines =
      log.length > maxLogLines ? log.sublist(log.length - maxLogLines) : log;
  b
    ..writeln()
    ..writeln('--- log, last ${lines.length} line(s) ---');
  for (final line in lines) {
    b.writeln(scrubLogLine(line));
  }
  return b.toString().trimRight();
}
