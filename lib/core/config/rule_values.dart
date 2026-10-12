import 'dart:io';

// Values that go into routing rules as they are, checked the way the core
// will check them. The core treats a single rule it cannot read as fatal and
// does not start, so whatever it would refuse must never reach it: a
// mistyped address in a panel's routing profile would otherwise cost the
// whole connection.

final _ipv4 = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$');
final _prefixLength = RegExp(r'^\d{1,3}$');

/// True when the core reads [value] as an address or a range of them:
/// `10.0.0.0/8`, `1.1.1.1`, `fe80::/10`.
bool isCoreAddress(String value) {
  final text = value.trim();
  final slash = text.indexOf('/');
  final host = slash < 0 ? text : text.substring(0, slash);
  final int maxBits;
  final v4 = _ipv4.firstMatch(host);
  if (v4 != null) {
    for (var i = 1; i <= 4; i++) {
      final part = v4.group(i)!;
      // No leading zeros either: the core will not guess whether 010 is
      // ten or eight.
      if (int.parse(part) > 255 || (part.length > 1 && part.startsWith('0'))) {
        return false;
      }
    }
    maxBits = 32;
  } else {
    if (!host.contains(':') || host.contains('%')) return false;
    if (InternetAddress.tryParse(host)?.type != InternetAddressType.IPv6) {
      return false;
    }
    maxBits = 128;
  }
  if (slash < 0) return true;
  final bits = text.substring(slash + 1);
  return _prefixLength.hasMatch(bits) && int.parse(bits) <= maxBits;
}

// Where this language's expressions and the core's (RE2) part ways: RE2 has
// no lookaround, no backreferences and no possessive quantifiers.
final _lookaround = RegExp(r'\(\?<?[=!]|\(\?>');
final _backreference = RegExp(r'(?<!\\)\\[1-9]|\\k<');
final _possessive = RegExp(r'(?<!\\)[*+?}]\+');
final _inlineFlags = RegExp(r'\(\?[imsU-]+\)');
final _scopedFlags = RegExp(r'\(\?[imsU-]+:');

/// True when the core's expression engine will compile [pattern].
///
/// A close check rather than an exact one, as only the core itself knows
/// for sure; [isRoutingComplaint] is there for what gets past this.
bool isCoreRegex(String pattern) {
  if (pattern.trim().isEmpty) return false;
  if (_lookaround.hasMatch(pattern) ||
      _backreference.hasMatch(pattern) ||
      _possessive.hasMatch(pattern)) {
    return false;
  }
  // Flags and named groups are spelled differently here, which says nothing
  // about whether the rest is well-formed.
  final probe = pattern
      .replaceAll(_inlineFlags, '')
      .replaceAll(_scopedFlags, '(?:')
      .replaceAll('(?P<', '(?<');
  try {
    RegExp(probe);
    return true;
  } on FormatException {
    return false;
  }
}

final _routingComplaint = RegExp(
    r'initialize (dns )?router|parse (dns )?rule|rule-set|rule_set',
    caseSensitive: false);

/// True when the reason the core gives for not starting is its routing:
/// a rule or a list of sites it could not read.
bool isRoutingComplaint(String message) => _routingComplaint.hasMatch(message);
