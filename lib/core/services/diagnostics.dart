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
