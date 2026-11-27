import 'dart:math' show max, min;

import 'package:xterm/xterm.dart';

class _HighlightRule {
  const _HighlightRule(this.pattern, this.color);

  final RegExp pattern;
  final int color;
}

/// Termius-style client-side keyword and data highlighter operating directly on
/// [Terminal.buffer] cells.
///
/// Highlights IPv4/IPv6/MAC addresses, errors/failures, and warnings/confirmations
/// even when the remote server outputs plain text or echoes keystrokes one by
/// one, while leaving server-supplied ANSI colors and alternate-screen TUI apps
/// (`vim`, `htop`, `nano`) untouched.
class SshTerminalHighlighter {
  static const _colorIp = CellColor.named | NamedColor.brightMagenta;
  static const _colorError = CellColor.named | NamedColor.brightRed;
  static const _colorHighlight = CellColor.named | NamedColor.brightYellow;

  static final _rules = <_HighlightRule>[
    // IPv4 (with valid 0..255 octets and optional /CIDR)
    _HighlightRule(
      RegExp(
        r'(?<![0-9.])(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}'
        r'(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(?:/(?:3[0-2]|[12]?\d))?(?![0-9.])',
      ),
      _colorIp,
    ),
    // MAC address (aa:bb:cc:dd:ee:ff)
    _HighlightRule(
      RegExp(
        r'\b(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}\b',
      ),
      _colorIp,
    ),
    // Errors, failures, negative states
    _HighlightRule(
      RegExp(
        r'\b(?:error|errors|err|fail|failed|failure|fatal|critical|crit|'
        r'denied|refused|forbidden|exception|panic|killed|invalid|timeout|'
        r'offline|down|dead|stopped|inactive|disabled|false)\b',
        caseSensitive: false,
      ),
      _colorError,
    ),
    // Warnings & affirmative/status highlights (matches Termius defaults like "Yes")
    _HighlightRule(
      RegExp(
        r'\b(?:yes|true|ok|active|running|enabled|connected|success|'
        r'succeeded|passed|online|healthy|warn|warning|caution|deprecated|'
        r'notice|pending)\b',
        caseSensitive: false,
      ),
      _colorHighlight,
    ),
  ];

  // Tracks cells colored by this highlighter per BufferLine so edits/backspaces
  // restore them cleanly without touching server-set ANSI colors. GC cleans up
  // automatically when lines leave scrollback.
  final _applied = Expando<Map<int, int>>('ssh_hl');

  /// Writes [text] to [terminal] and highlights affected lines when [enabled].
  void writeAndHighlight(
    Terminal terminal,
    String text, {
    required bool enabled,
  }) {
    final beforeHeight = terminal.buffer.height;
    final beforeY = terminal.buffer.absoluteCursorY;
    terminal.write(text);
    if (!enabled || terminal.isUsingAltBuffer) return;

    final buf = terminal.buffer;
    final afterY = buf.absoluteCursorY;
    final grew = (buf.height - beforeHeight).clamp(0, buf.height);
    // Cap per-chunk scan to avoid slowing down huge `cat` dumps.
    // ponytail: 200-line window per chunk; increase if users paste >200 lines at once.
    final rawStart = min(beforeY, afterY) - grew - 1;
    final end = min(buf.height - 1, max(beforeY, afterY));
    final start = max(0, max(rawStart, end - 200));

    var changed = false;
    for (var y = start; y <= end; y++) {
      if (_highlightLine(buf.lines[y])) changed = true;
    }
    if (changed) terminal.notifyListeners();
  }

  /// Re-applies highlighting to all lines currently in the main buffer.
  void highlightAll(Terminal terminal) {
    if (terminal.isUsingAltBuffer) return;
    final buf = terminal.buffer;
    var changed = false;
    for (var y = 0; y < buf.height; y++) {
      if (_highlightLine(buf.lines[y])) changed = true;
    }
    if (changed) terminal.notifyListeners();
  }

  /// Removes only colors added by this highlighter, preserving server ANSI colors.
  void clearAll(Terminal terminal) {
    final buf = terminal.buffer;
    var changed = false;
    for (var y = 0; y < buf.height; y++) {
      final line = buf.lines[y];
      final prev = _applied[line];
      if (prev == null || prev.isEmpty) continue;
      for (final e in prev.entries) {
        if (e.key < line.length && line.getForeground(e.key) == e.value) {
          line.setForeground(e.key, CellColor.normal);
          changed = true;
        }
      }
      _applied[line] = null;
    }
    if (changed) terminal.notifyListeners();
  }

  bool _highlightLine(BufferLine line) {
    var changed = false;
    final prev = _applied[line];
    if (prev != null) {
      for (final e in prev.entries) {
        if (e.key < line.length && line.getForeground(e.key) == e.value) {
          line.setForeground(e.key, CellColor.normal);
          changed = true;
        }
      }
      _applied[line] = null;
    }

    // Build visible line text and map UTF-16 code unit offsets to cell columns.
    final sb = StringBuffer();
    final colOfUnit = <int>[];
    var lastNonSpaceUnits = 0;
    for (var col = 0; col < line.length; col++) {
      final cp = line.getCodePoint(col);
      if (cp == 0) {
        // Wide-char trailing cell has width 0; empty trailing cells are spaces.
        if (line.getWidth(col) == 0) continue;
        sb.writeCharCode(0x20);
        colOfUnit.add(col);
        continue;
      }
      final ch = String.fromCharCode(cp);
      sb.write(ch);
      for (var k = 0; k < ch.length; k++) {
        colOfUnit.add(col);
      }
      if (cp != 0x20) lastNonSpaceUnits = colOfUnit.length;
    }
    if (lastNonSpaceUnits == 0) return changed;

    final text = sb.toString().substring(0, lastNonSpaceUnits);
    final nextApplied = <int, int>{};

    for (final rule in _rules) {
      for (final m in rule.pattern.allMatches(text)) {
        for (var u = m.start; u < m.end; u++) {
          final col = colOfUnit[u];
          if (nextApplied.containsKey(col)) continue;
          // Only tint cells using the terminal default foreground.
          if (line.getForeground(col) != CellColor.normal) continue;
          line.setForeground(col, rule.color);
          nextApplied[col] = rule.color;
          changed = true;
        }
      }
    }

    if (nextApplied.isNotEmpty) {
      _applied[line] = nextApplied;
    }
    return changed;
  }
}
