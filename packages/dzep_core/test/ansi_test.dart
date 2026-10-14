import 'package:dzep_core/ansi.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final c = TermColors.fallback;

  test('truecolor in kitty colon form and in semicolon form', () {
    final spans = ansiSpans('\x1b[38:2:0:180:255ma\x1b[38;2;1;2;3;48;5;196mb\x1b[0mc', c);
    expect(spans.map((s) => s.text).join(), 'abc');
    expect(spans[0].style!.color, const Color(0xFF00B4FF));
    expect(spans[1].style!.color, const Color(0xFF010203));
    expect(spans[1].style!.backgroundColor, c.palette[196]);
    expect(spans[2].style!.color, c.foreground);
    expect(spans[2].style!.backgroundColor, isNull);
  });

  test('attributes on and off, basic and bright colors', () {
    final spans = ansiSpans('\x1b[1;31ma\x1b[22;39;94mb', c);
    expect(spans[0].style!.fontWeight, FontWeight.bold);
    expect(spans[0].style!.color, c.palette[1]);
    expect(spans[1].style!.fontWeight, isNull);
    expect(spans[1].style!.color, c.palette[12]);
  });

  test('hyperlinks, prompt marks and other escapes leave only their text', () {
    final spans = ansiSpans('\x1b]133;A\x1b\\\x1b]8;id=1;file:///x\x1b\\link\x1b]8;;\x1b\\ \x1b[2Kend', c);
    expect(spans.map((s) => s.text).join(), 'link end');
  });

  test('escapes with intermediates (a charset choice, ESC ( B) leave nothing', () {
    final spans = ansiSpans('\x1b(B\x1b[32ma\x1b(0\x1b#8b\x1b7c', c);
    expect(spans.map((s) => s.text).join(), 'abc');
    expect(spans.first.style!.color, c.palette[2]);
  });
}
