import 'package:flutter/painting.dart';

/// A terminal's colors: default foreground and background plus the 256-color
/// palette, as the terminal reports them (kitty's `get-colors`, iTerm2's profile).
class TermColors {
  const TermColors({required this.foreground, required this.background, required this.palette});

  factory TermColors.fromJson(Map<String, dynamic> j) => TermColors(
    foreground: Color(0xFF000000 | (j['fg'] as int)),
    background: Color(0xFF000000 | (j['bg'] as int)),
    palette: [for (final c in j['palette'] as List) Color(0xFF000000 | (c as int))],
  );

  /// The xterm defaults, until the Mac has sent the terminal's.
  static final fallback = TermColors(
    foreground: const Color(0xFFDDDDDD),
    background: const Color(0xFF000000),
    palette: [for (var i = 0; i < 256; i++) xterm(i)],
  );

  final Color foreground;
  final Color background;
  final List<Color> palette;

  /// xterm's 256 colors: 16 basic, a 6×6×6 cube, 24 greys.
  static Color xterm(int i) {
    const basic = [
      0x000000, 0xCD0000, 0x00CD00, 0xCDCD00, 0x0000EE, 0xCD00CD, 0x00CDCD, 0xE5E5E5, //
      0x7F7F7F, 0xFF0000, 0x00FF00, 0xFFFF00, 0x5C5CFF, 0xFF00FF, 0x00FFFF, 0xFFFFFF,
    ];
    if (i < 16) return Color(0xFF000000 | basic[i]);
    if (i < 232) {
      int level(int v) => v == 0 ? 0 : 55 + v * 40;
      final n = i - 16;
      return Color.fromARGB(255, level(n ~/ 36), level(n ~/ 6 % 6), level(n % 6));
    }
    final g = 8 + (i - 232) * 10;
    return Color.fromARGB(255, g, g, g);
  }
}

class _Pen {
  Color? fg;
  Color? bg;
  bool bold = false;
  bool dim = false;
  bool italic = false;
  bool underline = false;
  bool strike = false;
  bool reverse = false;

  void reset() {
    fg = bg = null;
    bold = dim = italic = underline = strike = reverse = false;
  }

  TextStyle style(TermColors c) {
    var f = fg ?? c.foreground;
    var b = bg;
    if (reverse) (f, b) = (b ?? c.background, f);
    if (dim) f = f.withValues(alpha: .6);
    return TextStyle(
      color: f,
      backgroundColor: b,
      fontWeight: bold ? FontWeight.bold : null,
      fontStyle: italic ? FontStyle.italic : null,
      decoration: underline
          ? TextDecoration.underline
          : strike
          ? TextDecoration.lineThrough
          : null,
    );
  }
}

final _escape = RegExp(
  // SGR, other CSI, OSC (to BEL or ESC \), and any other escape: two bytes,
  // or more with intermediates (a charset choice, ESC ( B, as WezTerm sends).
  r'\x1b\[([0-9;:]*)m|\x1b\[[0-9;:?<=>]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[ -/]*[0-~]',
);

/// Terminal text with ANSI escapes as styled spans: SGR colors (16, 256 and
/// truecolor, `;` or kitty's `:` form) and attributes; every other escape
/// (hyperlinks, prompt marks) is dropped.
List<TextSpan> ansiSpans(String text, TermColors colors) {
  final spans = <TextSpan>[];
  final pen = _Pen();
  var at = 0;
  for (final m in _escape.allMatches(text)) {
    if (m.start > at) spans.add(TextSpan(text: text.substring(at, m.start), style: pen.style(colors)));
    at = m.end;
    final params = m[1];
    if (params != null) _sgr(params, pen, colors);
  }
  if (at < text.length) spans.add(TextSpan(text: text.substring(at), style: pen.style(colors)));
  return spans;
}

void _sgr(String params, _Pen pen, TermColors colors) {
  // `38:2:r:g:b` stays one group; `38;2;r;g;b` spreads over five.
  final groups = params.isEmpty ? ['0'] : params.split(';');
  for (var i = 0; i < groups.length; i++) {
    final parts = groups[i].split(':');
    final code = int.tryParse(parts.first) ?? 0;
    switch (code) {
      case 0:
        pen.reset();
      case 1:
        pen.bold = true;
      case 2:
        pen.dim = true;
      case 3:
        pen.italic = true;
      case 4:
        pen.underline = parts.length < 2 || parts[1] != '0';
      case 7:
        pen.reverse = true;
      case 9:
        pen.strike = true;
      case 22:
        pen
          ..bold = false
          ..dim = false;
      case 23:
        pen.italic = false;
      case 24:
        pen.underline = false;
      case 27:
        pen.reverse = false;
      case 29:
        pen.strike = false;
      case >= 30 && <= 37:
        pen.fg = colors.palette[code - 30];
      case 39:
        pen.fg = null;
      case >= 40 && <= 47:
        pen.bg = colors.palette[code - 40];
      case 49:
        pen.bg = null;
      case >= 90 && <= 97:
        pen.fg = colors.palette[code - 90 + 8];
      case >= 100 && <= 107:
        pen.bg = colors.palette[code - 100 + 8];
      case 38 || 48 || 58:
        final List<int?> args;
        if (parts.length > 1) {
          args = [for (final p in parts.skip(1)) int.tryParse(p)];
        } else {
          final mode = i + 1 < groups.length ? int.tryParse(groups[i + 1]) : null;
          final n = mode == 2 ? 4 : (mode == 5 ? 2 : 1);
          args = [for (final p in groups.skip(i + 1).take(n)) int.tryParse(p)];
          i += args.length;
        }
        final color = _extended(args, colors);
        if (code == 38) pen.fg = color;
        if (code == 48) pen.bg = color;
    }
  }
}

/// `5;n` or `2;[colorspace;]r;g;b`, without the leading 38/48.
Color? _extended(List<int?> args, TermColors colors) {
  if (args.isEmpty) return null;
  if (args.first == 5 && args.length > 1) {
    final n = args[1];
    return n != null && n >= 0 && n < colors.palette.length ? colors.palette[n] : null;
  }
  if (args.first == 2) {
    final rgb = args.length >= 5 ? args.sublist(args.length - 3) : args.skip(1).toList();
    if (rgb.length != 3) return null;
    return Color.fromARGB(255, rgb[0] ?? 0, rgb[1] ?? 0, rgb[2] ?? 0);
  }
  return null;
}
