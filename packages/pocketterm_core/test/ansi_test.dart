import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketterm_core/ansi.dart';

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

  test('a cut-off OSC, CSI or lone ESC at the end leaks none of its bytes', () {
    for (final cut in ['\x1b]8;;https://example.com/a', '\x1b[38;2;1', '\x1b']) {
      expect(ansiSpans('text$cut', c).map((s) => s.text).join(), 'text', reason: cut);
    }
    // An OSC whose terminator never came, followed by the next escape.
    expect(ansiSpans('\x1b]0;title\x1b[31mred', c).map((s) => s.text).join(), 'red');
  });

  test("kitty's graphics (APC) and tmux passthrough (DCS) leave nothing of their payload", () {
    final spans = ansiSpans('a\x1b_Gf=100,a=T;iVBORw0KGgo=\x1b\\b\x1bPtmux;\x1b\x1b]52;c;eA==\x07\x1b\\c', c);
    expect(spans.map((s) => s.text).join(), 'abc');
  });

  test('private modes, keyboard modes and 256 colors with a missing index draw nothing', () {
    final spans = ansiSpans('\x1b[?2004h\x1b[>4;2m\x1b[=1;u\x1b[38;5ma\x1b[48;5;999mb', c);
    expect(spans.map((s) => s.text).join(), 'ab');
    expect(spans.last.style!.backgroundColor, isNull);
  });
}
